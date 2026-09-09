/* trace_nav.c -- scriptable interactive libdvdnav tracer.
 *
 * Boots the disc, plays through (auto-skipping finite/transition stills), and
 * PARKS whenever it reaches an interactive screen -- either an indefinite
 * (0xff) still OR a cell that carries PCI/HLI buttons (a looping video menu).
 * At each park it DUMPS the screen: current title/part (+ libdvdnav's own
 * "Video Title Domain: VTS/PGC" log line if the lib was built with tracing),
 * every button's rect + 8-byte command, and the forced-select/activate btns.
 *
 * A space-separated SCRIPT drives navigation, one token consumed per park:
 *   N     select button N and ACTIVATE it            (e.g. "2")
 *   .     leave this screen (dvdnav_still_skip)      -- pass a timed/idle still
 *   mR    dvdnav_menu_call(Root)      mT = Title
 *   wK    passive: let K more cell-changes pass before the next park is honored
 *
 * A button-bearing cell is only a PROVISIONAL park -- see the PROBATION note
 * above main() -- so it is confirmed before it is dumped or acted on.
 *
 * When the script is exhausted the tracer dumps the final park and exits, so
 *   trace_nav disc.iso ""          # just show the first interactive screen
 *   trace_nav disc.iso "2"         # press button 2 on the first screen, show next
 *   trace_nav disc.iso "2 1 3"     # walk three menus deep
 *
 * This is the ground-truth oracle for how a real DVD player authors Scene It's
 * interactive game screens (ring-select, timer, yes/no) -- decode the disc,
 * don't theorize (docs/conformance.md).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dvdnav/dvdnav.h"
#include "dvdnav/dvd_types.h"
#include "dvdread/ifo_types.h"
#include "vm/decoder.h"        /* registers_t */
#include "vm/vm.h"             /* dvd_state_t {domain,vtsN,pgcN,cellN,registers} */
#include "dvdnav_internal.h"   /* struct dvdnav_s { vm_t *vm; ... } */

/* Dump the internal VM state (domain/vts/pgc/cell + GPRMs) so the reach into a
 * freeze can be diffed against the RTL reader+VM. domain: 1=FP 2=VTS 4=VTSM
 * 8=VMGM (DVDDomain_t bitmask). */
static void dump_vm(dvdnav_t *nav, const char *tag) {
  vm_t *vm = nav->vm;
  if (!vm) return;
  dvd_state_t *s = &vm->state;
  printf("    VM[%s] dom=%d vtsN=%d pgcN=%d pgN=%d cellN=%d  SPRM4=%d SPRM5=%d  GPRM[",
         tag, (int)s->domain, s->vtsN, s->pgcN, s->pgN, s->cellN,
         s->registers.SPRM[4], s->registers.SPRM[5]);
  for (int i = 0; i < 16; i++)
    printf("%d%s", s->registers.GPRM[i], i < 15 ? "," : "");
  printf("]\n");
}

#define MAXTOK 64
static char  tok[MAXTOK][16];
static int   ntok = 0, tokidx = 0;

static void parse_script(const char *s) {
  if (!s) return;
  const char *p = s;
  while (*p && ntok < MAXTOK) {
    while (*p == ' ') p++;
    if (!*p) break;
    int n = 0;
    while (*p && *p != ' ' && n < 15) tok[ntok][n++] = *p++;
    tok[ntok][n] = 0; ntok++;
  }
}

static void dump_screen(dvdnav_t *nav, int parkno) {
  int32_t tt = -1, ptt = -1, pgcn = -1;
  dvdnav_current_title_info(nav, &tt, &ptt);
  dvdnav_current_title_program(nav, &tt, &pgcn, &ptt);
  pci_t *pci = dvdnav_get_current_nav_pci(nav);
  int nb = (pci && pci->hli.hl_gi.hli_ss) ? (pci->hli.hl_gi.btn_ns & 0x3f) : 0;
  printf("\n===== PARK #%d  title=%d part=%d  buttons=%d  fosl=%d foac=%d =====\n",
         parkno, tt, ptt, nb,
         pci ? (pci->hli.hl_gi.fosl_btnn & 0x3f) : 0,
         pci ? (pci->hli.hl_gi.foac_btnn & 0x3f) : 0);
  if (pci) printf("  nv_pck_lbn=%u (VOBU sector)\n", pci->pci_gi.nv_pck_lbn);
  if (nb) {
    hli_t *h = &pci->hli;
    printf("  hl_gi: btngr_ns=%d dsp_ty(g1)=%d  coli[grp1] sel=%08x act=%08x  "
           "[grp2] sel=%08x  (sel nibbles = [Ci3..Ci0 A3..A0])\n",
           h->hl_gi.btngr_ns, h->hl_gi.btngr1_dsp_ty,
           h->btn_colit.btn_coli[0][0], h->btn_colit.btn_coli[0][1],
           h->btn_colit.btn_coli[1][0]);
  }
  for (int i = 0; i < nb; i++) {
    btni_t *b = &pci->hli.btnit[i];
    unsigned char *c = (unsigned char *)&b->cmd;
    printf("  btn %2d: x%d..%d y%d..%d  u/d/l/r=%d/%d/%d/%d  auto=%d  cmd: "
           "%02x %02x %02x %02x %02x %02x %02x %02x\n",
           i + 1, b->x_start, b->x_end, b->y_start, b->y_end,
           b->up, b->down, b->left, b->right, b->auto_action_mode,
           c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]);
  }
  fflush(stdout);
}

/* Apply the next script token at a park. Returns 1 if we should keep going,
 * 0 if the script is exhausted (caller finishes after the final dump). */
static int apply_action(dvdnav_t *nav) {
  if (tokidx >= ntok) return 0;
  char *t = tok[tokidx++];
  pci_t *pci = dvdnav_get_current_nav_pci(nav);
  if (t[0] == '.') {
    printf(">> action: still_skip / leave screen\n");
    dvdnav_still_skip(nav);
  } else if (t[0] == 'm') {
    int which = (t[1] == 'T') ? DVD_MENU_Title : DVD_MENU_Root;
    printf(">> action: menu_call(%s)\n", which == DVD_MENU_Title ? "Title" : "Root");
    if (dvdnav_menu_call(nav, which) != DVDNAV_STATUS_OK)
      printf("   menu_call FAILED: %s\n", dvdnav_err_to_string(nav));
  } else if (t[0] == 'w') {
    /* passive wait handled by caller via return code marker */
    printf(">> action: wait %s cell-changes\n", t + 1);
    return 2 + atoi(t + 1);            /* encode wait count */
  } else {
    int n = atoi(t);
    printf(">> action: select+activate button %d\n", n);
    if (dvdnav_button_select_and_activate(nav, pci, n) != DVDNAV_STATUS_OK)
      printf("   button_select_and_activate FAILED: %s\n", dvdnav_err_to_string(nav));
  }
  return 1;
}

/* --- PROBATION: a cell with buttons is only a PROVISIONAL park -------------
 *
 * "A cell whose PCI carries buttons is an interactive screen" is a HEURISTIC,
 * and it is FALSE for a short authored clip that happens to carry an HLI. The
 * two are indistinguishable at the instant the buttons appear.
 *
 * MEASURED (SHERLOCK_HOLMES, VMGM PGC 26): cells=1, cell still=0, pbtime=9s,
 * POST = `HL_BTNN = button 4; LinkPGCN 15`. The disc AUTHORS a 9 s clip with a
 * highlight up which then links itself to PGC 15, whose cell still=255 -- the
 * real, indefinite menu still. Same shape on 24_DVD_BOARD_GAME, whose boot
 * VMGM PGC 2 is a 5-cell ~24 s intro with POST `JumpSS VTSM (vts 1, menu 4)`.
 *
 * Stopping at the first button-bearing cell cost twice over. It reported the
 * transient clip as the LANDING (making the board's correct 26 -> 15 look like
 * a divergence when the divergence was the tracer's), and it APPLIED THE NEXT
 * BUTTON THERE -- on a screen the board never sits on, so every step after it
 * compared two different walks.
 *
 * So a candidate is confirmed only when it behaves like a screen rather than a
 * clip. Confirmed by ANY of:
 *   - the VM reaching a STILL on it. A still is the picture STOPPING, which is
 *     exactly what the board's own park rule measures, and it counts whether
 *     the still is indefinite or FINITE: PAW_PATROL_MEET_EVEREST's VMGM PGC 14
 *     is one button with fosl=1 behind a 10 s still -- a screen the viewer
 *     really can press, which is why the tracer's blanket "auto-skip finite
 *     stills" must not apply while buttons are up;
 *   - the VM returning to the same (domain, vts, pgc, CELL) after a cell change
 *     -- a loop, which is what a looping video menu is and what a clip's cells
 *     never do (they ADVANCE, which is why the identity includes the cell: a
 *     multi-cell intro would otherwise read as a loop on its own pgc number);
 * ⛔ AND *NOT* "it survived a block budget". That arm was tried and REMOVED:
 * SHERLOCK_HOLMES VMGM PGC 13 is a 117 s clip (cells=1, still=0, pbtime=117s)
 * whose POST is `HL_BTNN = button 1; LinkPGCN 27`, and 117 s of video is far
 * more than any sane cap -- so the budget confirmed the clip as a park and the
 * board, which plays it out and lands on 27, was reported as diverging. Same
 * shape on SPEED RACER (title PGC 8 -> 13) and tomb_raider (1 -> 2).
 * A screen that never stills AND never loops is not a screen: every genuine
 * interactive park does one or the other, by construction. So a candidate that
 * does neither is simply never confirmed, the trace ends at the global block
 * cap with no park, and nav_diff reports the step as unreadable instead of
 * inventing a landing. An honest "I could not tell" beats a confident wrong
 * answer -- which is the whole reason this differential exists.
 * An indefinite (0xff) still needs no candidate at all: it is a park by
 * construction, so that path is unchanged.
 *
 * ⚠ Cheap in practice, because the question is normally settled at the
 * candidate cell's own END: PGC 26 resolves in its 211 sectors, PGC 15 in
 * its 88. */

int main(int argc, char **argv) {
  dvdnav_t *nav;
  uint8_t mem[DVD_VIDEO_LB_LEN];
  int finished = 0, parkno = 0, parked = 0, acted = 0;
  int wait_cells = 0, cells = 0;
  int cand_on = 0, cand_dom = -1, cand_vts = -1, cand_pgc = -1, cand_cell = -1;
  int cand_loops = 0;
  long cand_blocks = 0;
  long blocks = 0, blocks_in_cell = 0;

  if (argc < 2) { printf("usage: %s <iso> [\"script\"] [rnd_seed]\n", argv[0]); return 1; }
  parse_script(argc > 2 ? argv[2] : "");
  { const char *s = getenv("ATMOS_SEED");
    if (argc > 3) srand((unsigned)atoi(argv[3]));
    else if (s) srand((unsigned)atoi(s));
    printf(">> rnd seed = %s\n", argc > 3 ? argv[3] : (s ? s : "default(1)")); }
  if (dvdnav_open(&nav, argv[1]) != DVDNAV_STATUS_OK) { printf("open failed\n"); return 2; }
  dvdnav_set_readahead_flag(nav, 0);
  dvdnav_set_PGC_positioning_flag(nav, 1);

  while (!finished) {
    int event, len;
    uint8_t *buf = mem;
    if (dvdnav_get_next_block(nav, buf, &event, &len) == DVDNAV_STATUS_ERR) {
      printf("BLOCK ERR: %s\n", dvdnav_err_to_string(nav)); break;
    }
    switch (event) {
    case DVDNAV_BLOCK_OK:
      blocks++; blocks_in_cell++;
      /* looping VIDEO menu: a cell that carries buttons. Park once we've
       * played ~a VOBU into it (so the PCI is populated), if not waiting. */
      if (!parked && !acted && wait_cells == 0 && blocks_in_cell > 4) {
        pci_t *pci = dvdnav_get_current_nav_pci(nav);
        if (pci && pci->hli.hl_gi.hli_ss && (pci->hli.hl_gi.btn_ns & 0x3f)) {
          dvd_state_t *st = &nav->vm->state;
          if (!cand_on || st->domain != cand_dom || st->vtsN != cand_vts ||
              st->pgcN != cand_pgc || st->cellN != cand_cell) {
            cand_on = 1; cand_dom = st->domain; cand_vts = st->vtsN;
            cand_pgc = st->pgcN; cand_cell = st->cellN;
            cand_blocks = 0; cand_loops = 0;
          } else {
            cand_blocks++;      /* diagnostic only -- never confirms a park */
          }
          if (cand_loops > 0) {
            printf("[park confirmed: pgc %d cell %d looped]\n",
                   cand_pgc, cand_cell);
            cand_on = 0;
            dump_screen(nav, ++parkno); parked = 1;
            int r = apply_action(nav);
            if (r == 0) { printf("\n[script done -> stop]\n"); finished = 1; }
            else if (r >= 2) { wait_cells = r - 2; parked = 0; }
            else { acted = 1; }
          }
        }
      }
      if (blocks > 400000) { printf("[block cap]\n"); finished = 1; }
      break;
    case DVDNAV_STILL_FRAME: {
      dvdnav_still_event_t *s = (dvdnav_still_event_t *)buf;
      if (len == 0 && s->length == 0xff) { /* len field is in the event struct */ }
      if (s->length == 0xff) {                 /* indefinite still = a park */
        cand_on = 0;   /* a still is a park by construction; no probation */
        if (!parked) {
          dump_screen(nav, ++parkno); parked = 1;
          int r = apply_action(nav);
          if (r == 0) { printf("\n[script done -> stop]\n"); finished = 1; }
          else if (r >= 2) { wait_cells = r - 2; parked = 0; dvdnav_still_skip(nav); }
          else acted = 1;
        } else {
          /* already acted on this still; if the VM didn't leave, force it */
          dvdnav_still_skip(nav);
        }
      } else if (cand_on && !parked && nav->vm &&
                 nav->vm->state.domain == cand_dom &&
                 nav->vm->state.vtsN   == cand_vts &&
                 nav->vm->state.pgcN   == cand_pgc) {
        /* A FINITE still under a live candidate: the picture has stopped with
         * buttons up, so this is an interactive screen on a timer, not a
         * transition. Confirm it rather than skipping past it. */
        printf("[park confirmed: pgc %d  %ds still with buttons up]\n",
               cand_pgc, s->length);
        cand_on = 0;
        dump_screen(nav, ++parkno); parked = 1;
        int r = apply_action(nav);
        if (r == 0) { printf("\n[script done -> stop]\n"); finished = 1; }
        else if (r >= 2) { wait_cells = r - 2; parked = 0; dvdnav_still_skip(nav); }
        else acted = 1;
      } else {
        printf("[skip %ds still]\n", s->length);
        dvdnav_still_skip(nav);
      }
      break; }
    case DVDNAV_WAIT: dvdnav_wait_skip(nav); break;
    case DVDNAV_CELL_CHANGE: {
      int32_t tt = 0, ptt = 0; dvdnav_current_title_info(nav, &tt, &ptt);
      printf("[CELL #%d] title=%d part=%d  (blocks_in_prev_cell=%ld)\n",
             ++cells, tt, ptt, blocks_in_cell);
      dump_vm(nav, "cell");
      if (cand_on) {
        dvd_state_t *st = &nav->vm->state;
        if (st->domain == cand_dom && st->vtsN == cand_vts &&
            st->pgcN == cand_pgc && st->cellN == cand_cell)
          cand_loops++;      /* came back to the same cell -> a real loop */
      }
      blocks_in_cell = 0; parked = 0; acted = 0;
      if (wait_cells > 0) wait_cells--;
      if (cells > 4000) { printf("[cell cap]\n"); finished = 1; }
      break; }
    case DVDNAV_HIGHLIGHT: {
      dvdnav_highlight_event_t *h = (dvdnav_highlight_event_t *)buf;
      printf("[HIGHLIGHT -> button %d]\n", h->buttonN); break; }
    case DVDNAV_VTS_CHANGE: printf("[VTS_CHANGE]\n"); break;
    case DVDNAV_HOP_CHANNEL: printf("[HOP_CHANNEL]\n"); break;
    case DVDNAV_STOP: printf("[STOP]\n"); finished = 1; break;
    default: break;
    }
  }
  dvdnav_close(nav);
  return 0;
}
