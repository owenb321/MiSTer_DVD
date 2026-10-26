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

Output (--out, default tools/streams/hil_runs/<time>, gitignored): scenario.json, agent.jsonl (one JSON object per press, mark, wait and
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
# The Main appends every fast-telemetry row and every nav event to these two files in
# the board's RAM-backed /tmp (246 MB). Unattended runs filled it in hours, after which
# the Main's writes failed silently. Start each run empty (which also keeps an earlier
# run's events out of this one); the agent streams what it needs to the host.
TELEM_LOG = "/tmp/dvd_telem_fast.jsonl"


def truncate_logs():
    for p_ in (TELEM_LOG, NAVTRACE):
        try:
            open(p_, "w").close()
        except Exception:
            pass


# the host empties these just before it launches the disc (launch), so what is in them now
# is this run's: the title menu can arm before the agent is up (Dragon's Lair 20th: 3 s),
# and emptying them here threw that arm away -- the route then waited ~100 s for the menu
# to come round again. Without the host's word, start clean as before.
if not sc.get("_nav_fresh"):
    truncate_logs()
KEYS = sc.get("_keys", {})
with open(FAST, "w") as f:
    f.write(str(sc.get("telem_ms", 20)))
rows, last_t, nav, nav_pos, nav_new = [], [None], {}, [0], []
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
                e = ev.get("ev")
                if e == "PGC":
                    nav.update(vts=ev["vts"], pgcn=ev["pgcn"], menu=ev["menu"])
                elif e == "CELL":
                    nav["rcell"] = ev["cell"]       # the READER's 0-based cell, ~1 s ahead
                    # when the reader entered each cell: tells apart windows whose hli_s_ptm
                    # low bits collide (resp_pick)
                    nav.setdefault("cell_t", {})[(ev.get("vts"), ev["cell"])] = ev.get("t_ev")
                elif e == "ARMED":
                    nav["armed"] = ev["armed"]
                nav_new.append(ev)
    except FileNotFoundError:
        pass
    except Exception as e:
        out({"warn": "navtrace: %s" % e})
    return rows[-1] if rows else None


def resp_pick(cands, ev):
    """One response for an arm. hli_s_ptm's low bits can COLLIDE between windows of one
    PGC whose cells restart their PTS (Dragon's Lair II: cells 22 and 27, different
    answers; the agent pressed 22's at 27 and died every other pass). The reader's CELL
    events say when each cell was read, ~a second ahead of the picture, so a window arms
    about lag + open_s after its cell was read: take the candidate that fits best, and
    learn the lag from unambiguous matches."""
    if len(cands) <= 1:
        r_ = cands[0] if cands else None
        if r_ is not None:
            t_read = nav.get("cell_t", {}).get((r_["vts"], int(r_["at"].split("/")[3]) - 1))
            if t_read is not None and r_.get("open_s") is not None:
                lag = ev["t_ev"] - t_read - r_["open_s"]
                if 0 < lag < 3:
                    nav["lag"] = 0.8 * nav.get("lag", lag) + 0.2 * lag
        return r_
    lag = nav.get("lag", 1.0)
    best, bd = None, None
    for r_ in cands:
        t_read = nav.get("cell_t", {}).get((r_["vts"], int(r_["at"].split("/")[3]) - 1))
        if t_read is None or t_read > ev["t_ev"]:
            continue
        d = abs(ev["t_ev"] - t_read - (r_.get("open_s") or 0) - lag)
        if bd is None or d < bd:
            best, bd = r_, d
    out({"resp_pick": [r_["at"] for r_ in cands], "chose": best and best["at"], "lag": round(lag, 3)})
    return best


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
out({"start": mono(), "nav_fresh": bool(sc.get("_nav_fresh"))})
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
        state["base"] = None
        # "resets": N = lock on only after the picture counter has reset N times since
        # this step began (each jump's flush resets it), e.g. 2 = past an intro to the
        # cell the second jump lands in
        need, seen, t_from = st.get("resets", 0), 0, t0
        after = t0 + st.get("after_s", 0.0)     # resets before this are ignored (an intro)
        last_c = None
        # "live_edges": N = lock on at the Nth video_live 0->1 edge after after_s instead
        # (a jump that keeps the VBUF does NOT reset the counters, but live still drops:
        # Mad Dog's intro -> duel)
        need_e, last_live = st.get("live_edges", 0), None
        # "after_still": count a live edge only once a still has been seen (Mad Dog's
        # intros all end in a 2 s still; the duel is the first live edge after it)
        saw_still = not st.get("after_still")
        while mono() < lim and (seen < need or need_e):
            r = poll()
            if r and r["t"] >= t0:
                lv = r["flags"]["video_live"]
                if need and last_c is not None and r["_c"] < last_c and r["t"] >= after:
                    seen += 1
                    t_from = r["t"]
                    out({"step": i, "reset": seen, "t": r["t"]})
                if r["flags"]["still"] and r["t"] >= after:
                    saw_still = True
                if need_e and saw_still and last_live == 0 and lv == 1 and r["t"] >= after:
                    need_e -= 1
                    t_from = r["t"]
                    out({"step": i, "live_edge": True, "t": r["t"], "_c": r["_c"]})
                last_c, last_live = r["_c"], lv
            time.sleep(0.002)
        while mono() < lim and state["base"] is None:
            r = poll()
            since = [x for x in rows if x["t"] >= t_from]
            # "menu_ok": the run may carry the menu flag (a duel entered by a jump reads
            # menu=1, still=1 throughout on these builds); otherwise a menu is not play
            if since and since[-1]["flags"]["video_live"] == 1 and (
                    st.get("menu_ok") or since[-1]["flags"]["menu"] == 0):
                state["base"] = min(since, key=lambda x: x["_c"])
            time.sleep(0.004)
        out({"step": i, "base": state["base"] and state["base"]["t"]})
        if state["base"] is None:
            ok = False
            break
    elif "play" in st:
        # Autoplay on the nav FIFO: when a scoring window arms (HLI_ARM), find it by
        # (VTS, hli_s_ptm low 20 bits) in the disc's target table, steer to its target
        # (from the forced select, else from the last button aimed at, else by homing)
        # and fire Select. Stops when `until` holds. Needs a core with the FIFO.
        pl = st["play"]
        lim = t0 + pl.get("timeout", 900)
        tbl = {}
        for w in sc.get("targets", []):
            tbl.setdefault((w["vts"], w["s_ptm"] & 0xFFFFF), []).append(w)
        last_aim, pending, met = None, [], False
        ri, last_route_btn = 0, None
        nav["route_left"] = len(pl.get("route") or [])
        # an arm queued before this step whose screen is still up (no PGC change since:
        # a title menu that armed while the agent was starting) is still live: keep it
        back = list(nav_new)
        del nav_new[:]
        live = None
        for ev in back:
            if ev.get("ev") == "HLI_ARM":
                live = ev
            elif ev.get("ev") == "PGC":
                live = None
        if live is not None:
            nav_new.append(live)
        while mono() < lim:
            r = poll()
            while nav_new:
                ev = nav_new.pop(0)
                if ev.get("ev") != "HLI_ARM" or not ev.get("btn_ns"):
                    continue
                # responses (tools/quiz_key.py): a screen -> answer table for discs whose
                # draws make the order unknowable. Matched on every arm, in any order,
                # never consumed; each answer is logged so hil_expect can check the disc
                # took the RIGHT branch afterwards.
                cands = [r_ for r_ in pl.get("responses") or []
                         if ev["sptm_lo"] == r_["sptm_lo"] and nav.get("vts") == r_["vts"]
                         and nav.get("pgcn") == r_["pgcn"]]
                resp = resp_pick(cands, ev)
                if resp is not None:
                    start = resp["fosl"] or 1
                    taps = resp["paths"].get(str(start)) or []
                    for n_, k in enumerate(taps):
                        pending.append((mono() + pl.get("route_delay_s", 0.3) + 0.06 * n_, k,
                                        {"respond": resp["at"]}))
                    # a timed move (tools/move_key.py): an auto-action target fires on the
                    # arrow alone, and a Select after it would land on whatever the jump
                    # brought up; a "wait" key presses nothing. A target that is ALREADY
                    # highlighted (no arrow to tap) still needs Select: moving onto an
                    # auto-action button fires it, being on it does not (Dragon's Lair II's
                    # sword is the centre button, the forced select: the agent pressed
                    # nothing and died there five times)
                    if not resp.get("no_select") or (not taps and resp.get("answer") != "idle"
                                                     and resp.get("press") != "idle"):
                        pending.append((mono() + pl.get("route_delay_s", 0.3) + 0.06 * len(taps) + 0.1,
                                        "select", {"respond": resp["at"]}))
                    out({"respond": resp["at"], "button": resp.get("press", resp["answer"]),
                         "answer": resp["answer"], "pick": resp.get("pick", "right"), "taps": taps,
                         "right": resp.get("right"), "t": mono(), "arm_t": ev["t_ev"]})
                    continue
                # a planned route (tools/choice_graph.py route --steps): each step names
                # the input point it expects (VTS, PGCN, hli_s_ptm low bits) and the button;
                # an arm that is not the next step is logged and NOT pressed -- a route
                # that diverged must say so, not press blind
                route = pl.get("route") or []
                if ri < len(route):
                    # resynchronise: the disc may already be further along than the model
                    # assumed (an attract loop's first pass sets state the model's earlier
                    # press skipped), so an arm that matches ANY later step jumps the plan
                    # there -- same destination, entered from where the disc really is
                    # In the VMGM domain the core keeps reporting the title set it was
                    # called from (a CallSS from VTS 3 reads vts=3) while the model says 0:
                    # match a VMGM step on the menu flag, PGCN and start time only.
                    def _is(k):
                        r_ = route[k]
                        if ev["sptm_lo"] != r_["sptm_lo"] or nav.get("pgcn") != r_["pgcn"]:
                            return False
                        if r_.get("dom") == "VMGM":
                            # at power-on the FIFO's PGC events read vts=0 with menu=0
                            return bool(nav.get("menu")) or nav.get("vts") == 0
                        return nav.get("vts") == r_["vts"] and bool(nav.get("menu")) == bool(r_.get("menu"))
                    hit_ = next((k for k in range(ri, len(route)) if _is(k)), None)
                    if hit_ is not None and hit_ > ri:
                        out({"route": "resync", "from_step": ri, "to_step": hit_, "t": mono()})
                        ri = hit_
                    sp_ = route[ri]
                    if hit_ is not None:
                        start = sp_["fosl"] or last_route_btn or 1
                        taps = sp_["paths"].get(str(start))
                        if taps is None:
                            out({"route": "no path", "step": ri, "from": start, "to": sp_["button"]})
                            taps = []
                        for n_, k in enumerate(taps):
                            pending.append((mono() + pl.get("route_delay_s", 0.3) + 0.06 * n_, k,
                                            {"route_step": ri}))
                        pending.append((mono() + pl.get("route_delay_s", 0.3) + 0.06 * len(taps) + 0.1,
                                        "select", {"route_step": ri}))
                        out({"route": "step", "step": ri, "button": sp_["button"], "taps": taps,
                             "at": [sp_["vts"], sp_["pgcn"], sp_["cell"]], "cmd": sp_["cmd"],
                             "t": mono(), "arm_t": ev["t_ev"]})
                        last_route_btn = sp_["button"]
                        ri += 1
                        nav["route_left"] = len(route) - ri
                        continue
                    out({"route": "unexpected arm", "expected_step": ri,
                         "want": [sp_["vts"], sp_["pgcn"], sp_["sptm_lo"]],
                         "got": [nav.get("vts"), nav.get("pgcn"), ev["sptm_lo"]], "t": mono()})
                    continue
                key = "%s:%s" % (nav.get("vts"), nav.get("pgcn"))
                # "VTS:PGCN" = press Select there; "VTS:PGCN=right,right" = taps first
                # (a route menu: pick a route other than the preselected one)
                # "VTS:PGCN@sptm_lo" names one window (e.g. Mad Dog's intro skip, VTS 1
                # PGC 1 @16274), leaving that PGC's other windows to the shot table
                hit = [a for a in pl.get("also_select", [])
                       if a.split("=")[0] in (key, "%s@%d" % (key, ev["sptm_lo"]))]
                if hit:
                    taps = [k for k in hit[0].partition("=")[2].split(",") if k]
                    for n_, k in enumerate(taps):
                        pending.append((mono() + 0.6 + 0.1 * n_, k, {"why": key}))
                    pending.append((mono() + 1.0 + 0.1 * len(taps), "select", {"why": key}))
                    continue
                ws = [w for w in tbl.get((nav.get("vts"), ev["sptm_lo"]), [])
                      if w["pgcn"] == nav.get("pgcn")] or tbl.get((nav.get("vts"), ev["sptm_lo"]), [])
                if not ws:
                    out({"autoplay": "unknown window", "vts": nav.get("vts"),
                         "pgcn": nav.get("pgcn"), "sptm_lo": ev["sptm_lo"],
                         "btn_ns": ev.get("btn_ns"), "t": mono()})
                    # explore: take the preselected button on any screen it cannot
                    # place, so a menu-driven disc walks its default path
                    if pl.get("select_unknown_after_s") is not None:
                        pending.append((mono() + pl["select_unknown_after_s"], "select",
                                        {"why": "unknown %s:%s@%d" % (nav.get("vts"), nav.get("pgcn"),
                                                                      ev["sptm_lo"])}))
                    continue
                w = ws[0]
                if not w["targets"]:
                    out({"autoplay": "no target", "w": [w["vts"], w["pgcn"], w["cell"]], "t": mono()})
                    continue
                start = w["fosl"] or last_aim
                taps = w["from"].get(str(start)) if start else None
                how = "from b%s" % start if taps is not None else "homing"
                if taps is None:
                    taps = w["aim"] or []
                ov = pl.get("override", {}).get("%d:%d:%d" % (w["vts"], w["pgcn"], w["cell"]), {})
                if ov.get("skip"):
                    out({"autoplay": "skipped", "w": [w["vts"], w["pgcn"], w["cell"]], "t": mono()})
                    continue
                tt = [tap(KEYS[k], pl.get("hold_ms", 20)) for k in taps]
                fire = max(mono() + pl.get("delay_s", 0.15) + 0.03 * len(taps),
                           mono() + ov.get("select_after_arm_s", 0.0))
                pending.append((fire, "select", {"w": [w["vts"], w["pgcn"], w["cell"]]}))
                last_aim = w["targets"][0]
                out({"autoplay": "aim", "w": [w["vts"], w["pgcn"], w["cell"]], "target": last_aim,
                     "how": how, "taps": taps, "t": tt[0] if tt else mono(), "arm_t": ev["t_ev"]})
            for p_ in [p_ for p_ in pending if mono() >= p_[0]]:
                pending.remove(p_)
                t = tap(KEYS[p_[1]], 30)
                out(dict(p_[2], autoplay=p_[1], t=t))
            try:
                if r and eval(pl["until"], {}, env(r)):
                    met = True
                    break
            except Exception as e:
                out({"step": i, "err": "until: %s" % e}); break
            time.sleep(0.002)
        out({"step": i, "play_until": pl["until"], "met": met, "t": mono()})
        if not met:
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
    elif "keys" in st and "at_picture" in st:
        # a burst of taps, written back to back: the key daemon plays them in order,
        # hold_ms each. The FIFO's PS2 events (when present) give each one's arrival.
        if state["base"] is None:
            out({"step": i, "err": "at_picture before base"}); ok = False; break
        lim = t0 + st.get("timeout", 30)
        while mono() < lim:
            r = poll()
            if r and env(r)["pictures"] >= st["at_picture"]:
                ts = [tap(c, st.get("hold_ms", 20)) for c in st["codes"]]
                out({"step": i, "keys": st["keys"], "t": ts[0], "t_last": ts[-1],
                     "at_picture": st["at_picture"], "pictures": env(r)["pictures"]})
                break
            time.sleep(0.001)
        else:
            out({"step": i, "err": "picture %d never reached" % st["at_picture"]})
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
time.sleep(0.1)
truncate_logs()
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
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


def launch(sc):
    cmd = [sys.executable, os.path.join(HERE, 'mister.py'), 'launch', sc['iso']]
    for k, v in sc.get('opts', {}).items():
        cmd += ['--opt', '%s=%s' % (k, v)]
    _, n = M.ssh('wc -l < /tmp/dvd_report.log 2>/dev/null || echo 0\n'
                 ': > /tmp/dvd_navtrace.jsonl 2>/dev/null; : > /tmp/dvd_telem_fast.jsonl 2>/dev/null\n',
                 check=False)
    sc['_nav_fresh'] = True
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        sys.exit('launch failed:\n' + p.stdout + p.stderr)
    # a failed mount still tells the core a disc arrived; catch it here, not as a timeout.
    # Only this launch's lines: the log keeps earlier launches'.
    _, log = M.ssh('tail -n +%d /tmp/dvd_report.log 2>/dev/null | grep "mount result" | tail -1\n'
                   % (int(n.strip() or 0) + 1), check=False)
    if 'FAILED' in log:
        sys.exit('launch: the image did not mount (%s) -- is the share mounted?' % log.strip())


def key_file(fp, suffix):
    """(path, where-to-build) of an image's VM-judged keys. The committed set in
    tools/hil_discs/keys/ comes first, so the suite runs on any checkout; a local cache in
    tools/streams/hil_keys/ (gitignored) is the fallback for keys still being worked on."""
    for d in (os.path.join(HERE, 'hil_discs', 'keys'), os.path.join(HERE, 'streams', 'hil_keys')):
        p = os.path.join(d, fp + suffix)
        if os.path.exists(p):
            return p, p
    return None, os.path.join(HERE, 'hil_discs', 'keys', fp + suffix)


def run_agent(sc, out_dir):
    names = M.key_names()
    sc['_keys'] = {k: names[k] for k in ('up', 'down', 'left', 'right', 'select')}
    if any('play' in st for st in sc['steps']):
        sc['targets'] = targets_for(sc.get('_local_iso'))
    for st in sc['steps']:
        # a choice route is stored as its button script; the per-step plan (what each
        # input point looks like, how to aim) is derived from the image at run time
        if 'play' in st and st['play'].get('responses_from') == 'quiz_vm' and not st['play'].get('responses'):
            # VM-judged keys take minutes per disc: cached by image fingerprint
            import hil_disc
            import quiz_key
            kf, want = key_file(hil_disc.fingerprint(sc.get('_local_iso')), '.jsonl')
            if not kf:
                sys.exit('no VM answer keys for this image: build them with\n'
                         '  tools/quiz_key.py <iso> --vm --setup <profile quiz.setup> --json %s' % want)
            st['play']['responses'] = quiz_key.responses(sc.get('_local_iso'), kf,
                                                        st['play'].get('pick', 'right'))
            print('  responses: %d VM-judged answer keys' % len(st['play']['responses']), flush=True)
        if 'play' in st and st['play'].get('responses_from') == 'move_vm' and not st['play'].get('responses'):
            # timed moves (reaction games), judged in the VM: cached by image fingerprint
            import hil_disc
            import move_key
            kf, want = key_file(hil_disc.fingerprint(sc.get('_local_iso')), '.moves.jsonl')
            if not kf:
                sys.exit('no move keys for this image: build them with\n'
                         '  tools/move_key.py <iso> --json %s' % want)
            st['play']['responses'] = move_key.responses(sc.get('_local_iso'), kf,
                                                         st['play'].get('pick', 'right'))
            # windows the profile says not to answer (a tutorial the route skips past:
            # Time Traveler's practice moves, where nothing kills and the learner's
            # 'death' is the call that starts the game)
            skip = tuple(st['play'].get('skip_keys') or ())
            if skip:
                st['play']['responses'] = [r for r in st['play']['responses'] if not r['at'].startswith(skip)]
            print('  responses: %d VM-judged timed moves' % len(st['play']['responses']), flush=True)
        if 'play' in st and st['play'].get('responses_from') == 'quiz_key' and not st['play'].get('responses'):
            import quiz_key
            st['play']['responses'] = quiz_key.responses(sc.get('_local_iso'))
            print('  responses: %d answer keys from the disc' % len(st['play']['responses']), flush=True)
        if 'play' in st and st['play'].get('route_script') is not None and not st['play'].get('route'):
            import choice_graph
            st['play']['route'] = choice_graph.route_steps(sc.get('_local_iso'),
                                                           st['play']['route_script'])
            print('  route: %d steps planned' % len(st['play']['route']), flush=True)
    for st in sc['steps']:
        if 'keys' in st:
            bad = [k for k in st['keys'] if k not in names]
            if bad:
                sys.exit('unknown keys %r' % bad)
            st['codes'] = [names[k] for k in st['keys']]
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


def targets_for(iso):
    """The disc's scoring windows with their targets and aim paths (disc_timing),
    cached beside the run because a full disc walk takes ~30 s."""
    import disc_timing as DT
    if not iso:
        sys.exit('a "play" step needs --local-iso (the target table comes from the disc)')
    cache = os.path.join(os.environ.get('TMPDIR', '/tmp'),
                         'hil_targets_%s.json' % os.path.basename(iso).replace(' ', '_'))
    if os.path.exists(cache) and os.path.getmtime(cache) > os.path.getmtime(iso):
        return json.load(open(cache))
    t = [{k: v for k, v in w.items() if k != 'cmd'} for w in DT.scoring_targets(iso)]
    json.dump(t, open(cache, 'w'))
    return t


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


def scenario_of(a, sets=None):
    """The scenario to run: a JSON file, or a profile's named scenario with its image
    resolved for this rig (tools/hil_disc.py)."""
    if a.disc:
        import hil_disc
        prof = hil_disc.load(a.disc)
        if not a.scenario:
            sys.exit('--disc needs --scenario (tools/hil_disc.py list)')
        sc = hil_disc.expand(prof, a.scenario, sets)
        if not (a.iso and a.local_iso):
            host_iso, board_iso = hil_disc.resolve_image(prof, hil_disc.rig(a.rig))
            a.local_iso = a.local_iso or host_iso
            sc['iso'] = a.iso or board_iso
        else:
            sc['iso'] = a.iso
        if not sc.get('iso'):
            sys.exit('no rig path for the image: set share_root in tools/.mister_rigs.json or pass --iso')
        return sc
    if not a.scenario:
        sys.exit('give a scenario file, or --disc NAME --scenario NAME')
    sc = json.load(open(a.scenario))
    if sets:
        sc = sub(sc, sets)
    if a.iso:
        sc['iso'] = a.iso
    return sc


def cmd_run(a, sc=None, out_dir=None):
    sc = sc or scenario_of(a, a._sets)
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
    with open(os.path.join(out_dir, 'scenario.json'), 'w') as f:
        json.dump(sc, f, indent=1)      # again: run_agent derived the route plan, targets
    with open(os.path.join(out_dir, 'clock.json'), 'w') as f:
        json.dump(clock, f, indent=1)
    print('  clock: board->host offset %.4f s, rtt %.1f ms'
          % (clock['board_mono_to_host_wall'], clock['rtt_s'] * 1e3))
    if cap:
        # capture_s is a ceiling, not the length: stop a couple of seconds after the
        # agent finishes ('q' makes ffmpeg finalise the file cleanly)
        time.sleep(2.0)
        try:
            cap.communicate(b'q', timeout=30)
        except Exception:
            cap.kill()
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
    if sc.get('expect'):
        import hil_expect
        r, res = hil_expect.check(out_dir)
        txt, verdict = hil_expect.render(r, res)
        with open(os.path.join(out_dir, 'EXPECT.txt'), 'w') as f:
            f.write(txt + '\n')
        print(txt, flush=True)
        a._verdicts.append((out_dir, verdict))
    return events


def cmd_sweep(a):
    name, _, vals = a.vary.partition('=')
    rbfs = a.rbf or [None]
    for rbf in rbfs:
        if rbf:
            subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'deploy',
                            '--agent', '--rbf', rbf], check=True)
        for v in vals.split(','):
            sc = scenario_of(a, dict(a._sets, **{name: float(v)}))
            tag = '%s_%s=%s' % (os.path.basename(rbf or 'current').replace('.rbf', ''), name, v)
            print('== %s' % tag, flush=True)
            cmd_run(a, sc, os.path.join(a.out, tag))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sp = ap.add_subparsers(dest='cmd', required=True)
    sp.add_parser('list', help='disc profiles and their scenarios')
    for n in ('run', 'sweep'):
        p = sp.add_parser(n)
        p.add_argument('scenario_file', nargs='?', help='a scenario JSON (or use --disc/--scenario)')
        p.add_argument('--disc', help='a profile in tools/hil_discs/')
        p.add_argument('--scenario', dest='scenario', help='a scenario of that profile')
        p.add_argument('--rig', help='a rig in tools/.mister_rigs.json (default: its "default")')
        p.add_argument('--set', action='append', default=[], help='NAME=value for a $NAME')
        p.add_argument('--iso', help='the image path ON THE RIG (default: resolved)')
        p.add_argument('--out', help='run directory (default tools/streams/hil_runs/<time>: '
                       'gitignored and on disk; a game-length capture is ~3 MB/s, too big '
                       'for a RAM-backed /tmp)')
        p.add_argument('--no-capture', action='store_true')
        p.add_argument('--local-iso', help='host copy of the image, for the alignment')
        if n == 'run':
            p.add_argument('--rbf', help='deploy this core first')
        else:
            p.add_argument('--vary', required=True, help='NAME=v1,v2,...')
            p.add_argument('--rbf', action='append', help='repeat to A/B builds')
    a = ap.parse_args()
    if a.cmd == 'list':
        import hil_disc
        sys.argv = ['hil_disc.py', 'list']
        return hil_disc.main()
    if a.scenario_file and not a.disc:
        a.scenario = a.scenario_file
    a._sets = {}
    for kv in a.set:
        k, _, v = kv.partition('=')
        try:
            a._sets[k] = float(v)
        except ValueError:
            a._sets[k] = v
    a._verdicts = []
    if a.disc or a.rig:
        import hil_disc
        r = hil_disc.rig(a.rig)
        if r.get('host'):
            os.environ['MISTER_HOST'] = r['host']   # every mister.py call follows it
    if not a.out:
        a.out = os.path.join(HERE, 'streams', 'hil_runs', time.strftime('%Y%m%d_%H%M%S'))
    if shutil.which('ffmpeg') is None:
        sys.exit('ffmpeg not found')
    if a.cmd == 'run':
        if a.rbf:
            subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), 'deploy',
                            '--agent', '--rbf', a.rbf], check=True)
        cmd_run(a)
    else:
        cmd_sweep(a)
    if a._verdicts:
        print('\n'.join('%-7s %s' % (v, d) for d, v in a._verdicts))
        rank = {'PASS': 0, 'NODATA': 2, 'FAIL': 1}
        sys.exit(max(rank[v] for _, v in a._verdicts) if any(v == 'FAIL' for _, v in a._verdicts)
                 else max(rank[v] for _, v in a._verdicts))


if __name__ == '__main__':
    main()
