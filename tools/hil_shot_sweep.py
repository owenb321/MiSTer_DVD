#!/usr/bin/env python3
"""hil_shot_sweep.py -- time a button press to a display PTS on the rig and score
whether a cell command counted it (issue #176, docs/dvd_nav.md "A cell command with
buttons up").

An FMV shooting game scores a shot with a CELL COMMAND that reads a register the
shot's button set. Whether a press counts therefore depends on WHEN, in display time,
it lands relative to the cell end. This drives one trial per target PTS:

  1. relaunch the disc and walk to the start of play (--prep steps, HUD-gated);
  2. on the BOARD, from fast (20 ms) telemetry: picture k of the title is
     PTS_FIRST + (k-1)/fps, k = pickups + drops since the title flush (the counters
     reset there), and the press times are solved on the board's monotonic clock
     against the measured pickup rate;
  3. tap the aim keys (--aim) at --aim-pts, then Select at the target;
  4. score from the telemetry: a MISS is the cell command's seek, whose flush drops
     video_live at the cell end (picture --miss-at, +/- a few); a HIT plays on past it.

⚠ Timed presses use single `key <code> 30` taps. The key daemon's `keys` command costs
170 ms per key and QUEUES whatever is written behind it, so a Select written after
three `keys` Rights lands ~0.3 s late (this cost a wasted control sweep, 2026-10-12).

Run the control arm first (the old core, `mister.py deploy --rbf`), then the fix.

Example -- Mad Dog McCree's first shootout (VTS 1 PGC 1 cell 2; HLI 35.549-37.518 s,
cell end 37.551 s; Play -> Deputy; the 64 s intro skips with Select):

    tools/mister.py deploy --agent --main <MiSTer_DVDcss> --rbf releases/<core>.rbf
    tools/hil_shot_sweep.py "<games/DVD path>/MAD DOG.iso" --sel 36.6 37.0 37.3 \\
        --pts-first 0.181 --miss-at 1118 --aim right right right --aim-pts 35.75 \\
        --prep "/0:01:04 CH  1/ 2=select" "/0:00:00 CH  1/ 2=select" "CH 17/ 2="

--prep steps are "REGEX=KEY": wait until the decoded HUD status line (Debug Overlay on,
so CH = {PGCN, VTS}) matches REGEX, then press KEY (empty = press nothing). "@SECONDS=KEY"
waits a fixed time instead, for a rig whose output mode the HUD decoder is not calibrated
for (it reads 720-wide rasters; a 640x480 rig decodes nothing). The last
step should land on the menu whose Select starts play; the trial presses that Select.
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
import mister as M  # noqa: E402

BOARD = r'''
import json, os, sys, time
FIFO = "/tmp/mister_hil"
cfg = json.loads(sys.argv[1])
FPS = 30000 / 1001 if cfg["ntsc"] else 25.0


def mono():
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def tap(code):
    with open(FIFO, "w") as f:
        f.write("key %d 30\n" % code)


def rd():
    try:
        with open("/tmp/dvd_telem.json") as f:
            return json.loads(f.read())
    except Exception:
        return None


with open("/tmp/dvd_telem_fast", "w") as f:
    f.write("20")
time.sleep(2.6)                          # dvd_ctl re-reads the knob every 2 s
rows, last = [], [None]


def poll():
    r = rd()
    if r and r.get("t") != last[0]:
        last[0] = r["t"]
        r["_c"] = (r["pickups"] + r["drops"]) & 0xFFFF
        rows.append(r)
        return r


for _ in range(40):
    poll(); time.sleep(0.01)
t0 = mono()
tap(cfg["start_key"])
log = {}
base = None
while mono() - t0 < 15 and base is None:
    r = poll()
    if r and len(rows) > 2 and r["flags"]["menu"] == 0 and r["flags"]["video_live"] == 1:
        base = min((x for x in rows if x["t"] >= t0), key=lambda x: x["_c"])
    time.sleep(0.005)
if base is None:
    log["err"] = "no title start"
else:
    cb, tb = base["_c"], base["t"]
    aims, sel = list(cfg["aim"]), cfg["sel_pts"]
    fit, t_fit, fired_a, fired_s = None, 0, False, False
    while mono() - t0 < cfg["secs"]:
        poll()
        if mono() - t_fit > 0.5:
            live = [x for x in rows if x["t"] > max(tb + 1.0, mono() - 10.0)]
            if len(live) >= 20:
                t_fit = mono()
                n = len(live)
                mt = sum(x["t"] for x in live) / n
                mc = sum((x["_c"] - cb) & 0xFFFF for x in live) / n
                sxx = sum((x["t"] - mt) ** 2 for x in live)
                sxy = sum((x["t"] - mt) * (((x["_c"] - cb) & 0xFFFF) - mc) for x in live)
                rate = sxy / sxx
                t_of = lambda pts: mt + ((pts - cfg["pts_first"]) * FPS + 1 - mc) / rate
                fit = (rate, t_of(cfg["aim_pts"]), t_of(sel))
        if fit:
            now = mono()
            if not fired_a and now >= fit[1]:
                for i, k in enumerate(aims):
                    if i:
                        time.sleep(0.1)
                    tap(k)
                log["t_aim"] = now; fired_a = True
            if not fired_s and now >= fit[2]:
                tap(cfg["sel_key"]); log["t_sel"] = now; log["t_sel_plan"] = fit[2]
                log["rate"] = fit[0]; fired_s = True
        time.sleep(0.004)
os.remove("/tmp/dvd_telem_fast")
print("ROWS " + json.dumps([{k: r[k] for k in ("t", "pickups", "drops", "lates", "aud_frames",
                                                "aud_play", "aud_gate", "reanchors",
                                                "av_drift_ms") if k in r} |
                            {"live": r["flags"]["video_live"], "menu": r["flags"]["menu"]}
                            for r in rows]))
print("LOG " + json.dumps(log))
'''


def hud():
    out = subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'shot', '--decode'],
                         capture_output=True, text=True).stdout
    m = re.search(r"status: '(.*?)'", out)
    return m.group(1) if m else ''


def prep(args, keys):
    subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'launch', args.iso,
                    '--opt', 'Debug Overlay=On'], capture_output=True, text=True)
    for step in args.prep:
        rx, _, key = step.rpartition('=')
        if rx.startswith('@'):           # a timed step: for a rig whose HUD cannot be decoded
            time.sleep(float(rx[1:]))
            if key:
                subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'key', key],
                               capture_output=True)
            continue
        end = time.time() + args.step_timeout
        h = ''
        while time.time() < end:
            h = hud()
            if re.search(rx, h):
                break
            time.sleep(1.0)
        else:
            return 'prep step %r timed out (HUD %r)' % (rx, h)
        time.sleep(2.5)                  # let a menu highlight promote before a press
        if key:
            subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'key', key],
                           capture_output=True)
    return None


def verdict(rows, miss_at, slack=17):
    """MISS = video_live drops within `slack` pictures of the cell end; HIT = plays past it."""
    start = None
    for i, r in enumerate(rows):
        if not r['menu'] and r['pickups'] == 0:
            start = i
        elif start is not None and r['pickups'] > 30:
            break
    if start is None:
        return '?', 'no title start'
    peak, drop = 0, None
    for r in rows[start + 1:]:
        if r['pickups'] > 0 and not r['live']:
            drop = r['pickups']
            break
        peak = max(peak, r['pickups'])
    if drop is not None and abs(drop - miss_at) <= slack:
        return 'MISS', 'live drop at picture %d' % drop
    if peak > miss_at + slack and (drop is None or drop > miss_at + slack):
        return 'HIT', 'played to picture %d%s' % (peak, '' if drop is None else
                                                 ', drop at %d' % drop)
    return '?', 'peak %d, drop %s' % (peak, drop)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('iso', help='image path ON THE MISTER')
    ap.add_argument('--sel', type=float, nargs='+', required=True, help='target PTS (s)')
    ap.add_argument('--pts-first', type=float, required=True,
                    help="PTS of the title's first picture (its first VOBU's vobu_s_ptm)")
    ap.add_argument('--miss-at', type=int, required=True,
                    help='picture number where a miss flushes (the scored cell end)')
    ap.add_argument('--aim', nargs='*', default=[], help='keys tapped 0.1 s apart before Select')
    ap.add_argument('--aim-pts', type=float, default=0.0)
    ap.add_argument('--start-key', default='select', help='the key that starts play')
    ap.add_argument('--sel-key', default='select')
    ap.add_argument('--prep', nargs='*', default=[], help='"REGEX=KEY" steps (see above)')
    ap.add_argument('--secs', type=float, default=46.0, help='board-side trial length')
    ap.add_argument('--pal', action='store_true', help='25 fps content (default 29.97)')
    ap.add_argument('--step-timeout', type=float, default=90.0)
    ap.add_argument('--save', help='directory for each trial\'s telemetry rows')
    a = ap.parse_args()
    names = M.key_names()
    for k in a.aim + [a.start_key, a.sel_key]:
        if k not in names:
            sys.exit('unknown key %r' % k)
    host = M.host()
    rc = 0
    for pts in a.sel:
        err = prep(a, names)
        if err:
            print('RESULT sel=%.2f PREP-FAIL %s' % (pts, err), flush=True)
            rc = 1
            continue
        cfg = {'sel_pts': pts, 'aim_pts': a.aim_pts, 'aim': [names[k] for k in a.aim],
               'start_key': names[a.start_key], 'sel_key': names[a.sel_key],
               'pts_first': a.pts_first, 'secs': a.secs, 'ntsc': not a.pal}
        p = subprocess.run(['ssh', *M.SSH_OPTS, host, 'python3 - %s' % repr(json.dumps(cfg))],
                           input=BOARD, capture_output=True, text=True,
                           timeout=a.secs + 60)
        rows = log = None
        for line in p.stdout.splitlines():
            if line.startswith('ROWS '):
                rows = json.loads(line[5:])
            elif line.startswith('LOG '):
                log = json.loads(line[4:])
        if rows is None:
            print('RESULT sel=%.2f ERROR %s' % (pts, (p.stderr or p.stdout)[-300:]), flush=True)
            rc = 1
            continue
        if a.save:
            os.makedirs(a.save, exist_ok=True)
            with open(os.path.join(a.save, 'sel_%.2f.json' % pts), 'w') as f:
                json.dump({'log': log, 'rows': rows}, f)
        v, why = verdict(rows, a.miss_at)
        lag = (log['t_sel'] - log['t_sel_plan']) if log and 't_sel' in log else None
        print('RESULT sel=%.2f %s (%s; fired %s s off plan%s)'
              % (pts, v, why, 'n/a' if lag is None else '%+.3f' % lag,
                 '' if not log or 'err' not in log else '; ' + log['err']), flush=True)
    return rc


if __name__ == '__main__':
    sys.exit(main())
