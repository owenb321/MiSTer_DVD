#!/usr/bin/env python3
"""imdct_isa.py -- the AC-3 IMDCT as a term program on the shared audio engine (docs/
imdct_engine.md I1): the templates, the walk over imdct_512's schedule, and a
cycle-accurate executor shaped like the RTL dts_vec will run it on.

THE MACHINE (what I2 builds):
  ring     2,048 words, 35 bits. Regions below (RING). A store wraps to 32 bits, or to
           35 for the BHALF pre-sums m0..m3, which feed a multiplier and are 33 bits.
  X        the block's coefficients, {slot, bin}, Q1.23 (read only).
  term     one a cycle: read ONE word (ring or X; a delay-line word reads 0 until its
           channel has been transformed since reset), and fold it into the accumulator:
             mode set / add / sub:  acc  =|+=|-=  v
             v = floor(sample * const / 2^sh)   (a product: const from a ROM table,
                                                 sh 17, or DRC's 5 - e)
             v = sample                          (no const: an add)
           the element's terms that end an output write acc to `dst` (wrapped).
           Subtraction negates the FLOORED product, as imdct_512 does.
  timing   a term issued at cycle n presents its read address at n - 1 and its write
           lands at the end of n + 1, so a read issued at n sees writes from terms
           issued <= n - 3. A read of an address with a write still in flight STALLS
           until it lands (sequential semantics: the program reads what it wrote).

Exactness: every value that reaches pcm, the buffer or the delay line is reduced mod
2^32 in imdct_512 (w32), and every sum here is an exact integer sum of the same floored
products, so equal mod 2^32. The two places a wrap feeds a MULTIPLIER are reproduced
exactly: POST's ar/ai/br/bi (stored w32, then multiplied by the window) and the DRC'd
coefficients (w32, never actually wide). BHALF's m0..m3 are kept exact at 35 bits.

THE FOLD (5.1 -> 2) accumulates: each output word of each channel adds its share into
pcm slots 0/1 as POST produces it (first contributor writes). Exact mod 2^32.

Usage:
    tools/imdct_isa.py check [--frames N] [STREAM.ac3 ...]   bit-exact vs imdct_model,
                                                               every block; cycles
    tools/imdct_isa.py check --random N                       random and extreme blocks
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import imdct_model as IM     # noqa: E402

W32, W35 = 32, 35
MUL_SAMPLE_BITS = 33             # the widened sample operand (docs/imdct_engine.md)
MUL_CONST_BITS = 27

# ring regions
RING = {'BUF': 0, 'TMP': 256, 'D': 512, 'DLY': 768, 'PCM': 1408, 'END': 1920}
assert RING['END'] <= 2048
NTMP = 16
assert RING['TMP'] + NTMP <= RING['D']
OPS = ('IFFT2', 'IFFT4', 'BZERO', 'BHALF', 'BFULL')


def wrap(v, n):
    return IM.wrap(v, n)


# ------------------------------------------------------------------ templates
# A template is a list of terms; a term is (mode, src, const, dst, wrap):
#   mode   'set' | 'add' | 'sub'
#   src    an operand symbol (resolved per element) -- a sample read
#   const  a constant symbol, or None (an add)
#   dst    an operand symbol to write acc to after this term, or None
#   wrap   the store's width (W32, or W35 for an exact pre-sum)
def T(mode, src, const=None, dst=None, wr=W32):
    return (mode, src, const, dst, wr)


def chain(dst, *parts, wr=W32):
    """An output: parts are (sign, src, const); the first sets acc."""
    out = []
    for n, (sg, src, cst) in enumerate(parts):
        mode = ('set' if sg > 0 else 'nset') if n == 0 else ('add' if sg > 0 else 'sub')
        out.append([mode, src, cst, None, wr])
    out[-1][3] = dst
    return [tuple(t) for t in out]


P, M = +1, -1
# the butterflies: inputs c0..c3 (buf words at sa..sd), temps t0..t15, twiddle wr / wi
TPL = {}
# IFFT2: a = c0 + c1 at sa, b = c0 - c1 at sb. c0, c1 copied first (b would read a
# clobbered c0 otherwise).
TPL['IFFT2'] = (chain('t0', (P, 'c0r', None)) + chain('t1', (P, 'c0i', None)) +
                chain('t2', (P, 'c1r', None)) + chain('t3', (P, 'c1i', None)) +
                chain('c0r', (P, 't0', None), (P, 't2', None)) +
                chain('c0i', (P, 't1', None), (P, 't3', None)) +
                chain('c1r', (P, 't0', None), (M, 't2', None)) +
                chain('c1i', (P, 't1', None), (M, 't3', None)))
# IFFT4: A = c0 + c1, B = c0 - c1, T = c2 + c3, U = (c2i - c3i, c3r - c2r) into temps;
# then a = A + T, b = B + U, c = A - T, d = B - U.
_ABTU = (chain('t0', (P, 'c0r', None), (P, 'c1r', None)) +
         chain('t1', (P, 'c0i', None), (P, 'c1i', None)) +
         chain('t2', (P, 'c0r', None), (M, 'c1r', None)) +
         chain('t3', (P, 'c0i', None), (M, 'c1i', None)))
_TU = (chain('t4', (P, 'c2r', None), (P, 'c3r', None)) +
       chain('t5', (P, 'c2i', None), (P, 'c3i', None)) +
       chain('t6', (P, 'c2i', None), (M, 'c3i', None)) +
       chain('t7', (P, 'c3r', None), (M, 'c2r', None)))
_OUT = (chain('c0r', (P, 't0', None), (P, 't4', None)) +
        chain('c0i', (P, 't1', None), (P, 't5', None)) +
        chain('c1r', (P, 't2', None), (P, 't6', None)) +
        chain('c1i', (P, 't3', None), (P, 't7', None)) +
        chain('c2r', (P, 't0', None), (M, 't4', None)) +
        chain('c2i', (P, 't1', None), (M, 't5', None)) +
        chain('c3r', (P, 't2', None), (M, 't6', None)) +
        chain('c3i', (P, 't3', None), (M, 't7', None)))
TPL['IFFT4'] = _ABTU + _TU + _OUT
# BZERO: A = c0, B = c1 (copied), T, U as IFFT4
_AB = (chain('t0', (P, 'c0r', None)) + chain('t1', (P, 'c0i', None)) +
       chain('t2', (P, 'c1r', None)) + chain('t3', (P, 'c1i', None)))
TPL['BZERO'] = _AB + _TU + _OUT
# BHALF: m0 = c2r + c2i, m1 = c2i - c2r, m2 = c3r - c3i, m3 = c3i + c3r (exact, 35-bit
# store); T = (p(m0) + p(m2), p(m1) + p(m3)), U = (p(m1) - p(m3), p(m2) - p(m0))
TPL['BHALF'] = (_AB +
                chain('t8', (P, 'c2r', None), (P, 'c2i', None), wr=W35) +
                chain('t9', (P, 'c2i', None), (M, 'c2r', None), wr=W35) +
                chain('t10', (P, 'c3r', None), (M, 'c3i', None), wr=W35) +
                chain('t11', (P, 'c3i', None), (P, 'c3r', None), wr=W35) +
                chain('t4', (P, 't8', 'wr'), (P, 't10', 'wr')) +
                chain('t5', (P, 't9', 'wr'), (P, 't11', 'wr')) +
                chain('t6', (P, 't9', 'wr'), (M, 't11', 'wr')) +
                chain('t7', (P, 't10', 'wr'), (M, 't8', 'wr')) +
                _OUT)
# BFULL: tt5 = p(c2r, wr) + p(c2i, wi), tt6 = p(c2i, wr) - p(c2r, wi),
# f7 = p(c3r, wr) - p(c3i, wi), f8 = p(c3i, wr) + p(c3r, wi);
# T = (tt5 + f7, tt6 + f8), U = (tt6 - f8, f7 - tt5): one four-product chain each
TPL['BFULL'] = (chain('t4', (P, 'c2r', 'wr'), (P, 'c2i', 'wi'), (P, 'c3r', 'wr'), (M, 'c3i', 'wi')) +
                chain('t5', (P, 'c2i', 'wr'), (M, 'c2r', 'wi'), (P, 'c3i', 'wr'), (P, 'c3r', 'wi')) +
                chain('t6', (P, 'c2i', 'wr'), (M, 'c2r', 'wi'), (M, 'c3i', 'wr'), (M, 'c3r', 'wi')) +
                chain('t7', (P, 'c3r', 'wr'), (M, 'c3i', 'wi'), (M, 'c2r', 'wr'), (M, 'c2i', 'wi')) +
                _AB + _OUT)

# PRE (pass 2): buf[i] = (p(D[a1], pi) + p(D[a0], pr), p(D[a1], pr) - p(D[a0], pi))
TPL['PRE'] = (chain('bi_r', (P, 'da1', 'pi'), (P, 'da0', 'pr')) +
              chain('bi_i', (P, 'da1', 'pr'), (M, 'da0', 'pi')))
# DRC (pass 1): D[j] = (X[j] * mant) >> (5 - e)
TPL['DRC'] = chain('dj', (P, 'xj', 'mant'))

# POST, long, element i: ar, br to temps; four outputs (each a fold contribution); the
# delay line's ai, bi last (the outputs read d0, d1 first)
POST_L_TMP = (chain('t0', (P, 'bir', 'pr'), (P, 'bii', 'pi')) +          # ar
              chain('t1', (P, 'bmr', 'pi'), (P, 'bmi', 'pr')))           # br
POST_L_OUT = [   # (output index symbol, parts)
    ('o0', ((P, 'd0', 'wb0'), (M, 't0', 'wa0'))),      # out[2i]       = pa0
    ('o1', ((P, 'd0', 'wa0'), (P, 't0', 'wb0'))),      # out[255-2i]   = pa1
    ('o2', ((P, 'd1', 'wb1'), (P, 't1', 'wa1'))),      # out[2i+1]     = pb0
    ('o3', ((P, 'd1', 'wa1'), (M, 't1', 'wb1'))),      # out[254-2i]   = pb1
]
POST_L_DLY = (chain('d0', (P, 'bir', 'pi'), (M, 'bii', 'pr')) +          # ai
              chain('d1', (P, 'bmr', 'pr'), (M, 'bmi', 'pi')))           # bi
# POST, short, element i
POST_S_TMP = (chain('t0', (P, 'q1ir', 'pr'), (P, 'q1ii', 'pi')) +        # s_ar
              chain('t1', (P, 'q1ir', 'pi'), (M, 'q1ii', 'pr')) +        # s_ai
              chain('t2', (P, 'q1mr', 'pi'), (P, 'q1mi', 'pr')) +        # s_br
              chain('t3', (P, 'q1mr', 'pr'), (M, 'q1mi', 'pi')))         # s_bi
POST_S_OUT = [
    ('o0', ((P, 'd2i', 'wb0'), (M, 't0', 'wa0'))),     # out[2i]
    ('o1', ((P, 'd2i', 'wa0'), (P, 't0', 'wb0'))),     # out[255-2i]
    ('o2', ((P, 'd127', 'wa1'), (P, 't1', 'wb1'))),    # out[128+2i]
    ('o3', ((P, 'd127', 'wb1'), (M, 't1', 'wa1'))),    # out[127-2i]
    ('o4', ((P, 'd2i1', 'wb2'), (M, 't3', 'wa2'))),    # out[2i+1]
    ('o5', ((P, 'd2i1', 'wa2'), (P, 't3', 'wb2'))),    # out[254-2i]
    ('o6', ((P, 'd126', 'wa3'), (P, 't2', 'wb3'))),    # out[129+2i]
    ('o7', ((P, 'd126', 'wb3'), (M, 't2', 'wa3'))),    # out[126-2i]
]
POST_S_DLY = (chain('d2i', (P, 'q2ir', 'pi'), (M, 'q2ii', 'pr')) +       # s_ci
              chain('d2i1', (P, 'q2mr', 'pi'), (P, 'q2mi', 'pr')) +      # s_dr
              chain('d126', (P, 'q2mr', 'pr'), (M, 'q2mi', 'pi')) +      # s_di
              chain('d127', (P, 'q2ir', 'pr'), (P, 'q2ii', 'pi')))       # s_cr


# ------------------------------------------------------------------ the fold
CLEV = IM.CLEV


def fold_plan(acmod, nf, cmix, surmix):
    """-> per channel, the list of (mode, slot, gain) its output words contribute:
    gain None is the word itself, else p(word, gain). imdct_512's S_DMX, accumulated."""
    if nf <= 2:
        return [[('set', ch, None)] for ch in range(nf)]
    has_c = bool(acmod & 1) and acmod != 1
    has_s = bool(acmod & 4)
    mono_s = acmod in (4, 5)
    clev = CLEV[cmix] if has_c else 0
    if surmix == 0:
        slev = 65536 if mono_s else 92682
    elif surmix == 1:
        slev = 46341 if mono_s else 65536
    else:
        slev = 0
    if not has_s:
        slev = 0
    roles = ['L'] + (['C', 'R'] if has_c else ['R'])
    if has_s:
        roles += ['S'] if mono_s else ['LS', 'RS']
    assert len(roles) == nf, (acmod, roles)
    plan, set1 = [], False
    for r in roles:
        if r == 'L':
            plan.append([('set', 0, None)])
        elif r == 'C':
            plan.append([('add', 0, clev), ('set', 1, clev)])
            set1 = True
        elif r == 'R':
            plan.append([('add' if set1 else 'set', 1, None)])
            set1 = True
        elif r == 'S':
            plan.append([c for c in (('add', 0, slev), ('add', 1, slev)) if slev])
        elif r == 'LS':
            plan.append([('add', 0, slev)] if slev else [])
        else:
            plan.append([('add', 1, slev)] if slev else [])
    return plan


# ------------------------------------------------------------------ the executor
class Engine:
    """The ring, the stall model, and the per-block state imdct_512 carries."""

    def __init__(self, junk=1):
        # the ring powers up holding whatever DTS or MP2 left: junk, so a delay-line read
        # the first block fails to mask shows
        rng = random.Random(junk)
        self.ring = [rng.randint(-(1 << 31), (1 << 31) - 1) for _ in range(2048)] if junk else [0] * 2048
        # a channel's delay line is valid once that channel has been transformed since
        # reset; until then its reads are 0 (imdct_512: the M10K's power-up zeros and
        # first_blk; a channel a stream adds mid-play starts from zero overlap too)
        self.valid = set()
        self.cycles = 0
        self.terms = 0
        self.stalls = 0
        self.max_sample = 0
        self.max_const = 0
        self._now = 0                 # the next issue cycle
        self.elements = 0             # elements walked (each may cost ELEM_OVH to fetch)
        self._pend = {}               # address -> the first cycle a read may see it

    # a term: resolved (mode, src_kind, src_addr, const, shift, dst_addr, wrap)
    def term(self, mode, sval_fn, saddr, const, sh, dst, wr):
        if saddr is not None and saddr in self._pend:
            ready = self._pend[saddr]
            if ready > self._now:
                self.stalls += ready - self._now
                self._now = ready
        s = sval_fn()
        if const is None:
            v = s
        else:
            self.max_sample = max(self.max_sample, IM.sbits(s))
            self.max_const = max(self.max_const, IM.sbits(const))
            assert IM.sbits(s) <= MUL_SAMPLE_BITS, (s, IM.sbits(s))
            assert IM.sbits(const) <= MUL_CONST_BITS, const
            v = (s * const) >> sh
        if mode == 'set':
            self.acc = v
        elif mode == 'nset':
            self.acc = -v
        elif mode == 'add':
            self.acc += v
        else:
            self.acc -= v
        if dst is not None:
            self.ring[dst] = wrap(self.acc, wr)
            self._pend[dst] = self._now + 3
        self.terms += 1
        self._now += 1

    def barrier(self, n=0):
        """A phase boundary: pipeline refill."""
        self._now += n


class Block:
    """One channel's transform: resolves the templates' symbols and runs them."""

    def __init__(self, eng, coeff, ch, short, dynrng, plan):
        self.e, self.coeff, self.ch, self.short = eng, coeff, ch, short
        self.plan = plan
        mant = 32 + (dynrng & 31)
        ex = (dynrng >> 5) & 7
        ex = ex - 8 if ex & 4 else ex
        self.mant, self.drc_sh = mant, 5 - ex
        self.sym = {}
        self.cst = {}

    def addr(self, s):
        return self.sym[s]

    def rd(self, s):
        a = self.sym[s]
        if isinstance(a, tuple):            # ('X', bin)
            return lambda: self.coeff[a[1]], None
        if self.ch not in self.e.valid and RING['DLY'] <= a < RING['PCM']:
            return (lambda: 0), a
        return (lambda: self.e.ring[a]), a

    def run(self, tpl, sh=17):
        self.e.elements += 1
        for mode, src, cst, dst, wr in tpl:
            fn, sa = self.rd(src)
            self.e.term(mode, fn, sa, None if cst is None else self.cst[cst], sh,
                        None if dst is None else self.sym[dst], wr)

    def transform(self):
        e, ch = self.e, self.ch
        R = RING
        buf = lambda i, part: R['BUF'] + 2 * (i & 127) + part     # noqa: E731
        dly = lambda j: R['DLY'] + 128 * ch + j                   # noqa: E731
        for n in range(NTMP):
            self.sym[f't{n}'] = R['TMP'] + n
        # ---- PRE pass 1: DRC every coefficient into D
        self.cst['mant'] = self.mant
        for j in range(256):
            self.sym['xj'] = ('X', j)
            self.sym['dj'] = R['D'] + j
            self.run(TPL['DRC'], sh=self.drc_sh)
        e.barrier(2)
        # ---- PRE pass 2
        for i in range(128):
            if self.short:
                fo = IM.FFTORDER[i & 63]
                a0 = (fo + 1) & 255 if i >= 64 else fo
                a1 = (255 - fo) & 255 if i >= 64 else (254 - fo) & 255
                pr, pi = IM.PRE2[i & 63]
            else:
                fo = IM.FFTORDER[i]
                a0, a1 = fo, (255 - fo) & 255
                pr, pi = IM.PRE1[i]
            self.sym.update(da0=R['D'] + a0, da1=R['D'] + a1, bi_r=buf(i, 0), bi_i=buf(i, 1))
            self.cst.update(pr=pr, pi=pi)
            self.run(TPL['PRE'])
        e.barrier(2)
        self.ifft_post()

    def ifft_post(self):
        e, ch = self.e, self.ch
        R = RING
        buf = lambda i, part: R['BUF'] + 2 * (i & 127) + part     # noqa: E731
        dly = lambda j: R['DLY'] + 128 * ch + j                   # noqa: E731
        for n in range(NTMP):
            self.sym[f't{n}'] = R['TMP'] + n
        # ---- the IFFT
        for op, sa, sb, sc, sd, wr, wi in IM.SCHED[self.short]:
            for nm, ix in (('c0', sa), ('c1', sb), ('c2', sc), ('c3', sd)):
                self.sym[nm + 'r'], self.sym[nm + 'i'] = buf(ix, 0), buf(ix, 1)
            self.cst.update(wr=wr, wi=wi)
            self.run(TPL[OPS[op]])
        e.barrier(2)
        # ---- POST, window, overlap, the fold
        if not self.short:
            for i in range(64):
                self.sym.update(bir=buf(i, 0), bii=buf(i, 1), bmr=buf(127 - i, 0), bmi=buf(127 - i, 1),
                                d0=dly(2 * i), d1=dly(2 * i + 1))
                pr, pi = IM.POST1[i]
                self.cst.update(pr=pr, pi=pi,
                                wa0=IM.WINDOW[2 * i], wb0=IM.WINDOW[255 - 2 * i],
                                wa1=IM.WINDOW[2 * i + 1], wb1=IM.WINDOW[254 - 2 * i])
                self.run(POST_L_TMP)
                ks = {'o0': 2 * i, 'o1': 255 - 2 * i, 'o2': 2 * i + 1, 'o3': 254 - 2 * i}
                self.outs([(ks[o], parts) for o, parts in POST_L_OUT])
                self.run(POST_L_DLY)
        else:
            for i in range(32):
                self.sym.update(q1ir=buf(i, 0), q1ii=buf(i, 1), q1mr=buf(63 - i, 0), q1mi=buf(63 - i, 1),
                                q2ir=buf(64 + i, 0), q2ii=buf(64 + i, 1),
                                q2mr=buf(127 - i, 0), q2mi=buf(127 - i, 1),
                                d2i=dly(2 * i), d2i1=dly(2 * i + 1), d126=dly(126 - 2 * i),
                                d127=dly(127 - 2 * i))
                pr, pi = IM.POST2[i]
                W = IM.WINDOW
                self.cst.update(pr=pr, pi=pi,
                                wa0=W[2 * i], wb0=W[255 - 2 * i],
                                wa1=W[127 - 2 * i], wb1=W[128 + 2 * i],
                                wa2=W[2 * i + 1], wb2=W[254 - 2 * i],
                                wa3=W[126 - 2 * i], wb3=W[129 + 2 * i])
                self.run(POST_S_TMP)
                ks = {'o0': 2 * i, 'o1': 255 - 2 * i, 'o2': 128 + 2 * i, 'o3': 127 - 2 * i,
                      'o4': 2 * i + 1, 'o5': 254 - 2 * i, 'o6': 129 + 2 * i, 'o7': 126 - 2 * i}
                self.outs([(ks[o], parts) for o, parts in POST_S_OUT])
                self.run(POST_S_DLY)
        e.barrier(2)

    def outs(self, words):
        """An element's output words and their fold contributions (docs/imdct_engine.md
        "The fold"). A word a gain multiplies is formed first into its own temp (t8 +
        n, w32: the value imdct_512's pcm slot held), every one of them before any share
        is added, so no share reads a temp still in flight."""
        R = RING
        contrib = self.plan[self.ch]
        direct = [c for c in contrib if c[2] is None]
        gained = [c for c in contrib if c[2] is not None]
        lift = {'set': 'add', 'nset': 'sub', 'add': 'add', 'sub': 'sub'}
        for n, (k, parts) in enumerate(words):
            if direct:
                (mode, slot, _), = direct
                self.sym['pk'] = R['PCM'] + 256 * slot + k
                tpl = chain('pk', *parts)
                if mode == 'add':                   # acc = slot; then the chain on top
                    tpl = [('set', 'pk', None, None, W32)] + [(lift[t[0]],) + t[1:] for t in tpl]
                self.run(tpl)
            if gained:
                self.sym['vk'] = R['TMP'] + 8 + n
                self.run(chain('vk', *parts))
        for n, (k, parts) in enumerate(words):
            self.sym['vk'] = R['TMP'] + 8 + n
            for mode, slot, gain in gained:
                self.sym['pk'] = R['PCM'] + 256 * slot + k
                self.cst['g'] = gain
                if mode == 'set':
                    self.run(chain('pk', (P, 'vk', 'g')))
                else:
                    self.run([('set', 'pk', None, None, W32), ('add', 'vk', 'g', 'pk', W32)])


def run_block(eng, coeff, nf, blksw, dynrng, acmod, cmix, surmix):
    plan = fold_plan(acmod, nf, cmix, surmix)
    for ch in range(nf):
        short = bool((blksw >> ch) & 1) if ch < 5 else False
        Block(eng, coeff[ch], ch, short, dynrng, plan).transform()
    eng.valid |= set(range(nf))


# ------------------------------------------------------------------ the check
def compare(eng, im, nf, acmod):
    bad = []
    slots = [0] if nf == 1 else [0, 1]
    for s in slots:
        got = [IM.wrap(eng.ring[RING['PCM'] + 256 * s + k], 32) for k in range(256)]
        want = [IM.wrap(v, 32) for v in im.pcm[s]]
        if got != want:
            k = next(k for k in range(256) if got[k] != want[k])
            bad.append(f'pcm slot {s} [{k}] {got[k]} != {want[k]}')
    for ch in range(nf):
        got = [IM.wrap(eng.ring[RING['DLY'] + 128 * ch + j], 32) for j in range(128)]
        want = [IM.wrap(v, 32) for v in im.delay[ch][:128]]
        if got != want:
            j = next(j for j in range(128) if got[j] != want[j])
            bad.append(f'delay ch {ch} [{j}] {got[j]} != {want[j]}')
    return bad


# Cycles charged per element walked. 0 is a REQUIREMENT on the RTL, not an estimate: the
# sequencer fetches the next element's schedule entry while the current one issues, so
# elements run back to back (docs/imdct_engine.md I1). At 1 the worst AC-3 frame is
# 63.7 % under the budget's x1.25, over the 60 % bar; at 0, 58.8 %. I2's bench must
# match these cycles exactly.
ELEM_OVH = 0


def block_cycles(eng):
    return eng._now + ELEM_OVH * eng.elements


def frame_cycles(path, nframes):
    """-> per frame (in decode order, up to the first refusal), the IMDCT's cycles on
    the engine: tools/test_ac3_isa.py's budget charge."""
    eng, out = Engine(), []
    for hdr, bl in IM.decode_blocks(path, nframes):
        c0 = block_cycles(eng)
        for b in bl:
            run_block(eng, b['coeff'], IM.nfchans(hdr['acmod']), b['blksw'], b['dynrng'],
                      hdr['acmod'], hdr['cmixlev'], hdr['surmixlev'])
        out.append(block_cycles(eng) - c0)
    return out


def check_stream(path, nframes):
    eng, im = Engine(), IM.Imdct512()
    blocks = bad = 0
    first_bad = None
    per_block = []
    for hdr, bl in IM.decode_blocks(path, nframes):
        ac, nf = hdr['acmod'], IM.nfchans(hdr['acmod'])
        for b in bl:
            c0 = block_cycles(eng)
            run_block(eng, b['coeff'], nf, b['blksw'], b['dynrng'], ac, hdr['cmixlev'], hdr['surmixlev'])
            per_block.append((nf, block_cycles(eng) - c0))
            im.block(b['coeff'], nf, b['blksw'], b['dynrng'], ac, hdr['cmixlev'], hdr['surmixlev'])
            d = compare(eng, im, nf, ac)
            blocks += 1
            if d:
                bad += 1
                first_bad = first_bad or f'block {blocks - 1}: {d[0]}'
    return blocks, bad, first_bad, per_block, eng


def rand_block(rng, kind):
    nf = rng.choice([1, 2, 3, 4, 5])
    acmod = {1: 1, 2: rng.choice([0, 2]), 3: rng.choice([3, 4]), 4: rng.choice([5, 6]), 5: 7}[nf]
    if kind == 'full':
        coeff = [[rng.choice([-(1 << 23), (1 << 23) - 1]) for _ in range(256)] for _ in range(nf)]
        dyn = rng.choice([0x7F, 0x5F, 0x00, 0xFF])
    else:
        coeff = [[rng.randint(-(1 << 23), (1 << 23) - 1) for _ in range(256)] for _ in range(nf)]
        dyn = rng.randint(0, 255)
    return dict(nf=nf, acmod=acmod, coeff=coeff, blksw=rng.randint(0, 31), dynrng=dyn,
                cmix=rng.randint(0, 3), surmix=rng.randint(0, 3))


def check_random(n, seed=1):
    rng = random.Random(seed)
    bad = 0
    first = None
    for k in range(n):
        eng, im = Engine(), IM.Imdct512()          # a fresh pair: acmod changes per block
        for rep in range(3):                        # three blocks: the delay line carries
            b = rand_block(rng, 'full' if k % 2 else 'rand')
            run_block(eng, b['coeff'], b['nf'], b['blksw'], b['dynrng'], b['acmod'], b['cmix'], b['surmix'])
            im.block(b['coeff'], b['nf'], b['blksw'], b['dynrng'], b['acmod'], b['cmix'], b['surmix'])
            d = compare(eng, im, b['nf'], b['acmod'])
            if d:
                bad += 1
                first = first or f'case {k} rep {rep} {b["nf"]}ch acmod {b["acmod"]}: {d[0]}'
            # the next block of a fresh decoder state only: keep nf (delay lines are per ch)
    return n, bad, first


# ------------------------------------------------------------------ mutations (--red)
# Each breaks one thing the equality depends on; `need` is the stream feature (or the
# random arm) that must catch it. A mutation nothing catches is a FAIL.
def _mut_tpl(key, idx, field, val):
    def f():
        t = list(TPL[key][idx]); t[field] = val; TPL[key][idx] = tuple(t)
    return f


def _mut_global(name, fn):
    def f():
        globals()[name] = fn(globals()[name])
    return f


def _neg_floor():
    orig = Engine.term

    def term(self, mode, sval_fn, saddr, const, sh, dst, wr):
        if mode == 'sub' and const is not None:     # negate the operand, not the product
            v = sval_fn
            return orig(self, 'add', lambda: -v(), saddr, const, sh, dst, wr)
        return orig(self, mode, sval_fn, saddr, const, sh, dst, wr)
    Engine.term = term


def _no_first():
    orig = Block.rd

    def rd(self, s):
        valid, self.e.valid = self.e.valid, set(range(5))
        try:
            return orig(self, s)
        finally:
            self.e.valid = valid
    Block.rd = rd


def _drc_off():
    orig = Block.__init__

    def init(self, *a, **k):
        orig(self, *a, **k)
        self.drc_sh += 1
    Block.__init__ = init


def _slev():
    orig = fold_plan

    def fp(acmod, nf, cmix, surmix):
        return [[(m, sl, (g + 1 if g and g in (92682, 65536, 46341) and m == 'add' and sl == 1 and acmod & 4 else g))
                 for m, sl, g in c] for c in orig(acmod, nf, cmix, surmix)]
    globals()['fold_plan'] = fp


MUTS = {
    'short_dly':  (lambda: POST_S_DLY.__setitem__(0, ('nset',) + POST_S_DLY[0][1:]), 'short'),
    'drc_shift':  (_drc_off, 'any'),
    'neg_floor':  (_neg_floor, 'any'),
    'no_first':   (_no_first, 'any'),
    'slev':       (_slev, 'surround'),
    'm_w32':      (lambda: TPL.__setitem__('BHALF', [t[:4] + (W32,) if t[4] == W35 else t
                                                    for t in TPL['BHALF']]), 'random'),
    'bfull_wi':   (lambda: TPL.__setitem__('BFULL', [(t[0], t[1], 'wr', t[3], t[4]) if t[2] == 'wi' else t
                                                     for t in TPL['BFULL']]), 'any'),
}


def red(nframes):
    """Each mutation in a fresh interpreter: -> the number that nothing caught."""
    import subprocess
    blind = 0
    for name, (_, need) in MUTS.items():
        r = subprocess.run([sys.executable, __file__, 'check', '--mutate', name, '--frames', str(nframes),
                            '--random', '30'] + RED_STREAMS[need], capture_output=True, text=True)
        caught = 'RESULT: FAIL' in r.stdout
        blind += not caught
        hit = [(l.split()[2][:24] if l.startswith('[strm]') else l.split()[0])
               for l in r.stdout.splitlines() if l.startswith('[') and ' FAIL' in l[:12]]
        print(f'    RED {name:10s} ' + (f'caught ({", ".join(hit[:3])})' if caught else 'BLIND: FAIL'))
    return blind


RED_STREAMS = {}


def check_unit(n, seed=2):
    """IFFT + POST from an injected work buffer and delay line: any 32-bit words, with
    clusters at the rails (BHALF's pre-sums then need 33 bits). The stream and random
    arms cannot reach those states through PRE."""
    rng = random.Random(seed)
    bad, first, wide = 0, None, 0
    top = (1 << 31) - 1
    for k in range(n):
        short = bool(k & 1)
        mode = k % 3
        def word():                                           # noqa: E306
            if mode == 0:
                return rng.randint(-(1 << 31), top)
            if mode == 1:
                return rng.choice([top, top - rng.randint(0, 1 << 20), -(1 << 31) + rng.randint(0, 1 << 20)])
            return rng.choice([top, -(1 << 31)])
        buf = [(word(), word()) for _ in range(128)]
        dl = [word() for _ in range(128)]
        im = IM.Imdct512()
        im.first = False
        im.delay[0] = dl + [0] * 128
        im.ifft_post(0, short, list(buf), im.p, im.cost)
        eng = Engine()
        eng.valid = {0}
        for i, (r, q) in enumerate(buf):
            eng.ring[RING['BUF'] + 2 * i], eng.ring[RING['BUF'] + 2 * i + 1] = r, q
        for j in range(128):
            eng.ring[RING['DLY'] + j] = dl[j]
        Block(eng, [0] * 256, 0, short, 0, fold_plan(1, 1, 0, 0)).ifft_post()
        wide = max(wide, eng.max_sample)
        d = compare(eng, im, 1, 1)
        if d:
            bad += 1
            first = first or f'case {k} ({"short" if short else "long"}, mode {mode}): {d[0]}'
    return n, bad, first, wide


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('check')
    c.add_argument('streams', nargs='*')
    c.add_argument('--frames', type=int, default=4)
    c.add_argument('--random', type=int, default=0)
    c.add_argument('--mutate', choices=sorted(MUTS))
    c.add_argument('--red', action='store_true', help='run every mutation; each must be caught')
    a = ap.parse_args()
    fails = 0
    if a.mutate:
        MUTS[a.mutate][0]()
    if a.red:
        gs = IM.gate_streams()
        pick = lambda key: [p for p in gs if key in os.path.basename(p)][:1]     # noqa: E731
        RED_STREAMS.update(short=pick('09114_SCN'), surround=pick('acmod6_22'),
                           any=pick('noise_5p1_48k_640k'), random=[])
        RED_STREAMS['any'] += pick('10_2026')                                    # live DRC
        n = red(min(a.frames, 4))
        print(f'RESULT: {"PASS" if not n else "FAIL"} ({n} blind)')
        return 1 if n else 0
    if a.random:
        n, bad, first, wide = check_unit(a.random)
        print(f'[unit] {"PASS" if not bad and wide > 32 else "FAIL"} {n} injected buffers, {bad} bad, '
              f'widest sample {wide} bits' + (f' ({first})' if first else '')
              + ('' if wide > 32 else ' -- never reached 33 bits: vacuous'))
        fails += bad != 0 or wide <= 32
        n, bad, first = check_random(a.random)
        print(f'[rand] {"PASS" if not bad else "FAIL"} {n} cases x 3 blocks, {bad} bad' + (f' ({first})' if first else ''))
        fails += bad != 0
    paths = a.streams or (IM.gate_streams() if not a.random else [])
    worst = (0, '')
    for p in paths:
        blocks, bad, first, per, eng = check_stream(p, a.frames)
        if not blocks:
            print(f'[strm] SKIP {os.path.basename(p)}: no blocks')
            continue
        mx = max(c for _, c in per)
        fails += bad != 0
        print(f'[strm] {"PASS" if not bad else "FAIL"} {os.path.basename(p)[:50]:50s} {blocks:4d} blocks'
              f'  max {mx:6d} cyc/block  stalls {eng.stalls}  sample<= {eng.max_sample}b'
              + (f'  ({first})' if first else ''))
        if mx > worst[0]:
            worst = (mx, os.path.basename(p))
    if paths:
        print(f'worst block: {worst[0]} cycles ({worst[1]}); 6 blocks = '
              f'{100 * 6 * worst[0] / IM.FRAME_CYC:.1f} % of a frame')
    print(f'RESULT: {"PASS" if not fails else "FAIL"}')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
