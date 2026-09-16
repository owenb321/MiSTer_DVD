#!/usr/bin/env python3
"""fry_detect.py -- is this board capture of a menu decoded with the WRONG matrix?

Compares a screenshot against **ffmpeg's decode of that menu's own bytes off the
disc**. ffmpeg parses the still's own sequence header, so it dequantises with the
matrix the disc authored: a same-content reference, which is the whole point.

  ratio = high-frequency energy(board) / high-frequency energy(ffmpeg truth)

A picture dequantised with a matrix flatter than its own has every AC coefficient
scaled up, so its local contrast rises. Measured on NACHO_LIBRE_WS VTS_07 PGCN 13:

    v0.4.0 (clean)   0.87x        softscope, fried instance   2.53x

⚠⚠ THIS EXISTS BECAUSE tools/blockiness (energy ON the 8-px DCT grid / off it) IS
NOT USABLE AS A POPULATION ORACLE, and trusting it cost a wrong conclusion that had
to be retracted. On posterised menu art its strong OFF-grid edges swell the
denominator: the fried capture above measures 0.785 and the CLEAN ground truth
1.058 -- the metric moves the WRONG WAY. Blockiness is only sound with a
same-content control; this tool provides one by construction.

⚠ The comparison must exclude the harness's own overlay. `Debug Overlay=On` paints
O[2] blocks top-left and the HUD paints a status line; measured over the FULL frame
they roughly double the board's HF energy and swamp the signal. The default box is
the picture body only.

⚠ A capture taken while a menu is still building, or an interlaced weave of moving
content, also raises HF. Sample a SETTLED menu, and read a single elevated reading
as a candidate rather than a verdict -- the defect this hunts is intermittent
(~1 in 5 launches on Nacho Libre, ~1 in 8 historically on Elmo), so the measurement
that means anything is a RATE over repeated launches, not one frame.
"""
import sys, os, argparse, subprocess
import numpy as np
from PIL import Image


def hf(a):
    """Mean |Laplacian| -- local contrast energy."""
    return float(np.abs(a[1:-1, 1:-1] * 4 - a[:-2, 1:-1] - a[2:, 1:-1]
                        - a[1:-1, :-2] - a[1:-1, 2:]).mean())


def body(a, top=0.20, bot=0.80, side=20):
    h, w = a.shape
    return a[int(h * top):int(h * bot), side:w - side]


def luma(path):
    return np.asarray(Image.open(path).convert('L'), dtype=float)


def truth_png(iso, vts, pgcn, out):
    """Decode the menu's own elementary stream with ffmpeg."""
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    from dvd_vm_ref import IsoNav, DOM_VMGM, DOM_VTSM
    import struct
    nav = IsoNav(iso)
    lst = nav.pgcit(DOM_VMGM if vts == 0 else DOM_VTSM, vts)
    _, abs_ = lst[pgcn - 1]
    h = nav.rd(abs_, 236)
    co = struct.unpack('>H', h[232:234])[0]
    e = nav.rd(abs_ + co, 24)
    first = struct.unpack('>I', e[8:12])[0]
    last = struct.unpack('>I', e[20:24])[0]
    base = nav.menu_vob[vts][0]
    es = bytearray()
    for s in range(first, min(last + 1, first + 400)):
        sec = nav.sec(base + s)
        if len(sec) < 2048 or sec[:4] != b'\x00\x00\x01\xba':
            continue
        i = 14 + (sec[13] & 7)
        while i + 6 <= 2048:
            if sec[i:i+3] != b'\x00\x00\x01':
                break
            sid = sec[i+3]; ln = (sec[i+4] << 8) | sec[i+5]
            b = sec[i+6:i+6+ln]
            if sid == 0xE0 and len(b) >= 3:
                es += b[3 + b[2]:]
            i += 6 + ln
    open(out + '.m2v', 'wb').write(bytes(es))
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', out + '.m2v',
                    '-frames:v', '1', out + '.png'], check=True)
    return out + '.png'


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('captures', nargs='+', help='board screenshots (PNG)')
    ap.add_argument('--truth', help='reference PNG (else build it with --iso/--vts/--pgcn)')
    ap.add_argument('--iso'); ap.add_argument('--vts', type=int); ap.add_argument('--pgcn', type=int)
    ap.add_argument('--threshold', type=float, default=1.5)
    a = ap.parse_args()

    ref = a.truth or truth_png(a.iso, a.vts, a.pgcn, '/tmp/fry_truth')
    t = body(luma(ref))
    r0 = hf(t)
    print('truth %-44s HF=%.1f' % (os.path.basename(ref), r0))
    fried = 0
    for c in a.captures:
        v = hf(body(luma(c))) / r0
        tag = 'FRIED' if v >= a.threshold else 'clean'
        fried += v >= a.threshold
        print('  %-46s %5.2fx  %s' % (os.path.basename(c), v, tag))
    print('  -> %d/%d fried (threshold %.2fx)' % (fried, len(a.captures), a.threshold))
    return 0


if __name__ == '__main__':
    sys.exit(main())
