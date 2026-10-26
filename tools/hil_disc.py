#!/usr/bin/env python3
"""hil_disc.py -- disc profiles for the real-time play harness: what is known about one
interactive disc, and the named, repeatable tests run on it (docs/hil_play_harness.md
"Disc profiles").

    tools/hil_disc.py list                       # profiles and their scenarios
    tools/hil_disc.py show mad_dog saloon        # the expanded scenario, as the agent gets it
    tools/hil_disc.py resolve mad_dog            # where the image is, on the host and the rig
    tools/hil_disc.py draft <iso> [-o new.json]  # a starting profile for a new disc
    tools/hil_disc.py explored <run dir>         # after its "explore" scenario ran on HW:
                                                 # what the profile still has to answer

A profile (tools/hil_discs/<name>.json) holds only facts about the DISC, never about a
rig or a workstation:

    image     {"fingerprint": sha1 of VIDEO_TS.IFO, "name_hints": [paths relative to the
              library root]} -- the image is found by content, so a rip filed under
              another name, or on another share layout, still resolves
    pal       25 fps content (default 29.97)
    policy    {"also_select": {name: "VTS:PGCN[@sptm][=taps]"}, "routes": {name: ...}}:
              non-shot screens the autoplayer must answer (menus, continue, skips)
    macros    {name: [steps]}: step lists scenarios reuse ({"macro": name})
    notes     [{"text", "why"}]: what was learned the hard way, so a later session does
              not rediscover it
    scenarios {name: {"description", "steps", "measure", "expect", ...}}

In a scenario's steps, a "play" step names policy entries instead of spelling them:
"policy": ["intro_skip", "continue", "route:saloon"]. "$NAME" values come from the
scenario's "vars" (overridable with hil_play --set NAME=v).

Where the rig keeps the library comes from tools/.mister_rigs.json (gitignored):

    {"default": "main",
     "rigs": {"main": {"host": "root@<addr>", "share_root": "/media/fat/cifs/<share>",
                       "library_root": "/path/to/the/same/library/on/this/host",
                       "capture": true}}}

library_root falls back to $DVD_ISO_DIR. A rig without the file still works through
tools/.mister_host, but then needs --iso/--local-iso by hand.
"""
import argparse
import copy
import glob
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nav_extract as ne  # noqa: E402

PROFILES = os.path.join(HERE, 'hil_discs')
RIGS = os.path.join(HERE, '.mister_rigs.json')
INDEX = os.path.join(HERE, 'streams', 'hil_image_index.json')   # fingerprint cache


# ---------------------------------------------------------------------------------
# images
# ---------------------------------------------------------------------------------
def fingerprint(iso):
    """sha1 of VIDEO_TS.IFO: identical for every rip of one disc, whatever its name."""
    with open(iso, 'rb') as f:
        f.seek(16 * 2048)
        pvd = f.read(2048)
        if pvd[1:6] != b'CD001':
            raise ValueError('not an ISO9660 image')
        root = (int.from_bytes(pvd[158:162], 'little'), int.from_bytes(pvd[166:170], 'little'))
        vdir = next(((e, l) for n, e, l in ne.walk_dir(f, *root) if n.startswith(b'VIDEO_TS')), None)
        if not vdir:
            raise ValueError('no VIDEO_TS')
        ifo = next(((e, l) for n, e, l in ne.walk_dir(f, *vdir) if n.startswith(b'VIDEO_TS.IFO')), None)
        if not ifo:
            raise ValueError('no VIDEO_TS.IFO')
        f.seek(ifo[0] * 2048)
        return hashlib.sha1(f.read(min(ifo[1], 4 * 1024 * 1024))).hexdigest()


def rig(name=None):
    """The rig's entry from tools/.mister_rigs.json, or {} without the file."""
    if not os.path.exists(RIGS):
        return {}
    cfg = json.load(open(RIGS))
    name = name or os.environ.get('MISTER_RIG') or cfg.get('default')
    r = cfg.get('rigs', {}).get(name)
    if r is None:
        sys.exit('rig %r is not in %s (rigs: %s)' % (name, RIGS, ', '.join(cfg.get('rigs', {}))))
    return dict(r, name=name)


def library_root(r):
    root = r.get('library_root') or os.environ.get('DVD_ISO_DIR')
    if not root:
        sys.exit('no library root: set library_root in %s or $DVD_ISO_DIR' % RIGS)
    return os.path.expanduser(root)


def _index():
    try:
        return json.load(open(INDEX))
    except Exception:
        return {}


def resolve_image(profile, r):
    """(host path, rig path) of the profile's image: a name hint whose fingerprint
    matches, else any image in the library with that fingerprint (indexed once, by
    size+mtime, in tools/streams). Exits rather than guess."""
    root = library_root(r)
    want = profile['image'].get('fingerprint')
    cands = [os.path.join(root, h) for h in profile['image'].get('name_hints', [])]
    idx, dirty = _index(), False
    for path in cands + sorted(glob.glob(os.path.join(root, '**', '*.[iI][sS][oO]'), recursive=True)):
        if not os.path.exists(path):
            continue
        st = os.stat(path)
        key = '%s|%d|%d' % (os.path.relpath(path, root), st.st_size, int(st.st_mtime))
        fp = idx.get(key)
        if fp is None:
            try:
                fp = fingerprint(path)
            except Exception:
                fp = 'unreadable'
            idx[key], dirty = fp, True
        if want is None or fp == want:
            break
    else:
        path = None
    if dirty:
        os.makedirs(os.path.dirname(INDEX), exist_ok=True)
        json.dump(idx, open(INDEX, 'w'))
    if path is None:
        sys.exit('no image with fingerprint %s under %s' % (want, root))
    rel = os.path.relpath(path, root)
    share = r.get('share_root')
    return path, (os.path.join(share, rel) if share else None)


# ---------------------------------------------------------------------------------
# profiles and scenarios
# ---------------------------------------------------------------------------------
def load(name):
    p = name if name.endswith('.json') else os.path.join(PROFILES, name + '.json')
    if not os.path.exists(p):
        sys.exit('no profile %s (have: %s)' % (p, ', '.join(names())))
    return json.load(open(p))


def names():
    return sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(PROFILES, '*.json')))


def _subst(o, var):
    if isinstance(o, dict):
        return {k: _subst(v, var) for k, v in o.items()}
    if isinstance(o, list):
        return [_subst(v, var) for v in o]
    if isinstance(o, str) and o.startswith('$'):
        if o[1:] not in var:
            sys.exit('scenario uses %s but neither its "vars" nor --set gives it' % o)
        return var[o[1:]]
    return o


def _policy_entries(profile, refs):
    pol = profile.get('policy', {})
    out = []
    for ref in refs:
        if ref.startswith('route:'):
            v = pol.get('routes', {}).get(ref[6:])
        else:
            v = pol.get('also_select', {}).get(ref)
        if v is None:
            sys.exit('policy %r is not defined in the profile' % ref)
        out += v if isinstance(v, list) else [v]
    return out


def expand(profile, scenario, sets=None):
    """The scenario as hil_play runs it: macros inlined, policy names resolved, $vars
    substituted. The result carries "expect" and "measure" through untouched."""
    sc = copy.deepcopy(profile['scenarios'][scenario])
    var = dict(sc.pop('vars', {}))
    var.update(sets or {})
    steps = []
    for st in sc.get('steps', []):
        if 'macro' in st:
            if st['macro'] not in profile.get('macros', {}):
                sys.exit('macro %r is not defined' % st['macro'])
            steps += copy.deepcopy(profile['macros'][st['macro']])
        else:
            steps.append(st)
    for st in steps:
        if 'play' in st and 'policy' in st['play']:
            st['play']['also_select'] = (_policy_entries(profile, st['play'].pop('policy'))
                                         + st['play'].get('also_select', []))
    sc['steps'] = steps
    sc = _subst(sc, var)
    if 'measure' in sc:
        sc['align'] = sc['measure']             # hil_play's name for it
    sc.setdefault('pal', profile.get('pal', False))
    sc['_disc'] = profile.get('name')
    sc['_scenario'] = scenario
    sc['_vars'] = var
    return sc


# ---------------------------------------------------------------------------------
# draft: a starting profile for a new disc, from the disc alone
# ---------------------------------------------------------------------------------
def draft(iso, root=None):
    """What the disc says about itself: its scoring windows and how many the
    autoplayer can aim at, the title-domain multi-button menus it cannot classify, and
    indefinite stills with buttons (route menus) -- each a TODO for the policy."""
    import disc_timing as DT
    shots = DT.scoring_targets(iso)
    menus, stills = [], []
    with open(iso, 'rb') as f:
        for v in range(1, 100):
            try:
                ifo = ne.find_vts_ifo(f, v)
            except SystemExit:
                break
            _, _, npgc = DT.title_pgc_addr(f, ifo, 1)
            for pg in range(1, npgc + 1):
                try:
                    d = DT.dump(iso, v, pg)
                except Exception:
                    continue
                for c in d['cells']:
                    for h in c['hli'][:1]:
                        if h['btn_ns'] >= 2 and not h['setonly'] and not any(
                                s['vts'] == v and s['pgcn'] == pg and s['cell'] == c['cell'] for s in shots):
                            menus.append({'vts': v, 'pgcn': pg, 'cell': c['cell'],
                                          'buttons': h['btn_ns'], 'still': c['still'],
                                          'fosl': h['fosl'], 'sptm_lo': h['s_ptm'] & 0xFFFFF,
                                          'commands': [b['cmd'] for b in h['buttons'][:4]]})
                        if c['still'] == 255 and h['btn_ns']:
                            stills.append('%d:%d' % (v, pg))
    name = os.path.splitext(os.path.basename(iso))[0].lower().replace(' ', '_')
    hint = os.path.relpath(iso, root) if root and os.path.abspath(iso).startswith(os.path.abspath(root)) \
        else os.path.basename(iso)
    return {
        'name': name, 'title': os.path.splitext(os.path.basename(iso))[0],
        'image': {'fingerprint': fingerprint(iso), 'name_hints': [hint]},
        'pal': False,
        'policy': {'also_select': {}, 'routes': {}},
        'macros': {'start': [{'wait': 'live and not menu', 'timeout': 60}]},
        'notes': [{'text': 'Drafted from the disc alone; nothing here is confirmed on HW yet.',
                   'why': 'tools/hil_disc.py draft'}],
        'scenarios': {
            'explore': {
                'description': 'Start the disc and let the autoplayer play what it recognises '
                               'for 5 minutes; then: tools/hil_disc.py explored <run dir>',
                'opts': {'Debug Overlay': 'On'}, 'capture_s': 330,
                'steps': [{'macro': 'start'},
                          {'play': {'until': 'False', 'timeout': 300, 'policy': [],
                                    'select_unknown_after_s': 2.0,
                                    'delay_s': 0.15, 'hold_ms': 20}}],
                'expect': []}},
        '_draft': {
            'scoring_windows': len(shots),
            'aimable': sum(1 for s in shots if s['aim']),
            'no_target': [{k: s[k] for k in ('vts', 'pgcn', 'cell', 'cmd')}
                          for s in shots if not s['targets']][:40],
            'title_menus_not_shots': menus[:60],
            'indefinite_stills_with_buttons': sorted(set(stills)),
            'todo': ['decide which of title_menus_not_shots / indefinite_stills the '
                     'autoplayer must answer, and add them to policy',
                     'write a "start" macro that gets from the disc menu into play',
                     'confirm on HW (hil_play run --disc ... --scenario ...)'],
        },
    }


def explored(run_dir):
    """What an exploratory run met: the title sets and PGCs it entered, every highlight
    the autoplayer could not place (unknown window / no target), and the reader stills
    it sat in -- the TODO list for the profile."""
    lines = [json.loads(l) for l in open(os.path.join(run_dir, 'agent.jsonl'))]
    start = next((o['start'] for o in lines if 'start' in o), 0)
    nav = [o['nav'] for o in lines if 'nav' in o and o['nav'].get('t_ev', 0) >= start - 5]
    if not nav:
        return 'no nav events: this core has no nav FIFO (explore needs one)'
    pgcs, stills, vts, on = [], [], None, None
    for e in nav:
        if e['ev'] == 'PGC':
            # menu-domain PGCs are marked M (VMGM/VTSM): a game's screens often live there
            key = '%s%d:%d' % ('M' if e.get('menu') else '', e['vts'], e['pgcn'])
            if not pgcs or pgcs[-1] != key:
                pgcs.append(key)
        if e['ev'] in ('PGC', 'CELL'):
            vts = e.get('vts', vts)
        if e['ev'] == 'STATE' and e.get('chg', 0) & 2:
            if e['still']:
                on = (e, pgcs[-1] if pgcs else '?')
            elif on:
                stills.append('%s %.1f s' % (on[1], e['t_ev'] - on[0]['t_ev']))
                on = None
    unk = [o for o in lines if o.get('autoplay') in ('unknown window', 'no target')]
    shots = [o for o in lines if o.get('autoplay') == 'aim']
    out = ['PGCs entered, in order (M = menu domain): %s' % ' '.join(pgcs),
           'shots the autoplayer fired: %d' % len(shots),
           'windows it could not place (%d):' % len(unk)]
    seen = set()
    for o in unk:
        k = (o.get('vts'), o.get('pgcn'), o.get('sptm_lo'), tuple(o.get('w', [])))
        if k in seen:
            continue
        seen.add(k)
        out.append('   %s' % ({kk: v for kk, v in o.items() if kk not in ('t',)}))
    out.append('reader stills (PGC, length): %s' % ', '.join(stills[:30]))
    if on:
        out.append('   ...and still in a still at the end: %s -- a screen waiting for input?' % on[1])
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sp = ap.add_subparsers(dest='cmd', required=True)
    sp.add_parser('list')
    p = sp.add_parser('show'); p.add_argument('disc'); p.add_argument('scenario')
    p.add_argument('--set', action='append', default=[], help='NAME=value')
    p = sp.add_parser('resolve'); p.add_argument('disc'); p.add_argument('--rig')
    p = sp.add_parser('explored'); p.add_argument('run_dir')
    p = sp.add_parser('draft'); p.add_argument('iso'); p.add_argument('-o', '--out')
    p.add_argument('--root', help='library root (default $DVD_ISO_DIR)')
    a = ap.parse_args()
    if a.cmd == 'list':
        for n in names():
            pr = load(n)
            print('%-14s %s' % (n, pr.get('title', '')))
            for s, sc in pr.get('scenarios', {}).items():
                print('    %-18s %s' % (s, sc.get('description', '')))
    elif a.cmd == 'show':
        sets = dict(kv.split('=', 1) for kv in a.set)
        print(json.dumps(expand(load(a.disc), a.scenario, sets), indent=1))
    elif a.cmd == 'explored':
        print(explored(a.run_dir))
    elif a.cmd == 'resolve':
        r = rig(a.rig)
        host, board = resolve_image(load(a.disc), r)
        print('host:  %s\nrig %s: %s' % (host, r.get('name', '?'), board))
    else:
        d = draft(a.iso, a.root or os.environ.get('DVD_ISO_DIR'))
        s = json.dumps(d, indent=1)
        if a.out:
            open(a.out, 'w').write(s + '\n')
        else:
            print(s)


if __name__ == '__main__':
    main()
