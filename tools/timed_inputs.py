#!/usr/bin/env python3
"""timed_inputs.py -- what each "buttons over video" input point of a disc really is
(docs/hil_play_harness.md "Buttons over video").

    tools/timed_inputs.py <iso|dir>... [--jobs N] [--show N] [-o out.jsonl]

disc_classify counts a title-domain cell that plays video while link buttons are live as
"timed". That lumps together three things a play harness treats very differently, told
apart here by what happens if NOBODY presses (the cell's command, else the next cell,
else the POST) against what each button does:

  loop-wait   doing nothing comes back to this cell (LinkPGN/LinkCN to it or earlier,
              LinkTopC, LinkPrevC): a menu over a looping clip -- no timing to hit,
              it is a choice still in all but name (Tomb Raider's "press to go on")
  skip        every button goes where doing nothing goes: pressing only gets there
              sooner
  menu-call   every press only calls a menu (CallSS/JumpSS: pause, inventory)
  reaction    doing nothing goes ON, somewhere a press does not: the window is a
              moment to act in, and missing it is a different story (Dragon's Lair)

A window that runs on through the next cells with the same buttons is ONE input point
(Dragon's Lair 20th: a move opens 4.2 s into cell 43 and closes at the end of cell 45);
its open/close are timed from its first cell, and `cells` names the span. `actions`
counts buttons that only SET a register for a later cell command to judge (the sword,
like Mad Dog's shot). e_ptm absent = open to the end of the cell.

Outcomes are compared statically, from the commands: a button that sets a register and
LinkTailPGC is told apart from another by what it sets (the POST decides), so two of
those read as different even where the POST would merge them. The rig, or the VM
(choice_graph), settles any one input point; this sizes the population.
Per window: open/close in seconds from the cell's first picture, and the cell length.
"""
import argparse
import collections
import concurrent.futures
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

NO_END = 0xFFFFFFFF


def sig(cmd):
    return re.sub(r'\s*\(button \d+\)', '', cmd or '').strip()


def outcome(cmd, cell, ncells, pm):
    """A comparable target for one command run at the end of / from cell `cell`:
    ('cell', n) inside this PGC, ('loop',) when that is this cell or an earlier one,
    else the command's own text (other PGCs, register sets + TailPGC, conditionals)."""
    s = sig(cmd)
    if s.startswith('if '):
        return ('cmd', s)
    m = re.match(r'^LinkPGN (\d+)$', s)
    if m:
        p = int(m.group(1))
        n = pm[p - 1] if 1 <= p <= len(pm) else None
        return ('cmd', s) if n is None else (('loop',) if n <= cell else ('cell', n))
    m = re.match(r'^LinkCN (\d+)$', s)
    if m:
        n = int(m.group(1))
        return ('loop',) if n <= cell else ('cell', n)
    if s in ('LinkTopC', 'LinkPrevC'):
        return ('loop',)
    if s == 'LinkNextC':
        return ('cell', cell + 1) if cell < ncells else ('post',)
    if s == 'LinkTailPGC':
        return ('post',)
    return ('cmd', s)


def idle_outcome(c, ncells, pm):
    if c['cmd']:
        return outcome(c['cmd'], c['cell'], ncells, pm)
    return ('cell', c['cell'] + 1) if c['cell'] < ncells else ('post',)


def classify_cell(c, ncells, pm):
    """-> list of input points (one per distinct HLI window with link buttons)."""
    out, seen = [], set()
    if c.get('still') == 0xFF:
        return out
    idle = idle_outcome(c, ncells, pm)
    for h in c.get('hli') or []:
        if not h['btn_ns'] or (h['s_ptm'], h['e_ptm']) in seen:
            continue
        seen.add((h['s_ptm'], h['e_ptm']))
        # a SET button is an input too: the cell command judges it later (Dragon's
        # Lair's sword, Mad Dog's shot). Windows of set buttons only were dropped here,
        # which hid most of Dragon's Lair's moves.
        links = [b for b in h['buttons'] if b['kind'] in ('link', 'set')]
        if not links:
            continue
        presses = {b['n']: outcome(b['cmd'], c['cell'], ncells, pm) for b in links}
        menu = all(o[0] == 'cmd' and re.match(r'(CallSS|JumpSS) ', o[1]) for o in presses.values())
        if idle == ('loop',):
            kind = 'loop-wait'
        elif menu:
            kind = 'menu-call'
        elif all(o == idle for o in presses.values()):
            kind = 'skip'
        else:
            kind = 'reaction'
        fp = c.get('first_ptm')
        end = c.get('end_ptm')
        to_end = h['e_ptm'] in (None, NO_END)
        close = end if to_end else h['e_ptm']
        out.append({'cell': c['cell'], 'kind': kind, 'buttons': len(h['buttons']),
                    'links': len(links), 'still': c['still'], 'dur': round(c['dur'], 2),
                    'open_s': round((h['s_ptm'] - fp) / 90000, 3) if fp is not None else None,
                    'close_s': round((close - fp) / 90000, 3) if fp is not None and close else None,
                    'to_end': to_end, 'cells': [c['cell']],
                    'actions': sum(1 for b in h['buttons'] if b['kind'] != 'link'
                                   and re.match(r'(SetMode Register )?g\[\d+\] (=|\+=)', sig(b['cmd']))),
                    'layout': [(b['n'], b['kind'], re.sub(r'0x[0-9a-f]+|\d+$', '#', sig(b['cmd'])))
                               for b in h['buttons']],
                    'sptm_lo': h['s_ptm'] & 0xFFFFF,
                    'idle': list(idle), 'press': {str(n): list(o) for n, o in presses.items()}})
    return out


def scan(iso):
    import disc_timing as DT
    import nav_extract as ne
    res = {'iso': os.path.relpath(iso, os.environ.get('DVD_ISO_DIR', os.path.dirname(iso))),
           'points': [], 'errors': []}
    with open(iso, 'rb') as f:
        for v in range(1, 100):
            try:
                ifo = ne.find_vts_ifo(f, v)
            except SystemExit:
                break
            try:
                _, _, npgc = DT.title_pgc_addr(f, ifo, 1)
            except SystemExit:
                continue
            for pg in range(1, npgc + 1):
                try:
                    d = DT.dump(iso, v, pg)
                except Exception as e:
                    res['errors'].append('VTS %d PGC %d: %s' % (v, pg, e))
                    continue
                n = len(d['cells'])
                prev = None
                for c in d['cells']:
                    pts = classify_cell(c, n, d['pm'])
                    # a window that runs on into this cell with the same buttons: one point
                    if (prev and len(pts) == 1 and (pts[0]['open_s'] or 0) <= 0.1 and prev['to_end']
                            and pts[0]['layout'] == prev['layout'] and prev['cells'][-1] == c['cell'] - 1):
                        q = pts[0]
                        prev['close_s'] = round(prev['span_s'] + q['close_s'], 3)
                        prev['span_s'] = round(prev['span_s'] + q['dur'], 3)
                        prev['to_end'] = q['to_end']
                        prev['cells'].append(c['cell'])
                        prev['idle'] = q['idle']          # what doing nothing does: the LAST cell's
                        if q['kind'] != prev['kind'] and 'reaction' in (q['kind'], prev['kind']):
                            prev['kind'] = 'reaction'
                        continue
                    for p in pts:
                        p['span_s'] = p['dur']
                        res['points'].append(dict(p, at='TT/%d/%d/%d' % (v, pg, c['cell'])))
                    prev = res['points'][-1] if pts and res['points'][-1]['at'].endswith('/%d' % c['cell']) else None
    res['kinds'] = dict(collections.Counter(p['kind'] for p in res['points']))
    return res


def _job(iso):
    try:
        return scan(iso)
    except Exception as e:
        return {'iso': iso, 'points': [], 'kinds': {}, 'errors': [str(e)]}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('paths', nargs='+')
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--show', type=int, default=0, help='list N reaction points per disc')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    isos = []
    for p in a.paths:
        isos += sorted(glob.glob(os.path.join(p, '*.[iI][sS][oO]'))) if os.path.isdir(p) else [p]
    res = []
    with concurrent.futures.ProcessPoolExecutor(a.jobs) as ex:
        for r in ex.map(_job, isos):
            res.append(r)
            k = r['kinds']
            rx = [p for p in r['points'] if p['kind'] == 'reaction']
            win = sorted(p['close_s'] - p['open_s'] for p in rx
                         if p['open_s'] is not None and p['close_s'] is not None)
            print('%-48s loop-wait %4d  skip %4d  menu %4d  reaction %4d (actions in %d)%s%s' % (
                r['iso'][-48:], k.get('loop-wait', 0), k.get('skip', 0), k.get('menu-call', 0),
                k.get('reaction', 0), sum(1 for p in rx if p['actions']),
                '  window median %.2f s' % win[len(win) // 2] if win else '',
                '  [errors: %d]' % len(r['errors']) if r['errors'] else ''), flush=True)
            for p in rx[:a.show]:
                print('    %s%s %.2f-%.2f s of %.2f%s  idle %s  press %s' % (
                    p['at'], ('-%d' % p['cells'][-1]) if len(p['cells']) > 1 else '',
                    p['open_s'] or 0, p['close_s'] or 0, p['span_s'],
                    ' (to end)' if p['to_end'] else '', p['idle'], p['press']))
    if a.out:
        with open(a.out, 'w') as f:
            for r in res:
                f.write(json.dumps(r) + '\n')


if __name__ == '__main__':
    main()
