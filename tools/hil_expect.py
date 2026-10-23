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
    no_purple       {}                no frame washed purple (the one-picture SPU blip)

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
