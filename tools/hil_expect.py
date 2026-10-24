#!/usr/bin/env python3
"""hil_expect.py -- judge a hil_play run against its scenario's expectations
(docs/hil_play_harness.md "Disc profiles").

    tools/hil_expect.py <run dir> [--json]
    tools/hil_expect.py <run dir> --disc mad_dog --scenario saloon   # judge an older run
                                                   # (or re-judge after a profile edit)

The run directory's scenario.json carries "expect": a list of assertions, each one of:

    reaches         {vts, cell}       the reader entered that cell (1-based)
    reaches_any     {vts, cells}      ... one of those cells
    screen_sequence {vts, cells:[a,b]} on the CAPTURE, cell a was followed by cell b
    arms_on_time    {vts, max_late_s} every highlight armed in that VTS within
                                      +/- max_late_s of its hli_s_ptm (HLI_ARM late_ticks;
                                      negative = early, e.g. EARLY_LEAD)
    shots_scored    {vts}             every autoplayer shot in that VTS produced a
                                      BTN_ACT on its target before the cell's command ran
    no_reader_still {vts, cells}      no STATE still=1 while the reader was in those cells
    no_silence      {cells, max_s}    no capture silence (-60 dB) >= max_s while those
                                      cells (of the measured VTS) were on screen
    no_freeze       {cells, max_s}    no frozen picture >= max_s over the same span
    junction_clean  {vts, cells, window, max_s}  no freeze/silence >= max_s around each FIFO
                                      entry into those cells (angle-block ends, joins)
    no_purple       {}                no frame washed purple (the one-picture SPU blip)
    answers_right   {verdict, want}   every answer given from a responses table (quiz_key)
                                      was followed by the right answer's branch; with
                                      verdict {g, right: up}, by a write raising GPRM g
                                      (the disc's score); want "wrong" = the control arm
    moves_right     {want}            every timed move from a move table (move_key) played a
                                      right option's next cell and no death clip; want
                                      "wrong" = the control arm (every move reads wrong)
    route_followed  {}                a planned choice route (play.route_script) was taken
                                      step by step where the offline model predicted

Each assertion is PASS, FAIL or NODATA. NODATA means the instrument was not there
(a core without the nav FIFO, no capture, the scene never reached), and is never
counted as a pass: an instrument that cannot see its subject must not report health.
The exit status is 1 if anything FAILed, 2 if nothing failed but something had no data.
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np

PASS, FAIL, NODATA = 'PASS', 'FAIL', 'NODATA'


class Run:
    def __init__(self, d):
        self.d = d
        self.sc = json.load(open(os.path.join(d, 'scenario.json')))
        self.lines = [json.loads(l) for l in open(os.path.join(d, 'agent.jsonl'))]
        # Only this run's events. Before the agent emptied the Main's nav log at start
        # (2026-10-23), a run replayed the previous run's events, so a core WITHOUT the
        # FIFO appeared to have one and a duel inherited another build's arm. Anything
        # stamped before the agent started is not this run's.
        start = next((o['start'] for o in self.lines if 'start' in o), None)
        # the host emptied the log just before launching the disc: all of it is this run's
        if any(o.get('nav_fresh') for o in self.lines if 'start' in o):
            start = None
        self.stale = 0
        self.nav = []
        for o in self.lines:
            if 'nav' in o and 't_ev' in o['nav']:
                if start is not None and o['nav']['t_ev'] < start - 5.0:
                    self.stale += 1
                else:
                    self.nav.append(o['nav'])
        self.fifo = bool(self.nav)
        self.aims = [o for o in self.lines if o.get('autoplay') == 'aim']
        tl = os.path.join(d, 'timeline.json')
        self.tl = json.load(open(tl)) if os.path.exists(tl) else None
        self.cap = os.path.join(d, 'cap.mkv') if os.path.exists(os.path.join(d, 'cap.mkv')) else None
        # annotate every FIFO event with the VTS and (1-based) reader cell it happened in
        vts = cell = None
        for e in self.nav:
            if e['ev'] in ('PGC', 'CELL'):
                vts = e.get('vts', vts)
            if e['ev'] == 'CELL':
                cell = e.get('cell', 0) + 1
            e['_vts'], e['_cell'] = vts, cell

    def measured(self, vts=None):
        if not self.tl:
            return False
        return vts is None or self.sc.get('align', {}).get('vts') == vts


# ---------------------------------------------------------------------------------
def a_reaches(r, x, cells=None):
    cells = cells or [x['cell']]
    if r.fifo:
        hit = [e for e in r.nav if e['ev'] == 'CELL' and e.get('vts') == x['vts']
               and e.get('cell', -1) + 1 in cells]
        seen = sorted({e.get('cell', -1) + 1 for e in r.nav if e['ev'] == 'CELL' and e.get('vts') == x['vts']})
        return (PASS, 'reader entered cell %d' % (hit[0]['cell'] + 1)) if hit else \
            (FAIL, 'VTS %d cells reached: %s' % (x['vts'], seen or 'none'))
    if r.measured(x['vts']):
        seen = sorted({f['cell'] for f in r.tl['frames'] if f.get('cell')})
        ok = [c for c in cells if c in seen]
        return (PASS, 'cell %d on screen (capture)' % ok[0]) if ok else \
            (FAIL, 'cells on screen: %s' % seen)
    return NODATA, 'no nav FIFO and no capture of VTS %d' % x['vts']


def a_reaches_any(r, x):
    return a_reaches(r, x, x['cells'])


def a_screen_sequence(r, x):
    if not r.measured(x['vts']):
        return NODATA, 'no capture timeline of VTS %d' % x['vts']
    a, b = x['cells']
    prev, after = None, []
    for f in r.tl['frames']:
        c = f.get('cell')
        if c is None:
            continue
        if prev == a and c != a:
            after.append(c)
        prev = c
    if b in after:
        return PASS, 'cell %d -> %d on screen' % (a, b)
    return FAIL, ('cell %d was followed by %s' % (a, after) if after else 'cell %d never left the screen (or never shown)' % a)


def a_arms_on_time(r, x):
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core'
    lim = x.get('max_late_s', 0.05) * 90000
    arms = [e for e in r.nav if e['ev'] == 'HLI_ARM' and e['_vts'] == x['vts'] and e.get('btn_ns')]
    if not arms:
        return NODATA, 'no highlight armed in VTS %d' % x['vts']
    bad = [e for e in arms if abs(e.get('late_ticks', 0)) > lim]
    if bad:
        return FAIL, '; '.join('cell %s armed %+.3f s vs s_ptm' % (e['_cell'], e['late_ticks'] / 9e4)
                               for e in bad[:6])
    return PASS, '%d arms, worst %+.4f s' % (len(arms), max((e.get('late_ticks', 0) for e in arms), key=abs) / 9e4)


def a_shots_scored(r, x):
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core'
    aims = [a for a in r.aims if a['w'][0] == x['vts']]
    if not aims:
        return NODATA, 'the autoplayer fired nothing in VTS %d' % x['vts']
    bad = []
    for a in aims:
        cell0 = a['w'][2] - 1
        t0 = a.get('arm_t', a['t']) - 0.05
        cmd = next((e['t_ev'] for e in r.nav if e['ev'] == 'CELL_CMD' and e['t_ev'] > t0
                    and e.get('cell') == cell0), None)
        act = [e for e in r.nav if e['ev'] == 'BTN_ACT' and e['t_ev'] > t0
               and (cmd is None or e['t_ev'] <= cmd)]
        if not any(e.get('btn') == a['target'] for e in act):
            bad.append('cell %d target b%d: %s' % (a['w'][2], a['target'],
                       'got %s' % [e.get('btn') for e in act] if act else
                       'no button activated before the cell command'))
    return (FAIL, '; '.join(bad)) if bad else (PASS, '%d shots, each activated its target before the cell command' % len(aims))


def a_no_reader_still(r, x):
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core'
    if not any(e['_vts'] == x['vts'] for e in r.nav):
        return NODATA, 'VTS %d never reached' % x['vts']
    bad, on = [], None
    for e in r.nav:
        if e['ev'] != 'STATE' or not (e.get('chg', 0) & 2):
            continue
        if e['still']:
            on = e
        elif on:
            if on['_vts'] == x['vts'] and on['_cell'] in x['cells']:
                bad.append('cell %d still %.3f s' % (on['_cell'], e['t_ev'] - on['t_ev']))
            on = None
    return (FAIL, '; '.join(bad)) if bad else (PASS, 'no still in VTS %d cells %s' % (x['vts'], x['cells']))


def _span(r, cells):
    """Capture-file offsets (s) from the first frame of the first listed cell on screen
    to the last frame of the last, taking the first contiguous run through them."""
    fr = r.tl['frames']
    ts = [f['t'] for f in fr if f.get('cell') in cells]
    if not ts:
        return None
    start = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=start_time',
                                  '-of', 'csv=p=0', r.cap], capture_output=True, text=True).stdout)
    lo = ts[0]
    hi = lo
    for f in fr:                          # extend while we stay among the cells (or unmatched)
        if f['t'] < lo:
            continue
        if f.get('cell') in cells:
            hi = f['t']
        elif f.get('cell') is not None and f['t'] - hi > 1.0:
            break
    return lo - start, hi - start


def _detect(r, x, kind):
    if not r.cap or not r.tl:
        return NODATA, 'no capture'
    sp = _span(r, x['cells'])
    if not sp:
        return NODATA, 'cells %s never on screen' % x['cells']
    lo, hi = sp
    mx = x.get('max_s', 0.3)
    if hi - lo < max(1.0, mx):
        # a span the alignment barely saw cannot vouch for anything (castle_h12c: 0.0 s
        # and 0.2 s spans read PASS) -- an instrument blind to its subject reports health
        return NODATA, 'cells %s on screen for only %.1f s in the alignment' % (x['cells'], hi - lo)
    if kind == 'silence':
        args = ['-vn', '-af', 'silencedetect=n=-60dB:d=%.2f' % mx]
        key = 'silence_duration'
    else:
        args = ['-an', '-vf', 'crop=520:300:100:90,freezedetect=n=0.002:d=%.2f' % mx]
        key = 'freeze_duration'
    p = subprocess.run(['ffmpeg', '-hide_banner', '-ss', '%.3f' % lo, '-i', r.cap, '-t', '%.3f' % (hi - lo)]
                       + args + ['-f', 'null', '-'], capture_output=True, text=True)
    runs = [float(l.split(key + ':')[1].split()[0]) for l in p.stderr.splitlines() if key + ':' in l]
    if runs:
        return FAIL, '%s run(s) %s s over cells %s (%.1f s span)' % (kind, [round(v, 3) for v in runs], x['cells'], hi - lo)
    return PASS, 'none >= %.2f s over cells %s (%.1f s span)' % (mx, x['cells'], hi - lo)


def a_junction_clean(r, x):
    """No frozen picture or silence >= max_s around each entry into the listed cells of
    VTS x['vts'] (an angle-block end, a seamless join). The entries come from the nav
    FIFO's CELL events (the reader's), mapped to the capture through clock.json, and
    each is checked over [entry + window[0], entry + window[1]] s -- the picture runs
    behind the reader, so the window reaches past it. Picture matching is NOT used: on a
    long film it scatters, and its spans read 0 s."""
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core'
    if not r.cap:
        return NODATA, 'no capture'
    ck = os.path.join(r.d, 'clock.json')
    if not os.path.exists(ck):
        return NODATA, 'no clock.json'
    off = json.load(open(ck))['board_mono_to_host_wall']
    start = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=start_time',
                                  '-of', 'csv=p=0', r.cap], capture_output=True, text=True).stdout)
    dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                '-of', 'csv=p=0', r.cap], capture_output=True, text=True).stdout)
    w0, w1 = x.get('window', [-1.0, 6.0])
    mx = x.get('max_s', 0.5)
    ents, bad, seen = [], [], set()
    for e in r.nav:
        if e['ev'] == 'CELL' and e.get('vts') == x['vts'] and e.get('cell', -1) + 1 in x['cells']:
            c = e['cell'] + 1
            if c in seen:
                continue
            seen.add(c)
            t = e['t_ev'] + off - start
            if 0 <= t + w0 and t + w1 <= dur:
                ents.append((c, t))
    if not ents:
        return NODATA, 'no entry into cells %s inside the capture' % x['cells']
    iso = r.sc.get('_local_iso')
    tol = x.get('tolerance_s', 0.4)

    def runs_of(src, ss, tt, kind, scale=''):
        if kind == 'freeze':
            args, key = ['-an', '-vf', scale + 'crop=520:300:100:90,freezedetect=n=0.002:d=%.2f' % mx], 'freeze_duration'
        else:
            args, key = ['-vn', '-af', 'silencedetect=n=-60dB:d=%.2f' % mx], 'silence_duration'
        p = subprocess.run(['ffmpeg', '-hide_banner', '-ss', '%.3f' % max(ss, 0), '-i', src, '-t', '%.3f' % tt]
                           + args + ['-f', 'null', '-'], capture_output=True, text=True)
        out = []
        for l in p.stderr.splitlines():          # back-to-back runs add up
            if key + ':' in l:
                out.append(float(l.split(key + ':')[1].split()[0]))
        return sum(out) if out else 0.0

    def ref_cut(c):
        # the disc's own pictures/sound across the join: the previous cell and this one
        import disc_timing as DT
        d = DT.dump(iso, x['vts'], x.get('pgcn', 1), {0})
        prev = c - 1
        path = os.path.join(r.d, 'ref_join_%d.vob' % c)
        if not os.path.exists(path):
            with open(iso, 'rb') as f, open(path, 'wb') as o:
                for cc in (prev, c):
                    z = d['cells'][cc - 1]
                    f.seek(z['lba_first'] * 2048)
                    o.write(f.read((z['lba_last'] - z['lba_first'] + 1) * 2048))
        return path, d['cells'][prev - 1]['dur']

    for c, t in ents:
        for kind in ('freeze', 'silence'):
            got = runs_of(r.cap, t + w0, w1 - w0, kind)
            if not got:
                continue
            ref = 0.0
            if iso and os.path.exists(iso):
                # the film may hold a still or a quiet moment there itself: only a capture
                # freeze/silence LONGER than the disc's own across the same join is a hitch
                # (Castle in the Sky: a title card after the opening angle block)
                path, jt = ref_cut(c)
                ref = runs_of(path, jt + w0, w1 - w0, kind, 'scale=720:480,')
            if got > ref + tol:
                bad.append('cell %d: %s %.2f s (the disc itself %.2f s)' % (c, kind, got, ref))
    if bad:
        return FAIL, '; '.join(bad)
    return PASS, 'no freeze or silence >= %.2f s around %d entries %s (window %s s)' % (
        mx, len(ents), [c for c, _ in ents], [w0, w1])


def a_no_silence(r, x):
    return _detect(r, x, 'silence')


def a_no_freeze(r, x):
    return _detect(r, x, 'freeze')


def purple_frames(cap, thr=25.0):
    """Frames whose picture is washed purple-blue: (R+B)/2 - G above thr, blue well
    above green and above red (a bright red scene lifts the first term alone)."""
    W, H = 90, 60
    p = subprocess.run(['ffmpeg', '-v', 'error', '-i', cap, '-an', '-vf',
                        'crop=528:470:98:5,scale=%d:%d' % (W, H), '-pix_fmt', 'rgb24',
                        '-f', 'rawvideo', '-'], capture_output=True)
    a = np.frombuffer(p.stdout, np.uint8)
    n = len(a) // (W * H * 3)
    m = a[:n * W * H * 3].reshape(n, H * W, 3).astype(np.float32).mean(axis=1)
    score = (m[:, 0] + m[:, 2]) / 2 - m[:, 1]
    return n, np.flatnonzero((score > thr) & (m[:, 2] - m[:, 1] > 25) & (m[:, 2] > m[:, 0]))


def a_no_purple(r, x):
    if not r.cap:
        return NODATA, 'no capture'
    n, hits = purple_frames(r.cap, x.get('threshold', 25.0))
    if n == 0:
        return NODATA, 'capture decoded no frames'
    if len(hits):
        return FAIL, '%d purple frame(s) of %d, first at capture %.2f s' % (len(hits), n, hits[0] / 60.0)
    return PASS, 'none in %d frames' % n


def a_answers_right(r, x):
    """Every answer the agent gave (responses) was followed by the disc taking the RIGHT
    answer's branch: the next PGC / cell event after the press matches the target its
    command names (LinkPGCN n -> PGC n; LinkPGN/LinkCN n -> that program/cell). An answer
    whose command names no checkable target is counted, not judged."""
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core'
    answers = [o for o in r.lines if 'respond' in o and 'button' in o]
    if not answers:
        return NODATA, 'no question screen came up'
    if x.get('verdict'):
        return _answers_by_register(r, x, answers)
    table = {}
    for st in r.sc.get('steps', []):
        for k in (st.get('play') or {}).get('responses') or []:
            table[k['at']] = k
    ok, bad, unk = 0, [], 0
    for a in answers:
        key = table.get(a['respond'], {})
        if key.get('right_path'):
            # the path the disc took after the press, leaving the question's PGC: the
            # (vts, pgcn, cell) of each CELL event, PGCN carried from PGC events
            _, qv, qp, _ = a['respond'].split('/')
            seq, pg = [], None
            for e in r.nav:
                if e['t_ev'] <= a['t']:
                    continue
                if e['ev'] == 'PGC':
                    pg = e.get('pgcn')
                elif e['ev'] == 'CELL' and pg is not None:
                    step = [e.get('vts'), pg, e.get('cell', -1) + 1]
                    if (step[0], step[1]) != (int(qv), int(qp)):
                        seq.append(step)
                if len(seq) >= len(key['right_path']):
                    break
            rp = [list(x) for x in key['right_path']]
            wps = key.get('wrong_paths') or ([key['wrong_path']] if key.get('wrong_path') else [])
            wps = [[list(x) for x in w] for w in wps]
            if seq[:len(rp)] == rp:
                ok += 1
            elif any(seq[:len(w)] == w for w in wps):
                bad.append('%s: took the WRONG branch %s' % (a['respond'], seq[:len(rp)]))
            else:
                unk += 1
            continue
        m = re.search(r'Link(PGCN|PGN|CN) (\d+)', a.get('right') or '')
        if not m:
            unk += 1
            continue
        kind, n = m.group(1), int(m.group(2))
        nxt = next((e for e in r.nav if e['t_ev'] > a['t'] and e['ev'] in ('PGC', 'CELL')), None)
        if nxt is None:
            unk += 1
        elif (kind == 'PGCN' and nxt['ev'] == 'PGC' and nxt.get('pgcn') == n) or (
                kind == 'CN' and nxt['ev'] == 'CELL' and nxt.get('cell', -1) + 1 == n) or (
                kind == 'PGN' and nxt['ev'] == 'CELL'):     # program -> cell needs the map
            ok += 1
        else:
            bad.append('%s: expected %s %d, disc went to %s' % (a['respond'], kind, n,
                       {k: nxt.get(k) for k in ('ev', 'vts', 'pgcn', 'cell')}))
    if bad:
        return FAIL, '%d right, %d wrong branch: %s' % (ok, len(bad), '; '.join(bad[:3]))
    if not ok:
        return NODATA, '%d answers, none with a checkable target' % unk
    return PASS, '%d answers took the right branch%s; %d distinct questions' % (
        ok, (', %d unjudged' % unk) if unk else '', len({a['respond'] for a in answers}))


def _answers_by_register(r, x, answers):
    """answers_right judged by the disc's own score register (expect {"verdict": {"g": N,
    "right": "up"}}): after each answer, the first VM write to GPRM g[N] must RAISE it
    for a right answer; anything else (Weakest Link: the chain resets to 0) is wrong.
    A path compare cannot do this on a disc whose feedback PGCs depend on the game's
    state (players, round): the offline key, played from a cold start, names PGCs the
    rig never visits. x["want"] = "wrong" is the control arm (quiz_key pick='wrong'):
    there every answer must read wrong, or the register cannot tell the two apart."""
    g = int(x['verdict']['g'])
    want = x.get('want', 'right')
    writes = [e for e in r.nav if e['ev'] == 'GPRM' and e.get('g') == g]
    ok, bad, unk = 0, [], 0
    for i, a in enumerate(answers):
        t1 = answers[i + 1]['t'] if i + 1 < len(answers) else float('inf')
        before = next((e['val'] for e in reversed(writes) if e['t_ev'] <= a['t']), 0)
        after = next((e['val'] for e in writes if a['t'] < e['t_ev'] < t1), None)
        if after is None:
            unk += 1
            continue
        got = 'right' if after > before else 'wrong'
        if got == want:
            ok += 1
        else:
            bad.append('%s b%d: g[%d] %d -> %d reads %s' % (a['respond'], a['button'], g, before, after, got))
    if bad:
        return FAIL, '%d read %s, %d did not: %s' % (ok, want, len(bad), '; '.join(bad[:3]))
    if not ok:
        return NODATA, '%d answers, none followed by a g[%d] write' % (len(answers), g)
    return PASS, '%d answers read %s by g[%d]%s; %d distinct questions' % (
        ok, want, g, (', %d with no write' % unk) if unk else '', len({a['respond'] for a in answers}))


def a_moves_right(r, x):
    """Every timed move the agent made from a move table (tools/move_key.py) had the
    RIGHT outcome. A DEATH CLIP is a cell of the window's PGC that runs the disc's death
    command (the key's death_cells), or the first cell of a wrong option's VM path that no
    right option visits (Dragon's Lair: cell 76 for a wrong direction, cell 8 for doing
    nothing in a chained window whose first cell, 4, the right move also plays). A move is
    WRONG if the rig played one of those clips before the next move, RIGHT if it played a
    right option's first cell and no clip. Local by design: what the death handler does
    next depends on lives and scene order, and a path from a cold start names places a
    mid-game rig never visits (the Weakest Link lesson)."""
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core'
    table = {}
    for st in r.sc.get('steps', []):
        for k in (st.get('play') or {}).get('responses') or []:
            if k.get('timed'):
                table[k['at']] = k
    moves = [o for o in r.lines if 'respond' in o and 'button' in o and o['respond'] in table]
    if not moves:
        return NODATA, 'no timed move came up'
    ok, bad, unk = 0, [], 0
    for i, a in enumerate(moves):
        k = table[a['respond']]
        v = int(k['at'].split('/')[1])
        vp = {o: [tuple(e[::2]) for e in p] for o, p in (k.get('vm_paths') or {}).items()}
        rcells = {e for o in k['right'] for e in vp.get(o, [])}
        rfirst = {vp[o][0] for o in k['right'] if vp.get(o)}
        clips = {next((e for e in vp.get(o, []) if e not in rcells), None) for o in k['wrong']} - {None}
        # and every cell of this PGC that runs the disc's death command (move_key)
        clips |= {(v, c) for c in k.get('death_cells') or []}
        t1 = min(moves[i + 1]['t'] if i + 1 < len(moves) else float('inf'), a['t'] + 8)
        # title-domain cells only: while a VMGM handler runs (CallSS), the FIFO's CELL
        # event carries menu=1, cell 0 and the CALLING VTS -- read as title cell 1, it
        # matched Time Traveler's death cell 1 after every right move
        seq = [(e.get('vts'), e.get('cell', -1) + 1) for e in r.nav
               if e['ev'] == 'CELL' and a['t'] < e['t_ev'] < t1 and not e.get('menu')
               and not (e.get('vts') == v and e.get('cell', -1) + 1 in k['cells'])]
        hit = next((e for e in seq if e in clips), None)
        if seq and seq[0] in {(v, c) for c in k.get('angle_siblings') or []}:
            bad.append('%s (pressed %s): played VTS %d cell %d, the window\'s OTHER ANGLE copy' % (
                a['respond'], a['button'], *seq[0]))
        elif hit:
            bad.append('%s (pressed %s, key %s): played VTS %d cell %d, a death clip' % (
                a['respond'], a['button'], k['answer'], *hit))
        elif seq and seq[0] in rfirst:
            ok += 1
        else:
            unk += 1
    want = x.get('want', 'right')
    if want == 'wrong':
        # the control arm: every move must read wrong
        if ok:
            return FAIL, '%d moves read right in the wrong-move arm' % ok
        if not bad:
            return NODATA, '%d moves, none recognised' % len(moves)
        return PASS, '%d moves read wrong%s' % (len(bad), (', %d unrecognised' % unk) if unk else '')
    # play that keeps coming back to one window is not progress, whatever each landing
    # reads (Dragon's Lair II: a treasure taken 98 times read '8 right, 98 unrecognised')
    run, worst = 1, (1, None)
    for x, y in zip(moves, moves[1:]):
        run = run + 1 if y['respond'] == x['respond'] else 1
        worst = max(worst, (run, y['respond']), key=lambda t: t[0])
    if worst[0] >= 4:
        bad.append('%s answered %d times running: play is not getting past it' % (worst[1], worst[0]))
    if bad:
        return FAIL, '%d right, %d wrong: %s' % (ok, len(bad), '; '.join(bad[:3]))
    if not ok:
        return NODATA, '%d moves, no landing recognised' % len(moves)
    if unk > ok:
        return NODATA, '%d right but %d unrecognised: the check cannot see most moves' % (ok, unk)
    return PASS, '%d moves landed right%s; %d distinct' % (
        ok, (', %d unrecognised' % unk) if unk else '', len({a['respond'] for a in moves}))


def a_route_followed(r, x):
    """Every step of a planned choice route (play.route) was recognised on the rig, in
    order, at the input point the model predicted; the first divergence is the finding."""
    plan = next((st['play'].get('route') for st in r.sc.get('steps', [])
                 if 'play' in st and st['play'].get('route')), None)
    if not plan:
        return NODATA, 'the scenario has no planned route'
    if not r.fifo:
        return NODATA, 'no nav FIFO on this core (the route player needs it)'
    done = [o for o in r.lines if o.get('route') == 'step']
    off = [o for o in r.lines if o.get('route') == 'unexpected arm']
    resync = [o for o in r.lines if o.get('route') == 'resync']
    if done and done[-1]['step'] == len(plan) - 1:
        return PASS, 'reached the last of %d steps (%d taken%s)' % (
            len(plan), len(done), ', resynced at step %s' % [o['to_step'] for o in resync]
            if resync else '')
        return PASS, 'all %d steps taken where the model said%s' % (
            len(plan), '' if not off else ' (%d other arms ignored)' % len(off))
    first = next((o for o in off if o.get('expected_step') == len(done)), None)
    nxt = (done[-1]['step'] + 1) if done else 0
    first = next((o for o in off if o.get('expected_step') == nxt), first)
    return FAIL, 'stopped after step %d of %d; step %d expected %s at VTS %s PGC %s, %s' % (
        nxt - 1, len(plan), nxt, plan[nxt]['cmd'], plan[nxt]['vts'], plan[nxt]['pgcn'],
        'the rig armed %s instead' % first['got'] if first else 'no further input point armed')


CHECKS = {k[2:]: v for k, v in globals().items() if k.startswith('a_')}


def check(run_dir, expect=None):
    r = Run(run_dir)
    if expect is not None:
        r.sc['expect'] = expect
    out = []
    if not r.sc.get('expect'):
        out.append({'expect': {'type': '(none)'}, 'result': NODATA,
                    'detail': 'the scenario carries no expectations'})
    for x in r.sc.get('expect', []):
        fn = CHECKS.get(x.get('type'))
        if not fn:
            out.append({'expect': x, 'result': FAIL, 'detail': 'unknown expectation type'})
            continue
        try:
            res, det = fn(r, x)
        except Exception as e:
            res, det = NODATA, 'checker error: %s' % e
        out.append({'expect': x, 'result': res, 'detail': det})
    return r, out


def render(r, out):
    lines = ['%s / %s  (%s)' % (r.sc.get('_disc', '?'), r.sc.get('_scenario', '?'), r.d),
             'nav FIFO: %s, capture: %s, timeline: %s%s' % (
                 'yes' if r.fifo else 'NO', 'yes' if r.cap else 'NO', 'yes' if r.tl else 'NO',
                 ', %d nav events stamped before the run ignored (FIFO backlog or an earlier run)' % r.stale if r.stale else '')]
    for o in out:
        x = {k: v for k, v in o['expect'].items() if k != 'type'}
        lines.append('  %-6s %-16s %-34s %s' % (o['result'], o['expect']['type'],
                                                json.dumps(x, separators=(',', ':'))[:34], o['detail']))
    res = [o['result'] for o in out]
    verdict = FAIL if FAIL in res else (NODATA if NODATA in res else PASS)
    lines.append('VERDICT: %s (%d pass, %d fail, %d no data)' % (
        verdict, res.count(PASS), res.count(FAIL), res.count(NODATA)))
    return '\n'.join(lines), verdict


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('run_dir')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--disc', help='take the expectations from this profile...')
    ap.add_argument('--scenario', help='...and scenario, instead of the run\'s own')
    a = ap.parse_args()
    exp = None
    if a.disc:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import hil_disc
        sc = hil_disc.expand(hil_disc.load(a.disc), a.scenario)
        exp = sc['expect']
    r, out = check(a.run_dir, exp)
    if a.disc:
        r.sc.setdefault('_disc', a.disc)
        r.sc.setdefault('_scenario', a.scenario)
    txt, verdict = render(r, out)
    with open(os.path.join(a.run_dir, 'EXPECT.txt'), 'w') as f:
        f.write(txt + '\n')
    print(json.dumps(out, indent=1) if a.json else txt)
    sys.exit({PASS: 0, FAIL: 1, NODATA: 2}[verdict])


if __name__ == '__main__':
    main()
