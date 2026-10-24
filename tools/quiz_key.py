#!/usr/bin/env python3
"""quiz_key.py -- derive a quiz disc's answer key from the disc itself, where the disc
holds one (docs/hil_play_harness.md "Answering").

    tools/quiz_key.py <iso>... [--json out.jsonl] [--show N]

A disc can only be answered automatically if its buttons DO different things: the right
answer leads somewhere else, or scores. For every title-domain input point with >= 3
buttons this compares what each button does (its command with the "(button N)" detail
removed):
  odd-one-out  exactly one button differs and the rest are identical -- the wrong answers
               share a destination ("Wrong!") and the right one goes elsewhere: the key
  score        buttons differ only in a register value: REPORTED, NOT A KEY -- on the
               library these were answer-index codes and menu picks (Scene It's main menu,
               Cluedo's suspects), not points
  all-same     every button does the same: the disc does not judge (an honour-system or
               board game, e.g. Scene It -- the players score off the disc)
  mixed        no single odd one out: menus, maps, multi-way choices
The verdict is a hypothesis drawn from the disc's commands; a run on the rig, with the
feedback screen recognised, confirms it.
"""
import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def sig(cmd):
    return re.sub(r'\s*\(button \d+\)', '', cmd).strip()


def judge(buttons):
    sigs = [sig(b['cmd']) for b in buttons]
    c = collections.Counter(sigs)
    if len(c) == 1:
        return 'all-same', None
    if len(c) == 2:
        (a, na), (b, nb) = c.most_common()
        if nb == 1 and na == len(sigs) - 1:
            odd = next(bt['n'] for bt, s in zip(buttons, sigs) if s == b)
            return 'odd-one-out', odd
    adds = []
    for bt, s in zip(buttons, sigs):
        m = re.search(r'g\[(\d+)\] (\+=|=) (0x[0-9a-f]+|\d+)', s)
        adds.append((int(m.group(3), 0) if m else None, bt['n']))
    if all(v is not None for v, _ in adds) and len({v for v, _ in adds}) > 1:
        return 'score', max(adds)[1]
    return 'mixed', None


def scan(iso):
    import disc_timing as DT
    import nav_extract as ne
    out = {'iso': os.path.basename(iso), 'screens': 0, 'verdicts': collections.Counter(), 'keys': []}
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
                except Exception:
                    continue
                for c in d['cells']:
                    for h in c['hli'][:1]:
                        if h['btn_ns'] < 3:
                            continue
                        out['screens'] += 1
                        verdict, ans = judge(h['buttons'])
                        out['verdicts'][verdict] += 1
                        # 'score' guesses from register values; on the library those were
                        # answer-index codes and menu picks, not points -- not a key
                        if ans is not None and verdict == 'odd-one-out':
                            out['keys'].append({'at': 'TT/%d/%d/%d' % (v, pg, c['cell']),
                                                'sptm_lo': h['s_ptm'] & 0xFFFFF, 'answer': ans,
                                                'how': verdict, 'buttons': len(h['buttons']),
                                                'still': c['still'],
                                                'right': next(b['cmd'] for b in h['buttons'] if b['n'] == ans),
                                                'wrong': next((b['cmd'] for b in h['buttons'] if b['n'] != ans), None)})
    out['verdicts'] = dict(out['verdicts'])
    return out


# ---------------------------------------------------------------------------------
# VM method: press each answer in the core's own VM and compare where it GOES
# ---------------------------------------------------------------------------------
def _jtt(k):
    return 'x3002000000%02x0000' % k


def _lpgcn(n):
    return 'x200400000000%04x' % n


def title_entries(iso, setup=()):
    """{vts: ttn}: the title whose JumpTT lands in each VTS (probed in the VM)."""
    import nav_offline as N
    out = {}
    for k in range(1, 100):
        P = N.Player(iso)
        rows = P.run(' '.join(list(setup) + [_jtt(k)]), park_on_buttons=True)
        if not rows:
            break
        st = rows[-1][1]
        if st['dom'] == 2 and st['vts'] not in out:
            out[st['vts']] = k
    return out


def _path_after(iso, script, n_tail=6):
    import nav_offline as N
    P = N.Player(iso)
    rows = P.run(' '.join(script), park_on_buttons=True)
    # the trace from the press: replay the prefix to know where it ends
    Q = N.Player(iso)
    Q.run(' '.join(script[:-1]), park_on_buttons=True)
    tail = P.trace[len(Q.trace):]
    return [(t[1], t[2], t[3] + 1) for t in tail[:n_tail]], (rows[-1][1] if rows else None)


def vm_key(iso, setup, ttn, vts, pgcn, cell, buttons):
    """Press each button of one screen in the VM; the right answer is the one whose path
    differs from all the others, after setting aside buttons that come back to this same
    screen (bank, replay). -> (verdict, answer, right_path, wrong_path, paths)."""
    base = list(setup) + [_jtt(ttn)] + ([] if pgcn == 0 else [_lpgcn(pgcn)])
    paths = {}
    for b in buttons:
        path, _ = _path_after(iso, base + [str(b['n'])])
        paths[b['n']] = path
    back = {n for n, p in paths.items() if p and p[0][:2] == (vts, pgcn) and p[0][2] <= cell}
    # compare from where the path LEAVES this question's PGC: each answer usually has its
    # own short feedback cell first (Weakest Link: cells 3/7/6/4), and only then do the
    # right and the wrong answers part ways
    rest = {n: tuple(e for e in p if e[:2] != (vts, pgcn))[:3] for n, p in paths.items() if n not in back}
    c = collections.Counter(rest.values())
    if len(rest) >= 3 and len(c) == 2:
        (maj, nmaj), (odd, nodd) = c.most_common()
        if nodd == 1:
            ans = next(n for n, p in rest.items() if p == odd)
            return 'vm-odd-one-out', ans, list(odd), list(maj), paths
    return ('vm-all-same' if len(c) == 1 else 'vm-mixed'), None, None, None, paths


def _vm_job(arg):
    iso, setup, ttn, k = arg
    _, v, pg, cell = k['at'].split('/')
    import disc_timing as DT
    d = DT.dump(iso, int(v), int(pg), {int(cell)})
    h = d['cells'][int(cell) - 1]['hli'][0]
    try:
        verdict, ans, rp, wp, paths = vm_key(iso, setup, ttn, int(v), int(pg), int(cell), h['buttons'])
    except Exception as e:
        return dict(k, how='vm-error: %s' % e, answer=None)
    return dict(k, how=verdict, answer=ans, right_path=rp, wrong_path=wp,
                paths={str(n): p for n, p in paths.items()})


def vm_scan(iso, setup=(), vts_only=None, limit=None, jobs=6):
    """VM-judged keys for every >= 3-button title screen that is the first input point of
    its PGC (reachable by JumpTT + LinkPGCN)."""
    import concurrent.futures
    import disc_timing as DT
    import nav_extract as ne
    entries = title_entries(iso, setup)
    todo = []
    with open(iso, 'rb') as f:
        for v, ttn in sorted(entries.items()):
            if vts_only and v not in vts_only:
                continue
            ifo = ne.find_vts_ifo(f, v)
            _, _, npgc = DT.title_pgc_addr(f, ifo, 1)
            for pg in range(1, npgc + 1):
                d = DT.dump(iso, v, pg)
                first = next((c for c in d['cells'] if c['hli'] and c['hli'][0]['btn_ns']), None)
                if first and first['hli'][0]['btn_ns'] >= 3:
                    h = first['hli'][0]
                    todo.append((iso, list(setup), ttn, {
                        'at': 'TT/%d/%d/%d' % (v, pg, first['cell']), 'sptm_lo': h['s_ptm'] & 0xFFFFF,
                        'buttons': h['btn_ns'], 'still': first['still']}))
                if limit and len(todo) >= limit:
                    break
    with concurrent.futures.ProcessPoolExecutor(jobs) as ex:
        return list(ex.map(_vm_job, todo))


def responses(iso, keys_file=None):
    """The agent's answer table: every derived key, with what it needs to recognise the
    screen on the rig (VTS, PGCN, hli_s_ptm low bits) and aim (paths over the links).
    keys_file: VM-judged keys (vm_scan output, JSON lines) -- else the command method."""
    import disc_timing as DT
    out = []
    keys = ([json.loads(l) for l in open(keys_file)] if keys_file else scan(iso)['keys'])
    for k in keys:
        if not k.get('answer'):
            continue
        _, v, pg, cell = k['at'].split('/')
        d = DT.dump(iso, int(v), int(pg), {int(cell)})
        h = d['cells'][int(cell) - 1]['hli'][0]
        out.append(dict(k, vts=int(v), pgcn=int(pg), fosl=h['fosl'],
                        paths={str(b['n']): DT.path(h['buttons'], b['n'], k['answer'])
                               for b in h['buttons']}))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('isos', nargs='+')
    ap.add_argument('--json')
    ap.add_argument('--show', type=int, default=3)
    ap.add_argument('--vm', action='store_true', help='judge answers by pressing them in the VM '
                    '(needed where a POST reads the selected button)')
    ap.add_argument('--setup', nargs='*', default=[], help='x-tokens run first (e.g. give a clock '
                    'time: x7100000875300000 = g[8] = 30000)')
    ap.add_argument('--vts', type=int, nargs='*')
    ap.add_argument('--limit', type=int)
    a = ap.parse_args()
    if a.vm:
        for iso in a.isos:
            res = vm_scan(iso, a.setup, set(a.vts or []) or None, a.limit)
            c = collections.Counter(r['how'] for r in res)
            print('%s: %d screens, %s' % (os.path.basename(iso), len(res), dict(c)))
            for r in [r for r in res if r.get('answer')][:a.show]:
                print('    %s b%d  right %s  wrong %s' % (r['at'], r['answer'], r['right_path'][:2], r['wrong_path'][:2]))
            if a.json:
                with open(a.json, 'w') as f:
                    for r in res:
                        f.write(json.dumps(r) + '\n')
        return
    import concurrent.futures
    with concurrent.futures.ProcessPoolExecutor(6) as ex:
        res = list(ex.map(scan, a.isos))
    for r in res:
        print('%-46s screens(>=3 btns) %4d  %s  keys %d' % (r['iso'][-46:], r['screens'], r['verdicts'], len(r['keys'])))
        for k in r['keys'][:a.show]:
            print('    %s b%d (%s, %d btns, still %d): right "%s"  wrong "%s"' % (
                k['at'], k['answer'], k['how'], k['buttons'], k['still'], k['right'][:50], (k['wrong'] or '')[:50]))
    if a.json:
        with open(a.json, 'w') as f:
            for r in res:
                f.write(json.dumps(r) + '\n')


if __name__ == '__main__':
    main()
