#!/usr/bin/env python3
"""hil_field_toggles.py -- Video Output round trips under 50 ms telemetry, events timed.

docs/field_parity.md "Strict first field", HW rounds 1-2. Launches a disc on Interlaced
with event-capture telemetry (--telem-fast-ms 50), then switches Video Output Progressive ->
Interlaced N times. Every fb_heals / strict_waits increment is placed relative to the switch
that preceded it.

★ WHY THE TIMING IS DONE THIS WAY. The custom Main stamps rows with CLOCK_MONOTONIC, which is
/proc/uptime on the MiSTer, so the host reads the target's uptime around each osd command
and maps both onto one clock. The obvious marker -- the video_live flag dropping at the mode
switch's flush -- does NOT work in a disc MENU: emu.sv forces the STD mux-lead hold off while
menu_active, so video_live never drops there (dvd/mode_realign.sv). This timing is what
found HW round 1's cause: heals landing 0.54 / 0.62 s after the switch = PAR_CONFIRM after a
re-break a few fields in (a leftover progressive FRAME image spending a one-shot arm).

Usage: tools/hil_field_toggles.py <arm-name> <iso-on-the-mister> <N>
Logs go to $HIL_OUT (default /tmp/hil_field)/<arm>_timed.jsonl.
"""
import json
import os
import subprocess
import sys
import threading
import time

arm, iso, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
out = os.environ.get('HIL_OUT', '/tmp/hil_field')
os.makedirs(out, exist_ok=True)
log = os.path.join(out, f'{arm}_timed.jsonl')
secs = 40 + n * 10 + 10


def mp(*a, timeout=300):
    return subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mister.py'), *a], capture_output=True, text=True,
                          timeout=timeout)


def uptime():
    r = mp('shell', 'cat /proc/uptime', timeout=60)
    return float(r.stdout.split()[0])


res = {}
th = threading.Thread(target=lambda: res.setdefault('r', mp(
    'launch', iso, '--opt', 'Video Output=Interlaced', '--telem-log', log,
    '--telem-seconds', str(secs), '--telem-fast-ms', '50', timeout=secs + 200)))
th.start()
time.sleep(40)
events = []                                  # (mister_t_before, mister_t_after, mode)
for i in range(n):
    for mode in ('Progressive', 'Interlaced'):
        t0 = uptime()
        mp('osd', f'Video Output={mode}')
        t1 = uptime()
        events.append((t0, t1, mode))
        time.sleep(4)
th.join()

rows = []
for line in open(log):
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
rows = [r for r in rows if 'fb_heals' in r]
print(f'{len(rows)} rows, t {rows[0]["t"]:.1f}..{rows[-1]["t"]:.1f}; '
      f'{len(events)} switches, t {events[0][0]:.1f}..{events[-1][1]:.1f}')


def last_switch(t):
    best = None
    for e in events:
        if e[0] <= t:
            best = e
    return best


tot = {'fb_heals': 0, 'strict_waits': 0}
for a, b in zip(rows, rows[1:]):
    for k, m in (('fb_heals', 0x7F), ('strict_waits', 0xFF)):
        d = (b[k] - a[k]) & m
        if d:
            e = last_switch(b['t'])
            tot[k] += d
            if e:
                print(f'  {k:12s} +{d}  {b["t"] - e[1]:6.2f} s after the switch to {e[2]:11s} '
                      f'(osd took {e[1] - e[0]:.2f} s)   lates {b["lates"]} pickups {b["pickups"]}')
            else:
                print(f'  {k:12s} +{d}  before any switch')
print(f'== {arm}: {n} round trips; fb_heals +{tot["fb_heals"]}, strict_waits +{tot["strict_waits"]}')
