#!/usr/bin/env python3
"""hil_suite.py -- the interactive-disc regression gate: run every profile scenario marked
for the suite against a build (and a control build), and print one PASS/FAIL table
(docs/hil_play_harness.md "Regression suite").

    tools/hil_suite.py plan [--tier quick|full]
    tools/hil_suite.py run --rbf BUILD.rbf [--control CONTROL.rbf] [--tier quick|full]
                           [--only DISC[/SCENARIO] ...] [--leave build|control|none] [--out DIR]
    tools/hil_suite.py table DIR

A scenario joins the suite through its own profile (tools/hil_discs/<disc>.json):

    "suite": {"tier": "quick", "timeout": 150, "capture_s": 180, "align": false}

  tier       quick = every build; full = also the long ones (--tier full runs both)
  timeout    overrides every play step's timeout (a shorter run that still exercises
             the scenario's checks)
  capture_s  overrides the capture ceiling
  align      false drops the picture alignment ('measure'): only screen_sequence,
             no_freeze and no_silence need it, and on a feature film it costs ~13 min

Each build is flashed (mister.py deploy --rbf-only), its core_version read back from the
rig, and every scenario run with hil_play and judged with hil_expect. Runs are never
wrapped in an outer timeout: hil_play's own step timeouts bound them, and an outer one
killed the alignment twice (2026-10-24). The table puts each expectation's control and
build verdicts side by side and marks REGRESSION (control PASS, build not) and FIXED.
Results: <out>/suite.json and <out>/suite.md (tools/streams/hil_suite/<time>, gitignored).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hil_disc  # noqa: E402

OVERHEAD_S = 45          # launch, clock sync, the agent's start: per scenario, measured


def members(tier='quick', only=()):
    """[(disc, scenario, suite entry, scenario)] in profile order."""
    out = []
    for name in sorted(hil_disc.names()):
        prof = hil_disc.load(name)
        for scn, sc in prof.get('scenarios', {}).items():
            su = sc.get('suite')
            if not su:
                continue
            if tier == 'quick' and su.get('tier', 'quick') != 'quick':
                continue
            if only and not any(o in (name, '%s/%s' % (name, scn)) for o in only):
                continue
            out.append((name, scn, su, sc))
    return out


def cost(su, sc):
    return su.get('capture_s', sc.get('capture_s', 300)) + OVERHEAD_S


def scenario_for(name, scn, su, rig):
    """The expanded scenario with the suite's overrides, and the image paths."""
    prof = hil_disc.load(name)
    sc = hil_disc.expand(prof, scn, {})
    host_iso, board_iso = hil_disc.resolve_image(prof, rig)
    sc['iso'] = board_iso
    if 'capture_s' in su:
        sc['capture_s'] = su['capture_s']
    if 'timeout' in su:
        for st in sc.get('steps', []):
            if 'play' in st:
                st['play']['timeout'] = su['timeout']
    if su.get('align') is False:
        sc.pop('align', None)
        sc.pop('measure', None)
    return sc, host_iso


def build_id(rbf):
    h = hashlib.sha256(open(rbf, 'rb').read()).hexdigest()
    meta = {}
    side = rbf + '.json'
    if os.path.exists(side):
        try:
            meta = json.load(open(side))
        except Exception:
            meta = {}
    git = meta.get('git') or {}
    return {'rbf': os.path.basename(rbf), 'sha256': h[:16],
            'branch': git.get('branch'), 'commit': (git.get('sha') or '')[:10] or None,
            'dirty': git.get('dirty'), 'seed': (meta.get('fit') or {}).get('seed')}


def mister(*args):
    p = subprocess.run([sys.executable, os.path.join(HERE, 'mister.py'), *args],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def core_version():
    _, out = mister('state')
    for ln in out.splitlines():
        if ln.startswith('core_version='):
            return ln.split('=', 1)[1].strip()
    return None


def run_build(tag, rbf, plan, rig, out):
    print('== %s: flashing %s' % (tag, os.path.basename(rbf)), flush=True)
    rc, msg = mister('deploy', '--rbf', rbf, '--rbf-only')
    if rc:
        sys.exit('deploy failed:\n' + msg)
    ident = dict(build_id(rbf), core_version=core_version())
    print('   on the rig: %s' % ident['core_version'], flush=True)
    res = []
    for name, scn, su, _ in plan:
        sc, host_iso = scenario_for(name, scn, su, rig)
        d = os.path.join(out, tag, '%s__%s' % (name, scn))
        os.makedirs(d, exist_ok=True)
        sf = os.path.join(d, 'suite_scenario.json')
        json.dump(sc, open(sf, 'w'), indent=1)
        t0 = time.time()
        print('   %-20s %-18s ...' % (name, scn), end='', flush=True)
        with open(os.path.join(d, 'run.log'), 'w') as log:
            subprocess.run([sys.executable, '-u', os.path.join(HERE, 'hil_play.py'), 'run', sf,
                            '--local-iso', host_iso, '--out', d], stdout=log, stderr=subprocess.STDOUT)
        p = subprocess.run([sys.executable, os.path.join(HERE, 'hil_expect.py'), d, '--json'],
                           capture_output=True, text=True)
        try:
            verdicts = json.loads(p.stdout)
        except Exception:
            verdicts = [{'expect': {'type': '(run)'}, 'result': 'NODATA',
                         'detail': 'no verdict: see %s/run.log' % d}]
        took = time.time() - t0
        worst = 'FAIL' if any(v['result'] == 'FAIL' for v in verdicts) else (
            'NODATA' if any(v['result'] == 'NODATA' for v in verdicts) else 'PASS')
        print(' %s (%.0f s)' % (worst, took), flush=True)
        res.append({'disc': name, 'scenario': scn, 'dir': d, 'seconds': round(took),
                    'verdicts': verdicts})
    return {'build': ident, 'results': res}


def table(doc):
    """Markdown: one row per expectation, control and build side by side."""
    builds = [b for b in ('control', 'build') if b in doc]
    rows = {}
    for b in builds:
        for r in doc[b]['results']:
            for v in r['verdicts']:
                e = dict(v['expect'])
                k = (r['disc'], r['scenario'], e.pop('type'), json.dumps(e, sort_keys=True))
                rows.setdefault(k, {})[b] = v
    hdr = '| Disc | Scenario | Check | ' + ' | '.join(
        '%s (%s)' % (b, doc[b]['build'].get('core_version') or doc[b]['build']['rbf']) for b in builds) + ' | |'
    lines = [hdr, '|' + '---|' * (4 + len(builds))]
    reg = fix = 0
    for (disc, scn, typ, args), vs in rows.items():
        cells = []
        for b in builds:
            v = vs.get(b)
            cells.append('%s: %s' % (v['result'], v['detail'][:70]) if v else '-')
        mark = ''
        if len(builds) == 2:
            c, n = (vs.get('control') or {}).get('result'), (vs.get('build') or {}).get('result')
            if c == 'PASS' and n != 'PASS':
                mark, reg = '**REGRESSION**', reg + 1
            elif c != 'PASS' and n == 'PASS':
                mark, fix = 'fixed', fix + 1
        lines.append('| %s | %s | %s | %s | %s |' % (disc, scn, typ, ' | '.join(cells), mark))
    n_fail = sum(1 for vs in rows.values() if (vs.get('build') or {}).get('result') == 'FAIL')
    head = ['# HIL suite %s' % doc['started'], '',
            'Build: `%s`' % json.dumps(doc['build']['build'])]
    if 'control' in doc:
        head.append('Control: `%s`' % json.dumps(doc['control']['build']))
    head += ['', '%d checks; build FAIL %d%s' % (len(rows), n_fail,
             ('; %d regression(s), %d fixed vs control' % (reg, fix)) if len(builds) == 2 else ''), '']
    return '\n'.join(head + lines) + '\n', reg, n_fail


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('plan')
    p.add_argument('--tier', default='quick', choices=('quick', 'full'))
    p.add_argument('--only', nargs='*', default=[])
    p = sp.add_parser('run')
    p.add_argument('--rbf', required=True)
    p.add_argument('--control')
    p.add_argument('--tier', default='quick', choices=('quick', 'full'))
    p.add_argument('--only', nargs='*', default=[])
    p.add_argument('--rig')
    p.add_argument('--leave', default='build', choices=('build', 'control', 'none'),
                   help='which build the rig is left on (default: the build under test)')
    p.add_argument('--out')
    p = sp.add_parser('table')
    p.add_argument('dir')
    a = ap.parse_args()

    if a.cmd == 'table':
        doc = json.load(open(os.path.join(a.dir, 'suite.json')))
        print(table(doc)[0])
        return
    plan = members(a.tier, a.only)
    if a.cmd == 'plan':
        tot = 0
        for name, scn, su, sc in plan:
            c = cost(su, sc)
            tot += c
            print('%-20s %-20s %-6s ~%4.0f s  %s' % (name, scn, su.get('tier', 'quick'), c,
                                                     [e['type'] for e in sc.get('expect', [])]))
        print('%d scenarios, ~%.0f min per build' % (len(plan), tot / 60))
        return
    if not plan:
        sys.exit('no scenario is marked for the suite (a "suite" entry in tools/hil_discs/*.json)')
    rig = hil_disc.rig(a.rig)
    if rig.get('host'):
        os.environ['MISTER_HOST'] = rig['host']
    out = a.out or os.path.join(HERE, 'streams', 'hil_suite', time.strftime('%Y%m%d_%H%M%S'))
    os.makedirs(out, exist_ok=True)
    _, before = mister('state')
    doc = {'started': time.strftime('%Y-%m-%d %H:%M'), 'tier': a.tier,
           'rig_before': [l for l in before.splitlines() if '=' in l]}
    est = sum(cost(su, sc) for _, _, su, sc in plan) * (2 if a.control else 1)
    print('%d scenarios x %d build(s), ~%.0f min; results in %s' % (
        len(plan), 2 if a.control else 1, est / 60, out), flush=True)
    try:
        if a.control:
            doc['control'] = run_build('control', a.control, plan, rig, out)
            json.dump(doc, open(os.path.join(out, 'suite.json'), 'w'), indent=1)
        doc['build'] = run_build('build', a.rbf, plan, rig, out)
        json.dump(doc, open(os.path.join(out, 'suite.json'), 'w'), indent=1)
    finally:
        leave = {'build': a.rbf, 'control': a.control}.get(a.leave)
        if leave:
            mister('deploy', '--rbf', leave, '--rbf-only')
            print('rig left on %s (%s)' % (os.path.basename(leave), core_version()), flush=True)
    md, reg, n_fail = table(doc)
    open(os.path.join(out, 'suite.md'), 'w').write(md)
    print(md)
    sys.exit(1 if reg or n_fail else 0)


if __name__ == '__main__':
    main()
