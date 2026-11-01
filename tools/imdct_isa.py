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
RING = {'BUF': 0, 'TMP': 256, 'D': 512, 'DLY': 768, 'PCM': 1536, 'END': 2048}   # PCM = {2'b11, slot, k}
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
POST_L_TMP = (chain('t0', (P, 'bAr', 'pr'), (P, 'bAi', 'pi')) +          # ar
              chain('t1', (P, 'bDr', 'pi'), (P, 'bDi', 'pr')))           # br
POST_L_OUT = [   # (output index symbol, parts)
    ('o0', ((P, 'dl0', 'wb0'), (M, 't0', 'wa0'))),      # out[2i]       = pa0
    ('o1', ((P, 'dl0', 'wa0'), (P, 't0', 'wb0'))),      # out[255-2i]   = pa1
    ('o2', ((P, 'dl1', 'wb1'), (P, 't1', 'wa1'))),      # out[2i+1]     = pb0
    ('o3', ((P, 'dl1', 'wa1'), (M, 't1', 'wb1'))),      # out[254-2i]   = pb1
]
POST_L_DLY = (chain('dl0', (P, 'bAr', 'pi'), (M, 'bAi', 'pr')) +          # ai
              chain('dl1', (P, 'bDr', 'pr'), (M, 'bDi', 'pi')))           # bi
# POST, short, element i
POST_S_TMP = (chain('t0', (P, 'bAr', 'pr'), (P, 'bAi', 'pi')) +        # s_ar
              chain('t1', (P, 'bAr', 'pi'), (M, 'bAi', 'pr')) +        # s_ai
              chain('t2', (P, 'bBr', 'pi'), (P, 'bBi', 'pr')) +        # s_br
              chain('t3', (P, 'bBr', 'pr'), (M, 'bBi', 'pi')))         # s_bi
POST_S_OUT = [
    ('o0', ((P, 'dl0', 'wb0'), (M, 't0', 'wa0'))),     # out[2i]
    ('o1', ((P, 'dl0', 'wa0'), (P, 't0', 'wb0'))),     # out[255-2i]
    ('o2', ((P, 'dl3', 'wa1'), (P, 't1', 'wb1'))),    # out[128+2i]
    ('o3', ((P, 'dl3', 'wb1'), (M, 't1', 'wa1'))),    # out[127-2i]
    ('o4', ((P, 'dl1', 'wb2'), (M, 't3', 'wa2'))),    # out[2i+1]
    ('o5', ((P, 'dl1', 'wa2'), (P, 't3', 'wb2'))),    # out[254-2i]
    ('o6', ((P, 'dl2', 'wa3'), (P, 't2', 'wb3'))),    # out[129+2i]
    ('o7', ((P, 'dl2', 'wb3'), (M, 't2', 'wa3'))),    # out[126-2i]
]
POST_S_DLY = (chain('dl0', (P, 'bCr', 'pi'), (M, 'bCi', 'pr')) +       # s_ci
              chain('dl1', (P, 'bDr', 'pi'), (P, 'bDi', 'pr')) +      # s_dr
              chain('dl2', (P, 'bDr', 'pr'), (M, 'bDi', 'pi')) +      # s_di
              chain('dl3', (P, 'bCr', 'pr'), (P, 'bCi', 'pi')))       # s_cr


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


# ------------------------------------------------------------------ the ROM (what I2 runs)
# Operand symbols -> 6-bit codes. The RTL resolves a code to an address with the
# element's context (resolve_src below is that function); code 0 is "none".
SRC = (['none'] + [f'c{n}{p}' for n in range(4) for p in 'ri'] + [f't{n}' for n in range(NTMP)] +
       ['da0', 'da1', 'bi_r', 'bi_i', 'xj', 'dj'] +
       [f'b{q}{p}' for q in 'ABCD' for p in 'ri'] + [f'dl{n}' for n in range(4)] +
       [f'p{sl}_{n}' for sl in (0, 1) for n in range(8)])
assert len(SRC) <= 64
SRC_CODE = {n: k for k, n in enumerate(SRC)}
# Constant symbols -> 4-bit codes; 0 = no constant (an add term)
CST = ['none', 'wr', 'wi', 'pr', 'pi', 'wa0', 'wb0', 'wa1', 'wb1', 'wa2', 'wb2', 'wa3', 'wb3',
       'mant', 'clev', 'slev']
assert len(CST) <= 16
CST_CODE = {n: k for k, n in enumerate(CST)}
MODE_CODE = {'set': 0, 'nset': 1, 'add': 2, 'sub': 3}
MODES = {v: k for k, v in MODE_CODE.items()}
TERM_BITS = 20                     # {last, w35, dst[5:0], cst[3:0], src[5:0], mode[1:0]}

# The fold's per-channel roles (fold_plan's contributions, the gain named by its constant)
CLASSES = {
    'D0':   [('set', 0, None)],                       # L, or channel 0 of a 1/2-channel mode
    'D1':   [('set', 1, None)],                       # channel 1 of a 2-channel mode; R, no C
    'A1':   [('add', 1, None)],                       # R after C
    'C':    [('add', 0, 'clev'), ('set', 1, 'clev')],
    'S':    [('add', 0, 'slev'), ('add', 1, 'slev')], # one surround, both sides
    'LS':   [('add', 0, 'slev')],
    'RS':   [('add', 1, 'slev')],
    'NONE': [],                                       # a surround at slev 0: delay line only
}
CLASS_LIST = list(CLASSES)


def fold_classes(acmod, nf, cmix, surmix):
    """-> (per-channel class names, clev, slev): fold_plan, as the ROM's classes."""
    plan = fold_plan(acmod, nf, cmix, surmix)
    has_c = bool(acmod & 1) and acmod != 1
    clev = CLEV[cmix] if (has_c and nf > 2) else 0
    names, slev = [], 0
    for c in plan:
        if c == [('set', 0, None)]:
            names.append('D0')
        elif c == [('set', 1, None)]:
            names.append('D1')
        elif c == [('add', 1, None)]:
            names.append('A1')
        elif not c:
            names.append('NONE')
        elif c[0][2] == clev and len(c) == 2 and c[1][0] == 'set':
            names.append('C')
        else:
            slev = c[0][2]
            names.append({2: 'S'}.get(len(c), 'LS' if c[0][1] == 0 else 'RS'))
    return names, clev, slev


def _outs_symbolic(cls, out_parts):
    """An element's output words, symbolically (Block.outs' order)."""
    contrib = CLASSES[cls]
    direct = [c for c in contrib if c[2] is None]
    gained = [c for c in contrib if c[2] is not None]
    lift = {'set': 'add', 'nset': 'sub', 'add': 'add', 'sub': 'sub'}
    t = []
    for n, (_, parts) in enumerate(out_parts):
        if direct:
            (mode, slot, _), = direct
            tpl = chain(f'p{slot}_{n}', *parts)
            if mode == 'add':
                tpl = [('set', f'p{slot}_{n}', None, None, W32)] + [(lift[x[0]],) + x[1:] for x in tpl]
            t += tpl
        if gained:
            t += chain(f't{8 + n}', *parts)
    for n, _ in enumerate(out_parts):
        for mode, slot, g in gained:
            if mode == 'set':
                t += chain(f'p{slot}_{n}', (P, f't{8 + n}', g))
            else:
                t += [('set', f'p{slot}_{n}', None, None, W32), ('add', f't{8 + n}', g, f'p{slot}_{n}', W32)]
    return t


def templates():
    """-> {kind: [terms]}: every element kind the walk runs."""
    k = {'DRC': TPL['DRC'], 'PRE': TPL['PRE']}
    for op in OPS:
        k[op] = TPL[op]
    for cls in CLASSES:
        k['POSTL_' + cls] = POST_L_TMP + _outs_symbolic(cls, POST_L_OUT) + POST_L_DLY
        k['POSTS_' + cls] = POST_S_TMP + _outs_symbolic(cls, POST_S_OUT) + POST_S_DLY
    return k


def encode(term, last):
    mode, src, cst, dst, wr = term
    return (MODE_CODE[mode] | SRC_CODE[src] << 2 | CST_CODE[cst or 'none'] << 8 |
            (SRC_CODE[dst] if dst else 0) << 12 | (wr == W35) << 18 | last << 19)


def decode(w):
    return (MODES[w & 3], SRC[(w >> 2) & 63], CST[(w >> 8) & 15], SRC[(w >> 12) & 63],
            W35 if (w >> 18) & 1 else W32, (w >> 19) & 1)


def build_rom():
    """-> (words, {kind: (base, length)}): the term ROM and its directory."""
    words, dirn = [], {}
    for kind, tpl in templates().items():
        dirn[kind] = (len(words), len(tpl))
        for n, t in enumerate(tpl):
            words.append(encode(t, n == len(tpl) - 1))
    return words, dirn


ROM, DIR = build_rom()


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
        """Fixed cycles: the RTL's pipeline fill and drain (BLOCK_FILL, BLOCK_DRAIN)."""
        self._now += n


# Output word n's sample index, and the window taps, by element i (long / short POST)
def k_of(n, i, short):
    return ((2 * i, 255 - 2 * i, 128 + 2 * i, 127 - 2 * i, 2 * i + 1, 254 - 2 * i, 129 + 2 * i, 126 - 2 * i)
            if short else (2 * i, 255 - 2 * i, 2 * i + 1, 254 - 2 * i))[n]


def win_of(sym, i, short):
    n, ab = int(sym[2]), sym[1]
    if short:
        idx = {('a', 0): 2 * i, ('b', 0): 255 - 2 * i, ('a', 1): 127 - 2 * i, ('b', 1): 128 + 2 * i,
               ('a', 2): 2 * i + 1, ('b', 2): 254 - 2 * i, ('a', 3): 126 - 2 * i, ('b', 3): 129 + 2 * i}
    else:
        idx = {('a', 0): 2 * i, ('b', 0): 255 - 2 * i, ('a', 1): 2 * i + 1, ('b', 1): 254 - 2 * i}
    return idx[(ab, n)]


class Ctx:
    """An element's context: what the RTL holds in registers while its terms issue."""
    __slots__ = ('ch', 'short', 'i', 'j', 'a0', 'a1', 's', 'wr', 'wi', 'phase')

    def __init__(self, **k):
        for f in self.__slots__:
            setattr(self, f, k.get(f, 0))


def resolve_src(sym, c):
    """A sample symbol -> its ring address, or ('X', bin). The RTL's address mux."""
    R = RING
    if sym[0] == 'c' and len(sym) == 3:
        return R['BUF'] + 2 * (c.s[int(sym[1])] & 127) + (sym[2] == 'i')
    if sym[0] == 't':
        return R['TMP'] + int(sym[1:])
    if sym in ('da0', 'da1'):
        return R['D'] + (c.a0 if sym == 'da0' else c.a1)
    if sym in ('bi_r', 'bi_i'):
        return R['BUF'] + 2 * c.i + (sym == 'bi_i')
    if sym == 'xj':
        return ('X', c.j)
    if sym == 'dj':
        return R['D'] + c.j
    if sym[0] == 'b':
        ix = {'A': c.i, 'B': 63 - c.i, 'C': 64 + c.i, 'D': 127 - c.i}[sym[1]]
        return R['BUF'] + 2 * ix + (sym[2] == 'i')
    if sym[:2] == 'dl':
        j = (2 * c.i, 2 * c.i + 1, 126 - 2 * c.i, 127 - 2 * c.i)[int(sym[2])]
        return R['DLY'] + 128 * c.ch + j
    if sym[0] == 'p':
        return R['PCM'] + 256 * int(sym[1]) + k_of(int(sym[3]), c.i, c.short)
    raise KeyError(sym)


def resolve_cst(sym, c, blk):
    """A constant symbol -> (value, shift). The RTL's constant-ROM address mux."""
    if sym == 'wr':
        return c.wr, 17
    if sym == 'wi':
        return c.wi, 17
    if sym in ('pr', 'pi'):
        if c.phase == 'PRE':
            t = IM.PRE2[c.i & 63] if c.short else IM.PRE1[c.i]
        else:
            t = IM.POST2[c.i] if c.short else IM.POST1[c.i]
        return t[sym == 'pi'], 17
    if sym[0] == 'w':
        return IM.WINDOW[win_of(sym, c.i, c.short)], 17
    if sym == 'mant':
        return blk.mant, blk.drc_sh
    if sym == 'clev':
        return blk.clev, 17
    if sym == 'slev':
        return blk.slev, 17
    raise KeyError(sym)


class Block:
    """One channel's transform, run from the term ROM (ROM, DIR) only."""

    def __init__(self, eng, coeff, ch, short, dynrng, cls, clev, slev):
        self.e, self.coeff, self.ch, self.short = eng, coeff, ch, short
        self.cls, self.clev, self.slev = cls, clev, slev
        mant = 32 + (dynrng & 31)
        ex = (dynrng >> 5) & 7
        ex = ex - 8 if ex & 4 else ex
        self.mant, self.drc_sh = mant, 5 - ex

    def run_kind(self, kind, c):
        e = self.e
        e.elements += 1
        base, n = DIR[kind]
        for w in ROM[base:base + n]:
            mode, src, cst, dst, wr, _ = decode(w)
            a = resolve_src(src, c)
            if isinstance(a, tuple):
                fn, sa = (lambda b=a[1]: self.coeff[b]), None
            elif self.ch not in e.valid and RING['DLY'] <= a < RING['PCM']:
                fn, sa = (lambda: 0), a
            else:
                fn, sa = (lambda x=a: e.ring[x]), a
            if cst == 'none':
                const, sh = None, 0
            else:
                const, sh = resolve_cst(cst, c, self)
            e.term(mode, fn, sa, const, sh, None if dst == 'none' else resolve_src(dst, c), wr)

    def transform(self):
        c = Ctx(ch=self.ch, short=self.short, phase='DRC')
        for j in range(256):
            c.j = j
            self.run_kind('DRC', c)
        c.phase = 'PRE'
        for i in range(128):
            if self.short:
                fo = IM.FFTORDER[i & 63]
                c.a0 = (fo + 1) & 255 if i >= 64 else fo
                c.a1 = (255 - fo) & 255 if i >= 64 else (254 - fo) & 255
            else:
                fo = IM.FFTORDER[i]
                c.a0, c.a1 = fo, (255 - fo) & 255
            c.i = i
            self.run_kind('PRE', c)
        self.ifft_post()

    def ifft_post(self):
        c = Ctx(ch=self.ch, short=self.short, phase='IFFT')
        for op, sa, sb, sc, sd, wr, wi in IM.SCHED[self.short]:
            c.s, c.wr, c.wi = (sa, sb, sc, sd), wr, wi
            self.run_kind(OPS[op], c)
        c.phase = 'POST'
        kind = ('POSTS_' if self.short else 'POSTL_') + self.cls
        for i in range(32 if self.short else 64):
            c.i = i
            self.run_kind(kind, c)


BLOCK_FILL = 2       # op start -> the first term issues (fetch, resolve)
BLOCK_DRAIN = 3      # the last term issues -> its write lands -> done


def run_block(eng, coeff, nf, blksw, dynrng, acmod, cmix, surmix):
    cls, clev, slev = fold_classes(acmod, nf, cmix, surmix)
    eng.barrier(BLOCK_FILL)
    for ch in range(nf):
        short = bool((blksw >> ch) & 1) if ch < 5 else False
        Block(eng, coeff[ch], ch, short, dynrng, cls[ch], clev, slev).transform()
    eng.barrier(BLOCK_DRAIN)
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
# 63.7 % under the budget's x1.25, over the 60 % bar; at 0, 58.8 %. The RTL meets it:
# bench/dvd/run_imdct_eng.sh [cycles] matches every item, so the budget charges these
# at x1.0.
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
    orig = Block.run_kind

    def run_kind(self, kind, c):
        valid, self.e.valid = self.e.valid, set(range(5))
        try:
            return orig(self, kind, c)
        finally:
            self.e.valid = valid
    Block.run_kind = run_kind


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
        Block(eng, [0] * 256, 0, short, 0, 'D0', 0, 0).ifft_post()
        wide = max(wide, eng.max_sample)
        d = compare(eng, im, 1, 1)
        if d:
            bad += 1
            first = first or f'case {k} ({"short" if short else "long"}, mode {mode}): {d[0]}'
    return n, bad, first, wide


# ------------------------------------------------------------------ RTL vectors
def _w35(v):
    return v & ((1 << 35) - 1)


def write_vectors(out, streams=(), frames=2, nrand=0, nunit=0, seed=3):
    """One continuous run for bench/dvd/imdct_eng_tb.sv, from a junk ring:
      ring0.mem   2048 x 35  the ring before the first item
      items.txt   per item: N nf blksw dynrng acmod cmix surmix cycles  (a block)
                            U short cycles                              (ISKIP: IFFT +
                            POST of channel 0 on an injected buffer and delay line)
      coeff.mem   per N item, nf x 256 Q1.23 words (slot = channel)
      inj.mem     per U item, 256 buffer words then 128 delay words (35-bit)
      expect.mem  per item, the whole ring after it (2048 x 35): every word, temps too
    -> the item count."""
    os.makedirs(out, exist_ok=True)
    eng = Engine(junk=seed)
    rng = random.Random(seed)
    items = []
    for p in streams:
        for hdr, bl in IM.decode_blocks(p, frames):
            for b in bl:
                items.append(('N', b['coeff'], IM.nfchans(hdr['acmod']), b['blksw'], b['dynrng'],
                              hdr['acmod'], hdr['cmixlev'], hdr['surmixlev']))
    for k in range(nrand):
        b = rand_block(rng, 'full' if k % 2 else 'rand')
        items.append(('N', b['coeff'], b['nf'], b['blksw'], b['dynrng'], b['acmod'], b['cmix'], b['surmix']))
    for k in range(nunit):
        top = (1 << 31) - 1
        mode = k % 3
        def word():                                           # noqa: E306
            if mode == 0:
                return rng.randint(-(1 << 31), top)
            if mode == 1:
                return rng.choice([top, top - rng.randint(0, 1 << 20), -(1 << 31) + rng.randint(0, 1 << 20)])
            return rng.choice([top, -(1 << 31)])
        items.append(('U', bool(k & 1), [word() for _ in range(256)], [word() for _ in range(128)]))
    with open(os.path.join(out, 'ring0.mem'), 'w') as f:
        f.writelines(f'{_w35(v):09x}\n' for v in eng.ring)
    fi = open(os.path.join(out, 'items.txt'), 'w')
    fc = open(os.path.join(out, 'coeff.mem'), 'w')
    fj = open(os.path.join(out, 'inj.mem'), 'w')
    fe = open(os.path.join(out, 'expect.mem'), 'w')
    wide = 0
    for it in items:
        c0 = block_cycles(eng)
        if it[0] == 'N':
            _, coeff, nf, blksw, dyn, acmod, cmix, sur = it
            run_block(eng, coeff, nf, blksw, dyn, acmod, cmix, sur)
            for ch in range(nf):
                fc.writelines(f'{v & 0xFFFFFF:06x}\n' for v in coeff[ch])
            fi.write(f'N {nf} {blksw} {dyn} {acmod} {cmix} {sur} {block_cycles(eng) - c0}\n')
        else:
            _, short, buf, dl = it
            for n, v in enumerate(buf):
                eng.ring[RING['BUF'] + n] = v
            for j, v in enumerate(dl):
                eng.ring[RING['DLY'] + j] = v
            fj.writelines(f'{_w35(v):09x}\n' for v in buf + dl)
            eng.valid |= {0}
            eng.barrier(BLOCK_FILL)
            Block(eng, [0] * 256, 0, short, 0, 'D0', 0, 0).ifft_post()
            eng.barrier(BLOCK_DRAIN)
            fi.write(f'U {int(short)} {block_cycles(eng) - c0}\n')
        fe.writelines(f'{_w35(v):09x}\n' for v in eng.ring)
        wide = max(wide, eng.max_sample)
    for f in (fi, fc, fj, fe):
        f.close()
    return len(items), wide


KINDS = (['DRC', 'PRE'] + list(OPS) + ['POSTL_' + c for c in CLASS_LIST] +
         ['POSTS_' + c for c in CLASS_LIST])        # kind code = index (IFFT op k = 2 + k)
ASM_MEM = os.path.join(os.path.dirname(HERE), 'dvd', 'dts', 'imdct_tprog.mem')
ASM_SVH = os.path.join(os.path.dirname(HERE), 'dvd', 'dts', 'imdct_isa.svh')


def asm_text():
    mem = ''.join(f'{w:05x}\n' for w in ROM)
    kb = ''.join(f'{DIR[k][0]:010b}' for k in reversed(KINDS))
    kl = ''.join(f'{DIR[k][1]:07b}' for k in reversed(KINDS))
    assert max(DIR[k][0] for k in KINDS) < 1024 and max(DIR[k][1] for k in KINDS) < 128
    L = ['// dvd/dts/imdct_isa.svh -- GENERATED by tools/imdct_isa.py asm. DO NOT EDIT.',
         '// The AC-3 IMDCT term program\'s directory and codes (docs/imdct_engine.md).',
         f'localparam int IM_TP_WORDS = {len(ROM)};',
         f'localparam int IM_NKIND = {len(KINDS)};',
         '// kind k: base IM_KB[10k +: 10], length IM_KL[7k +: 7]; ' +
         ', '.join(f'{n} {k}' for n, k in enumerate(KINDS)),
         f"localparam logic [{10 * len(KINDS) - 1}:0] IM_KB = {10 * len(KINDS)}'b{kb};",
         f"localparam logic [{7 * len(KINDS) - 1}:0] IM_KL = {7 * len(KINDS)}'b{kl};",
         f'localparam logic [4:0] IM_K_DRC = 5\'d0, IM_K_PRE = 5\'d1, IM_K_OP = 5\'d2, '
         f'IM_K_POSTL = 5\'d{KINDS.index("POSTL_" + CLASS_LIST[0])}, '
         f'IM_K_POSTS = 5\'d{KINDS.index("POSTS_" + CLASS_LIST[0])};',
         '// fold classes: ' + ', '.join(f'{n} {c}' for n, c in enumerate(CLASS_LIST)),
         '// source symbols (6 bits): ' + ', '.join(f'{n} {c}' for n, c in enumerate(SRC)),
         f"localparam logic [5:0] IM_S_C = 6'd{SRC_CODE['c0r']}, IM_S_T = 6'd{SRC_CODE['t0']}, "
         f"IM_S_DA0 = 6'd{SRC_CODE['da0']}, IM_S_DA1 = 6'd{SRC_CODE['da1']}, "
         f"IM_S_BIR = 6'd{SRC_CODE['bi_r']}, IM_S_BII = 6'd{SRC_CODE['bi_i']}, "
         f"IM_S_XJ = 6'd{SRC_CODE['xj']}, IM_S_DJ = 6'd{SRC_CODE['dj']}, "
         f"IM_S_B = 6'd{SRC_CODE['bAr']}, IM_S_DL = 6'd{SRC_CODE['dl0']}, IM_S_P = 6'd{SRC_CODE['p0_0']};",
         '// constant symbols (4 bits): ' + ', '.join(f'{n} {c}' for n, c in enumerate(CST)),
         "localparam logic [3:0] " + ', '.join(f"IM_C_{c.upper()} = 4'd{n}" for n, c in enumerate(CST)) + ';',
         f"localparam logic [10:0] IM_R_BUF = 11'd{RING['BUF']}, IM_R_TMP = 11'd{RING['TMP']}, "
         f"IM_R_D = 11'd{RING['D']}, IM_R_DLY = 11'd{RING['DLY']}, IM_R_PCM = 11'd{RING['PCM']};",
         '']
    return mem, '\n'.join(L)


def asm(check=False):
    mem, svh = asm_text()
    if check:
        ok = all(os.path.exists(f) and open(f).read() == t for f, t in ((ASM_MEM, mem), (ASM_SVH, svh)))
        return 0 if ok else 1
    open(ASM_MEM, 'w').write(mem)
    open(ASM_SVH, 'w').write(svh)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sm = sub.add_parser('asm')
    sm.add_argument('--check', action='store_true', help='the generated files match (exit 1 if not)')
    v = sub.add_parser('vec')
    v.add_argument('streams', nargs='*')
    v.add_argument('--out', required=True)
    v.add_argument('--frames', type=int, default=1)
    v.add_argument('--random', type=int, default=0)
    v.add_argument('--unit', type=int, default=0)
    c = sub.add_parser('check')
    c.add_argument('streams', nargs='*')
    c.add_argument('--frames', type=int, default=4)
    c.add_argument('--random', type=int, default=0)
    c.add_argument('--mutate', choices=sorted(MUTS))
    c.add_argument('--red', action='store_true', help='run every mutation; each must be caught')
    a = ap.parse_args()
    if a.cmd == 'asm':
        rc = asm(check=a.check)
        print(f'imdct_isa asm: {"up to date" if a.check and not rc else "STALE" if rc else "written"} '
              f'({len(ROM)} words, {len(KINDS)} kinds)')
        return rc
    if a.cmd == 'vec':
        n, wide = write_vectors(a.out, a.streams, a.frames, a.random, a.unit)
        print(f'imdct_isa vec: {n} items -> {a.out} (widest sample {wide} bits)')
        return 0
    fails = 0
    if a.mutate:
        MUTS[a.mutate][0]()
        globals().update(zip(('ROM', 'DIR'), build_rom()))   # a template mutation reaches the ROM
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
