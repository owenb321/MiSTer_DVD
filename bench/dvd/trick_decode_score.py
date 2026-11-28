#!/usr/bin/env python3
"""trick_decode_score.py <log> <stream.m2v> [--pics N] [--min-psnr DB]

Scores bench/dvd/trick_decode_tb.sv: rebuilds every picture the RTL decoder reconstructed
(from the framestore writes it logged) and compares each with ffmpeg's decode of the same
stream, in order. For an I-frame-only stream decode order is display order, so picture i
of the RTL is frame i of ffmpeg.

Framestore layout (rtl/mpeg2/mem_addr.v, dvd/mem_override/mem_codes.v, MP@ML):
  a 64-bit word holds 8 horizontally adjacent pixels, leftmost in the top byte, each
  stored SIGNED (pixel - 128: rtl/mpeg2/motcomp_recon.v, so averaging keeps the DC level);
  luma word  = base_Y + y * (mb_width * 2) + x / 8
  chroma word = base_C + y * mb_width + x / 8         (Cb plane first, then Cr)
  slot s base_Y = s * (2^16 + 2 * 2^14); base_Cb = base_Y + 2^16; base_Cr = base_Cb + 2^14
  (Cb-first measured 2026-11-23: the other order scores 19.8 dB, this one 66 dB.)

The two decoders' IDCTs are both IEEE 1180 conformant, not bit-identical, so the score is
a PSNR floor (default 45 dB) and a per-pixel ceiling, not equality. A decoder that loses
sync or mis-parses a picture lands far below either.

Exit 0 = PASS (every expected picture present and above the floor), 1 = FAIL.
"""
import argparse, subprocess, sys
import numpy as np

WY, WC = 1 << 16, 1 << 14
SLOT = WY + 2 * WC


def rtl_pictures(log, W, H):
    mbw = (W + 15) // 16
    per_pic = (W * H + 2 * (W // 2) * (H // 2)) // 8
    words, events, summary = [], [], None
    for line in open(log):
        t = line.split()
        if not t:
            continue
        if t[0] == 'W':
            words.append((int(t[1], 16), int(t[2], 16)))
        elif t[0] == 'E':
            events.append(' '.join(t[1:]))
        elif t[0] == 'D':
            summary = t[1:]
    pics = []
    for p in range(len(words) // per_pic):
        Y = np.zeros((H, W), np.uint8)
        Cr = np.zeros((H // 2, W // 2), np.uint8)
        Cb = np.zeros((H // 2, W // 2), np.uint8)
        for a, d in words[p * per_pic:(p + 1) * per_pic]:
            off = a % SLOT
            px = [((d >> (56 - 8 * i)) & 0xFF) ^ 0x80 for i in range(8)]   # stored offset by 128 (two's complement around mid-grey)
            if off < WY:
                y, xw = divmod(off, mbw * 2)
                if y < H and xw * 8 < W:
                    Y[y, xw * 8:xw * 8 + 8] = px
            else:
                c = off - WY
                plane = Cb if c < WC else Cr
                c %= WC
                y, xw = divmod(c, mbw)
                if y < H // 2 and xw * 8 < W // 2:
                    plane[y, xw * 8:xw * 8 + 8] = px
        pics.append((Y, Cb, Cr))
    return pics, events, summary


def ffmpeg_frames(m2v, W, H):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'mpegvideo', '-i', m2v,
                          '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-'],
                         capture_output=True, check=True).stdout
    n = W * H * 3 // 2
    out = []
    for i in range(len(raw) // n):
        b = np.frombuffer(raw[i * n:(i + 1) * n], np.uint8)
        Y = b[:W * H].reshape(H, W)
        U = b[W * H:W * H * 5 // 4].reshape(H // 2, W // 2)
        V = b[W * H * 5 // 4:].reshape(H // 2, W // 2)
        out.append((Y, U, V))
    return out


def psnr(a, b):
    m = np.mean((a.astype(int) - b.astype(int)) ** 2)
    return 99.0 if m == 0 else 10 * np.log10(255 * 255 / m)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('m2v')
    ap.add_argument('--pics', type=int, default=0, help='pictures expected (default: all logged)')
    ap.add_argument('--min-psnr', type=float, default=45.0)
    ap.add_argument('--max-diff', type=int, default=24)
    ap.add_argument('--size', default='720x480')
    a = ap.parse_args()
    W, H = map(int, a.size.split('x'))
    pics, events, summary = rtl_pictures(a.log, W, H)
    ref = ffmpeg_frames(a.m2v, W, H)
    want = a.pics or len(pics)
    print('rtl pictures %d, ffmpeg frames %d, expected %d; events %s; summary %s'
          % (len(pics), len(ref), want, events or 'none', summary))
    ok = len(pics) >= want and len(ref) >= want and want > 0 and not events
    for i in range(min(want, len(pics), len(ref))):
        ps = [psnr(pics[i][c], ref[i][c]) for c in range(3)]
        md = max(int(np.max(np.abs(pics[i][c].astype(int) - ref[i][c].astype(int))))
                 for c in range(3))
        good = min(ps) >= a.min_psnr and md <= a.max_diff
        ok &= good
        print('  pic %2d  PSNR Y %5.1f Cb %5.1f Cr %5.1f  max |diff| %3d  %s'
              % (i, ps[0], ps[1], ps[2], md, 'ok' if good else 'BAD'))
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
