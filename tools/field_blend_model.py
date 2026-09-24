#!/usr/bin/env python3
# =============================================================================
# field_blend_model.py -- reference model, study and fixture generator for the
#                         non-adaptive field blend (dvd/field_blend.sv;
#                         docs/field_blend.md)
#
# THE KERNEL (the RTL mirrors this, not the other way round):
#   every output line of a true-interlaced picture, every channel Y/U/V:
#       out[y] = (a + 2*b + d + 2) >> 2      a = in[y-1], b = in[y], d = in[y+1]
#   edges MIRROR:  y == 0   -> a := d      (= in[1])
#                  y == H-1 -> d := a      (= in[H-2])
#   out.osd = b.osd (a palette index, never blended)
# There is no detector, no anchor and no per-refresh state, so a held picture
# is identical on every re-scan -- which is the whole point (the shelved Stage A
# alternated an anchor field per refresh, and that alternation was its shimmer).
# For an interior line a and d come from the OTHER field, so the output is
# exactly half own field, half other field; mirroring keeps that at the edges.
#
# THE RTL's INPUT STREAM is H+1 lines: the picture, then line H-2 again. The
# addrgen emits that extra line as the bottom line's lookahead, so the module
# needs no bottom special case -- d for line H-1 simply IS in[H-2].
#
# JOBS
#   synth    deterministic fixture, no disc: pseudo-random Y/U/V chosen so bob,
#            a dropped +2, a 9-bit sum and replicate edges all give different
#            output. Committed, so the module bench never skips.
#   fixture  the same from a real decoded frame (the frame with the most comb).
#   score    decode a cut, report comb ratio for weave / blend / bob and the
#            softening cost on TEMPORALLY STATIC pixels (where the woven frame is
#            the ground truth): MAE, PSNR and vertical-detail retention.
#   analyze / diff   HIL: score or compare captured PNGs.
#
# THE COMB RATIO (reference-free):
#     r = mean |Y(y) - Y(y+1)|  /  mean |Y(y) - Y(y+2)|
# r < 1 for a coherent picture; a woven frame with motion has r > 1.
# ⚠ BLIND SPOT: r cannot see the 50/50 GHOST a blend leaves on motion (the two
# instants are superimposed rather than interleaved, which r scores as coherent).
# That trade is judged by eye, not by this number.
#
# Usage:
#   tools/field_blend_model.py synth   --out bench/dvd/test_vobs/fblend_synth
#   tools/field_blend_model.py fixture <iso> --vts 1 --frac 0.10 --lines 96 --out <stem>
#   tools/field_blend_model.py score   <iso> [--vts N] [--frac F] [--frames N] [--brief]
#   tools/field_blend_model.py analyze shot*.png
#   tools/field_blend_model.py diff    a.png b.png
# =============================================================================
import sys, os, argparse, subprocess

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ISO_DIR = os.environ.get('DVD_ISO_DIR', '/mnt/dvd')


# ----------------------------------------------------------------------------
# the model
# ----------------------------------------------------------------------------
def rtl_input(yuvo):
    """The stream the module receives: H+1 lines, the extra one = line H-2."""
    H = yuvo.shape[0]
    return np.concatenate((yuvo, yuvo[H - 2:H - 1]), axis=0)


def blend(yuvo):
    H = yuvo.shape[0]
    x = yuvo.astype(np.int32)
    a = np.concatenate((x[1:2], x[:-1]), axis=0)          # y=0: a := d
    d = np.concatenate((x[1:], x[H - 2:H - 1]), axis=0)   # y=H-1: d := a
    out = yuvo.copy()
    out[:, :, :3] = ((a[:, :, :3] + 2 * x[:, :, :3] + d[:, :, :3] + 2) >> 2).astype(np.uint8)
    return out


def bob(Y):
    """Top field kept, bottom lines rebuilt from the neighbours (study only)."""
    x = Y.astype(np.int32)
    out = x.copy()
    for y in range(1, x.shape[0], 2):
        dn = x[y + 1] if y + 1 < x.shape[0] else x[y - 1]
        out[y] = (x[y - 1] + dn + 1) >> 1
    return out


def comb_ratio(Y):
    Y = Y.astype(np.int32)
    adj = np.abs(Y[:-2] - Y[1:-1]).mean()
    two = np.abs(Y[:-2] - Y[2:]).mean()
    return adj / two if two > 0 else float('nan')


# ----------------------------------------------------------------------------
# fixtures
# ----------------------------------------------------------------------------
def write_fixture(stem, yuvo, ft_code=0):
    """<stem>.in.hex: H+1 lines x W {y,u,v,osd}; .exp.hex: H x W; .meta.hex: W, H, ft_code."""
    H, W, _ = yuvo.shape
    src = rtl_input(yuvo)
    exp = blend(yuvo)
    for suf, arr, n in (('.in.hex', src, H + 1), ('.exp.hex', exp, H)):
        with open(stem + suf, 'w') as fh:
            for y in range(n):
                for c in range(W):
                    p = arr[y, c]
                    fh.write('%02x%02x%02x%02x\n' % (p[0], p[1], p[2], p[3]))
    with open(stem + '.meta.hex', 'w') as fh:
        for w in (W, H, ft_code):
            fh.write('%08x\n' % w)
    changed = int(np.count_nonzero(np.any(exp[:, :, :3] != yuvo[:, :, :3], axis=2)))
    print(f"  {stem}: {W}x{H + 1} in, {W}x{H} out, {changed} pixels changed "
          f"({100.0 * changed / (W * H):.1f} %)")
    return changed


def synth_frame(W=128, H=32):
    """Pseudo-random, fixed seed. Every one of these differs from the kernel on
    most pixels: bob ((a+d+1)>>1), no +2, a 9-bit sum (values are ~half above
    128, so a+2b+d >= 512 is common), replicate edges (a:=b / d:=b)."""
    rs = np.random.RandomState(20260924)
    yuvo = np.zeros((H, W, 4), dtype=np.uint8)
    yuvo[:, :, :3] = rs.randint(0, 256, size=(H, W, 3))
    yuvo[:, W - 8:, :3] = rs.randint(224, 256, size=(H, 8, 3))   # a saturating band
    # OSD varies by LINE as well as column: a pattern constant down a column would
    # blend to itself, and a mutation that blends OSD would go unseen.
    yuvo[:, :, 3] = (np.arange(W)[None, :] * 7 + np.arange(H)[:, None] * 53 + 3) & 0xFF
    return yuvo


# ----------------------------------------------------------------------------
# real frames
# ----------------------------------------------------------------------------
def es_cut(iso, vts, frac, sectors):
    from dvd_vm_ref import IsoNav
    from video_cadence_census import video_payload
    nav = IsoNav(iso)
    vts = vts if vts is not None else nav.best_vts
    runs = [(ext, dl // 2048) for ext, dl in nav.groups[vts]]
    total = sum(n for _, n in runs)

    def sector_at(idx):
        for ext, n in runs:
            if idx < n:
                return ext + idx
            idx -= n
        return None

    start = int(total * frac)
    parts = []
    for k in range(sectors):
        s = sector_at(start + k)
        if s is None:
            break
        d = video_payload(nav.sec(s))
        if d:
            parts.append(d)
    es = b''.join(parts)
    sh = es.find(b'\x00\x00\x01\xb3')
    return (es[sh:] if sh >= 0 else b''), vts


def decode(es):
    """ffmpeg: MPEG-2 ES -> list of (Y, U, V), chroma on the luma grid (4:4:4, as
    the core's resample delivers it). ffmpeg emits WOVEN frames, which is exactly
    what the core's Progressive path shows today."""
    probe = subprocess.run(['ffprobe', '-v', 'error', '-f', 'mpegvideo', '-select_streams', 'v:0',
                            '-show_entries', 'stream=width,height', '-of', 'csv=p=0', 'pipe:0'],
                           input=es, capture_output=True)
    w, h = (int(x) for x in probe.stdout.decode().strip().split(',')[:2])
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'mpegvideo', '-i', 'pipe:0',
                          '-f', 'rawvideo', '-pix_fmt', 'yuv444p', 'pipe:1'],
                         input=es, capture_output=True).stdout
    n = len(raw) // (w * h * 3)
    frames = []
    for i in range(n):
        f = np.frombuffer(raw[i * w * h * 3:(i + 1) * w * h * 3], dtype=np.uint8)
        frames.append((f[0:w * h].reshape(h, w), f[w * h:2 * w * h].reshape(h, w),
                       f[2 * w * h:].reshape(h, w)))
    return frames


def frame_to_yuvo(fr):
    Y, U, V = fr
    H, W = Y.shape
    yuvo = np.zeros((H, W, 4), dtype=np.uint8)
    yuvo[:, :, 0] = Y; yuvo[:, :, 1] = U; yuvo[:, :, 2] = V
    yuvo[:, :, 3] = (np.arange(W)[None, :] & 0xFF)
    return yuvo


def static_mask(prev, cur, nxt, tol=2):
    """Pixels whose whole 3x3 neighbourhood is unchanged across three pictures:
    there the woven frame is the truth, so any change the blend makes is loss."""
    p, c, n = (x.astype(np.int32) for x in (prev, cur, nxt))
    s = (np.abs(c - p) <= tol) & (np.abs(c - n) <= tol)
    m = s.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            m &= np.roll(np.roll(s, dy, 0), dx, 1)
    m[0, :] = m[-1, :] = False
    m[:, 0] = m[:, -1] = False
    return m


# ----------------------------------------------------------------------------
def cmd_synth(a):
    write_fixture(a.out, synth_frame(a.w, a.h))
    return 0


def cmd_fixture(a):
    es, vts = es_cut(a.iso, a.vts, a.frac, a.sectors)
    if not es:
        print("no sequence header in the cut -- move --frac", file=sys.stderr); return 1
    frames = decode(es)
    if len(frames) < 2:
        print(f"only {len(frames)} frames decoded", file=sys.stderr); return 1
    ratios = [comb_ratio(f[0]) for f in frames]
    k = int(np.argmax(ratios)) if a.frame is None else a.frame
    yuvo = frame_to_yuvo(frames[k])
    if a.lines:
        yuvo = yuvo[:a.lines]
    print(f"{os.path.basename(a.iso)} VTS{vts:02d}: {len(frames)} frames, picked #{k} "
          f"(comb ratio {ratios[k]:.3f}), {yuvo.shape[1]}x{yuvo.shape[0]}")
    write_fixture(a.out, yuvo)
    return 0


def cmd_score(a):
    es, vts = es_cut(a.iso, a.vts, a.frac, a.sectors)
    name = os.path.basename(a.iso)
    if not es:
        print(f"{name}: no sequence header in the cut -- move --frac"); return 1
    frames = decode(es)[:a.frames]
    if len(frames) < 3:
        print(f"{name}: only {len(frames)} frames decoded"); return 1
    rw, rb, rbob, mae, dret, stat = [], [], [], [], [], []
    for i, fr in enumerate(frames):
        Y = fr[0]
        B = blend(frame_to_yuvo(fr))[:, :, 0]
        rw.append(comb_ratio(Y)); rb.append(comb_ratio(B)); rbob.append(comb_ratio(bob(Y)))
        if 0 < i < len(frames) - 1:
            m = static_mask(frames[i - 1][0], Y, frames[i + 1][0])
            stat.append(m.mean())
            if m.sum() > 1000:
                Yi, Bi = Y.astype(np.int32), B.astype(np.int32)
                mae.append(np.abs(Bi - Yi)[m].mean())
                gw = np.abs(np.diff(Yi, axis=0))[m[:-1]].mean()
                gb = np.abs(np.diff(Bi, axis=0))[m[:-1]].mean()
                dret.append(gb / gw if gw > 0 else float('nan'))
    rw, rb, rbob = np.array(rw), np.array(rb), np.array(rbob)
    mae_m = float(np.mean(mae)) if mae else float('nan')
    psnr = 10 * np.log10(255.0 ** 2 / np.mean(np.square(mae))) if mae else float('nan')
    dr = float(np.nanmean(dret)) if dret else float('nan')
    if a.brief:
        print(f"{name[:40]:40s} VTS{vts:02d} n={len(frames):3d}  r weave {rw.mean():.3f} "
              f"(>1: {100 * (rw > 1).mean():5.1f}%)  blend {rb.mean():.3f}  "
              f"static {100 * np.mean(stat):4.1f}%  MAE {mae_m:4.2f}  detail {dr:.3f}")
        return 0
    print(f"{name} VTS{vts:02d} @{a.frac:.2f}: {len(frames)} frames")
    print(f"  comb ratio   weave {rw.mean():.3f} (max {rw.max():.3f}, frames r>1: {int((rw > 1).sum())})")
    print(f"               blend {rb.mean():.3f} (max {rb.max():.3f}, frames r>1: {int((rb > 1).sum())})")
    print(f"               bob   {rbob.mean():.3f} (max {rbob.max():.3f}, frames r>1: {int((rbob > 1).sum())})")
    print(f"  static pixels {100 * np.mean(stat):.1f} % of the picture; on them the blend costs")
    print(f"    MAE {mae_m:.2f} code values, PSNR {psnr:.1f} dB vs the woven truth")
    print(f"    vertical detail retained {dr:.3f} (mean |dY/dy| blend / weave)")
    return 0


def _luma(path, crop_bottom=56, crop_edge=8):
    from hud_read import load_image
    w, h, buf = load_image(path)
    a = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3).astype(np.float64)
    Y = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
    return Y[crop_edge:h - crop_bottom, crop_edge:w - crop_edge]


def cmd_analyze(a):
    rows = []
    for p in a.pngs:
        try:
            Y = _luma(p, a.crop_bottom)
            rows.append((os.path.basename(p), comb_ratio(Y), float(Y.std())))
        except Exception as e:                                    # noqa: BLE001
            print(f"  {os.path.basename(p)}: unreadable ({e})")
    if not rows:
        return 1
    print(f"  {'frame':<32}{'comb':>7}{'sigma':>7}")
    for n, r, s in rows:
        print(f"  {n:<32}{r:7.3f}{s:7.1f}")
    c = np.array([r for _, r, _ in rows])
    print(f"  n={len(rows)}  comb mean {c.mean():.3f} (min {c.min():.3f} max {c.max():.3f})  "
          f"frames comb>1: {int((c > 1).sum())}")
    return 0


def cmd_diff(a):
    from hud_read import load_image
    w1, h1, b1 = load_image(a.a)
    w2, h2, b2 = load_image(a.b)
    if (w1, h1) != (w2, h2):
        print(f"  DIFFERENT GEOMETRY: {w1}x{h1} vs {w2}x{h2}")
        return 1
    x = np.frombuffer(b1, np.uint8).reshape(h1, w1, 3).astype(np.int32)
    y = np.frombuffer(b2, np.uint8).reshape(h2, w2, 3).astype(np.int32)
    body = slice(8, h1 - a.crop_bottom)
    d = np.abs(x[body] - y[body]).sum(axis=2)
    n = int((d > 0).sum())
    print(f"  {os.path.basename(a.a)} vs {os.path.basename(a.b)}: "
          f"{n} of {d.size} picture pixels differ ({100.0 * n / d.size:.3f} %), max delta {int(d.max())}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('synth'); s.add_argument('--out', required=True)
    s.add_argument('--w', type=int, default=128); s.add_argument('--h', type=int, default=32)
    for name in ('fixture', 'score'):
        s = sub.add_parser(name); s.add_argument('iso')
        s.add_argument('--vts', type=int); s.add_argument('--frac', type=float, default=0.30)
        s.add_argument('--sectors', type=int, default=1500)
        if name == 'fixture':
            s.add_argument('--out', required=True); s.add_argument('--lines', type=int)
            s.add_argument('--frame', type=int)
        else:
            s.add_argument('--frames', type=int, default=40); s.add_argument('--brief', action='store_true')
    s = sub.add_parser('analyze'); s.add_argument('pngs', nargs='+')
    s.add_argument('--crop-bottom', type=int, default=56)
    s = sub.add_parser('diff'); s.add_argument('a'); s.add_argument('b')
    s.add_argument('--crop-bottom', type=int, default=56)
    a = ap.parse_args()
    return {'synth': cmd_synth, 'fixture': cmd_fixture, 'score': cmd_score,
            'analyze': cmd_analyze, 'diff': cmd_diff}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
