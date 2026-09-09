#!/usr/bin/env python3
"""
nav_diff.py -- run the same button path through libdvdnav and the BOARD, and
diff where each one landed. Track E phase 2 of the HIL harness.

The soak test (tools/dvd_explore.py) can see a core that has CRASHED. It cannot
see a core that navigated somewhere WRONG, because a wrong menu looks exactly
like a right one. This closes that: it drives an independent implementation of
the DVD virtual machine with the identical input and compares the landing.

WHY libdvdnav AND NOT tools/dvd_vm_ref.py
`dvd_vm_ref.py` is this project's golden VM model and it is NOT the oracle for
this job. It was written from the RTL, so it holds the RTL's assumptions -- when
the POST-only PGC dispatcher bug was found (CLAUDE.md, 70 of 505 discs), the
model had the same wrong assumption and agreed with the hardware all the way
through. libdvdnav is the independent implementation; it is what settled that
bug, and it is what this diffs against. `dvd_vm_ref` is useful as a THIRD
opinion when the two disagree, never as the reference.

WHY THE BUTTON NUMBER IS THE UNIT
libdvdnav's script token `<N>` is dvdnav_button_select_and_activate(N), and the
core decodes a DIGIT KEY to exactly that (dvd/emu.sv: a digit press forces
nav_pci's selection to that button AND activates it). So both sides take the
SAME button number and there is no D-pad walk to reconcile -- a walk would make
any disagreement ambiguous between "wrong landing" and "different route".

WHAT THE BOARD CAN ACTUALLY TELL US
With `Debug Overlay=On`, the transport HUD's "CH n/N" field is repurposed as
{reader PGCN, VTS} (dvd/emu.sv). That is TWO of libdvdnav's five state fields --
pgN and cellN are not observable, and the domain only indirectly. So the
comparison is on PGCN (+ VTS where both sides are in a title domain), which is
the headline nav question: "did it land in the right PGC?" Every nav bug this
project has fixed would have shown up there.

Usage:
    nav_diff.py <disc> --script "w3 1 w2 2"      # explicit path
    nav_diff.py <disc> --auto 4                  # walk buttons automatically
    nav_diff.py --list                           # discs visible to both sides

Script tokens (a subset of trace_nav's, chosen because the board can do them):
    N     select+activate button N   (digit key)
    mR    root menu                  (Menu key)
    mT    title menu                 (Title key)
    wN    wait N settle periods
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mister as M              # noqa: E402
import hud_read as H            # noqa: E402

TRACE_NAV = os.path.join(HERE, 'bin', 'trace_nav')

# The disc library is one SMB share mounted in two places. Both sides must open
# the same bytes, so a run names one disc and each side resolves its own path.
LOCAL_ROOT = os.environ.get('DVD_ISO_DIR', os.path.expanduser('~/dvd-isos'))
BOARD_ROOT = os.environ.get('MISTER_ISO_DIR', '/media/fat/cifs/games/DVD')

# ⚠ DOCUMENTED DELIBERATE DEVIATION (CLAUDE.md, docs/dvd_vm.md "Boot-chain menu
# shortcut"): before any menu-domain PGC has loaded, the core sends the Menu key
# to best_menu_vts Root instead of the playing title's own VTSM Root, because on
# a DVD-game disc the latter is a dispatcher that can start a random clip.
# libdvdnav does the spec thing and lands elsewhere. A difference on the FIRST
# menu call of a session is therefore EXPECTED and must not be reported as a
# defect -- doing so would train the reader to ignore real ones.
# Consecutive identical (PGCN,VTS) readings, WITH the highlight armed, before
# the board is called settled. Measured: 1 was not enough (see board_park).
SETTLE_REPEATS = 2

BOOT_MENU_NOTE = ('first menu call of the session -- the core deliberately '
                  'targets best_menu_vts Root (boot-chain shortcut)')


# ---------------------------------------------------------------------------
# the independent oracle
# ---------------------------------------------------------------------------
def trace_landings(iso, script, seed=None):
    """Run libdvdnav over the script. -> [{'action', 'pgcn', 'vts', 'dom', ...}]

    The landing for an action is the VM state at the NEXT park -- a park is
    where libdvdnav waits for input, which is the same place the board's picture
    goes still. Comparing anywhere else compares mid-transition states.
    """
    if not os.path.exists(TRACE_NAV):
        sys.exit(f'nav_diff: {TRACE_NAV} not built')
    cmd = [TRACE_NAV, iso, script] + ([str(seed)] if seed is not None else [])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    out = p.stdout

    vm_re = re.compile(r'VM\[\w+\]\s+dom=(-?\d+)\s+vtsN=(-?\d+)\s+pgcN=(-?\d+)'
                       r'\s+pgN=(-?\d+)\s+cellN=(-?\d+)')
    park_re = re.compile(r'^===== PARK #(\d+)\s+title=(-?\d+)\s+part=(-?\d+)\s+'
                         r'buttons=(\d+)', re.M)
    act_re = re.compile(r'^>> action: (.+)$', re.M)

    events, last_vm = [], None
    for line in out.splitlines():
        m = vm_re.search(line)
        if m:
            last_vm = dict(dom=int(m.group(1)), vts=int(m.group(2)),
                           pgcn=int(m.group(3)), pg=int(m.group(4)),
                           cell=int(m.group(5)))
            continue
        m = park_re.match(line)
        if m:
            events.append(('park', dict(park=int(m.group(1)),
                                        buttons=int(m.group(4)),
                                        state=dict(last_vm or {}))))
            continue
        m = act_re.match(line)
        if m:
            events.append(('action', m.group(1).strip()))

    # Pair each action with the state at the park that FOLLOWS it, and remember
    # how many buttons existed at the park it was applied AT.
    #
    # ⚠ THAT SECOND NUMBER IS WHAT KEEPS THE COMPARISON HONEST. A run that
    # pressed button 2 at a park with buttons=1 produced a reproducible,
    # confident "difference" that was nothing of the kind: the board correctly
    # ignores a digit for a button that does not exist, libdvdnav does something
    # else with it, and neither is wrong because the input is undefined. Only
    # well-defined inputs can be diffed.
    #
    # ⚠ THE **LAST** PARK BEFORE THE NEXT ACTION IS THE LANDING, NOT THE FIRST.
    # For an intermediate action those are the same park (the next park spends
    # the next script token, so exactly one sits between two actions). They
    # differ only if the tracer emits more than one -- and then the later one is
    # the settled screen, which is what the board's own SETTLE_REPEATS rule
    # reports. Taking the first would compare a transient against a settled
    # state, which is the shape of every false difference this tool has produced.
    out_rows, pending, at_park, row_idx = [], None, None, None
    for kind, val in events:
        if kind == 'park':
            if pending is not None:
                row = dict(action=pending, applied_buttons=applied_at,
                           buttons=val['buttons'], **val['state'])
                if row_idx is None:
                    out_rows.append(row)
                    row_idx = len(out_rows) - 1
                else:
                    out_rows[row_idx] = row
            at_park = val['buttons']
        elif kind == 'action':
            pending = val
            applied_at = at_park       # buttons at the park it is applied AT
            row_idx = None
    if pending is not None and row_idx is None:   # script ended before a re-park
        tail = [v for k, v in events if k == 'park']
        st = tail[-1]['state'] if tail else {}
        out_rows.append(dict(action=pending, applied_buttons=applied_at,
                             buttons=0, **st))
    return out_rows, out


# ---------------------------------------------------------------------------
# the board
# ---------------------------------------------------------------------------
def board_landing(tmpdir, step):
    """Screenshot the board and read {PGCN, VTS} off the HUD. -> dict or None."""
    png = os.path.join(tmpdir, f'nav{step:03d}.png')
    try:
        rc, _ = M.ssh('''
rm -f /media/fat/screenshots/navd.png
echo 'screenshot navd.png' > /dev/MiSTer_cmd
for i in $(seq 1 20); do
  sleep 0.25
  if [ -f /media/fat/screenshots/navd.png ]; then
    a=$(stat -c %s /media/fat/screenshots/navd.png); sleep 0.2
    b=$(stat -c %s /media/fat/screenshots/navd.png)
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
exit 1
''', check=False)
    except subprocess.TimeoutExpired:
        # ⚠ A DROPPED SSH ROUND-TRIP IS NOT A NAVIGATION DIFFERENCE.
        # One 120 s timeout during a 24-disc sweep aborted the whole run
        # with a traceback, and the sweep driver scored that exit code as
        # a FINDING. A lost screenshot is a retry, not evidence.
        return None
    if rc != 0:
        return None
    r = subprocess.run(['scp', *M.SSH_OPTS, '-q',
                        f'{M.host()}:/media/fat/screenshots/navd.png', png],
                       capture_output=True)
    if r.returncode != 0:
        return None
    w, h, buf = H.load_image(png)
    frame = H.Frame(w, h, buf)
    res = H.decode(frame)
    if not res['status']['present'] or res.get('dbg_pgcn') is None:
        return None
    # O[2] block 1 is hl_btns_armed -- the board's exact equivalent of
    # libdvdnav's `buttons=N` at a park. Gated on menus_on, which the launch
    # sets; `None` means the block was not drawn, not that it read false.
    blk = H.read_blocks(frame)
    return dict(pgcn=res['dbg_pgcn'], vts=res['dbg_vts'],
                armed=blk['hl_btns_armed']['value'],
                still=blk['still_active']['value'],
                elapsed=res.get('elapsed'), total=res.get('total'),
                png=png)


def _secs(t):
    """'0:01:33' -> 93. None or unparseable -> None."""
    if not t:
        return None
    try:
        parts = [int(x) for x in t.split(':')]
    except ValueError:
        return None
    v = 0
    for q in parts:
        v = v * 60 + q
    return v


def board_park(tmpdir, step, settle, timeout=45, want_armed=True):
    """Wait until the board has PARKED, then read its landing.

    ⚠ A FIXED SLEEP IS NOT A PARK, and using one produced two confident false
    DIFFs on the first run: the board was still walking its boot chain (PGC
    90 -> 2 -> 1) while the script was already pressing buttons, so the tool
    compared the board's boot cells against libdvdnav's settled menu and called
    it a navigation defect. libdvdnav applies every action AT a park; the board
    must be at one too or the two are not comparable.

    ⛔ NOT "the picture stopped moving" -- that is how dvd_explore detects a
    still, and it is wrong here: a MOTION menu (MiB's root, Sherlock's) loops
    video forever and never freezes, so a picture-based detector would time out
    on exactly the discs with the most interesting navigation. The reader's
    {PGCN, VTS} settling is the signal that works for both kinds.

    ⚠ AND STABILITY ALONE IS NOT A PARK EITHER, which the second attempt
    proved: a First Play LOGO cell holds one PGCN for many seconds, so
    "same PGCN twice" declared a park at pgc=90 while the boot chain was still
    walking to pgc=1. A park is where the disc WAITS FOR INPUT. libdvdnav says
    so with `buttons=N`; the board says so with hl_btns_armed, which O[2]
    block 1 exposes -- so the two are asking the same question.
    ⚠ AND ONE REPEAT IS NOT SETTLED. A highlight stays armed from the PREVIOUS
    menu while the reader walks to the next PGC, so `armed` plus one repeat
    still fired mid-transition -- the board read the pass-through PGC while
    libdvdnav reported the PGC it came to rest in, one step further on. The
    trajectory is printed so this is visible rather than inferred.

    ★★ AND STABLE + ARMED IS STILL NOT A PARK -- THE FIFTH ATTEMPT, and it is
    the exact mirror of the defect fixed in trace_nav. A disc may author a
    TRANSIENT CLIP WITH A HIGHLIGHT UP: 24_DVD_BOARD_GAME boots into VMGM PGC 2,
    a ~24 s intro whose POST is `JumpSS VTSM (vts 1, menu 4)`, and holds one
    PGCN with buttons armed for the whole of it. Every rule above passes there,
    so the sweep pressed its button during the intro and reported the resulting
    mismatch as a navigation defect on SIX discs.

    MEASURED on the board (screenshots, 8 s apart, `Debug Overlay=On`):

        t= 8..32s   CH 2  0:04/0:24 -> 0:19/0:24, then 0:08/0:35 -> 0:22/0:35
        t=40..96s   CH 3  0:00/0:29 0:13 0:26 | 0:10 0:24 | 0:08 0:21 0:04

    PGC 3 is where it comes to rest, and the IFO says why: `cell_cmd=1 ->
    LinkPGN 1`, a cell that replays itself. libdvdnav settles there too.

    So a park is confirmed the same way the oracle confirms one -- BY A STILL OR
    BY A LOOP:
      - `still_active` (O[2] block 6) -- the reader parked on a still;
      - or the HUD clock WRAPPED with the total unchanged -- the cell replayed.
    ⚠ The total must be unchanged, or a multi-cell intro reads as a loop: PGC 2
    above resets its clock too, but its total moves 0:24 -> 0:35 because a new
    CELL started. A real loop replays the same cell, so the total holds.
    ⚠ Neither can be required alone: a still-only rule times out on a looping
    motion menu (the mistake in row 2 of this list), and a loop-only rule never
    fires on a menu still, whose clock does not run at all.
    A landing that reaches the timeout without either is returned FLAGGED
    (`unconfirmed`) rather than silently trusted.
    """
    deadline = time.time() + timeout
    prev, stable, traj = None, 0, []
    prev_el, prev_tot, looped = None, None, False
    got = None
    while time.time() < deadline:
        got = board_landing(tmpdir, step)
        if got is not None:
            key = (got['pgcn'], got['vts'])
            traj.append(f"{got['pgcn']}{'*' if got.get('armed') else ''}")
            el, tot = _secs(got.get('elapsed')), _secs(got.get('total'))
            if key == prev:
                stable += 1
                # a LOOP: the same cell replayed -- clock went backwards while
                # the cell's own length stayed put (see the docstring).
                if (el is not None and prev_el is not None and el < prev_el
                        and tot is not None and tot == prev_tot):
                    looped = True
            else:
                stable, looped = 0, False
            prev, prev_el, prev_tot = key, el, tot
            settled = got.get('still') is True or looped
            if ((got.get('armed') or not want_armed)
                    and stable >= SETTLE_REPEATS and settled):
                got['traj'] = traj
                got['why'] = 'still' if got.get('still') else 'loop'
                return got
        time.sleep(settle)
    if got is not None:
        got['traj'] = traj
        # Stable and armed but neither still nor looping: it may be a transient
        # clip that simply outlasted the budget. Say so instead of trusting it.
        got['unconfirmed'] = True
        got['unsettled'] = not (stable >= SETTLE_REPEATS and got.get('armed'))
    return got                               # best effort; caller reports it


def board_apply(token, settle):
    """Apply one script token on the board."""
    if token.startswith('w'):
        return 'wait'          # the park wait below IS the wait
    if token.startswith('m'):
        key = 'title' if token[1:2] == 'T' else 'menu'
        M.cmd_key(argparse.Namespace(names=[key]))
        return key
    M.cmd_key(argparse.Namespace(names=[token]))
    return f'button {token}'


# ---------------------------------------------------------------------------
def resolve(disc):
    """One disc name -> (local path, board path). Both sides must see it."""
    if os.path.isabs(disc) and os.path.exists(disc):
        local = disc
        rel = os.path.relpath(local, LOCAL_ROOT)
    else:
        rel = disc
        local = os.path.join(LOCAL_ROOT, rel)
    if not os.path.exists(local):
        sys.exit(f'nav_diff: no such disc locally: {local}')
    return local, os.path.join(BOARD_ROOT, rel)


def is_nondeterministic(iso, script):
    """Run the oracle twice under different RNG seeds. Different landings mean
    the disc's navigation uses `rnd`, and a differential cannot be trusted on it.

    ⚠ MEASURED, not parsed out of the command table: ATMOSFEAR's boot chain ends
    in `rnd 6; JumpTT 1` (CLAUDE.md), so the core's LFSR and libdvdnav's RNG
    disagree by design and every landing after that point is a coin flip. A
    sweep that reports those as defects is worse than one that skips the disc.
    """
    a, _ = trace_landings(iso, script, seed=1)
    b, _ = trace_landings(iso, script, seed=99)
    pa = [r.get('pgcn') for r in a]
    pb = [r.get('pgcn') for r in b]
    return pa != pb, pa, pb


def auto_script(iso, steps, seed):
    """Build a script of VALID button presses by asking the oracle, one step at
    a time.

    Which buttons exist depends on where you are, and where you are depends on
    which buttons you pressed -- so the script cannot be written up front. Each
    iteration runs libdvdnav over the script so far, reads how many buttons the
    park it ended at offers, and appends one that exists. That is also what
    keeps a sweep honest: a script generated this way never contains the
    undefined input that produced a false difference by hand.
    """
    import random
    rng = random.Random(seed)
    script = []
    for _ in range(steps):
        rows, raw = trace_landings(iso, ' '.join(script) if script else 'w1', seed)
        # buttons offered at the park we are sitting at now
        parks = re.findall(r'^===== PARK #\d+.*?buttons=(\d+)', raw, re.M)
        n = int(parks[-1]) if parks else 0
        if n < 1:
            break
        # ⚠ THE BOARD PRESSES BUTTONS WITH DIGIT KEYS, so only 1..9 exist:
        # `emu.sv` decodes ONE digit per key. A menu with more buttons made
        # auto_script emit `10`, which aborted the run on 4 of 24 discs in a
        # sweep -- and the driver scored the exit code as a finding.
        script.append(str(rng.randint(1, min(n, 9))))
    return script


def cmd_list():
    hits = []
    for dirpath, _, files in os.walk(LOCAL_ROOT):
        for f in files:
            if f.lower().endswith(('.iso',)):
                hits.append(os.path.relpath(os.path.join(dirpath, f), LOCAL_ROOT))
    for h in sorted(hits)[:60]:
        print('  ' + h)
    print(f'  ... {len(hits)} ISOs under {LOCAL_ROOT}')
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('disc', nargs='?')
    ap.add_argument('--auto', type=int, metavar='N',
                    help='derive an N-step script of VALID buttons from the oracle')
    ap.add_argument('--script', default='w2 1',
                    help='e.g. "w3 1 w2 2" (see the token table above)')
    ap.add_argument('--settle', type=float, default=3.0,
                    help='seconds the board is given to land after an action')
    ap.add_argument('--seed', type=int, help='rnd seed for libdvdnav')
    ap.add_argument('--boot-timeout', type=float, default=240.0,
                    help='seconds to reach the first armed park')
    ap.add_argument('--action-timeout', type=float, default=90.0,
                    help='seconds to re-park after an action')
    ap.add_argument('--out')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--red', type=int, metavar='N',
                    help='drive the board with button N instead, to prove the comparison can fail')
    ap.add_argument('--no-board', action='store_true',
                    help='oracle only -- no hardware needed')
    args = ap.parse_args()
    if args.list:
        return cmd_list()
    if not args.disc:
        ap.error('a disc is required (or --list)')

    local, board = resolve(args.disc)
    tmpdir = args.out or os.path.join(
        os.environ.get('TMPDIR', '/tmp'), f'navdiff_{time.strftime("%H%M%S")}')
    os.makedirs(tmpdir, exist_ok=True)
    if args.auto:
        tokens = auto_script(local, args.auto, args.seed or 1)
        if not tokens:
            print('nav_diff: the oracle found no button menu on this disc')
            return 2
    else:
        tokens = args.script.split()

    print(f'nav_diff: {os.path.basename(local)}')
    print(f'  script : {" ".join(tokens)}')
    print(f'  oracle : libdvdnav (independent of our RTL and of dvd_vm_ref)')

    nd, pa, pb = is_nondeterministic(local, ' '.join(tokens))
    if nd:
        print(f'\n  ⚠ THIS DISC IS NON-DETERMINISTIC: the oracle lands '
              f'{pa} under one RNG seed and {pb} under another.')
        print('    Its navigation uses `rnd`, so the core\'s LFSR and '
              "libdvdnav's RNG disagree BY DESIGN.")
        print('    A differential cannot be trusted here; skipping the board.')
        return 2

    oracle, raw = trace_landings(local, ' '.join(tokens), args.seed)
    open(os.path.join(tmpdir, 'trace_nav.txt'), 'w').write(raw)
    print(f'  libdvdnav produced {len(oracle)} landing(s)')
    for r in oracle:
        print(f'     {r["action"]:<34} -> dom={r.get("dom")} vts={r.get("vts")} '
              f'pgc={r.get("pgcn")} pg={r.get("pg")} cell={r.get("cell")}')
    if args.no_board:
        return 0

    print(f'\n  board  : launching {board}')
    M.cmd_launch(argparse.Namespace(
        image=board, opt=['Debug Overlay=On', 'Disc Menus=On',
                          'Video Output=Progressive'],
        delay=2, timeout=90, no_wait=False))
    time.sleep(8)

    # Reach the first park before touching anything, exactly as libdvdnav does.
    # ⚠ GENEROUSLY: libdvdnav walks the nav graph at CPU speed while the board
    # PLAYS every cell in real time, so a boot chain of logo cells that costs
    # libdvdnav milliseconds costs the board minutes. A 45 s budget expired
    # mid-chain and the run then compared the board's boot cells against
    # libdvdnav's settled menu, reporting two confident differences that were
    # entirely this tool's.
    start = board_park(tmpdir, 0, args.settle, timeout=args.boot_timeout)
    if start:
        print(f'    booted to pgc={start["pgcn"]} vts={start["vts"]}'
              f' ({start.get("why", "?")})'
              f'   trajectory: {" ".join(start.get("traj", []))}'
              + ('  [UNSETTLED]' if start.get('unsettled') else ''))
    else:
        print('    (no readable landing after boot)')

    # ⛔ REFUSE to compare from an unknown starting state. Every landing after an
    # unsettled boot is measured against a board that is somewhere else entirely,
    # and the differences are the harness's, not the core's.
    if (start is None or start.get('unsettled') or not start.get('armed')
            or start.get('unconfirmed')):
        print('\n  ABORT: the board never reached a CONFIRMED park within '
              f'{args.boot_timeout}s -- nothing to compare against.')
        print('    A park is confirmed by a still or by the cell looping; '
              'stable+armed alone is a transient clip with a highlight up.')
        print('    Either the boot chain is longer than the budget (raise '
              '--boot-timeout) or this disc does not present a button menu.')
        print('    Comparing from here would report the harness, not the core.')
        return 2

    rows, menu_calls = [], 0
    for i, tok in enumerate(tokens):
        # ⚠ RED PROOF. A differential that reports "no differences" is worth
        # nothing until it has been shown to report one. --red presses a
        # DIFFERENT button on the board than the oracle was given, so the two
        # must land apart; if this run comes back clean the comparison is broken
        # and every green run before it meant nothing.
        drive = tok
        if args.red and tok.isdigit():
            drive = str(args.red)
            print(f'    [RED] oracle was given button {tok}; '
                  f'pressing {drive} on the board instead')
        did = board_apply(drive, args.settle)
        got = board_park(tmpdir, i + 1, args.settle,
                         timeout=args.action_timeout)
        if tok.startswith('m'):
            menu_calls += 1
        rows.append(dict(token=tok, did=did, board=got))

    # --- diff -------------------------------------------------------------
    print('\n  landing comparison -- PGCN is compared; VTS is shown for context '
          'ONLY.')
    # ⚠ The two VTS numbers do not mean the same thing and must not be diffed.
    # libdvdnav reports vtsN relative to the DOMAIN (-1 in VMGM, the menu's own
    # VTS in VTSM), while the board reports the reader's absolute VTS -- on a
    # DVD board game with 70+ title sets that reads 72 where libdvdnav says 1,
    # and neither is wrong. pg and cell are not observable from the board at all.
    print('     (libdvdnav\'s VTS is domain-relative, the board\'s is absolute)')
    findings, expected, unknown, invalid, downstream = [], [], [], [], []
    diverged = False
    acted = [r for r in rows if not r['token'].startswith('w')]
    for n, r in enumerate(acted):
        o = oracle[n] if n < len(oracle) else None
        b = r['board']
        if o is None:
            unknown.append(f'{r["did"]}: libdvdnav produced no landing')
            continue
        if b is None:
            unknown.append(f'{r["did"]}: no readable HUD on the board')
            continue
        if b.get('unconfirmed') and not b.get('unsettled'):
            # Stable and armed, but neither still nor looping inside the
            # budget -- i.e. possibly a transient clip that outlasted it. That
            # is exactly the state that produced six false differences, so it
            # is reported, never compared.
            unknown.append(f'{r["did"]}: park not confirmed (no still, no '
                           f'loop) within the budget '
                           f'(trajectory {" ".join(b.get("traj", []))})')
            print(f'    [....] {r["did"]:<12} park unconfirmed -- not compared')
            diverged = True
            continue
        if b.get('unsettled'):
            # It never reached an armed park, so it was still in transit. The
            # boot case already aborts; an ACTION that never settles was being
            # compared anyway, which is the same error one step later.
            unknown.append(f'{r["did"]}: never reached an armed park '
                           f'(trajectory {" ".join(b.get("traj", []))})')
            print(f'    [....] {r["did"]:<12} never parked -- not compared')
            diverged = True
            continue
        if diverged:
            # ⚠ ONCE THE TWO ARE IN DIFFERENT PLACES, NOTHING AFTER IS AN
            # INDEPENDENT FINDING: the next button is pressed at two different
            # menus, so a "difference" is guaranteed and says nothing. The
            # Sherlock sweep reported two, of which only the first could
            # possibly have meant anything.
            downstream.append(f'{r["did"]}: after an earlier divergence')
            print(f'    [----] {r["did"]:<12} downstream of a divergence '
                  '-- not compared')
            continue
        # An out-of-range button is not a comparable input.
        nb = o.get('applied_buttons')
        if r['token'].isdigit() and nb is not None and int(r['token']) > nb:
            invalid.append(f'{r["did"]}: the park it was pressed at had only '
                           f'{nb} button(s) -- undefined input, not compared')
            print(f'    [skip] {r["did"]:<12} no such button at that park '
                  f'(buttons={nb})')
            continue
        same = (o['pgcn'] == b['pgcn'])
        first_menu = r['token'].startswith('m') and menu_calls == 1 and n == 0
        mark = 'OK  ' if same else ('note' if first_menu else 'DIFF')
        print(f'    [{mark}] {r["did"]:<12} libdvdnav pgc={o["pgcn"]:<4}'
              f' vts={o["vts"]:<4} | board pgc={b["pgcn"]:<4} vts={b["vts"]:<4}'
              f' traj: {" ".join(b.get("traj", []))}'
              + ('  [UNSETTLED]' if b.get('unsettled') else ''))
        if same:
            continue
        if first_menu:
            expected.append(f'{r["did"]}: {BOOT_MENU_NOTE}')
        else:
            findings.append(f'{r["did"]}: libdvdnav landed in PGC {o["pgcn"]} '
                            f'(VTS {o["vts"]}), the board in PGC {b["pgcn"]} '
                            f'(VTS {b["vts"]})  [board trajectory: '
                            f'{" ".join(b.get("traj", []))}]')
            diverged = True

    print()
    for e in expected:
        print(f'  note (documented deviation): {e}')
    for iv in invalid:
        print(f'  skipped: {iv}')
    for d in downstream:
        print(f'  not compared: {d}')
    for u in unknown:
        print(f'  unknown: {u}')
    for f in findings:
        print(f'  !! DIFFERENCE: {f}')
    if not findings:
        print('  no navigation differences' +
              (' (some steps unreadable -- see above)' if unknown else ''))
    if args.red:
        ok = bool(findings)
        print(f'\n  RED PROOF: {"PASS" if ok else "FAIL"} -- a deliberately '
              f'mismatched input {"was" if ok else "was NOT"} reported as a '
              'difference')
        if not ok:
            print('    The comparison cannot fail. Do not trust a green run.')
        return 0 if ok else 3
    json.dump(dict(disc=os.path.basename(local), script=tokens,
                   oracle=oracle, board=[r['board'] for r in rows],
                   findings=findings, expected=expected, unknown=unknown,
                   invalid=invalid, downstream=downstream),
              open(os.path.join(tmpdir, 'nav_diff.json'), 'w'), indent=2)
    print(f'  artifacts: {tmpdir}')
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main())
