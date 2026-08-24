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

int main(int argc, char **argv) {
  dvdnav_t *nav;
  uint8_t mem[DVD_VIDEO_LB_LEN];
  int finished = 0, parkno = 0, parked = 0, acted = 0;
  int wait_cells = 0, cells = 0;
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
          dump_screen(nav, ++parkno); parked = 1;
          int r = apply_action(nav);
          if (r == 0) { printf("\n[script done -> stop]\n"); finished = 1; }
          else if (r >= 2) { wait_cells = r - 2; parked = 0; }
          else { acted = 1; }
        }
      }
      if (blocks > 400000) { printf("[block cap]\n"); finished = 1; }
      break;
    case DVDNAV_STILL_FRAME: {
      dvdnav_still_event_t *s = (dvdnav_still_event_t *)buf;
      if (len == 0 && s->length == 0xff) { /* len field is in the event struct */ }
      if (s->length == 0xff) {                 /* indefinite still = a park */
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
