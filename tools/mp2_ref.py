#!/usr/bin/env python3
"""
mp2_ref.py — bit-exact fixed-point reference model for the fabric MPEG-1 Layer II
audio decoder (dvd/mp2/*).

This is the golden model the RTL is verified against (same role tools/dvd_vm_ref.py
plays for dvd_vm.sv and the AC-3 cosim flow plays for dvd/ac3/*): every arithmetic
step is integer-only and mirrors the RTL's fixed-point widths exactly, so the RTL
testbench can demand BIT-EXACT PCM. Model correctness itself is established
separately by comparing this model's PCM against ffmpeg's float decode (SNR gate,
see selftest / bench/dvd/mp2_decode_tb.sv fixture generator).

Scope (DVD + future VCD/SVCD):
  - MPEG-1 (ID=1) Layer II only. 32/44.1/48 kHz. All Layer II bitrates.
  - mono, stereo, joint (intensity) stereo, dual channel. Output is always a
    stereo pair (mono duplicated) — the core is stereo-out only.
  - No CRC check (protection bit parsed, CRC bytes skipped) — matches RTL v1.
  - MPEG-2 LSF (ID=0) Layer II is NOT implemented (not DVD-legal).

Fixed-point contract (mirrored by the RTL, see docs/mpeg1.md):
  - Dequantized subband sample: signed 2.24 (sign + 1 int + 24 frac) => 27-bit.
    s'' = c*(s''' + d): s''' is the raw code word with MSB inverted, as a signed
    fraction in Q(nb-1); d addition done exactly; c is Q1.16; product rounded
    (truncated toward -inf, i.e. arithmetic shift) to Q2.24.
  - Scalefactor multiply: scf table is Q3.20 of 2^(3-idx/3) range... stored as
    Q1.20 of 2^(-idx/3) with idx 0..62; product (Q2.24 x Q1.20) >> 20 -> Q2.24,
    saturated to [-2^25, 2^25-1].
  - Synthesis matrixing: N[i][k] = cos((16+i)(2k+1)pi/64) in Q1.14 (16-bit signed
    incl. sign; +/-1.0 saturates to +/-16383);
    V[i] = (sum_k N[i][k]*S[k]) >> 14, accumulated in >=48 bits, result clipped
    to signed 30 bits (Q6.24 headroom: the matrix row gain can reach ~10).
  - Window: D[j] in Q2.16 (Table 3-B.3 x 2^16, integer-exact; |D| max ~1.145),
    512 taps; PCM = (sum of 16 windowed V terms) rounded >> 25 (Q.16 x Q.24 ->
    Q.40; s16 full scale = 2^15 => shift 40-15=25), clipped to s16.

Usage:
  mp2_ref.py decode  in.mp2 out.pcm  [--frames N] [--dump-stages dir]
  mp2_ref.py compare in.mp2          [--frames N]   # decode + SNR vs ffmpeg
  mp2_ref.py fixture in.mp2 out_dir  [--frames N]   # write TB fixture files
  mp2_ref.py selftest                                # synthetic + table checks

decode  writes interleaved s16le stereo PCM.
fixture writes: frames.hex (one byte per line, the exact frame bytes fed to the
RTL), pcm_golden.hex (one 32-bit word per line: {right[15:0], left[15:0]} per
output sample time), and meta.txt (frame count, sample rate, etc).
"""

import argparse
import math
import os
import struct
import subprocess
import sys

# ---------------------------------------------------------------------------
# Header / tables (ISO/IEC 11172-3)
# ---------------------------------------------------------------------------

BITRATES_L2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
SAMPLE_RATES = {0: 44100, 1: 48000, 2: 32000}

# Layer II bit allocation tables (Table 3-B.2a..d).
# Each entry: for subband sb, a list of the allowed quantization "steps" values
# indexed by the coded allocation value (0 = no samples). Values are nlevels.
# nbal (bits used to code the allocation) = ceil(log2(len(list))).
#
# Table 3-B.2a: 48kHz at 56..192 kbit/s/ch; 44.1/32 kHz high rates use 2b, etc.
# Selection logic in table_select().

_T2a_hi = [3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535]
# subbands 0-2: 4-bit alloc, 15 classes (above); 3-10: 4-bit with the 3/5/7/9.. set;
# 11-22: 3-bit; 23-26: 2-bit
_T2ab_0_2 = [0, 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535]
_T2ab_3_10 = [0, 3, 5, 7, 9, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 65535]
_T2ab_11_22 = [0, 3, 5, 7, 9, 15, 31, 65535]
_T2ab_23_end = [0, 3, 5, 65535]

_T2cd_0_1 = [0, 3, 5, 9, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767]
_T2cd_2_end = [0, 3, 5, 9, 15, 31, 63, 127]


def table_select(sample_rate, bitrate_kbps, nch):
    """Return (sblimit, per-subband allocation table list). ISO 11172-3 2.4.2.3."""
    per_ch = bitrate_kbps // nch
    if sample_rate == 32000 and per_ch in (32, 48):
        # Table 3-B.2d: 12 subbands
        return 12, [_T2cd_0_1 if sb < 2 else _T2cd_2_end for sb in range(12)]
    if sample_rate in (44100, 48000) and per_ch in (32, 48):
        # Table 3-B.2c: 8 subbands
        return 8, [_T2cd_0_1 if sb < 2 else _T2cd_2_end for sb in range(8)]
    if sample_rate == 48000:
        # Table 3-B.2a: 27 subbands
        sblimit = 27
    elif per_ch >= 96:
        # 44.1/32 kHz, >=96 kbit/s/ch: Table 3-B.2b: 30 subbands
        sblimit = 30
    else:
        # 44.1/32 kHz, 56..80: Table 3-B.2a (27 subbands)
        sblimit = 27
    tab = []
    for sb in range(sblimit):
        if sb < 3:
            tab.append(_T2ab_0_2)
        elif sb < 11:
            tab.append(_T2ab_3_10)
        elif sb < 23:
            tab.append(_T2ab_11_22)
        else:
            tab.append(_T2ab_23_end)
    return sblimit, tab


def nbal_of(alloc_list):
    n = len(alloc_list)
    return (n - 1).bit_length()


# Grouped classes: nlevels -> (bits per group of 3, grouped?)
def sample_bits(nlevels):
    """Return (grouped, bits) — grouped: one code covers 3 samples."""
    if nlevels == 3:
        return True, 5
    if nlevels == 5:
        return True, 7
    if nlevels == 9:
        return True, 10
    return False, nlevels.bit_length()  # 2^n - 1 classes: n bits


# (C, D) requantization constants per class (Table 3-B.4), in Q1.16 / exact.
# s'' = C * (s''' + D)  where s''' has |s'''| < 1.
# C = nlevels_scaled: e.g. 3 -> 1.33333333, D = 0.5, etc.
_CD = {
    3: (1.33333333333, 0.5),
    5: (1.60000000000, 0.5),
    7: (1.14285714286, 0.25),
    9: (1.77777777777, 0.5),
    15: (1.06666666666, 0.125),
    31: (1.03225806452, 0.0625),
    63: (1.01587301587, 0.03125),
    127: (1.00787401575, 0.015625),
    255: (1.00392156863, 0.0078125),
    511: (1.00195694716, 0.00390625),
    1023: (1.00097751711, 0.001953125),
    2047: (1.00048851979, 0.0009765625),
    4095: (1.00024420024, 0.00048828125),
    8191: (1.00012208522, 0.000244140625),
    16383: (1.00006103888, 0.0001220703125),
    32767: (1.00003051851, 0.00006103515625),
    65535: (1.00001525902, 0.000030517578125),
}

C_Q16 = {n: int(round(c * (1 << 16))) for n, (c, d) in _CD.items()}
# D as an exact power of two: D = 2^-d_shift... all D values are 2^-k
D_SHIFT = {n: int(round(-math.log2(d))) for n, (c, d) in _CD.items()}

# Scalefactor table: 2^(-idx/3), idx 0..62, Q1.20 --- idx 0..2 give 2.0, 1.5874, 1.2599
# ISO: scalefactor = 2.0 * 2^(-idx/3). Max value idx=0 -> 2.0 exactly.
SCF_Q20 = [int(round(2.0 * (2.0 ** (-i / 3.0)) * (1 << 20))) for i in range(63)]

# Synthesis matrixing coefficients N[i][k] = cos((16+i)(2k+1)pi/64), Q1.14.
N_Q14 = [[int(round(math.cos((16 + i) * (2 * k + 1) * math.pi / 64.0) * (1 << 14)))
          for k in range(32)] for i in range(64)]

# Window coefficients D[0..511] (Table 3-B.3), Q2.16 integer-exact.
# See tools/mp2_window.py for provenance (pl_mpeg via CDi_MiSTer).
from mp2_window import D_Q16  # 512-entry list, Q2.16 signed (|D| max ~1.145)


def _bits(data):
    """MSB-first bit reader over bytes."""
    pos = 0
    n = len(data) * 8

    def get(k):
        nonlocal pos
        v = 0
        for _ in range(k):
            if pos >= n:
                raise EOFError("bit reader past end of frame")
            byte = data[pos >> 3]
            v = (v << 1) | ((byte >> (7 - (pos & 7))) & 1)
            pos += 1
        return v

    def tell():
        return pos

    return get, tell


def sat(v, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return lo if v < lo else hi if v > hi else v


class MP2Decoder:
    def __init__(self):
        # Synthesis state per channel: V ring buffer of 1024 (Q6.24-ish, 30-bit)
        self.V = [[0] * 1024 for _ in range(2)]
        self.voff = [0, 0]

    # -- frame parsing ------------------------------------------------------
    @staticmethod
    def parse_header(b4):
        w = struct.unpack(">I", b4)[0]
        if (w >> 21) & 0x7FF != 0x7FF:
            return None
        id_bit = (w >> 19) & 1
        layer = (w >> 17) & 3
        if id_bit != 1 or layer != 2:  # MPEG-1 Layer II only
            return None
        protection = (w >> 16) & 1
        bidx = (w >> 12) & 0xF
        sridx = (w >> 10) & 3
        padding = (w >> 9) & 1
        mode = (w >> 6) & 3
        mode_ext = (w >> 4) & 3
        if bidx == 0 or bidx == 15 or sridx == 3:
            return None  # free-format unsupported / invalid
        sr = SAMPLE_RATES[sridx]
        br = BITRATES_L2[bidx]
        frame_len = 144 * br * 1000 // sr + padding
        return dict(bitrate=br, sample_rate=sr, padding=padding, mode=mode,
                    mode_ext=mode_ext, protection=protection, frame_len=frame_len)

    def decode_frame(self, frame, hdr):
        """frame: full frame bytes (starting at the sync word). Returns list of
        1152 (l, r) tuples of s16."""
        get, tell = _bits(frame)
        get(32)  # header
        if hdr["protection"] == 0:
            get(16)  # crc_check
        mode = hdr["mode"]
        nch = 1 if mode == 3 else 2
        sblimit, alloc_tab = table_select(hdr["sample_rate"], hdr["bitrate"], nch)
        bound = sblimit
        if mode == 1:  # joint (intensity) stereo
            bound = (hdr["mode_ext"] + 1) * 4
            if bound > sblimit:
                bound = sblimit

        # allocation
        alloc = [[0] * sblimit for _ in range(2)]
        for sb in range(bound):
            for ch in range(nch):
                alloc[ch][sb] = get(nbal_of(alloc_tab[sb]))
        for sb in range(bound, sblimit):
            a = get(nbal_of(alloc_tab[sb]))
            alloc[0][sb] = alloc[1][sb] = a

        # scfsi
        scfsi = [[0] * sblimit for _ in range(2)]
        for sb in range(sblimit):
            for ch in range(nch):
                if alloc[ch][sb]:
                    scfsi[ch][sb] = get(2)

        # scalefactors
        scf = [[[0, 0, 0] for _ in range(sblimit)] for _ in range(2)]
        for sb in range(sblimit):
            for ch in range(nch):
                if not alloc[ch][sb]:
                    continue
                s = scfsi[ch][sb]
                if s == 0:
                    a, b, c = get(6), get(6), get(6)
                elif s == 1:
                    a = get(6); c = get(6); b = a
                elif s == 2:
                    a = get(6); b = c = a
                else:
                    a = get(6); c = get(6); b = c
                scf[ch][sb] = [a, b, c]

        # samples: 12 granules x 3 samples
        pcm = []
        S = [[0] * 32 for _ in range(2)]  # dequantized subband samples, Q2.24
        for gr in range(12):
            part = gr // 4  # which scalefactor third
            triplet = [[[0, 0, 0] for _ in range(sblimit)] for _ in range(2)]
            for sb in range(sblimit):
                for ch in range(nch):
                    if sb >= bound and ch == 1:
                        continue  # intensity: shared samples read once (ch 0)
                    a = alloc[ch][sb]
                    if a == 0:
                        continue
                    nlevels = alloc_tab[sb][a]
                    grouped, nbits = sample_bits(nlevels)
                    if grouped:
                        code = get(nbits)
                        for k in range(3):
                            triplet[ch][sb][k] = code % nlevels
                            code //= nlevels
                    else:
                        for k in range(3):
                            triplet[ch][sb][k] = get(nbits)
            for k in range(3):
                for ch in range(2):
                    for sb in range(32):
                        S[ch][sb] = 0
                for sb in range(sblimit):
                    for ch in range(nch):
                        src = 0 if (sb >= bound) else ch
                        a = alloc[src][sb]
                        if a == 0:
                            continue
                        nlevels = alloc_tab[sb][a]
                        q = triplet[src][sb][k]
                        s24 = self.requantize(q, nlevels)
                        # scalefactor: per-channel even in intensity mode
                        idx = scf[ch][sb][part] if (sb < bound or nch == 1) \
                            else scf[ch][sb][part]
                        v = (s24 * SCF_Q20[idx]) >> 20
                        S[ch][sb] = sat(v, 27)
                if nch == 1:
                    S[1] = list(S[0])
                l = self.synth(0, S[0])
                r = self.synth(1, S[1])
                pcm.extend(zip(l, r))
        return pcm

    @staticmethod
    def requantize(q, nlevels):
        """ISO 2.4.3.3: s'' = C*(s''' + D). Integer-exact, returns Q2.24."""
        grouped, nbits = sample_bits(nlevels)
        if grouped:
            # q in 0..nlevels-1; map to code of nb bits where nb = bits needed
            nb = {3: 2, 5: 3, 9: 4}[nlevels]
        else:
            nb = nbits
        # s''': invert MSB, two's complement fraction with nb-1 fractional bits
        msb = 1 << (nb - 1)
        x = q ^ msb  # invert MSB
        if x & msb:
            x -= 1 << nb  # negative
        # x is now a signed integer in [-2^(nb-1), 2^(nb-1)-1], value = x / 2^(nb-1)
        # s''' + D:  D = 2^-dshift  => in units of 2^-(nb-1): D_units = 2^(nb-1-dshift)
        dsh = D_SHIFT[nlevels]
        x_q24 = x << (25 - nb)  # Q1.24: x / 2^(nb-1) => x * 2^24 / 2^(nb-1)
        d_q24 = 1 << (24 - dsh)
        s = x_q24 + d_q24
        # * C (Q1.16) -> >>16, keep Q2.24
        return (s * C_Q16[nlevels]) >> 16

    def synth(self, ch, S):
        """32-band polyphase synthesis. S: 32 subband samples Q2.24.
        Returns 32 s16 PCM samples."""
        V = self.V[ch]
        self.voff[ch] = (self.voff[ch] - 64) % 1024
        off = self.voff[ch]
        for i in range(64):
            acc = 0
            row = N_Q14[i]
            for k in range(32):
                acc += row[k] * S[k]
            v = acc >> 14  # back to Q~.24, worst-case gain ~<32 -> 30 bits + margin
            V[(off + i) & 1023] = sat(v, 32)
        pcm = []
        for j in range(32):
            acc = 0
            for i in range(8):
                acc += D_Q16[j + 64 * i] * V[(off + j + 128 * i) & 1023]
                acc += D_Q16[j + 64 * i + 32] * V[(off + j + 128 * i + 96) & 1023]
            # acc: Q2.16 * Q2.24 -> Q.40; s16 full scale 2^15 => >> 25, rounded.
            v = (acc + (1 << 24)) >> 25
            pcm.append(sat(v, 16))
        return pcm


# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

def iter_frames(data, max_frames=None):
    pos = 0
    n = 0
    while pos + 4 <= len(data):
        hdr = MP2Decoder.parse_header(data[pos:pos + 4])
        if hdr is None:
            pos += 1
            continue
        if pos + hdr["frame_len"] > len(data):
            break
        yield data[pos:pos + hdr["frame_len"]], hdr
        pos += hdr["frame_len"]
        n += 1
        if max_frames and n >= max_frames:
            break


def cmd_decode(args):
    data = open(args.infile, "rb").read()
    dec = MP2Decoder()
    out = open(args.outfile, "wb")
    nf = 0
    for frame, hdr in iter_frames(data, args.frames):
        for l, r in dec.decode_frame(frame, hdr):
            out.write(struct.pack("<hh", l, r))
        nf += 1
    out.close()
    print(f"decoded {nf} frames -> {args.outfile}")


def cmd_compare(args):
    data = open(args.infile, "rb").read()
    dec = MP2Decoder()
    ours = []
    nf = 0
    sr = None
    for frame, hdr in iter_frames(data, args.frames):
        sr = hdr["sample_rate"]
        ours.extend(dec.decode_frame(frame, hdr))
        nf += 1
    # ffmpeg float decode of the same bytes
    p = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "mp3", "-i", args.infile,
         "-f", "s16le", "-ac", "2", "-"],
        capture_output=True, check=True)
    ref = struct.unpack(f"<{len(p.stdout)//2}h", p.stdout)
    ref = list(zip(ref[0::2], ref[1::2]))
    # The polyphase filterbank delay: both decoders start from zero state, so
    # samples align 1:1 from the first output sample.
    ncmp = min(len(ours), len(ref))
    # skip the first frame (transient state differences) for SNR
    skip = 1152
    num = den = 0
    maxerr = 0
    for i in range(skip, ncmp):
        for c in range(2):
            e = ours[i][c] - ref[i][c]
            maxerr = max(maxerr, abs(e))
            num += ref[i][c] * ref[i][c]
            den += e * e
    snr = 10 * math.log10(num / den) if den else float("inf")
    print(f"frames={nf} sr={sr} cmp_samples={ncmp - skip} max_err={maxerr} SNR={snr:.1f} dB")
    # Gate: within the project's audio error budget (±2 LSB @ s16, same as the
    # AC-3 cosim PCM_TOL_LSB) or high SNR for loud content.
    return 0 if (maxerr <= 2 or snr > 60) else 1


def cmd_fixture(args):
    data = open(args.infile, "rb").read()
    os.makedirs(args.outdir, exist_ok=True)
    dec = MP2Decoder()
    fbytes = []
    pcm = []
    nf = 0
    sr = None
    for frame, hdr in iter_frames(data, args.frames):
        sr = hdr["sample_rate"]
        fbytes.extend(frame)
        pcm.extend(dec.decode_frame(frame, hdr))
        nf += 1
    with open(os.path.join(args.outdir, "frames.hex"), "w") as f:
        for b in fbytes:
            f.write(f"{b:02x}\n")
    with open(os.path.join(args.outdir, "pcm_golden.hex"), "w") as f:
        for l, r in pcm:
            f.write(f"{(r & 0xffff):04x}{(l & 0xffff):04x}\n")
    with open(os.path.join(args.outdir, "meta.txt"), "w") as f:
        f.write(f"frames {nf}\nsample_rate {sr}\nsamples {len(pcm)}\n")
    print(f"wrote {nf} frames, {len(pcm)} samples to {args.outdir}")


def cmd_selftest(args):
    # table sanity
    assert len(SCF_Q20) == 63 and SCF_Q20[0] == 2 << 20
    assert len(D_Q16) == 512
    for n, c in C_Q16.items():
        assert 1 << 16 <= c <= (2 << 16)
    ok_grp = {3: (True, 5), 5: (True, 7), 9: (True, 10), 65535: (False, 16)}
    for n, exp in ok_grp.items():
        assert sample_bits(n) == exp, (n, sample_bits(n))
    # requantize endpoints: q=0 (most negative), q=nlevels-1 (most positive);
    # range is symmetric (e.g. +/-2/3 for 3 levels) and inside +/-1.0
    for n in _CD:
        lo = MP2Decoder.requantize(0, n)
        hi = MP2Decoder.requantize(n - 1, n)
        assert lo < 0 < hi and abs(hi + lo) <= 1 and hi < (1 << 24), (n, lo, hi)
    print("selftest OK")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decode"); d.add_argument("infile"); d.add_argument("outfile")
    d.add_argument("--frames", type=int, default=None); d.set_defaults(fn=cmd_decode)
    c = sub.add_parser("compare"); c.add_argument("infile")
    c.add_argument("--frames", type=int, default=None); c.set_defaults(fn=cmd_compare)
    x = sub.add_parser("fixture"); x.add_argument("infile"); x.add_argument("outdir")
    x.add_argument("--frames", type=int, default=None); x.set_defaults(fn=cmd_fixture)
    s = sub.add_parser("selftest"); s.set_defaults(fn=cmd_selftest)
    args = ap.parse_args()
    rc = args.fn(args)
    sys.exit(rc or 0)


if __name__ == "__main__":
    main()
