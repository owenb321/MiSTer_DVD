#!/usr/bin/env python3
"""move_key.py -- the right move at every timed input point of a reaction game, judged
in the core's own VM (docs/hil_play_harness.md "Buttons over video").

    tools/move_key.py <iso> [--vts N...] [--limit N] [--json out.jsonl] [--show N]

Input points come from tools/timed_inputs.py (kind 'reaction': doing nothing goes on,
somewhere a press does not). At each, the VM plays every option from the window's first
cell -- doing NOTHING and each button -- and follows the path. Doing nothing is followed
PAST every later window (a wait of `--idle-cells` cell changes): consecutive windows
chain (Dragon's Lair 20th: title 3 cells 43-45, 46-48 and 49-51 are three windows of one
action, each with its own right button), so a plain "no press" only reaches the next
window, not its outcome.

Pass 1 judges each window on its own: its death is the place most options pass through.
From those, the disc's DEATH COMMAND is learned (death_commands: the command of each
wrong option's death clip, kept if it recurs) and every cell running it is a death cell.
Pass 2 walks each PGC in cell order and enters each window THROUGH the right press of the
window that leads into it (windows chain through registers: Dragon's Lair stores a value
unique to each window in g[0], alternately high and low, and the next cell's command
tests it), and calls an option WRONG if its path reaches a death cell, RIGHT otherwise. ("Comes back to this cell" is not enough: from a cold start the death
handler restarts a DIFFERENT title's scene.)

A window is reached by x-tokens: JumpTT (the title that lands in its VTS) and LinkCN
(its first cell), so whatever the scene set up before the move is not run. Keys are
cached by image fingerprint like quiz keys: tools/streams/hil_keys/<fp>.moves.jsonl.
"""
import argparse
import collections
import concurrent.futures
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def _lpgcn(n):
    return 'x200400000000%04x' % n


def _lcn(n):
    return 'x20070000000000%02x' % n


def _tail(iso, base, script, n_tail, no_park=()):
    import nav_offline as N
    P = N.Player(iso)
    P.no_park = set(no_park)
    P.run(' '.join(base + script), park_on_buttons=True)
    Q = N.Player(iso)
    Q.no_park = set(no_park)
    Q.run(' '.join(base), park_on_buttons=True)
    return [(t[1], t[2], t[3] + 1) for t in P.trace[len(Q.trace):][:n_tail]], Q


def _options(span, buttons, idle_cells=12):
    """option -> the tokens that play it at the window's park. A press carries no wait:
    the window's later cells are made not to stop play instead (Player.no_park), because
    whether a press STAYS in the window is the disc's business -- a set button's cell
    command can link out at the end of the window's first cell (TT/3/1/43: the sword sets
    g[0], 'if (g[0] > g[1]) LinkPTT 55'), and a wait counted for the whole window then
    skipped the NEXT scene's first window, whose death read as this press's."""
    opts = {'idle': ['w%d' % (len(span) + idle_cells)]}
    for b in buttons:
        if b['kind'] != 'none':
            opts[str(b['n'])] = [str(b['n'])]
    return opts


def _jvts_ptt(t, p):
    return 'x3005%04x00%02x0000' % (p, t)


def entry(ttn, pg, c0):
    # always LinkPGCN: a title need not start in PGC 1
    return [_jtt(ttn), _lpgcn(pg), _lcn(c0)]


_ENTRY = {}


def entry_for(iso, ttn, v, pg, c0):
    """Tokens that park the VM at (v, pg, c0), or None. JumpTT + LinkPGCN + LinkCN first;
    else the disc's own route into a PGC no title starts in: JumpVTS_PTT t:<the chapter
    holding the cell>. Dragon's Lair 20th VTS 6: title 12 lands in PGC 2, a dispatcher
    that JumpVTS_PTT's into PGC 1 by g[0], so 18 windows read 'unreached'."""
    import disc_timing as DT
    import nav_offline as N
    key = (v, pg, c0)
    if key in _ENTRY:
        return _ENTRY[key]
    pm = DT.dump(iso, v, pg, {0})['pm']
    prog = max((i + 1 for i, c in enumerate(pm) if c <= c0), default=1)
    for base in [entry(ttn, pg, c0)] + [[_jtt(ttn), _jvts_ptt(t, prog), _lcn(c0)] for t in (1, 2, 3)]:
        P = N.Player(iso)
        rows = P.run(' '.join(base), park_on_buttons=True)
        if rows and (rows[-1][1]['vts'], rows[-1][1]['pgcn'], rows[-1][1]['cell']) == key:
            _ENTRY[key] = base
            return base
    _ENTRY[key] = None
    return None


def judge_move(iso, ttn, pt, buttons, n_tail=10, idle_cells=12, base=None, no_park=()):
    """-> dict(verdict, answer, right, wrong, death, paths) for one timed input point.
    base: the tokens that reach it (default: JumpTT + LinkCN, i.e. entered cold)."""
    _, v, pg, c0 = pt['at'].split('/')
    v, pg, c0 = int(v), int(pg), int(c0)
    span = pt.get('cells') or [c0]
    base = base or entry_for(iso, ttn, v, pg, c0) or entry(ttn, pg, c0)
    opts = _options(span, buttons, idle_cells)
    paths, landed = {}, None
    rest = {(v, pg, c) for c in span[1:]}
    for k, scr in opts.items():
        p, Q = _tail(iso, base, scr, n_tail + (len(span) + idle_cells if k == 'idle' else 0),
                     set(no_park) | rest)
        # the window's own cells say nothing about the outcome
        paths[k] = [e for e in p if not (e[:2] == (v, pg) and e[2] in span)]
        landed = landed or (Q.state(0) if Q.pgc is not None else None)
    if not landed or (landed['vts'], landed['pgcn'], landed['cell']) != (v, pg, c0):
        return dict(verdict='unreached', answer=None, right=[], wrong=[], death=None, paths=paths,
                    landed=landed and [landed['vts'], landed['pgcn'], landed['cell']])
    seen = collections.Counter()
    first = {}
    for k, p in paths.items():
        for i, e in enumerate(dict.fromkeys(p)):
            seen[e] += 1
            first[e] = min(first.get(e, 99), i)
    order = lambda k: (k != 'idle', int(k) if k != 'idle' else 0)
    if not seen or seen.most_common(1)[0][1] < 2:
        return dict(verdict='unjudged', answer=None, right=[], wrong=[], death=None, paths=paths)
    top = max(seen.values())
    death = min((e for e, n in seen.items() if n == top), key=lambda e: first[e])
    wrong = sorted((k for k, p in paths.items() if death in p), key=order)
    right = sorted((k for k in paths if k not in wrong), key=order)
    if not right:
        verdict, ans = 'all-wrong', None
    elif 'idle' in wrong:
        verdict, ans = 'move', int(right[0])
    else:
        verdict, ans = 'wait', 'idle'
    return dict(verdict=verdict, answer=ans, right=right, wrong=wrong, death=list(death), paths=paths)


def _verdict(paths, death_set):
    order = lambda k: (k != 'idle', int(k) if k != 'idle' else 0)
    wrong = sorted((k for k, p in paths.items() if any(tuple(e) in death_set for e in p)), key=order)
    right = sorted((k for k in paths if k not in wrong), key=order)
    if not wrong:
        return 'unjudged', None, right, wrong
    if not right:
        return 'all-wrong', None, right, wrong
    if 'idle' in wrong:
        return 'move', int(right[0]), right, wrong
    return 'wait', 'idle', right, wrong


def death_commands(iso, res, min_share=0.1):
    """The disc's DEATH, as a command: for every window judged on its own, the command of
    the first cell each wrong option reaches that no right option visits (its death
    clip), kept if it recurs. Dragon's Lair 20th: 'CallSS VMGM (pgc 2, rsm_cell 1)'.
    A command, not a place: what the handler does next depends on the game's state (from
    a cold start it restarts title 2 at cell 72; mid-game it resumes and the game moves on
    to another scene), so 'reaches cell 72' was a cold-start artefact."""
    import disc_timing as DT
    cmds, c = {}, collections.Counter()
    def cmd(e):
        k = (e[0], e[1])
        if k not in cmds:
            try:
                cmds[k] = {x['cell']: x['cmd'] for x in DT.dump(iso, e[0], e[1], {0})['cells']}
            except Exception:
                cmds[k] = {}
        return cmds[k].get(e[2])
    for r in res:
        if r.get('verdict') != 'move':
            continue
        rc = {tuple(e) for o in r['right'] for e in r['paths'].get(o, [])}
        for o in r['wrong']:
            e = next((tuple(e) for e in r['paths'].get(o, []) if tuple(e) not in rc), None)
            if e and cmd(e):
                c[sig(cmd(e))] += 1
    n = sum(c.values())
    return {k for k, m in c.items() if m >= max(2, min_share * n)}


def death_cells(iso, commands):
    """Every title-domain cell whose command is a death command."""
    import disc_timing as DT
    import nav_extract as ne
    out = set()
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
                for x in DT.dump(iso, v, pg, {0})['cells']:
                    if x['cmd'] and sig(x['cmd']) in commands:
                        out.add((v, pg, x['cell']))
    return out


def sig(cmd):
    import re
    return re.sub(r'\s*\(button \d+\)', '', cmd or '').strip()


def rejudge(res, deaths):
    for r in res:
        if r['verdict'] in ('unreached',) or r['verdict'].startswith('error') or not r.get('paths'):
            continue
        paths = {k: [tuple(e) for e in p] for k, p in r['paths'].items()}
        r['verdict'], r['answer'], r['right'], r['wrong'] = _verdict(paths, deaths)
    return res


def _jtt(k):
    return 'x3002000000%02x0000' % k


def _buttons(iso, pt):
    import disc_timing as DT
    _, v, pg, c0 = pt['at'].split('/')
    d = DT.dump(iso, int(v), int(pg), {int(c0)})
    hs = [h for h in d['cells'][int(c0) - 1]['hli'] if h['btn_ns'] and (h['s_ptm'] & 0xFFFFF) == pt['sptm_lo']]
    return hs[0] if hs else d['cells'][int(c0) - 1]['hli'][0]


def _chain_job(arg):
    """Pass 2 for one PGC: windows in cell order, each entered THROUGH the right press of
    the window whose right path leads into it. Dragon's Lair stores a value unique to each
    window in g[0] and the next cell's command judges it: entered cold (g[0] = 0), cell 61
    read 'no press needed' and the rig died there after a right press at cell 60."""
    iso, ttn, pts, deaths = arg
    by_first = {p['cells'][0]: p for p in pts}
    ctx = {}
    out = []
    for p in sorted(pts, key=lambda p: p['cells'][0]):
        c0 = p['cells'][0]
        pre, pre_np = ctx.get(c0, (None, set()))
        if pre is not None and p['verdict'] not in ('unreached',) and not p['verdict'].startswith('error'):
            h = _buttons(iso, p)
            try:
                r = judge_move(iso, ttn, p, h['buttons'], base=pre, no_park=pre_np)
                if r['verdict'] != 'unreached':
                    p = dict(p, **r, chained=True)
            except Exception as e:
                p = dict(p, chain_error=str(e))
        if p.get('paths') and p['verdict'] != 'unreached':
            paths = {k: [tuple(e) for e in q] for k, q in p['paths'].items()}
            p['verdict'], p['answer'], p['right'], p['wrong'] = _verdict(paths, deaths)
            p['death_cells'] = sorted(e[2] for e in deaths if e[:2] == (int(p['at'].split('/')[1]), int(p['at'].split('/')[2])))
        if p['verdict'] in ('move', 'wait'):
            _, v, pg, _ = p['at'].split('/')
            opts = _options(p['cells'], _buttons(iso, p)['buttons'])
            tok = opts.get(str(p['answer']), [])
            if p['answer'] == 'idle':
                tok = ['w%d' % len(p['cells'])]
            base = pre if pre is not None else (entry_for(iso, ttn, int(v), int(pg), c0) or entry(ttn, int(pg), c0))
            # the windows already played on the way in keep their later cells from
            # stopping play, as they did when each was judged
            np = set(pre_np) | {(int(v), int(pg), c) for c in p['cells'][1:]}
            for e in p['paths'].get(str(p['answer']), []):
                if tuple(e[:2]) == (int(v), int(pg)) and e[2] in by_first and e[2] != c0:
                    ctx.setdefault(e[2], (base + tok, np))
                    break
        out.append(p)
    return out


def _job(arg):
    iso, ttn, pt = arg
    import disc_timing as DT
    _, v, pg, c0 = pt['at'].split('/')
    d = DT.dump(iso, int(v), int(pg), {int(c0)})
    hs = [h for h in d['cells'][int(c0) - 1]['hli'] if h['btn_ns'] and (h['s_ptm'] & 0xFFFFF) == pt['sptm_lo']]
    h = hs[0] if hs else d['cells'][int(c0) - 1]['hli'][0]
    try:
        r = judge_move(iso, ttn, pt, h['buttons'])
    except Exception as e:
        r = dict(verdict='error: %s' % e, answer=None, right=[], wrong=[], paths={})
    auto = {str(b['n']): b['auto'] for b in h['buttons']}
    return dict(pt, **r, fosl=h['fosl'], auto=auto)


def scan(iso, vts_only=None, limit=None, jobs=6):
    import quiz_key
    import timed_inputs
    pts = [p for p in timed_inputs.scan(iso)['points'] if p['kind'] == 'reaction']
    entries = quiz_key.title_entries(iso)
    todo = []
    for p in pts:
        v = int(p['at'].split('/')[1])
        if vts_only and v not in vts_only:
            continue
        if v not in entries:
            continue
        todo.append((iso, entries[v], p))
        if limit and len(todo) >= limit:
            break
    with concurrent.futures.ProcessPoolExecutor(jobs) as ex:
        res = list(ex.map(_job, todo))
        cmds = death_commands(iso, res)
        deaths = death_cells(iso, cmds)
        print('death commands %s: %d cells' % (sorted(cmds), len(deaths)), flush=True)
        res = rejudge(res, deaths)
        pgcs = collections.defaultdict(list)
        for r in res:
            _, v, pg, _ = r['at'].split('/')
            pgcs[(int(v), int(pg))].append(r)
        work = [(iso, entries[v], ps, deaths) for (v, pg), ps in pgcs.items()]
        return [r for rs in ex.map(_chain_job, work) for r in rs]


def responses(iso, keys_file, pick='right'):
    """The agent's table for timed moves: like quiz_key.responses, plus `auto` (an
    auto-action target fires on the arrow alone: no Select after it) and `idle` keys
    (hold still: logged, nothing pressed). pick='wrong' aims at the lowest WRONG press
    instead: the control arm, which moves_right must FAIL."""
    import disc_timing as DT
    out = []
    for k in map(json.loads, open(keys_file)):
        if k.get('verdict') not in ('move', 'wait'):
            continue
        _, v, pg, cell = k['at'].split('/')
        d = DT.dump(iso, int(v), int(pg), {int(cell)})
        hs = [h for h in d['cells'][int(cell) - 1]['hli'] if h['btn_ns'] and (h['s_ptm'] & 0xFFFFF) == k['sptm_lo']]
        h = hs[0] if hs else d['cells'][int(cell) - 1]['hli'][0]
        # `paths` becomes the agent's steering; the VM's option paths stay for the check
        ent = dict(k, vm_paths=k['paths'], vts=int(v), pgcn=int(pg), fosl=h['fosl'], timed=True, pick=pick)
        if pick == 'wrong':
            # the lowest wrong PRESS; where doing nothing is the only wrong option (most
            # Dragon's Lair windows: one right direction), the control holds still
            w = [o for o in k['wrong'] if o != 'idle']
            k = dict(k, answer=int(w[0]) if w else 'idle')
        # what the agent taps (timed_inputs' own `press` field is each button's outcome)
        ent['press'] = k['answer']
        ent['outcomes'] = k.get('press')
        if k['answer'] == 'idle':
            ent.update(paths={}, no_select=True)
        else:
            ent.update(paths={str(b['n']): DT.path(h['buttons'], b['n'], k['answer']) for b in h['buttons']},
                       no_select=bool(k['auto'].get(str(k['answer']))))
        out.append(ent)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('iso')
    ap.add_argument('--vts', type=int, nargs='*')
    ap.add_argument('--limit', type=int)
    ap.add_argument('--jobs', type=int, default=6)
    ap.add_argument('--json')
    ap.add_argument('--show', type=int, default=5)
    ap.add_argument('--rejudge', metavar='KEYS', help='re-judge a key file from its stored paths '
                    '(no VM run); writes --json, else in place')
    a = ap.parse_args()
    if a.rejudge:
        res = [json.loads(l) for l in open(a.rejudge)]
        res = rejudge(res, death_cells(a.iso, death_commands(a.iso, res)))
        a.json = a.json or a.rejudge
    else:
        res = scan(a.iso, set(a.vts or []) or None, a.limit, a.jobs)
    c = collections.Counter(r['verdict'] for r in res)
    print('%s: %d timed points, %s' % (os.path.basename(a.iso), len(res), dict(c)))
    for r in [r for r in res if r['verdict'] in ('move', 'wait')][:a.show]:
        print('    %s cells %s  %.2f-%.2f s  key %s  right %s wrong %s' % (
            r['at'], r['cells'], r['open_s'] or 0, r['close_s'] or 0, r['answer'], r['right'], r['wrong']))
    for r in [r for r in res if r['verdict'] not in ('move', 'wait')][:a.show]:
        print('    [%s] %s  %s' % (r['verdict'], r['at'], {k: p[:3] for k, p in r['paths'].items()}))
    if a.json:
        with open(a.json, 'w') as f:
            for r in res:
                f.write(json.dumps(r) + '\n')


if __name__ == '__main__':
    main()
