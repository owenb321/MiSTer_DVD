#!/usr/bin/env python3
"""disc_classify.py -- which play-harness primitives does each interactive disc need?
Offline: reads the image only (docs/hil_play_harness.md "Game types and primitives").

    tools/disc_classify.py <iso|dir>... [--jobs N] [-o out.jsonl]

Per disc, counted from the disc's own structures:
  shots        Set-only highlights read by a later cell command (Mad Dog's shot)
  choices      indefinite stills (0xFF) with >= 2 link buttons (Thayer's decision)
  timed_ch     link buttons live in a cell that plays video, not a still: a choice taken
               while a clip or timer runs (Dragon's Lair style) -- or a menu shown over
               playback; the disc's commands behind the window, or the rig, tell which
  multi_win    cells committing more than one distinct highlight (whack-a-mole)
  hotspots     buttons on choice screens that CallSS/JumpSS into a menu PGC, minus the
               disc's most common such target (an inventory/menu button on every
               screen): item pickups -- a proxy, the picture decides
  hidden       buttons too small (< 6 px) or outside the picture: input nobody sees
  rnd          VM rnd draws (all domains)
  counter      SetMode ... Counter: a register that counts seconds (a clock)
  loops        cell commands that link back into their own PGC's earlier cells
  subs         subpicture streams declared (title sets): possible subtitles
Then a suggested type. Only the TITLE domain's input points are counted: a game built in
menu PGCs (Scourge of Worlds) reads 'menus only' and needs a menu-domain pass. The counts are what the disc AUTHORS; whether a scene really
behaves that way is for a run on the rig to show.
"""
import argparse
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def classify(iso):
    import disc_timing as DT
    import nav_extract as ne
    out = {'iso': os.path.relpath(iso, os.environ.get('DVD_ISO_DIR', os.path.dirname(iso))),
           'shots': 0, 'choices': 0, 'timed_ch': 0, 'multi_win': 0, 'hotspots': 0,
           'hidden': 0, 'rnd': 0, 'counter': 0, 'loops': 0, 'subs': 0, 'vts': 0,
           'title_pgcs': 0, 'errors': []}
    texts, calls = [], []
    try:
        p = subprocess.run([sys.executable, os.path.join(HERE, 'iso_nav_check.py'), iso],
                           capture_output=True, text=True, timeout=600)
        texts.append(p.stdout)
    except Exception as e:
        out['errors'].append('iso_nav_check: %s' % e)
    try:
        with open(iso, 'rb') as f:
            for v in range(1, 100):
                try:
                    ifo = ne.find_vts_ifo(f, v)
                except SystemExit:
                    break
                out['vts'] = v
                f.seek(ifo * 2048)
                mat = f.read(2048)
                out['subs'] = max(out['subs'], mat[597] if len(mat) > 597 else 0)   # nr_of_vts_subp_streams
                try:
                    _, _, npgc = DT.title_pgc_addr(f, ifo, 1)
                except SystemExit:
                    continue
                for pg in range(1, npgc + 1):
                    out['title_pgcs'] += 1
                    try:
                        d = DT.dump(iso, v, pg)
                    except Exception as e:
                        out['errors'].append('VTS %d PGC %d: %s' % (v, pg, e))
                        continue
                    texts.append('\n'.join(d['pre'] + d['post']))
                    for c in d['cells']:
                        if c['cmd']:
                            texts.append(c['cmd'])
                            m = re.search(r'Link(?:CN|TopC|PrevC) ?(\d*)', c['cmd'])
                            if 'LinkTopC' in c['cmd'] or 'LinkPrevC' in c['cmd'] or (
                                    m and m.group(1) and int(m.group(1)) <= c['cell']):
                                out['loops'] += 1
                        wins = {h['s_ptm'] for h in c['hli'] if h['ss'] == 1 and h['btn_ns']}
                        if len(wins) > 1:
                            out['multi_win'] += 1
                        for h in c['hli'][:1]:
                            if not h['btn_ns']:
                                continue
                            kinds = [b['kind'] for b in h['buttons']]
                            for b in h['buttons']:
                                texts.append(b['cmd'])
                                if (b['x2'] - b['x1'] < 6 or b['y2'] - b['y1'] < 6
                                        or b['x1'] >= 720 or b['y1'] >= 576):
                                    out['hidden'] += 1
                            if h['setonly']:
                                out['shots'] += 1
                            elif kinds.count('link') >= 2 and c['still'] == 255:
                                out['choices'] += 1
                                calls += [b['cmd'] for b in h['buttons']
                                          if re.match(r'(CallSS|JumpSS) VMGM', b['cmd'])]
                            elif 'link' in kinds and c['still'] != 255 and c['dur'] > 1.0:
                                out['timed_ch'] += 1
    except Exception as e:
        out['errors'].append('walk: %s' % e)
    # the CallSS target on most choice screens is a menu/inventory button (Thayer's pouch),
    # not a pickup: only the others count as hotspots
    if calls:
        common = max(set(calls), key=calls.count)
        out['hotspots'] = sum(1 for c in calls if c != common)
    blob = '\n'.join(texts)
    out['rnd'] = len(re.findall(r'\brnd\b', blob))
    out['counter'] = len(re.findall(r'SetMode Counter', blob))
    out['type'] = suggest(out)
    return out


def suggest(o):
    t = []
    if o['shots'] >= 5:
        t.append('timed shooter')
    if o['timed_ch'] >= 5 and o['shots'] < 5:
        t.append('buttons over video')      # live while a clip/timer runs; timing unproven
    if o['multi_win'] >= 3:
        t.append('multi-window (whack-a-mole)')
    if o['choices'] >= 5:
        t.append('path/choice' + (' + items' if o['hotspots'] >= 3 else ''))
    if o['rnd'] >= 3:
        t.append('random (quiz/show/board)')
    if o['counter']:
        t.append('clocked')
    if o['hidden']:
        t.append('hidden input')
    return ', '.join(t) or 'menus only'


def _job(iso):
    try:
        return classify(iso)
    except Exception as e:
        return {'iso': iso, 'errors': ['%s' % e]}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('paths', nargs='+')
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    isos = []
    for p in a.paths:
        isos += sorted(glob.glob(os.path.join(p, '*.[iI][sS][oO]'))) if os.path.isdir(p) else [p]
    cols = ('shots', 'choices', 'timed_ch', 'multi_win', 'hotspots', 'hidden', 'rnd', 'counter',
            'loops', 'subs')
    res = []
    with concurrent.futures.ProcessPoolExecutor(a.jobs) as ex:
        for o in ex.map(_job, isos):
            res.append(o)
            print('%-48s %s  %s%s' % (o['iso'][-48:], ' '.join('%5s' % o.get(c, '?') for c in cols),
                                      o.get('type', '?'), '  [errors: %d]' % len(o['errors']) if o.get('errors') else ''),
                  flush=True)
    if a.out:
        with open(a.out, 'w') as f:
            for o in res:
                f.write(json.dumps(o) + '\n')
    print('%-48s %s' % ('', ' '.join('%5s' % c[:5] for c in cols)))


if __name__ == '__main__':
    main()
