#!/usr/bin/env python3
"""
lipsync_measure.py -- measure A/V sync from a sync-clip capture.

Companion to tools/sync_disc.py. Finds every video flash and every audio click,
pairs them by the clip's own frame counter, and reports the error over time --
a drift CURVE, not a single number, because the defect this exists to catch
(docs/lipsync_pickup.md) was a ramp that froze, not a constant offset.

Two modes, deliberately sharing ONE detector:

  source <file>    measure the generated clip itself. This is CALIBRATION, not
                   a sanity check: encoder and codec delay are real and
                   constant, so the reported answer for a capture is
                   (capture offset - source offset) and those terms cancel by
                   construction. Running a different detector over the source
                   would defeat that entirely.

  capture <file>   measure a recording of the core's output.

WHAT THIS TOOL CANNOT DO ALONE. The capture chain has its own A/V skew: v4l2
video and ALSA audio are separately clocked and separately buffered, and that
offset is very likely larger than the thing being measured. It MUST be
calibrated once -- feed the capture card a known-synchronous source and record
the result in tools/.mister_capture.json -- or the harness measures the capture
card and reports it as a core defect. `capture` refuses to print an absolute
figure until that number exists; --raw overrides for exploratory use.

Detection:

  video   mean luma per frame. The flash is a whole-region step, so this needs
          no alignment, no calibration and no OCR, and survives scaling,
          letterboxing and interlacing. Sub-frame timing comes from the luma
          CENTROID across the frames the flash straddles -- at 60 fps capture,
          whole-frame quantisation alone would be 16.7 ms, which is the same
          order as the thing being measured.
  audio   energy in a narrow band around the tone, then the steepest rise. The
          tone's onset is rectangular in the source for exactly this reason.
  ident   the binary counter strip, read after locating the active picture from
          a flash frame's own white bounding box -- so geometry is derived from
          the content and a scaled or letterboxed capture needs no config.
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sync_disc import (COUNTER_BITS, FPS, MEAS_FRAC, SAMPLE_RATE,  # noqa: E402
                       TONE_HZ, TONE_MS)

CAL_FILE = os.path.join(HERE, '.mister_capture.json')


# ---------------------------------------------------------------------------
def probe(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,r_frame_rate', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    s = json.loads(out)['streams'][0]
    num, den = (int(v) for v in s['r_frame_rate'].split('/'))
    return s['width'], s['height'], num / den


def video_luma(path, w, h, scale=4):
    """Mean luma per frame, plus a downscaled gray frame stack for geometry.

    Decoded at reduced size: the flash is a whole-region step, so resolution
    buys nothing and full-size frames of a 5-minute capture would not fit in
    memory.
    """
    sw, sh = w // scale, h // scale
    p = subprocess.Popen(
        ['ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo',
         '-pix_fmt', 'gray', '-s', f'{sw}x{sh}', '-'],
        stdout=subprocess.PIPE)
    frames, sz = [], sw * sh
    while True:
        buf = p.stdout.read(sz)
        if len(buf) < sz:
            break
        frames.append(np.frombuffer(buf, dtype=np.uint8).reshape(sh, sw))
    p.wait()
    if not frames:
        sys.exit(f'lipsync: no video frames decoded from {path}')
    stack = np.stack(frames)
    # Measure only the top MEAS_FRAC: the counter strip below it changes per
    # marker and would modulate the very quantity used for interpolation.
    return stack[:, :int(sh * MEAS_FRAC), :].mean(axis=(1, 2)), stack


def audio_env(path):
    """Envelope of the tone band, at sample rate."""
    raw = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', path, '-f', 's16le', '-ac', '1',
         '-ar', str(SAMPLE_RATE), '-'],
        capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype='<i2').astype(np.float32) / 32768.0
    if x.size == 0:
        sys.exit(f'lipsync: no audio decoded from {path}')
    # Quadrature mix down from the tone frequency, then a short moving average:
    # a matched filter for "is the tone present", insensitive to phase.
    n = np.arange(x.size, dtype=np.float32)
    ph = 2 * np.pi * TONE_HZ * n / SAMPLE_RATE
    i = x * np.cos(ph)
    q = x * np.sin(ph)
    win = max(8, int(SAMPLE_RATE * 0.002))
    k = np.ones(win, dtype=np.float32) / win
    env = np.hypot(np.convolve(i, k, 'same'), np.convolve(q, k, 'same'))
    return env


def find_flashes(luma, fps):
    """-> [(marker frame index, sub-frame refined time in seconds)]."""
    base = np.median(luma)
    peak = luma.max()
    if peak - base < 8:
        sys.exit('lipsync: no flashes found -- is this a sync clip?')
    thr = base + (peak - base) * 0.35
    above = luma > thr
    events, i, n = [], 0, len(luma)
    while i < n:
        if not above[i]:
            i += 1
            continue
        j = i
        while j < n and above[j]:
            j += 1
        # Luma-weighted centroid over the run and one frame either side. A
        # 1-frame flash split across two capture frames lands between them in
        # proportion to the overlap, which is what recovers sub-frame timing.
        lo, hi = max(0, i - 1), min(n, j + 1)
        seg = luma[lo:hi] - base
        seg = np.clip(seg, 0, None)
        idx = np.arange(lo, hi)
        centre = float((seg * idx).sum() / seg.sum())
        events.append((i, (centre + 0.5) / fps))
        i = j
    return events


def find_clicks(env):
    """-> [onset time in seconds], from the steepest rise of each burst."""
    thr = env.max() * 0.30
    above = env > thr
    out, i, n = [], 0, len(env)
    guard = int(SAMPLE_RATE * TONE_MS / 1000.0 * 3)
    while i < n:
        if not above[i]:
            i += 1
            continue
        j = min(n, i + guard)
        seg = env[max(0, i - guard // 2):j]
        d = np.diff(seg)
        onset = max(0, i - guard // 2) + (int(np.argmax(d)) if d.size else 0)
        out.append(onset / float(SAMPLE_RATE))
        while i < n and above[i]:
            i += 1
        i += guard // 4
    return out


def read_counters(stack, flash_frames):
    """Read the binary counter strip, locating the picture from a flash frame.

    The white region of a flash frame IS the measurement area, so its bounding
    box gives the active picture without knowing the capture's scaling or
    letterboxing.
    """
    if not flash_frames:
        return {}
    f = stack[flash_frames[0]]
    thr = (int(f.max()) + int(np.median(f))) // 2
    ys, xs = np.where(f > thr)
    if ys.size == 0:
        return {}
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    pic_h = (y1 - y0 + 1) / MEAS_FRAC
    cy = int(y0 + pic_h * (MEAS_FRAC + 1.0) / 2.0)      # middle of the strip
    cy = min(cy, stack.shape[1] - 1)
    bw = (x1 - x0 + 1) / COUNTER_BITS
    out = {}
    for fi in flash_frames:
        row = stack[fi, cy, :]
        val = 0
        for b in range(COUNTER_BITS):
            cx = int(x0 + (b + 0.5) * bw)
            if row[min(cx, row.size - 1)] > thr:
                val |= 1 << b
        out[fi] = val
    return out


# ---------------------------------------------------------------------------
def measure(path, label):
    w, h, fps = probe(path)
    luma, stack = video_luma(path, w, h)
    env = audio_env(path)
    flashes = find_flashes(luma, fps)
    clicks = find_clicks(env)
    counters = read_counters(stack, [f for f, _ in flashes])

    print(f'{label}: {os.path.basename(path)}  {w}x{h} @ {fps:.3f} fps')
    print(f'  flashes {len(flashes)}   clicks {len(clicks)}')
    if not flashes or not clicks:
        sys.exit('lipsync: nothing to pair')

    # Pair by TIME, never by index. Index pairing is silently catastrophic:
    # one missing marker -- a click clipped at t=0, or a capture started
    # mid-clip -- shifts every pair by one whole marker period and yields a
    # plausible-looking number that is out by ~1000 ms. MEASURED: an injected
    # -80 ms error came back as +910 ms that way.
    period = float(np.median(np.diff([v for _, v in flashes]))) if len(flashes) > 1 else 1.0
    window = period / 2.0
    ca = np.array(clicks)
    rows, used = [], set()
    for fi, vt in flashes:
        if ca.size == 0:
            break
        k = int(np.argmin(np.abs(ca - vt)))
        if abs(ca[k] - vt) > window or k in used:
            continue                      # no click for this flash
        used.add(k)
        rows.append({'marker': counters.get(fi), 'frame': fi,
                     'video_s': round(vt, 5), 'audio_s': round(float(ca[k]), 5),
                     'error_ms': round((float(ca[k]) - vt) * 1000.0, 2)})
    unpaired_v = len(flashes) - len(rows)
    unpaired_a = len(clicks) - len(used)
    if unpaired_v or unpaired_a:
        print(f'  unpaired: {unpaired_v} flash(es), {unpaired_a} click(s) '
              '(clipped at the ends, or dropped markers)')
    if not rows:
        sys.exit('lipsync: no flash/click pairs within half a marker period -- '
                 'the offset may exceed +/-%.0f ms' % (window * 1000))
    errs = np.array([r['error_ms'] for r in rows])
    # Drift is the slope, in ms per minute -- the shape that matters, since the
    # defect this replaces was a ramp rather than a constant offset.
    t = np.array([r['video_s'] for r in rows])
    slope = (np.polyfit(t, errs, 1)[0] * 60.0) if len(rows) > 2 else float('nan')
    stats = {'n': len(rows), 'mean_ms': float(errs.mean()),
             'median_ms': float(np.median(errs)), 'std_ms': float(errs.std()),
             'first_ms': float(errs[0]), 'last_ms': float(errs[-1]),
             'drift_ms_per_min': float(slope)}
    print(f'  error: mean {stats["mean_ms"]:+.1f} ms  median '
          f'{stats["median_ms"]:+.1f}  std {stats["std_ms"]:.1f}  '
          f'first {stats["first_ms"]:+.1f} -> last {stats["last_ms"]:+.1f}')
    print(f'  drift: {stats["drift_ms_per_min"]:+.2f} ms/min')
    # Near half a period, nearest-in-time pairing becomes ambiguous and could
    # be off by a whole marker. Say so rather than reporting with confidence.
    if abs(stats['median_ms']) > window * 1000.0 * 0.66:
        print(f'  !! WARNING: |error| approaches half a marker period '
              f'({window * 1000:.0f} ms) -- pairing may be off by one marker')
    if counters:
        seq = [r['marker'] for r in rows if r['marker'] is not None]
        gaps = sum(1 for a, b in zip(seq, seq[1:]) if b != a + 1)
        print(f'  counter: {seq[0]}..{seq[-1]}, {gaps} discontinuities'
              + ('  (dropped/repeated markers)' if gaps else ''))
    return rows, stats


def load_cal(source):
    if not os.path.exists(CAL_FILE):
        return None
    return json.load(open(CAL_FILE)).get(source)


def cmd_source(args):
    rows, stats = measure(args.file, 'source')
    if args.save:
        cal = json.load(open(CAL_FILE)) if os.path.exists(CAL_FILE) else {}
        cal['source_offset_ms'] = stats['median_ms']
        cal['source_file'] = os.path.basename(args.file)
        json.dump(cal, open(CAL_FILE, 'w'), indent=2)
        print(f'  saved source offset {stats["median_ms"]:+.2f} ms -> '
              f'{os.path.basename(CAL_FILE)}')
    write_csv(args.csv, rows)
    return 0


def cmd_capture(args):
    rows, stats = measure(args.file, 'capture')
    cal = json.load(open(CAL_FILE)) if os.path.exists(CAL_FILE) else {}
    src = cal.get('source_offset_ms')
    chain = cal.get(args.source, {}).get('skew_ms') if cal else None
    if src is None or chain is None:
        msg = ('lipsync: no calibration. The capture chain has its own A/V skew '
               '(separately clocked v4l2 and ALSA), and it is very likely '
               'larger than the effect being measured -- without it this number '
               'describes the capture card.\n'
               f'  missing: '
               + ', '.join(x for x, v in (('source_offset_ms', src),
                                          (f'{args.source}.skew_ms', chain))
                           if v is None))
        if not args.raw:
            sys.exit(msg + '\n  Re-run with --raw only for exploration.')
        print(msg)
    else:
        corrected = stats['median_ms'] - src - chain
        print(f'  CORRECTED lip-sync error: {corrected:+.1f} ms '
              f'(raw {stats["median_ms"]:+.1f} - source {src:+.1f} '
              f'- chain {chain:+.1f})')
    write_csv(args.csv, rows)
    return 0


def write_csv(path, rows):
    if not path:
        return
    with open(path, 'w') as f:
        f.write('marker,frame,video_s,audio_s,error_ms\n')
        for r in rows:
            f.write(f'{r["marker"]},{r["frame"]},{r["video_s"]},'
                    f'{r["audio_s"]},{r["error_ms"]}\n')
    print(f'  wrote {path}')


def cmd_selftest(args):
    """Generate clips with KNOWN injected errors and check they come back.

    An instrument that has never been shown to report a wrong answer correctly
    is not an instrument. This also pins the two failure modes already found:
    a negative offset clips the first click at t=0, and index-based pairing
    turned that into a plausible +910 ms instead of -90.6 ms.
    """
    import tempfile
    sync = os.path.join(HERE, 'sync_disc.py')
    fails, base = 0, None
    with tempfile.TemporaryDirectory() as tmp:
        for off in (0.0, 50.0, -80.0):
            vob = os.path.join(tmp, f'sync{off:+.0f}.VOB')
            subprocess.run([sys.executable, sync, 'make', '--minutes', '0.25',
                            '--audio-offset-ms', str(off), '-o', vob],
                           check=True, capture_output=True)
            _, st = measure(vob, f'selftest {off:+.0f}ms')
            if base is None:
                base = st['median_ms']
            got = st['median_ms'] - base
            ok = abs(got - off) < 2.0 and st['std_ms'] < 2.0
            print(f"  {'PASS' if ok else 'FAIL'} injected {off:+.0f} ms -> "
                  f"recovered {got:+.1f} ms (std {st['std_ms']:.2f})")
            if not ok:
                fails += 1
    print('lipsync selftest:', 'ALL GREEN' if not fails else f'{fails} FAILURE(S)')
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('source')
    p.add_argument('file')
    p.add_argument('--csv')
    p.add_argument('--save', action='store_true',
                   help='record the offset as the calibration baseline')
    p.set_defaults(fn=cmd_source)
    p = sub.add_parser('capture')
    p.add_argument('file')
    p.add_argument('--csv')
    p.add_argument('--source', default='hdmi', choices=('hdmi', 'analog'))
    p.add_argument('--raw', action='store_true')
    p.set_defaults(fn=cmd_capture)
    sub.add_parser('selftest').set_defaults(fn=cmd_selftest)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
