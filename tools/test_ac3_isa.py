#!/usr/bin/env python3
"""test_ac3_isa.py -- gate for the AC-3 engine program and emulator (A1).

Claims (docs/ac3_engine.md):
  [1] the emulator, running dvd/dts/ac3.uasm, is bit-exact against
      tools/ac3_model.py on every block of every stream -- exponents, baps,
      coefficients, blksw, dynrng -- and refuses exactly the frames the model
      refuses;
  [1r] and its coefficients, LFE, blksw and dynrng are bit-exact against the RTL
      DIRECTLY (bench/ac3/golden_main.cpp dumps, regenerated from the current RTL):
      not only through the model, so a convention error the model's snapshot and
      the emulator's shared could not hide;
  [2] every frame fits BUDGET of real time: the sequencer and its units at the
      RTL's own cycle counts (bench/dvd/run_ac3_seq.sh [cycles] checks the units'
      charges), the vector side's MODELLED charges with their headroom factor, and
      the IMDCT in series ON THE ENGINE (docs/imdct_engine.md): tools/imdct_isa.py's
      cycles for that frame's own blocks, with the same headroom factor until the RTL
      measures them (I2);
  [3] the generated images match the program (ac3_isa.py --asm --check).
RED arms: microcode mutations (`;MUT name:` lines in ac3.uasm), each tied to the
stream feature it needs; one that bites on no stream with the feature is a FAIL,
one whose feature no stream has is a GAP.
Streams: as tools/test_ac3_model.py.  Usage: python3 tools/test_ac3_isa.py [--frames N]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ac3_isa as A          # noqa: E402
import ac3_model as M        # noqa: E402
import imdct_isa as IS       # noqa: E402
from test_ac3_model import streams, features, goldens, golden_halts   # noqa: E402

FRAME_CYC = 27_000_000 * 1536 // 48000      # 864,000
BUDGET = 0.60
ARMS = {'p3seed': 'blocks', 'cplseed': 'cpl', 'phsflg': 'phsflg', 'dynreset': 'dynrnge',
        'knee': 'blocks', 'noremat': 'remat', 'nomerge': 'cplmerge', 'ctail': 'cpl',
        'nodual': 'dualmono', 'nodyn2': 'dualmono'}


def frame_cost(m, imdct):
    """The worst frame: the sequencer and its units as the RTL counts them, the
    modelled vector-side charges with headroom, plus that frame's IMDCT on the engine
    in series (imdct: per-frame cycles, tools/imdct_isa.frame_cycles), with headroom."""
    if not m.frame_cycles:
        return 0
    vec = m.vec_model / max(len(m.frame_cycles), 1)
    head = (A.CYC_HEADROOM - 1) * vec
    return max(fc + head + A.CYC_HEADROOM * (imdct[k] if k < len(imdct) else max(imdct, default=0))
               for k, fc in enumerate(m.frame_cycles))


def rtl_compare(m, gold_path):
    """The emulator's blocks against the RTL's dump -> (mismatches, first, blocks)."""
    eb = iter(m.blocks)
    bad, first, n = 0, None, 0
    for k, g in enumerate(M.read_golden(gold_path)):
        for b, gb in enumerate(g['blocks']):
            e = next(eb, None)
            if e is None:
                return bad, first, n          # the engine stopped (a refusal): [1] scores it
            n += 1
            for key in ('blksw', 'dynrng'):
                if e[key] != gb[key]:
                    bad += 1
                    first = first or f'frame {k} block {b}: {key}'
            chans = dict(enumerate(e['coeff']))
            if e['lfe'] is not None:
                chans[M.CH_LFE] = e['lfe']
            for ch, vals in gb['coeff'].items():
                if chans.get(ch) != vals:
                    bad += 1
                    first = first or f'frame {k} block {b} ch {ch}'
    return bad, first, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=24)
    a = ap.parse_args()
    fails = 0
    rc = A.write_mems(check=True)
    print(f'[3] {"PASS" if rc == 0 else "FAIL"} the generated images match ac3.uasm')
    fails += rc != 0
    paths = streams()
    gold = goldens(paths, a.frames)
    worst = (0.0, '')
    base_bad = {}
    feat = features(paths, a.frames)
    for p in paths:
        m, nf, bad, first = A.emulate(p, a.frames)
        base_bad[p] = bad
        rbad, rfirst, nrb = rtl_compare(m, gold[p])
        okr = rbad == 0 and (nrb > 0 or golden_halts(p, feat))
        fails += not okr
        if not okr:
            print(f'[1r] FAIL {os.path.basename(p)}: {rbad} values differ from the RTL ({rfirst})')
        frac = frame_cost(m, IS.frame_cycles(p, a.frames)) / FRAME_CYC
        if frac > worst[0]:
            worst = (frac, os.path.basename(p))
        ok1 = bad == 0 and (nf > 0 or 'refuse' in os.path.basename(p))
        ok2 = frac <= BUDGET
        fails += (not ok1) + (not ok2)
        print(f'[1] {"PASS" if ok1 else "FAIL"} {os.path.basename(p)}: {nf} frames, {bad} mismatches'
              + (f' ({first})' if first else '') + f'; [2] {"PASS" if ok2 else "FAIL"} worst frame '
              f'{frac * 100:.0f} %')
    for arm, need in ARMS.items():
        have = [p for p in paths if feat[p].get(need) and not base_bad[p]]
        if not have:
            print(f'    RED {arm:10s} GAP -- no stream has {need}')
            continue
        bit = sum(1 for p in have if A.emulate(p, a.frames, mutate=arm)[2])
        print(f'    RED {arm:10s} ' + (f'bites on {bit} of {len(have)} stream(s) with {need}' if bit
                                       else f'BLIND on {len(have)} stream(s) with {need}: FAIL'))
        fails += not bit
    print(f'worst frame: {worst[0] * 100:.1f} % of real time ({worst[1]})')
    print(f'RESULT: {"PASS" if not fails else "FAIL"}')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
