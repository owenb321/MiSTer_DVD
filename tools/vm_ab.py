#!/usr/bin/env python3
"""vm_ab.py -- the transaction-level A/B for the microcoded DVD VM (docs/nav_engine.md).

The microcoded VM must do exactly what the hardwired FSM it replaces did. Not cycle
for cycle (a sequencer takes longer), but transaction for transaction: the same
pulses with the same fields, in the same order, the same SPRM changes, and the same
VM state whenever it comes to rest. The old FSM is kept as the oracle
(bench/dvd/ref/dvd_vm_hw.sv, module dvd_vm_hw: dvd/dvd_vm.sv as it was before the
microcode, unchanged), so this is a bit-identical reference after all -- at the
transaction level, which is the level the reader and nav_pci see.

Three VMs run the same stimulus script (tools/nav_shell.py documents the format):
    old   the hardwired FSM in iverilog (bench/dvd/vm_ab_tb.sv)
    py    the microcode emulator inside the Python wrapper model (tools/nav_shell.py)
    new   the microcoded RTL in iverilog (bench/dvd/vm_ab_tb.sv +define+VM_NEW)
and their logs must be identical, step by step: each step's pulses in order, each
SPRM's changes in order, and the state dump.

Usage:
    tools/vm_ab.py                       # GREEN: py vs old over the generated corpus
    tools/vm_ab.py --new                 # ... and new vs old
    tools/vm_ab.py --seeds 200 --steps 120
    tools/vm_ab.py --script s.txt        # one script, full logs kept in .sim/vm_ab/
    tools/vm_ab.py --red                 # every ;MUT arm in dvd/nav/vm.uasm must diverge
"""
import argparse
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import nav_isa as N        # noqa: E402
import nav_shell as S      # noqa: E402

SIM = os.path.join(REPO, '.sim', 'vm_ab')
OLD_SRC = ['bench/dvd/ref/dvd_vm_hw.sv', 'bench/dvd/vm_ab_tb.sv']
NEW_SRC = ['dvd/nav/nav_seq.sv', 'dvd/dvd_vm.sv', 'bench/dvd/vm_ab_tb.sv']
ARG_ID = {'cellcmd': 0, 'btn': 1, 'chedge': 2, 'stir': 3, 'agl': 4}
INPUT_IDX = {n: i for i, n in enumerate(S.INPUTS)}


# ------------------------------------------------------------------ scripts -> ops
def script_to_ops(lines):
    ops = []
    for ln in lines:
        t = ln.split('#', 1)[0].split()
        if not t:
            continue
        if t[0] == 'set':
            ops.append((1, INPUT_IDX[t[1]], int(t[2], 0)))
        elif t[0] == 'cmd':
            ops.append((2, int(t[1], 0), int(t[2], 16)))
        elif t[0] == 'pm':
            ops.append((3, int(t[1], 0), int(t[2], 0)))
        elif t[0] == 'pulse':
            mask = 0
            for a in t[1:]:
                k, _, v = a.partition('=')
                mask |= 1 << S.PULSES.index(k)
                if k in ARG_ID:
                    ops.append((7, ARG_ID[k], int(v, 16) if k == 'btn' else int(v, 0)))
            ops.append((4, mask, 0))
        elif t[0] == 'timeout':
            ops.append((5, 0, 0))
        elif t[0] == 'settle':
            ops.append((6, 0, 0))
        else:
            raise ValueError(ln)
    return '\n'.join('%x %x %x' % o for o in ops) + '\n'


# ------------------------------------------------------------------ the generator
def rand_cmd(rng):
    """A random command, biased so the fields that select registers name real ones
    and the link fields land on real operations often enough to matter."""
    t = rng.choices(range(8), weights=[10, 22, 12, 16, 12, 12, 12, 4])[0]
    b = [rng.getrandbits(8) for _ in range(8)]
    b[0] = (t << 5) | (b[0] & 0x1F)
    for k in range(2, 8):
        r = rng.random()
        if r < 0.35:
            b[k] = rng.randrange(16)                 # a GPRM / small value
        elif r < 0.5:
            b[k] = 0x80 | rng.randrange(24)          # a SPRM
        elif r < 0.6:
            b[k] = 0
    if rng.random() < 0.5:
        b[7] = (b[7] & 0xE0) | rng.randrange(17)     # a real sub-instruction
    if t == 1 and rng.random() < 0.5:
        b[0] |= 0x10                                 # a jump
        b[1] = (b[1] & 0xF0) | rng.choice([1, 2, 3, 5, 6, 8])
    return bytes(b).hex()


def rand_input(rng):
    name = rng.choice(['cur_vts', 'cur_pgcn', 'cur_cell', 'cell_count', 'next_pgcn',
                       'prev_pgcn', 'goup_pgcn', 'menu_active', 'btn_sel', 'btns_armed',
                       'best_menu_vts', 'auto_vts', 'res_ttn', 'nr_pgms', 'nr_cell',
                       'cfg_lang', 'cfg_sprm14', 'cfg_sprm15', 'cfg_sprm20', 'enable'])
    w = S.INPUTS[name][0]
    if name == 'enable':
        v = 0 if rng.random() < 0.3 else 1
    elif name in ('cur_cell', 'cell_count', 'nr_pgms', 'nr_cell'):
        v = rng.choice([0, 1, 2, 3, 5, rng.randrange(1 << w)])
    elif name in ('next_pgcn', 'prev_pgcn', 'goup_pgcn', 'cur_pgcn'):
        v = rng.choice([0, 1, 2, rng.randrange(40), rng.randrange(1 << w)])
    else:
        v = rng.randrange(1 << w)
    return f'set {name} {v}'


def rand_table(rng):
    out = []
    pre, post, cell = (rng.choice([0, 0, 1, 2, 3, 5]) for _ in range(3))
    for i in range(pre + post + cell):
        out.append(f'cmd {i} {rand_cmd(rng)}')
    out += [f'set nr_pre {pre}', f'set nr_post {post}', f'set nr_cell {cell}']
    if rng.random() < 0.5:
        n = rng.randrange(1, 8)
        cells = sorted(rng.sample(range(1, 12), min(n, 11)))
        for i, c in enumerate(cells):
            out.append(f'pm {i} {c if rng.random() < 0.9 else 0}')
        out.append(f'set nr_pgms {len(cells)}')
    return out


def gen_script(seed, steps):
    rng = random.Random(seed)
    s = [f'# vm_ab seed {seed}']
    for name in ('cur_vts', 'best_menu_vts', 'auto_vts', 'cell_count', 'cur_pgcn'):
        s.append(f'set {name} {rng.randrange(1, 6)}')
    s += rand_table(rng)
    s.append('set nav_ready 1')
    for _ in range(steps):
        r = rng.random()
        if r < 0.20:
            s.append('pulse loaded')
        elif r < 0.26:
            s.append('pulse error')
        elif r < 0.34:
            s.append(f'pulse cellcmd={rng.randrange(5)}')
        elif r < 0.42:
            s.append('pulse pgcend')
        elif r < 0.50:
            s.append(f'pulse btn={rand_cmd(rng)}')
        elif r < 0.58:
            s.append('pulse ' + rng.choice(['menu', 'title', 'return', 'cmenu']))
        elif r < 0.62:
            s.append(f'pulse chedge={rng.randrange(2)}')
        elif r < 0.65:
            s.append('pulse tick')
        elif r < 0.67:
            s.append(f'pulse stir={rng.randrange(1 << 16)}')
        elif r < 0.69:
            s.append(f'pulse agl={rng.randrange(1, 10)}')
        elif r < 0.74:
            s.append('timeout')
        elif r < 0.88:
            s.append(rand_input(rng))
        elif r < 0.95:
            s += rand_table(rng)
        elif r < 0.97:
            s.append('pulse loaded btn=' + rand_cmd(rng))   # two in one cycle
        elif r < 0.985:
            s.append('pulse start')
            s.append('set nav_ready 0')
            s.append('set nav_ready 1')
        else:
            s.append('settle')
    return s


# ------------------------------------------------------------------ running
def build(new):
    os.makedirs(SIM, exist_ok=True)
    exe = os.path.join(SIM, 'new_sim' if new else 'old_sim')
    src = NEW_SRC if new else OLD_SRC
    cmd = ['iverilog', '-g2012', '-I', 'dvd', '-o', exe] + (['-DVM_NEW'] if new else []) + src
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if p.returncode:
        sys.exit('vm_ab: build failed:\n' + p.stdout + p.stderr)
    return exe


def run_rtl(exe, lines, tag):
    ops = os.path.join(SIM, tag + '.ops')
    log = os.path.join(SIM, tag + '.log')
    open(ops, 'w').write(script_to_ops(lines))
    p = subprocess.run(['vvp', '-n', exe, f'+in={ops}', f'+out={log}'], cwd=REPO,
                       capture_output=True, text=True, timeout=1800)
    if 'PASS: vm_ab_tb' not in p.stdout:
        return None, p.stdout[-2000:]
    return open(log).read().splitlines(), None


def run_py(lines, mutate=None):
    try:
        return S.run_script(lines, mutate).log, None
    except N.SeqError as e:
        return None, f'emulator: {e}'


def streams(log):
    """-> {(step, kind, key): [lines]} -- pulses per step in order, each SPRM's changes
    per step in order, the state per step."""
    out = {}
    for ln in log:

        f = ln.split()
        kind, step = f[0], int(f[1])
        key = f[2] if kind == 'L' else ''
        if kind == 'P' and f[2] == 'PREDONE':
            # pre_done is a level the reader latches (pre_seen): the old FSM raises it
            # in the same cycle as a dispatch's first pulse, so only its count per
            # step is a property, not its place among the other pulses
            kind = 'Q'
        out.setdefault((step, kind, key), []).append(ln)
    # SPRM8 alone has a hardware shadow that rewrites it every cycle while a menu is
    # armed and unfrozen, so between two VM writes it shows the shadow value for a
    # cycle. The old FSM's writes were often back to back and hid it; the sequencer's
    # never are. So compare the values the VM WROTE: drop the step's settled value
    # (the state dump compares it) and repeats, keep the order (docs/nav_engine.md).
    for k in [k for k in out if k[1] == 'L' and k[2] == 'sprm8']:
        vals = [ln.split()[3] for ln in out[k]]
        keep = []
        for ln, v in zip(out[k], vals):
            if v != vals[-1] and v not in [x.split()[3] for x in keep]:
                keep.append(ln)
        out[k] = keep
    return out


def compare(a, b):
    """-> None if equal, else a description of the first difference."""
    sa, sb = streams(a), streams(b)
    for k in sorted(set(sa) | set(sb)):
        if sa.get(k) != sb.get(k):
            x, y = sa.get(k, []), sb.get(k, [])
            if k[1] == 'S' and x and y:
                fx = dict(t.split('=') for t in x[0].split()[2:])
                fy = dict(t.split('=') for t in y[0].split()[2:])
                d = [f'{n}: {fx.get(n)} vs {fy.get(n)}' for n in fx if fx.get(n) != fy.get(n)]
                return f'step {k[0]} state: ' + ', '.join(d)
            return f'step {k[0]} {k[1]} {k[2]}:\n    {x}\n    {y}'
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--seeds', type=int, default=60)
    ap.add_argument('--steps', type=int, default=80)
    ap.add_argument('--first', type=int, default=1, help='first seed')
    ap.add_argument('--script', help='run one script file instead of the generator')
    ap.add_argument('--new', action='store_true', help='also run the microcoded RTL')
    ap.add_argument('--red', action='store_true', help='every ;MUT arm must diverge')
    a = ap.parse_args()

    if a.script:
        corpus = [(os.path.basename(a.script), open(a.script).read().splitlines())]
    else:
        corpus = [(f'seed{s}', gen_script(s, a.steps)) for s in range(a.first, a.first + a.seeds)]
    old = build(False)
    new = build(True) if a.new else None

    olds = {}
    fails = 0
    for name, lines in corpus:
        lo, err = run_rtl(old, lines, name + '.old')
        if lo is None:
            print(f'FAIL {name}: the old FSM did not run:\n{err}')
            fails += 1
            continue
        olds[name] = lo
        if a.script:
            open(os.path.join(SIM, name + '.old.txt'), 'w').write('\n'.join(lo) + '\n')
        if a.red:
            continue
        lp, err = run_py(lines)
        if lp is None:
            print(f'FAIL {name} [py]: {err}')
            fails += 1
            continue
        if a.script:
            open(os.path.join(SIM, name + '.py.txt'), 'w').write('\n'.join(lp) + '\n')
        d = compare(lo, lp)
        if d:
            print(f'FAIL {name} [py vs old]: {d}')
            fails += 1
        if new:
            ln, err = run_rtl(new, lines, name + '.new')
            if ln is None:
                print(f'FAIL {name} [new]: did not run:\n{err}')
                fails += 1
                continue
            d = compare(lo, ln)
            if d:
                print(f'FAIL {name} [new vs old]: {d}')
                fails += 1
    npulse = sum(1 for lo in olds.values() for ln in lo if ln.startswith('P '))
    print(f'vm_ab: {len(corpus)} scripts, {npulse} pulses from the old FSM')

    if a.red:
        arms = re.findall(r';\s*MUT\s+(\w+)\s*:', open(N.UASM).read())
        for arm in arms:
            bit = None
            for name, lines in corpus:
                lp, err = run_py(lines, arm)
                if lp is None or compare(olds[name], lp):
                    bit = name
                    break
            print(f'  RED {arm}: ' + (f'diverges ({bit})' if bit else 'BLIND -- never diverges'))
            if not bit:
                fails += 1
    print('PASS: vm_ab' if not fails else f'FAIL: vm_ab ({fails})')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
