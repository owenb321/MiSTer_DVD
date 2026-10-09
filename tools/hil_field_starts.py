#!/usr/bin/env python3
"""hil_field_starts.py -- the field-start HW gate: relaunch a disc N times, read word 31.

docs/field_parity.md "Strict first field". Each launch reloads the core (so the telemetry
counters start at 0), mounts (a decoder soft reset) and runs the disc's boot chain (more soft
resets at each ~keep_vbuf jump), on Video Output = Interlaced. For each launch the last
telemetry row's fb_heals / strict_waits are that launch's counts:

  fb_heals      the field-parity corrector's FEEDBACK heals -- each one is a ~0.5 s stretch
                of misaligned fields. The thing the strict first-field placement removes.
  strict_waits  frame-top slots the mixer refused because they were the wrong parity.

Expected: a control build (strict term removed) shows fb_heals ~ the number of starts that
headed for the wrong slot; the fix shows fb_heals 0 with strict_waits taking its place.
Needs the custom Main (it emits word 31) and a core with it; see the hil-testing skill.

Usage: tools/hil_field_starts.py <arm-name> <iso-on-the-mister> <N> [seconds]
Logs go to $HIL_OUT (default /tmp/hil_field)/<arm>/.
"""
import json
import os
import subprocess
import sys

arm, iso, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
secs = int(sys.argv[4]) if len(sys.argv) > 4 else 15
out = os.path.join(os.environ.get('HIL_OUT', '/tmp/hil_field'), arm)
os.makedirs(out, exist_ok=True)
tot_h = tot_w = 0
for i in range(n):
    log = f'{out}/run{i:02d}.jsonl'
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mister.py'), 'launch', iso,
                        '--opt', 'Video Output=Interlaced',
                        '--telem-log', log, '--telem-seconds', str(secs)],
                       capture_output=True, text=True)
    rows = []
    if os.path.exists(log):
        for line in open(log):
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    rows = [x for x in rows if 'fb_heals' in x]
    if not rows:
        print(f'{arm} run {i}: NO word-31 rows (rc={r.returncode}) {r.stdout[-300:]} {r.stderr[-300:]}')
        continue
    h, w = rows[-1]['fb_heals'], rows[-1]['strict_waits']
    lates = rows[-1].get('lates')
    tot_h += h
    tot_w += w
    print(f'{arm} run {i:2d}: fb_heals {h}  strict_waits {w}  lates {lates}  rows {len(rows)}', flush=True)
print(f'== {arm}: {n} launches, fb_heals total {tot_h}, strict_waits total {tot_w}')
