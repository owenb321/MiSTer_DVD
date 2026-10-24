#!/usr/bin/env python3
"""choice_graph.py -- map an interactive disc whose input is a CHOICE (an adventure such
as Thayer's Quest, a quiz's menus) rather than a timed shot, by playing it offline in the
core's own VM (tools/nav_offline.py's Player) and trying every button at every input
point (docs/hil_play_harness.md "Choice graphs").

    tools/choice_graph.py explore <iso> -o graph.json [--max-nodes 3000] [--max-depth 80]
    tools/choice_graph.py summary graph.json
    tools/choice_graph.py route graph.json --to "vts=5"      # shortest button script
    tools/choice_graph.py route graph.json --to "vts=8 pgcn=1 cell=12"

A NODE is an input point the model parks at: domain, VTS, PGCN, cell, its buttons
(number, links, command) and the 16 GPRMs when it got there. The registers are part of
the node's identity: in an adventure they ARE the game state (items held, progress,
lives), so the same scene with a different inventory is a different node. An EDGE is
"press button n here": it leads to the next park, or ends ('stop': the model ran out of
playback -- an ending, a credits roll, or a place the model cannot follow).

Each node keeps the shortest button script that reaches it from power-on, so `route`
answers "what do I press to get to X" -- which hil_play's autoplayer replays on the rig.

Model limits (see nav_offline.py): no clock (a timed still is skipped at once, so a
choice that only TIMES OUT is not an edge here), no rnd (a disc that draws random numbers
gives one fixed draw), and the reader is a model. A route is therefore a hypothesis to
confirm on hardware, not a fact.
"""
import argparse
import collections
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nav_offline as N   # noqa: E402

DOMS = {1: 'FP', 2: 'TT', 4: 'VMGM', 8: 'VTSM'}


def _buttons(P, st):
    """Full button records at the park the Player is sitting at: number, links, command
    (decoded), so a route can be aimed (links) and read (commands)."""
    import disc_timing as DT
    p = P.pgc
    if not p or not p.get('cells') or P.cell >= len(p['cells']):
        return []
    c = p['cells'][P.cell]
    base = P.d.vobs.get((P.dom, P.vts if P.dom in (N.DOM_VTSM, N.DOM_TT) else 0))
    if base is None or 'first' not in c:
        return []
    s = c['first']
    for _ in range(N.VOBU_SCAN):
        b = P.d.sec(base + s)
        if len(b) < 2048 or b[0:4] != b'\x00\x00\x01\xba':
            return []
        if not (b[0x26:0x2A] == b'\x00\x00\x01\xbf' and b[0x2C] == 0):
            return []
        pci = b[0x2D:0x2D + 979]
        if (int.from_bytes(pci[0x60:0x62], 'big') & 3) and (pci[0x71] & 0x3F):
            return [{k: v for k, v in bt.items() if k in ('n', 'up', 'dn', 'lf', 'rt', 'cmd', 'kind')}
                    | {'fosl': pci[0x74] & 0x3F, 'sptm_lo': int.from_bytes(pci[0x62:0x66], 'big') & 0xFFFFF}
                    for bt in DT.buttons(pci)]
        ea = int.from_bytes(b[0x40F:0x413], 'big')
        if ea == 0 or s + ea + 1 > c['last_vobu']:
            return []
        s += ea + 1
    return []


def play(iso, script):
    """Replay `script` from power-on. -> (landings, Player): the park each press led to."""
    P = N.Player(iso)
    rows = P.run(' '.join(map(str, script)), park_on_buttons=True)
    return rows, P


STATE_REGS = list(range(16))


def key_of(st):
    """Location plus the registers that ARE game state. Scratch registers (a compare
    temporary, a loop index, the choice code a dispatcher already consumed) would split
    one scene into as many nodes as paths that reach it; the profile names which
    registers matter (--state-regs)."""
    return '%s/%d/%d/%d|%s' % (DOMS.get(st['dom'], st['dom']), st['vts'], st['pgcn'], st['cell'],
                               ','.join('%x' % st['gprm'][i] for i in STATE_REGS))


def _loc(k):
    return k.split('|')[0]


def explore(iso, max_nodes, max_depth, per_loc=None, log=sys.stderr):
    """Over button presses, novelty first: the next node expanded is the one whose
    LOCATION has been expanded least, then the shallowest. Plain breadth-first spends the
    budget on menu combinatorics (an inventory screen whose every toggle flips a state
    bit) and never gets deep; coverage of places is what a map of an adventure needs.
    per_loc caps the states kept at one location (None = no cap). A node keeps the
    shortest script found to it, which under novelty-first is short but not always the
    shortest."""
    import heapq
    t0 = time.time()
    # an empty script runs to the first input point and stops there, sitting on it
    P = N.Player(iso)
    P.run('', park_on_buttons=True)
    btns = _buttons(P, None)
    st0 = P.state(len(btns))
    k0 = key_of(st0)
    nodes, edges = {k0: dict(st0, script=[], depth=0, buttons=btns)}, []
    expanded = collections.Counter()
    at_loc = collections.Counter({_loc(k0): 1})
    q = [(0, 0, 0, k0)]
    seq = 0
    runs = 0
    while q and len(nodes) < max_nodes:
        _, _, _, k = heapq.heappop(q)
        n = nodes[k]
        expanded[_loc(k)] += 1
        if n['depth'] >= max_depth:
            continue
        for b in n['buttons']:
            script = n['script'] + [b['n']]
            rows, P = play(iso, script)
            runs += 1
            if len(rows) < len(script):
                edges.append({'from': k, 'button': b['n'], 'to': None, 'why': 'never parked again'})
                continue
            st = rows[-1][1]
            if P.pgc is None:
                edges.append({'from': k, 'button': b['n'], 'to': 'STOP', 'why': 'playback stopped'})
                continue
            nk = key_of(st)
            edges.append({'from': k, 'button': b['n'], 'to': nk})
            if nk not in nodes:
                if per_loc and at_loc[_loc(nk)] >= per_loc:
                    edges[-1]['pruned'] = True     # a known place in yet another state
                    continue
                at_loc[_loc(nk)] += 1
                btns = _buttons(P, None)
                # a park with no buttons (a held still: an ending, a death) is terminal
                nodes[nk] = dict(st, script=script, depth=len(script), buttons=btns,
                                 terminal=not btns)
                if btns:
                    seq += 1
                    heapq.heappush(q, (expanded[_loc(nk)], len(script), seq, nk))
        if runs % 200 < len(n['buttons']):
            print('  %d nodes, %d edges, queue %d, %.0f s' % (len(nodes), len(edges), len(q),
                                                           time.time() - t0), file=log, flush=True)
    return {'iso': os.path.basename(iso), 'generated': time.strftime('%Y-%m-%d %H:%M'),
            'state_regs': STATE_REGS, 'per_loc': per_loc,
            'complete': not q, 'max_nodes': max_nodes, 'max_depth': max_depth,
            'nodes': nodes, 'edges': edges}


def _match(n, want):
    for kv in want.split():
        k, _, v = kv.partition('=')
        if k == 'dom':
            if DOMS.get(n['dom'], str(n['dom'])) != v:
                return False
        elif k.startswith('g'):
            if n['gprm'][int(k[1:])] != int(v, 0):
                return False
        elif n.get(k) != int(v, 0):
            return False
    return True


def summary(g):
    nodes, edges = g['nodes'], g['edges']
    out = ['%s: %d input points at %d locations, %d presses explored, %s (cap %d nodes / depth %d%s)' % (
        g['iso'], len(nodes), len({_loc(k) for k in nodes}), len(edges),
        'COMPLETE' if g['complete'] else 'INCOMPLETE', g['max_nodes'], g['max_depth'],
        ', <= %d states per location' % g['per_loc'] if g.get('per_loc') else '')]
    by = collections.Counter('%s VTS %d' % (DOMS.get(n['dom'], n['dom']), n['vts']) for n in nodes.values())
    out.append('input points by domain/VTS: ' + ', '.join('%s %d' % kv for kv in sorted(by.items())))
    first = {}
    for k, n in nodes.items():
        r = '%s VTS %d' % (DOMS.get(n['dom'], n['dom']), n['vts'])
        if r not in first or n['depth'] < first[r]['depth']:
            first[r] = n
    out.append('shortest way into each region:')
    for r, n in sorted(first.items(), key=lambda kv: kv[1]['depth']):
        out.append('   %-10s depth %3d: %s' % (r, n['depth'], ' '.join(map(str, n['script']))))
    stops = [e for e in edges if e['to'] in (None, 'STOP')]
    out.append('presses that end play (endings, or where the model stops): %d' % len(stops))
    for e in stops[:10]:
        n = nodes[e['from']]
        out.append('   from %s/%d/%d/%d button %d (%s): %s' % (
            DOMS.get(n['dom'], n['dom']), n['vts'], n['pgcn'], n['cell'], e['button'],
            next((b['cmd'] for b in n['buttons'] if b['n'] == e['button']), '?'), e['why']))
    deep = max(nodes.values(), key=lambda n: n['depth'])
    out.append('deepest input point: depth %d at %s/%d/%d/%d' % (
        deep['depth'], DOMS.get(deep['dom'], deep['dom']), deep['vts'], deep['pgcn'], deep['cell']))
    return '\n'.join(out)


def route(g, want):
    hits = [n for n in g['nodes'].values() if _match(n, want)]
    if not hits:
        return None
    return min(hits, key=lambda n: n['depth'])


def route_steps(iso, script):
    """The input points a script passes through, one per press, each with what the
    agent needs to recognise it on the rig (VTS, PGCN, domain, hli_s_ptm low 20 bits)
    and to aim at the chosen button from wherever the selection starts (tap paths over
    the authored links, from every button)."""
    import disc_timing as DT
    out = []
    for i, n in enumerate(script):
        P = N.Player(iso)
        P.run(' '.join(map(str, script[:i])), park_on_buttons=True)   # sits on park i
        st = P.state(0)
        btns = _buttons(P, None)
        if not btns or not any(b['n'] == n for b in btns):
            raise SystemExit('step %d: no button %d at %s/%d/%d/%d' % (
                i, n, DOMS.get(st['dom'], st['dom']), st['vts'], st['pgcn'], st['cell']))
        bl = [dict(b, x1=0, x2=0, y1=0, y2=0) for b in btns]
        paths = {str(b['n']): DT.path(bl, b['n'], n) for b in btns}
        out.append({'menu': st['dom'] in (4, 8), 'vts': st['vts'], 'pgcn': st['pgcn'],
                    'cell': st['cell'], 'sptm_lo': btns[0]['sptm_lo'], 'fosl': btns[0]['fosl'],
                    'button': n, 'cmd': next(b['cmd'] for b in btns if b['n'] == n),
                    'paths': {k: v for k, v in paths.items() if v is not None}})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('explore'); p.add_argument('iso'); p.add_argument('-o', '--out', required=True)
    p.add_argument('--max-nodes', type=int, default=3000)
    p.add_argument('--max-depth', type=int, default=80)
    p.add_argument('--per-loc', type=int, help='keep at most N states per location (prunes '
                   'menu combinatorics; default no cap)')
    p.add_argument('--state-regs', help='GPRMs that are game state, e.g. 1,2,3,5,6,7,13 '
                   '(default all 16); the rest are treated as scratch')
    p = sp.add_parser('summary'); p.add_argument('graph')
    p = sp.add_parser('route'); p.add_argument('graph'); p.add_argument('--to', required=True,
                                                                         help='e.g. "vts=5" or "dom=TT vts=3 cell=12 g0=0x26"')
    p.add_argument('--steps', metavar='ISO', help='also emit the per-step plan the autoplayer replays')
    a = ap.parse_args()
    if a.cmd == 'explore':
        if a.state_regs:
            STATE_REGS[:] = [int(x) for x in a.state_regs.split(',')]
        g = explore(a.iso, a.max_nodes, a.max_depth, a.per_loc)
        json.dump(g, open(a.out, 'w'))
        print(summary(g))
    elif a.cmd == 'summary':
        print(summary(json.load(open(a.graph))))
    else:
        n = route(json.load(open(a.graph)), a.to)
        if not n:
            sys.exit('no explored input point matches %r' % a.to)
        r = {'script': n['script'], 'depth': n['depth'],
             'at': {k: n[k] for k in ('dom', 'vts', 'pgcn', 'cell')}, 'gprm': n['gprm']}
        if a.steps:
            r['steps'] = route_steps(a.steps, n['script'])
        print(json.dumps(r, indent=1))


if __name__ == '__main__':
    main()
