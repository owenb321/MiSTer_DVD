#!/usr/bin/env python3
"""hil_play.py -- play a disc on the rig in real time from a scenario, with the capture
card recording, and put every press, telemetry sample and captured frame on ONE clock
(docs/hil_play_harness.md).

    tools/hil_play.py run <scenario.json> --out <dir> [--rbf releases/X.rbf] [--no-capture]
    tools/hil_play.py sweep <scenario.json> --out <dir> --vary at_pts=36.6,37.0,37.3 \\
        [--rbf A.rbf --rbf B.rbf]

A scenario is JSON:

    {"iso": "<image path ON THE MISTER>",
     "opts": {"Debug Overlay": "Off"},          # mister.py launch --opt pairs
     "capture_s": 60,                           # 0 = no capture
     "align": {"vts": 1, "pgcn": 1, "cells": [1, 2, 3],    # optional, for the report
               "overlay": true},                         # read Debug Overlay (needs it On)
     "steps": [
        {"wait": "menu", "timeout": 30},        # a predicate on the live state (below)
        {"sleep": 2.5},
        {"key": "select"},                      # one tap, stamped on the board's clock
        {"base": true, "timeout": 20},          # picture 1 of the title = the next live,
                                                #   non-menu run (counters reset at its flush)
        {"key": "right", "at_pts": 35.75},      # tap when picture (PTS-pts_first)*fps+1 shows
        {"key": "select", "at_pts": "$SEL"},    # $NAME: substituted by sweep --vary NAME=...
        {"host": "continue", "timeout": 400},   # block until host vision says so (below)
        {"key": "select", "at_picture": 12},    # tap when picture 12 after base is up
        {"mark": "shot"},
        {"sleep": 6}
     ],
     "pts_first": 0.181,                        # PTS of the base picture (disc_timing first_ptm)
     "host_waits": {"continue": {"vts": 4, "pgcn": 3, "min_score": 0.85}},
     "pal": false}

Predicates are Python expressions over the newest telemetry sample: `live`, `menu`,
`pause`, `still`, `pictures` (pickups+drops since `base`), `aud_frames`, `r` (the raw
row), and -- once the core carries the nav event FIFO -- `nav`, a dict of the latest
navigation state from /tmp/dvd_navtrace.jsonl (empty on a build without it).

Clocks. The board agent stamps everything with the board's CLOCK_MONOTONIC (telemetry
`t` is the same clock). Before the scenario it answers a few ping-pongs over the ssh
pipe; the lowest-RTT one gives board-mono -> host-wall with an uncertainty of RTT/2,
recorded in clock.json. The capture is recorded with -ts mono2abs -copyts, so its frame
and sample timestamps ARE host wall time. Hence a press's capture time is
t_board + offset, and hil_timeline.py then gives the picture on screen at that moment.

Presses go through the key daemon's FIFO as single `key <code> 30` taps (never the
queued `keys` command, 170 ms per key -- .claude/skills/hil-testing). The FIFO write is
stamped; the daemon's make follows within a few ms (measured by the `latency` scenario,
not assumed: docs/hil_play_harness.md).

Output (--out): scenario.json, agent.jsonl (one JSON object per press, mark, wait and
telemetry sample), clock.json, cap.mkv, and with "align" in the scenario timeline.json +
report.txt from hil_timeline.py, with the presses placed on the capture timeline.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mister as M  # noqa: E402

AGENT = r'''
import json, os, select, sys, time
FIFO = "/tmp/mister_hil"
TELEM, FAST = "/tmp/dvd_telem.json", "/tmp/dvd_telem_fast"
NAVTRACE = "/tmp/dvd_navtrace.jsonl"


def mono():
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def out(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()


# --- clock sync: answer pings until the host sends the scenario ------------------
for line in sys.stdin:
    if line.startswith("ping"):
        out({"pong": mono()})
        continue
    sc = json.loads(line)
    break

FPS = 25.0 if sc.get("pal") else 30000 / 1001
with open(FAST, "w") as f:
    f.write(str(sc.get("telem_ms", 20)))
rows, last_t, nav, nav_pos = [], [None], {}, [0]
state = {"base": None}


def poll():
    try:
        with open(TELEM) as f:
            r = json.loads(f.read())
    except Exception:
        r = None
    if r and r.get("t") != last_t[0]:
        last_t[0] = r["t"]
        r["_c"] = (r["pickups"] + r["drops"]) & 0xFFFF
        rows.append(r)
        out({"telem": r})
    # the nav event FIFO's drain log (absent on a core without it: nav stays {})
    try:
        with open(NAVTRACE) as f:
            f.seek(nav_pos[0])
            for ln in f:
                if not ln.endswith("\n"):
                    break
                nav_pos[0] += len(ln)
                ev = json.loads(ln)
                out({"nav": ev})
                nav.update(ev.get("state", {}))
    except FileNotFoundError:
        pass
    except Exception as e:
        out({"warn": "navtrace: %s" % e})
    return rows[-1] if rows else None


def env(r):
    fl = r["flags"] if r else {}
    b = state["base"]
    return {"r": r, "nav": nav, "live": fl.get("video_live", 0), "menu": fl.get("menu", 0),
            "pause": fl.get("pause", 0), "still": fl.get("still", 0),
            "aud_frames": r.get("aud_frames", 0) if r else 0,
            "pictures": ((r["_c"] - b["_c"]) & 0xFFFF) + 1 if (r and b) else 0}


def tap(code, hold=30):
    t = mono()
    with open(FIFO, "w") as f:
        f.write("key %d %d\n" % (code, hold))
    return t


def fit():
    """Picture count against board time over the last 10 s since base: (rate, t_of)."""
    b = state["base"]
    live = [x for x in rows if x["t"] > max(b["t"] + 1.0, mono() - 10.0)]
    if len(live) < 20:
        return None
    n = len(live)
    mt = sum(x["t"] for x in live) / n
    mc = sum((x["_c"] - b["_c"]) & 0xFFFF for x in live) / n
    sxx = sum((x["t"] - mt) ** 2 for x in live)
    sxy = sum((x["t"] - mt) * (((x["_c"] - b["_c"]) & 0xFFFF) - mc) for x in live)
    if sxx <= 0:
        return None
    rate = sxy / sxx
    return rate, lambda pts: mt + ((pts - sc["pts_first"]) * FPS + 1 - mc) / rate


time.sleep(2.6)                         # dvd_ctl re-reads the fast knob every 2 s
for _ in range(20):
    poll(); time.sleep(0.01)
out({"start": mono()})
ok = True
for i, st in enumerate(sc["steps"]):
    t0 = mono()
    if "sleep" in st:
        end = t0 + st["sleep"]
        while mono() < end:
            poll(); time.sleep(0.004)
    elif "wait" in st:
        lim, hit = t0 + st.get("timeout", 30), False
        while mono() < lim:
            r = poll()
            try:
                if r and eval(st["wait"], {}, env(r)):
                    hit = True
                    break
            except Exception as e:
                out({"step": i, "err": "predicate: %s" % e}); break
            time.sleep(0.004)
        out({"step": i, "wait": st["wait"], "met": hit, "t": mono(), "waited": mono() - t0})
        if not hit:
            ok = False
            break
    elif "base" in st:
        lim = t0 + st.get("timeout", 20)
        while mono() < lim and state["base"] is None:
            r = poll()
            since = [x for x in rows if x["t"] >= t0]
            if since and since[-1]["flags"]["menu"] == 0 and since[-1]["flags"]["video_live"] == 1:
                state["base"] = min(since, key=lambda x: x["_c"])
            time.sleep(0.004)
        out({"step": i, "base": state["base"] and state["base"]["t"]})
        if state["base"] is None:
            ok = False
            break
    elif "host" in st:
        # slow navigation by host vision: ask, keep polling telemetry, wait for its line
        out({"step": i, "want_host": st["host"], "t": mono()})
        lim, got = t0 + st.get("timeout", 300), None
        while mono() < lim and got is None:
            poll()
            r, _, _ = select.select([sys.stdin], [], [], 0.005)
            if r:
                got = sys.stdin.readline().strip()
        out({"step": i, "host": st["host"], "reply": got, "t": mono()})
        if got != "ok":
            ok = False
            break
    elif "key" in st and "at_picture" in st:
        if state["base"] is None:
            out({"step": i, "err": "at_picture before base"}); ok = False; break
        lim = t0 + st.get("timeout", 30)
        while mono() < lim:
            r = poll()
            if r and env(r)["pictures"] >= st["at_picture"]:
                t = tap(st["code"], st.get("hold_ms", 30))
                out({"step": i, "key": st["key"], "t": t, "at_picture": st["at_picture"],
                     "pictures": env(r)["pictures"], "row_t": r["t"]})
                break
            time.sleep(0.001)
        else:
            out({"step": i, "err": "picture %d never reached" % st["at_picture"]})
            ok = False
            break
    elif "key" in st and "at_pts" in st:
        if state["base"] is None:
            out({"step": i, "err": "at_pts before base"}); ok = False; break
        plan, lim = None, t0 + st.get("timeout", 120)
        while mono() < lim:
            poll()
            f = fit()
            if f:
                plan = f[1](st["at_pts"])
                if mono() >= plan:
                    t = tap(st["code"], st.get("hold_ms", 30))
                    out({"step": i, "key": st["key"], "t": t, "at_pts": st["at_pts"],
                         "plan": plan, "rate": f[0]})
                    break
            time.sleep(0.002)
        else:
            out({"step": i, "err": "at_pts %.3f never reached (plan %s)" % (st["at_pts"], plan)})
            ok = False
            break
    elif "key" in st:
        t = tap(st["code"], st.get("hold_ms", 30))
        out({"step": i, "key": st["key"], "t": t})
    elif "mark" in st:
        out({"step": i, "mark": st["mark"], "t": mono()})
for _ in range(10):
    poll(); time.sleep(0.02)
try:
    os.remove(FAST)
except Exception:
    pass
out({"done": ok, "t": mono()})
'''


def sub(o, var):
    """Replace "$NAME" string values (anywhere in the scenario) from var."""
    if isinstance(o, dict):
        return {k: sub(v, var) for k, v in o.items()}
    if isinstance(o, list):
        return [sub(v, var) for v in o]
    if isinstance(o, str) and o.startswith('$'):
        if o[1:] not in var:
            sys.exit('scenario uses %s but no --vary/--set gives it' % o)
        return var[o[1:]]
    return o


def start_capture(path, seconds):
    vdev, adev, afmt = M.capture_devices()
    if not vdev or not adev:
        sys.exit('capture card not found (MISTER_CAPTURE_NAME?)')
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'v4l2', '-ts', 'mono2abs', '-input_format', 'mjpeg',
           '-video_size', '720x480', '-framerate', '60', '-t', str(seconds), '-i', vdev,
           '-f', afmt, '-ac', '2', '-ar', '48000', '-t', str(seconds), '-i', adev,
           '-copyts', '-c:v', 'copy', '-c:a', 'pcm_s16le', path]
    return subprocess.Popen(cmd)


def launch(sc):
    cmd = [sys.executable, os.path.join(HERE, 'mister.py'), 'launch', sc['iso']]
    for k, v in sc.get('opts', {}).items():
        cmd += ['--opt', '%s=%s' % (k, v)]
    _, n = M.ssh('wc -l < /tmp/dvd_report.log 2>/dev/null || echo 0\n', check=False)
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        sys.exit('launch failed:\n' + p.stdout + p.stderr)
    # a failed mount still tells the core a disc arrived; catch it here, not as a timeout.
    # Only this launch's lines: the log keeps earlier launches'.
    _, log = M.ssh('tail -n +%d /tmp/dvd_report.log 2>/dev/null | grep "mount result" | tail -1\n'
                   % (int(n.strip() or 0) + 1), check=False)
    if 'FAILED' in log:
        sys.exit('launch: the image did not mount (%s) -- is the share mounted?' % log.strip())


def run_agent(sc, out_dir):
    names = M.key_names()
    for st in sc['steps']:
        if 'key' in st:
            if st['key'] not in names:
                sys.exit('unknown key %r (mister.py options lists them)' % st['key'])
            st['code'] = names[st['key']]
    p = subprocess.Popen(['ssh', *M.SSH_OPTS, M.host(), 'python3 -u -c %s'
                          % _shq(AGENT)],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    # clock: board mono -> host wall, from the lowest-RTT ping
    best = None
    for _ in range(15):
        h0 = time.time()
        p.stdin.write('ping\n'); p.stdin.flush()
        pong = json.loads(p.stdout.readline())['pong']
        h1 = time.time()
        if best is None or h1 - h0 < best[0]:
            best = (h1 - h0, (h0 + h1) / 2 - pong)
        time.sleep(0.02)
    clock = {'board_mono_to_host_wall': best[1], 'rtt_s': best[0],
             'uncertainty_s': best[0] / 2}
    p.stdin.write(json.dumps(sc) + '\n'); p.stdin.flush()
    events = []
    with open(os.path.join(out_dir, 'agent.jsonl'), 'w') as f:
        for line in p.stdout:
            f.write(line)
            o = json.loads(line)
            if 'telem' not in o and 'nav' not in o:
                events.append(o)
                print('  agent: %s' % line.strip(), flush=True)
            if 'want_host' in o:
                ans = host_wait(sc['host_waits'][o['want_host']], out_dir, sc)
                p.stdin.write(('ok' if ans else 'timeout') + '\n'); p.stdin.flush()
            if 'done' in o:
                break
    p.stdin.close()
    p.wait(timeout=30)
    return clock, events


_REFS = {}


def host_wait(w, out_dir, sc):
    """Block until a core screenshot matches one of the reference pictures named by
    w = {"vts", "pgcn", "cells", "min_score", "timeout"}. Screenshots are the core's raw
    raster (no pillarbox, no OSD), so they compare against the reference directly."""
    import numpy as np
    import hil_timeline as H
    key = (w['vts'], w['pgcn'], tuple(w.get('cells', [])))
    if key not in _REFS:
        iso = sc.get('_local_iso')
        timing = H.DT.dump(iso, w['vts'], w['pgcn'], set(w.get('cells', [])))
        th = [H.thumbs('-', H.cut_cell(iso, c['lba_first'], c['lba_last']))[1]
              for c in timing['cells'] if not w.get('cells') or c['cell'] in w['cells']]
        _REFS[key] = H.normalise(np.concatenate(th))[0]
    R = _REFS[key]
    shot = os.path.join(out_dir, 'host_wait.png')
    end = time.time() + w.get('timeout', 300)
    while time.time() < end:
        if os.path.exists(shot):
            os.remove(shot)             # a failed shot must not re-match the last one
        subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'shot', '--out', shot],
                       capture_output=True)
        if os.path.exists(shot):
            _, C = H.thumbs(shot)
            C, flat = H.normalise(C)
            best = float((C @ R.T).max()) if not flat[0] else 0.0
            print('  host: screenshot vs VTS %d PGC %d: %.3f' % (w['vts'], w['pgcn'], best),
                  flush=True)
            if best >= w.get('min_score', 0.85):
                return True
        time.sleep(0.5)
    return False


def _shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def cmd_run(a, sc=None, out_dir=None):
    sc = sc or json.load(open(a.scenario))
    sc['_local_iso'] = a.local_iso
    out_dir = out_dir or a.out
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, 'scenario.json'), 'w') as f:
        json.dump(sc, f, indent=1)
    cap = None
    cap_path = os.path.join(out_dir, 'cap.mkv')
    if sc.get('capture_s') and not a.no_capture:
        cap = start_capture(cap_path, sc['capture_s'])
        time.sleep(1.5)                 # the card's first ~1 s is not live
    launch(sc)
    clock, events = run_agent(sc, out_dir)
    with open(os.path.join(out_dir, 'clock.json'), 'w') as f:
        json.dump(clock, f, indent=1)
    print('  clock: board->host offset %.4f s, rtt %.1f ms'
          % (clock['board_mono_to_host_wall'], clock['rtt_s'] * 1e3))
    if cap:
        cap.wait()
        if sc.get('align') and a.local_iso:
            al = sc['align']
            tl = os.path.join(out_dir, 'timeline.json')
            subprocess.run([sys.executable, os.path.join(HERE, 'hil_timeline.py'), 'align',
                            cap_path, a.local_iso, str(al['vts']), str(al['pgcn']),
                            '--cells', *map(str, al.get('cells', [])), '-o', tl]
                           + (['--overlay'] if al.get('overlay') else []))
            if not os.path.exists(tl):
                print('  alignment failed: no timeline (see above)')
                return events
            rep = subprocess.run([sys.executable, os.path.join(HERE, 'hil_timeline.py'),
                                  'report', tl, '--keys', os.path.join(out_dir, 'agent.jsonl'),
                                  '--clock', os.path.join(out_dir, 'clock.json')],
                                 capture_output=True, text=True).stdout
            with open(os.path.join(out_dir, 'report.txt'), 'w') as f:
                f.write(rep)
            print(rep)
    return events


def cmd_sweep(a):
    base = json.load(open(a.scenario))
    name, _, vals = a.vary.partition('=')
    rbfs = a.rbf or [None]
    for rbf in rbfs:
        if rbf:
            subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'deploy',
                            '--agent', '--rbf', rbf], check=True)
        for v in vals.split(','):
            sc = sub(json.loads(json.dumps(base)), {name: float(v)})
            tag = '%s_%s=%s' % (os.path.basename(rbf or 'current').replace('.rbf', ''), name, v)
            print('== %s' % tag, flush=True)
            cmd_run(a, sc, os.path.join(a.out, tag))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sp = ap.add_subparsers(dest='cmd', required=True)
    for n in ('run', 'sweep'):
        p = sp.add_parser(n)
        p.add_argument('scenario')
        p.add_argument('--out', required=True)
        p.add_argument('--no-capture', action='store_true')
        p.add_argument('--local-iso', help='host copy of the image, for the alignment')
        if n == 'run':
            p.add_argument('--rbf', help='deploy this core first')
        else:
            p.add_argument('--vary', required=True, help='NAME=v1,v2,...')
            p.add_argument('--rbf', action='append', help='repeat to A/B builds')
    a = ap.parse_args()
    if shutil.which('ffmpeg') is None:
        sys.exit('ffmpeg not found')
    if a.cmd == 'run':
        if a.rbf:
            subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'deploy',
                            '--agent', '--rbf', a.rbf], check=True)
        cmd_run(a)
    else:
        cmd_sweep(a)


if __name__ == '__main__':
    main()
