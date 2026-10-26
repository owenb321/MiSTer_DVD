#!/usr/bin/env python3
"""vm_restore_check.py -- a restore puts back what the snapshot took (docs/nav_engine.md
§9; save states step 3).

tools/vm_ab.py --restore proves the RTL restores exactly as the Python model does. This
proves the model restores the RIGHT thing. Over random histories (the A/B's generator):

    1. a random prefix, then a snapshot (waiting out any jump until it completes);
       the VM's state at that moment is the reference;
    2. a random middle -- the VM goes elsewhere, its registers change -- ending with a
       live menu whose selection differs from the saved SPRM8 (buttons armed);
    3. a restore. Its jump must name the saved place: the domain, the reader's VTS for a
       title (the VM's for a menu), the PGCN, the cell; a title's VTS_TTN as a hint;
    4. the landing: the reader reports the saved PGC loaded, buttons not yet armed;
    5. the state must equal the reference in every field a restore owns.

Fields a restore does NOT own are excluded, with the reason beside each. The landing's
load updates a few on purpose (the last-menu latch on a menu load, SPRM6 on a title
load); those are expected from the saved place, as the hardware computes them.

Usage:
    tools/vm_restore_check.py [--seeds N] [--steps K]      # GREEN
    tools/vm_restore_check.py --red                          # every ;MUT rst* arm fails it
"""
import argparse
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nav_isa as N        # noqa: E402
import nav_shell as S      # noqa: E402
import vm_ab               # noqa: E402

DOM_TT = 3
# not owned by a restore: transient or rebuilt by the landing itself
EXCLUDED = {
    'fb', 'skip_pre', 'chain', 'fuse',         # the restore's own jump sets and consumes them
    'blk', 'nat', 'usr', 'events', 'tick', 'mode', 'frozen',   # control state, not VM state
    'tt_resolve',      # a jump's pending SPRM5 update: the restore clears it (else the
                       # landing would overwrite the restored SPRM5 with the live res_ttn)
}


def ix(name):
    return N.snap_layout().index(name)


def one(seed, steps, mutate):
    """-> None if the restore round-trips, else the first difference."""
    rng = random.Random(seed * 7919 + 1)
    sh = S.Shell(mutate=mutate)
    pre = [ln for ln in vm_ab.gen_script(seed, steps) if 'snap' not in ln and 'restore' not in ln]
    mid = [ln for ln in vm_ab.gen_script(seed + 100000, steps // 2)
           if 'snap' not in ln and 'restore' not in ln and not ln.startswith('#')]
    for ln in pre:
        sh.apply(ln)
    sh.apply('set enable 1')
    n0 = sum(1 for ln in sh.log if ln.startswith('N '))
    sh.apply('pulse snap')
    for _ in range(4):
        if sum(1 for ln in sh.log if ln.startswith('N ')) > n0:
            break
        sh.apply('timeout')
    if sum(1 for ln in sh.log if ln.startswith('N ')) == n0:
        return 'skip'                                # never at rest (a script quirk)
    ref = sh.dump()
    blob = list(sh.last_snap)
    for ln in mid:
        sh.apply(ln)
    # the player is now at some live menu: buttons armed, a different selection
    sh.apply('set enable 1')
    sh.apply('set btns_armed 1')
    saved_btn = (blob[ix('sprm8')] >> 10) & 0x3F
    sh.apply('set btn_sel %d' % ((saved_btn + 1 + rng.randrange(30)) % 64))
    nlog = len(sh.log)
    sh.apply('pulse restore')
    for _ in range(4):
        if any(ln.endswith(' RSTDONE') for ln in sh.log[nlog:]):
            break
        sh.apply('timeout')
    new = sh.log[nlog:]
    if not any(ln.endswith(' RSTDONE') for ln in new):
        return 'the restore never ran'
    # 3. the jump
    i = next(k for k, ln in enumerate(new) if ln.endswith(' RSTDONE'))
    jl = next((ln for ln in new[i:] if ' JUMP ' in ln), None)
    if jl is None:
        return 'the restore issued no jump'
    f = [int(x) for x in jl.split()[3:]]
    dom, vts, pgcn, entry, ttn, pgn, ptt, cell = f[:8]
    w = {k: blob[ix(k)] for k in ('in_vm_dom', 'in_vm_vts', 'in_cur_vts', 'in_cur_pgcn',
                                  'in_cur_cell', 'sprm5')}
    want = (w['in_vm_dom'] & 3,
            (w['in_cur_vts'] if (w['in_vm_dom'] & 3) == DOM_TT else w['in_vm_vts']) & 0xFF,
            w['in_cur_pgcn'], 0, (w['sprm5'] & 0x7F) if (w['in_vm_dom'] & 3) == DOM_TT else 0,
            0, 0, w['in_cur_cell'] & 0xFF)
    if (dom, vts, pgcn, entry, ttn, pgn, ptt, cell) != want:
        return 'jump %s, want %s' % ((dom, vts, pgcn, entry, ttn, pgn, ptt, cell), want)
    hint = any(' JHINT ' in ln for ln in new[i:])
    if hint != ((w['in_vm_dom'] & 3) == DOM_TT):
        return 'ttn hint %s for domain %d' % (hint, w['in_vm_dom'] & 3)
    # 4. the landing
    sh.apply('set btns_armed 0')
    for k in ('cur_vts', 'cur_pgcn', 'cur_cell'):
        sh.apply('set %s %d' % (k, w['in_' + k]))
    sh.apply('set menu_active %d' % blob[ix('in_menu_active')])
    # the reader's res_ttn is whatever the player last resolved, not the saved title's:
    # a restore that left a pending SPRM5 update would take it here
    sh.apply('set res_ttn %d' % (((w['sprm5'] & 0x7F) + 1 + rng.randrange(60)) & 0x7F))
    sh.apply('pulse loaded')
    got = sh.dump()
    # 5. the state
    exp = dict(ref)
    if (w['in_vm_dom'] & 3) in (1, 2):         # a menu load latches it (the wrapper's rule)
        exp.update(lm_v=1, lm_dom=w['in_vm_dom'] & 3, lm_vts=w['in_vm_vts'] & 0xFF,
                   lm_pgcn=w['in_cur_pgcn'], menu_seen=1)
    elif (w['in_vm_dom'] & 3) == DOM_TT:        # a title load sets SPRM6, clears the toggle
        exp['sprm6'] = w['in_cur_pgcn']
        exp['cvm'] = 0
    for k in S.STATE:
        if k in EXCLUDED:
            continue
        if got[k] != exp[k]:
            return '%s = %x, the snapshot had %x' % (k, got[k], exp[k])
    return None


def run(seeds, steps, mutate=None, verbose=True):
    fails, ok, skipped = [], 0, 0
    for sd in range(1, seeds + 1):
        try:
            r = one(sd, steps, mutate)
        except N.SeqError as e:
            r = 'emulator: %s' % e
        if r == 'skip':
            skipped += 1
        elif r:
            fails.append((sd, r))
        else:
            ok += 1
    if verbose:
        for sd, r in fails[:8]:
            print('  FAIL seed %d: %s' % (sd, r))
        print('vm_restore_check: %d round trips, %d failed, %d skipped (never at rest)'
              % (ok + len(fails), len(fails), skipped))
    return fails, ok


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--seeds', type=int, default=300)
    ap.add_argument('--steps', type=int, default=80)
    ap.add_argument('--red', action='store_true')
    a = ap.parse_args()
    fails, ok = run(a.seeds, a.steps)
    bad = 1 if fails or ok < a.seeds // 2 else 0
    if ok < a.seeds // 2:
        print('  FAIL fewer than half the seeds round-tripped: the check is not exercising much')
    if a.red:
        arms = [m for m in re.findall(r';\s*MUT\s+(\w+)\s*:', open(N.UASM).read())
                if m.startswith('rst')]
        for arm in arms:
            f, _ = run(min(a.seeds, 120), a.steps, arm, verbose=False)
            print('  RED %s: %s' % (arm, ('caught (seed %d: %s)' % f[0]) if f else 'BLIND'))
            if not f:
                bad = 1
    print('PASS: vm_restore_check' if not bad else 'FAIL: vm_restore_check')
    return bad


if __name__ == '__main__':
    sys.exit(main())
