#!/usr/bin/env python3
"""imdct_model.py -- dvd/ac3/imdct_512.sv's arithmetic in Python, bit for bit, and what
it would cost as a program on the shared audio engine (docs/logic_reclaim.md §10a).

The model follows the RTL, not liba52: every product is (sample * twiddle) >>> 17,
floored and wrapped to 34 bits; every stored word wraps to 32 bits; the five butterfly
ops, the long and short POST, DRC and the acmod-aware 5.1 fold are transcribed lane for
lane from imdct_512's operand mux. Its tables are PARSED from ac3_imdct_tables.svh, so
they cannot drift. bench/ac3/run_imdct_xcheck.sh scores it against the RTL itself.

The cost model counts engine TERMS (one a cycle, docs/dts_decoder.md "The half IMDCT is
a ROM program"). A term reads one sample from RAM, optionally multiplies it by a ROM
constant, floors, and adds the held result of the previous term. So an output costs one
term per operand it reads, and a product is exact only if every product is its own
term, because imdct_512 floors each product before it adds them. Temporaries that more
than one output reads (T/U, tt5/tt6, a/b/c/d) are written once and re-read.

The engine's multiplier is 27x27 signed. A sample operand that needs more than 27 bits
takes TWO terms (MP2's split: the low 16 bits, floor >> 16, then the high part on top,
floor >> 1, exact because floor(floor(y)/2) == floor(y/2)). The report gives three
figures: one pass (a widened multiplier), every product split (the static worst case),
and split only when the operand is wide (data-dependent, measured).

Usage:
    tools/imdct_model.py cost [--frames N] [STREAM.ac3 ...]   (default: the AC-3 gate set)
    tools/imdct_model.py vec STREAM.ac3 --frames N --out DIR  (vectors for the RTL cross-check)
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import ac3_model as M        # noqa: E402

OP_IFFT2, OP_IFFT4, OP_BZERO, OP_BHALF, OP_BFULL = range(5)
OPS = dict(OP_IFFT2=0, OP_IFFT4=1, OP_BZERO=2, OP_BHALF=3, OP_BFULL=4)
MUL_BITS = 27                    # dts_vec's signed operand width
FRAME_CYC = 27_000_000 * 1536 // 48000


# ------------------------------------------------------------------ the RTL's tables
def _tables():
    src = re.sub(r'//[^\n]*', '', open(os.path.join(REPO, 'dvd', 'ac3', 'ac3_imdct_tables.svh')).read())
    out = {}
    for m in re.finditer(r"(\w+)\s*=\s*'\{(.*?)\}\s*;", src, re.S):
        if m.group(1).endswith('_pk'):
            continue                 # packed copies of the arrays below
        vals = []
        for tok in m.group(2).split(','):
            tok = tok.strip().replace('_', '') if not tok.strip().startswith('OP_') else tok.strip()
            if not tok:
                continue
            if tok in OPS:
                vals.append(OPS[tok])
                continue
            neg = tok.startswith('-')
            tok = tok.lstrip('-+')
            mm = re.fullmatch(r"(?:\d+)?'s?([dhbo])([0-9a-fA-F]+)", tok)
            v = int(mm.group(2), {'d': 10, 'h': 16, 'b': 2, 'o': 8}[mm.group(1)]) if mm else int(tok, 0)
            vals.append(-v if neg else v)
        out[m.group(1)] = vals
    return out


T = _tables()


def s18(v):
    v &= 0x3FFFF
    return v - (1 << 18) if v & (1 << 17) else v


def wrap(v, n):
    v &= (1 << n) - 1
    return v - (1 << n) if v >> (n - 1) else v


def w32(v):
    return wrap(v, 32)


def w34(v):
    return wrap(v, 34)


FFTORDER = T['imdct_fftorder']
WINDOW = [s18(v) for v in T['imdct_window']]
PRE1 = list(zip(map(s18, T['imdct_pre1_re']), map(s18, T['imdct_pre1_im'])))
POST1 = list(zip(map(s18, T['imdct_post1_re']), map(s18, T['imdct_post1_im'])))
PRE2 = list(zip(map(s18, T['imdct_pre2_re']), map(s18, T['imdct_pre2_im'])))
POST2 = list(zip(map(s18, T['imdct_post2_re']), map(s18, T['imdct_post2_im'])))


def _sched(p):
    return list(zip(T[p + 'op'], T[p + 'a'], T[p + 'b'], T[p + 'c'], T[p + 'd'],
                    map(s18, T[p + 'wr']), map(s18, T[p + 'wi'])))


SCHED = {False: _sched('imdct_sched_'), True: _sched('imdct_s256_')}
assert len(FFTORDER) == 128 and len(WINDOW) == 256 and len(PRE1) == 128 and len(POST2) == 32
assert len(SCHED[False]) == 157 and len(SCHED[True]) == 134

CLEV = {0: 92682, 1: 77933, 2: 65536, 3: 77933}


def sbits(x):
    """Signed width: the fewest bits b with -2^(b-1) <= x < 2^(b-1)."""
    return (x if x >= 0 else ~x).bit_length() + 1


# ------------------------------------------------------------------ the cost model
# Terms an op costs in one pass. Every product is its own term (imdct_512 floors each
# product before adding), and a product's sample operand is what may be too wide.
#   drc      2   dk, d255k: coeff * mant >> shr (the coeff is 24 bits: never wide)
#   pre      4   re = p(d255k pi) + p(dk pr); im = p(d255k pr) - p(dk pi)
#   IFFT2    8   a, b: 4 words of 2 operands
#   IFFT4   32   A, B, T, U (8 words x 2), then a, b, c, d (8 x 2)
#   BZERO   24   T, U (4 x 2), then a, b, c, d (8 x 2)
#   BHALF   32   the 4 pre-sums (4 x 2); T, U as 4 two-product chains (8, products
#                re-formed per use); outputs (8 x 2)
#   BFULL   32   tt5, tt6, f7, f8 (4 two-product chains); T, U (4 x 2); outputs (8 x 2)
#   post    16   long POST per i: ar, ai, br, bi, then 4 windowed words (8 chains of 2)
#   post256 32   short POST per i: a..d (8 chains), 8 windowed words (8 chains)
#   dmx      -   Lo, Ro: the slot plus one term per product (C, S)
TERMS = {'drc': 2, 'pre': 4, OP_IFFT2: 8, OP_IFFT4: 32, OP_BZERO: 24, OP_BHALF: 32,
         OP_BFULL: 32, 'post': 16, 'post256': 32}


class Cost:
    """Terms for one run: `one` (a one-pass multiplier), `split` (every sample product
    two terms: the static worst case), `dyn` (two terms only when the operand is wider
    than MUL_BITS, measured)."""

    def __init__(self):
        self.one = self.split = self.dyn = 0
        self.muls = self.wide = 0
        self.width = {}              # site -> max operand width
        self.wide_by = {}            # site -> wide products
        self.units = 0               # butterflies + PRE/POST elements (stall points)

    def op(self, terms, prods, site):
        nwide = 0
        for x in prods:
            b = sbits(x)
            if b > self.width.get(site, 0):
                self.width[site] = b
            nwide += b > MUL_BITS
        self.one += terms
        self.split += terms + len(prods)
        self.dyn += terms + nwide
        self.muls += len(prods)
        self.wide += nwide
        self.units += site in ('pre', 'ifft', 'bhalf', 'bfull', 'post')
        if nwide:
            self.wide_by[site] = self.wide_by.get(site, 0) + nwide


# ------------------------------------------------------------------ the transform
class Imdct512:
    """One imdct_512 instance: its delay line and first-block flag persist."""

    def __init__(self):
        self.delay = [[0] * 256 for _ in range(5)]
        self.pcm = [[0] * 256 for _ in range(6)]       # slots, as pcm_mem: M10K powers up
        # zero, and stale slots persist (a 3/0 fold multiplies an unwritten one by 0)
        self.first = True
        self.cost = Cost()

    @staticmethod
    def p(a, b):
        return w34((a * b) >> 17)

    @staticmethod
    def p_red(a, b):            # the --red mutation: round half up instead of floor
        return w34((a * b + (1 << 16)) >> 17)

    def drc(self, c, dynrng):
        mant = 32 + (dynrng & 31)
        e = (dynrng >> 5) & 7
        e = e - 8 if e & 4 else e
        return w32((c * mant) >> (5 - e))

    def ifft_post(self, ch, short, buf, p, c):
        """The IFFT, then POST, the window and the overlap, for channel ch from the
        work buffer buf: into self.pcm[ch] and self.delay[ch]."""
        # ---- IFFT: the traced schedule
        for op, sa, sb, sc, sd, wr, wi in SCHED[short]:
            c0r, c0i = buf[sa & 127]
            c1r, c1i = buf[sb & 127]
            c2r, c2i = buf[sc & 127]
            c3r, c3i = buf[sd & 127]
            if op in (OP_IFFT2, OP_IFFT4):
                Ar, Ai, Br, Bi = c0r + c1r, c0i + c1i, c0r - c1r, c0i - c1i
            else:
                Ar, Ai, Br, Bi = c0r, c0i, c1r, c1i
            if op in (OP_IFFT4, OP_BZERO):
                Tr, Ti, Ur, Ui = c2r + c3r, c2i + c3i, c2i - c3i, c3r - c2r
                c.op(TERMS[op], [], 'ifft')
            elif op == OP_BHALF:
                m0, m1 = w34(c2r + c2i), w34(c2i - c2r)
                m2, m3 = w34(c3r - c3i), w34(c3i + c3r)
                c.op(TERMS[op], [m0, m2, m1, m3, m1, m3, m2, m0], 'bhalf')
                p0, p1, p2, p3 = p(m0, wr), p(m1, wr), p(m2, wr), p(m3, wr)
                Tr, Ti, Ur, Ui = w34(p0 + p2), w34(p1 + p3), w34(p1 - p3), w34(p2 - p0)
            elif op == OP_BFULL:
                c.op(TERMS[op], [c2r, c2i, c2i, c2r, c3r, c3i, c3i, c3r], 'bfull')
                tt5 = w34(p(c2r, wr) + p(c2i, wi))
                tt6 = w34(p(c2i, wr) - p(c2r, wi))
                f7 = w34(p(c3r, wr) - p(c3i, wi))
                f8 = w34(p(c3i, wr) + p(c3r, wi))
                Tr, Ti, Ur, Ui = w34(tt5 + f7), w34(tt6 + f8), w34(tt6 - f8), w34(f7 - tt5)
            else:
                Tr = Ti = Ur = Ui = 0
                c.op(TERMS[op], [], 'ifft')
            buf[sa & 127] = (w32(Ar + Tr), w32(Ai + Ti))
            buf[sb & 127] = (w32(Br + Ur), w32(Bi + Ui))
            if op != OP_IFFT2:
                buf[sc & 127] = (w32(Ar - Tr), w32(Ai - Ti))
                buf[sd & 127] = (w32(Br - Ur), w32(Bi - Ui))
        # ---- POST, window, overlap
        dl, out = self.delay[ch], self.pcm[ch]
        z = self.first
        if not short:
            for i in range(64):
                bir, bii = buf[i]
                b1r, b1i = buf[127 - i]
                d0 = 0 if z else dl[2 * i]
                d1 = 0 if z else dl[2 * i + 1]
                pr, pi = POST1[i]
                ar = w32(p(bir, pr) + p(bii, pi))
                ai = w32(p(bir, pi) - p(bii, pr))
                br = w32(p(b1r, pi) + p(b1i, pr))
                bi = w32(p(b1r, pr) - p(b1i, pi))
                wa, wb = WINDOW[2 * i], WINDOW[255 - 2 * i]
                pa0 = w32(p(d0, wb) - p(ar, wa))
                pa1 = w32(p(d0, wa) + p(ar, wb))
                wa, wb = WINDOW[2 * i + 1], WINDOW[254 - 2 * i]
                pb0 = w32(p(d1, wb) + p(br, wa))
                pb1 = w32(p(d1, wa) - p(br, wb))
                # 16 products: each sample operand once per product
                c.op(TERMS['post'], [bir, bii, bir, bii, b1r, b1i, b1r, b1i,
                              d0, ar, d0, ar, d1, br, d1, br], 'post')
                out[2 * i], out[2 * i + 1] = pa0, pb0
                out[255 - 2 * i], out[254 - 2 * i] = pa1, pb1
                dl[2 * i], dl[2 * i + 1] = ai, bi
        else:
            for i in range(32):
                q1ir, q1ii = buf[i]
                q1mr, q1mi = buf[63 - i]
                q2ir, q2ii = buf[64 + i]
                q2mr, q2mi = buf[127 - i]
                d2i = 0 if z else dl[2 * i]
                d2i1 = 0 if z else dl[2 * i + 1]
                d126 = 0 if z else dl[126 - 2 * i]
                d127 = 0 if z else dl[127 - 2 * i]
                pr, pi = POST2[i]
                s_ar = w32(p(q1ir, pr) + p(q1ii, pi)); s_ai = w32(p(q1ir, pi) - p(q1ii, pr))
                s_br = w32(p(q1mr, pi) + p(q1mi, pr)); s_bi = w32(p(q1mr, pr) - p(q1mi, pi))
                s_cr = w32(p(q2ir, pr) + p(q2ii, pi)); s_ci = w32(p(q2ir, pi) - p(q2ii, pr))
                s_dr = w32(p(q2mr, pi) + p(q2mi, pr)); s_di = w32(p(q2mr, pr) - p(q2mi, pi))
                wa, wb = WINDOW[2 * i], WINDOW[255 - 2 * i]
                o2i = w32(p(d2i, wb) - p(s_ar, wa)); o255 = w32(p(d2i, wa) + p(s_ar, wb))
                wa, wb = WINDOW[127 - 2 * i], WINDOW[128 + 2 * i]
                o128 = w32(p(d127, wa) + p(s_ai, wb)); o127 = w32(p(d127, wb) - p(s_ai, wa))
                wa, wb = WINDOW[2 * i + 1], WINDOW[254 - 2 * i]
                o2i1 = w32(p(d2i1, wb) - p(s_bi, wa)); o254 = w32(p(d2i1, wa) + p(s_bi, wb))
                wa, wb = WINDOW[126 - 2 * i], WINDOW[129 + 2 * i]
                o129 = w32(p(d126, wa) + p(s_br, wb)); o126 = w32(p(d126, wb) - p(s_br, wa))
                c.op(TERMS['post256'], [q1ir, q1ii, q1ir, q1ii, q1mr, q1mi, q1mr, q1mi,
                                 q2ir, q2ii, q2ir, q2ii, q2mr, q2mi, q2mr, q2mi,
                                 d2i, s_ar, d2i, s_ar, d127, s_ai, d127, s_ai,
                                 d2i1, s_bi, d2i1, s_bi, d126, s_br, d126, s_br], 'post')
                out[2 * i], out[255 - 2 * i], out[128 + 2 * i], out[127 - 2 * i] = o2i, o255, o128, o127
                out[2 * i + 1], out[254 - 2 * i], out[129 + 2 * i], out[126 - 2 * i] = o2i1, o254, o129, o126
                dl[2 * i], dl[2 * i + 1] = s_ci, s_dr
                dl[126 - 2 * i], dl[127 - 2 * i] = s_di, s_cr

    def block(self, coeff, nf, blksw, dynrng, acmod, cmix, surmix):
        """coeff[ch][256] (Q1.23) for ch < nf -> pcm slots, exactly as imdct_512 leaves them."""
        p, c = (self.p_red if os.environ.get('IMDCT_MODEL_RED') == '1' else self.p), self.cost
        for ch in range(nf):
            short = bool((blksw >> ch) & 1) if ch < 5 else False
            buf = [(0, 0)] * 128
            # ---- PRE
            for i in range(128):
                if short:
                    fo = FFTORDER[i & 63]
                    a0 = (fo + 1) & 255 if i >= 64 else fo
                    a1 = (255 - fo) & 255 if i >= 64 else (254 - fo) & 255
                    pr, pi = PRE2[i & 63]
                else:
                    fo = FFTORDER[i]
                    a0, a1 = fo, (255 - fo) & 255
                    pr, pi = PRE1[i]
                c.op(TERMS['drc'], [], 'drc')
                dk = self.drc(coeff[ch][a0], dynrng)
                d255k = self.drc(coeff[ch][a1], dynrng)
                c.op(TERMS['pre'], [d255k, dk, d255k, dk], 'pre')
                buf[i] = (w32(p(d255k, pi) + p(dk, pr)), w32(p(d255k, pr) - p(dk, pi)))
            self.ifft_post(ch, short, buf, p, c)
        # ---- the 5.1 -> stereo fold (imdct_512 S_DMX)
        if nf > 2:
            has_c = (acmod & 1) and acmod != 1
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
            s = self.pcm
            for k in range(256):
                L = s[0][k]
                R = s[2][k] if has_c else s[1][k]
                C = s[1][k]
                LS = s[3][k] if has_c else s[2][k]
                RS = LS if mono_s else (s[4][k] if has_c else s[3][k])
                cw = w32(p(C, clev))
                s[0][k] = w32(L + cw + w32(p(LS, slev)))
                s[1][k] = w32(R + cw + w32(p(RS, slev)))
                lo = ([C] if clev else []) + ([LS] if slev else [])
                ro = ([C] if clev else []) + ([RS] if slev else [])
                c.op(1 + len(lo), lo, 'dmx')
                c.op(1 + len(ro), ro, 'dmx')
        self.first = False
        return self.pcm


def nfchans(acmod):
    return M.NFCHANS[acmod]


def decode_blocks(path, nframes):
    """-> [(hdr, block)] from the RTL-order model, up to the first refusal."""
    buf = open(path, 'rb').read()
    dec = M.Decoder()
    out = []
    for k, (_, fr) in enumerate(M.frames(buf)):
        if nframes and k >= nframes:
            break
        try:
            hdr, blocks = dec.frame(fr)
        except M.Ac3Error:
            break
        out.append((hdr, blocks))
    return out


# ------------------------------------------------------------------ the RTL cross-check
def write_vectors(path, nframes, out):
    """params.mem: one word a block {nf, blksw, dynrng, acmod, cmix, surmix};
    coeff.mem: 2048 Q1.23 words a block at {ch, bin}; expect.mem: 6 x 256 pcm slots
    a block, as imdct_512's pcm_mem holds them after `done`."""
    os.makedirs(out, exist_ok=True)
    im = Imdct512()
    n = live = 0
    with open(os.path.join(out, 'params.mem'), 'w') as fp, \
            open(os.path.join(out, 'coeff.mem'), 'w') as fc, \
            open(os.path.join(out, 'expect.mem'), 'w') as fe:
        for hdr, blocks in decode_blocks(path, nframes):
            ac, nf = hdr['acmod'], nfchans(hdr['acmod'])
            for b in blocks:
                word = (nf << 20) | (b['blksw'] << 15) | (b['dynrng'] << 7) | (ac << 4) \
                    | (hdr['cmixlev'] << 2) | hdr['surmixlev']
                fp.write(f'{word:06x}\n')
                for ch in range(8):
                    vals = b['coeff'][ch] if ch < nf else [0] * 256
                    for v in vals:
                        fc.write(f'{v & 0xFFFFFF:06x}\n')
                        live += v != 0
                pcm = im.block(b['coeff'], nf, b['blksw'], b['dynrng'], ac,
                               hdr['cmixlev'], hdr['surmixlev'])
                for ch in range(6):
                    for v in pcm[ch]:
                        fe.write(f'{v & 0xFFFFFFFF:08x}\n')
                n += 1
    return n, live


# ------------------------------------------------------------------ the cycle budget
def gate_streams():
    from test_ac3_model import streams
    return streams()


def cost_stream(path, nframes):
    """-> dict: per frame engine cycles (parse, as test_ac3_isa.frame_cost charges them)
    and the IMDCT's terms three ways; the operand widths seen."""
    import ac3_isa as A
    m, _, bad, _ = A.emulate(path, nframes)
    fc = m.frame_cycles
    head = (A.CYC_HEADROOM - 1) * m.vec_model / max(len(fc), 1) if fc else 0
    im = Imdct512()
    rows = []
    for k, (hdr, blocks) in enumerate(decode_blocks(path, nframes)):
        if k >= len(fc):
            break
        c0 = (im.cost.one, im.cost.split, im.cost.dyn, im.cost.units)
        for b in blocks:
            im.block(b['coeff'], nfchans(hdr['acmod']), b['blksw'], b['dynrng'], hdr['acmod'],
                     hdr['cmixlev'], hdr['surmixlev'])
        c = im.cost
        rows.append(dict(parse=fc[k] + head, acmod=hdr['acmod'],
                         one=c.one - c0[0], split=c.split - c0[1], dyn=c.dyn - c0[2],
                         units=c.units - c0[3]))
    return dict(rows=rows, cost=im.cost, bad=bad)


def main():
    global MUL_BITS
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    v = sub.add_parser('vec')
    v.add_argument('stream')
    v.add_argument('--frames', type=int, default=2)
    v.add_argument('--out', required=True)
    c = sub.add_parser('cost')
    c.add_argument('streams', nargs='*')
    c.add_argument('--frames', type=int, default=24)
    c.add_argument('--stall', type=int, default=2,
                   help='bubble cycles charged per butterfly and per PRE/POST element')
    c.add_argument('--mul-bits', type=int, default=MUL_BITS,
                   help='the multiplier operand width (a smaller one exercises the split path)')
    c.add_argument('--headroom', type=float, default=1.25,
                   help="test_ac3_isa's CYC_HEADROOM, applied to the modelled IMDCT charge")
    a = ap.parse_args()
    if a.cmd == 'vec':
        n, live = write_vectors(a.stream, a.frames, a.out)
        print(f'imdct_model: {n} blocks, {live} nonzero coefficients -> {a.out}')
        return 0
    MUL_BITS = a.mul_bits
    paths = a.streams or gate_streams()
    worst = {'one': (0, ''), 'split': (0, ''), 'dyn': (0, '')}
    gate = {'one': (0, ''), 'split': (0, ''), 'dyn': (0, '')}
    tot = Cost()
    print(f'{"stream":58s} fr  parse%  +IMDCT one / dyn / split (worst frame, % of {FRAME_CYC})')
    for p in paths:
        r = cost_stream(p, a.frames)
        rows = r['rows']
        if not rows:
            print(f'{os.path.basename(p)[:58]:58s}  -- no frames before a refusal')
            continue
        st = r['cost']
        # the bubble allowance: per butterfly and per PRE/POST element, all channels
        for key in ('one', 'split', 'dyn'):
            for row in rows:
                row[key] += a.stall * row['units']
        line = []
        for key in ('one', 'dyn', 'split'):
            w = max(rows, key=lambda x: x['parse'] + x[key])
            f = (w['parse'] + w[key]) / FRAME_CYC
            line.append(f'{100 * f:5.1f}')
            if f > worst[key][0]:
                worst[key] = (f, os.path.basename(p))
            g = max((x['parse'] + a.headroom * x[key]) / FRAME_CYC for x in rows)
            if g > gate[key][0]:
                gate[key] = (g, os.path.basename(p))
        pw = max(x['parse'] for x in rows) / FRAME_CYC
        print(f'{os.path.basename(p)[:58]:58s} {len(rows):2d} {100 * pw:6.1f}  '
              + ' / '.join(line)
              + f'   wide {st.wide}/{st.muls}' + (f' {st.wide_by}' if st.wide else ''))
        tot.muls += st.muls
        tot.wide += st.wide
        for s_, b in st.width.items():
            tot.width[s_] = max(tot.width.get(s_, 0), b)
    print(f'\nworst frame: one pass {100 * worst["one"][0]:.1f} % ({worst["one"][1]}); '
          f'split when wide {100 * worst["dyn"][0]:.1f} % ({worst["dyn"][1]}); '
          f'always split {100 * worst["split"][0]:.1f} % ({worst["split"][1]})')
    print(f'with x{a.headroom} on the modelled IMDCT charge (the budget gate\'s convention): '
          f'one pass {100 * gate["one"][0]:.1f} %; split when wide {100 * gate["dyn"][0]:.1f} %; '
          f'always split {100 * gate["split"][0]:.1f} %')
    print(f'products {tot.muls}, wider than {MUL_BITS} bits: {tot.wide}; '
          f'max operand width by site {dict(sorted(tot.width.items()))}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
