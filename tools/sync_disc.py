#!/usr/bin/env python3
"""
sync_disc.py -- generate a DVD-legal A/V sync test clip.

Lip-sync on this core has been measured by hand, painfully: docs/lipsync_pickup.md
records twelve hardware rounds, one of which was voided entirely by a
mis-calibrated instrument. This makes the measurement mechanical by giving the
clip markers that survive ANY pipeline -- scaling, interlacing, 3:2 pull-down,
the analog chain and a RetroTINK -- so the same disc measures every output mode.

The markers, once per second:

  video   ONE frame of the measurement region goes full white. Not a shape, not
          text: a whole-region luma step, so detection is a mean over an area
          and needs no calibration, no alignment and no OCR.
  audio   a short tone burst whose first sample is the flash frame's PTS.
  ident   a binary frame counter in a strip along the bottom, HELD until the
          next flash, so a marker can be identified from any captured frame in
          its interval rather than only from the flash itself.

Three design points that matter, each for a measured reason:

  * The counter strip is OUTSIDE the measurement region. A flash frame's luma
    must be IDENTICAL for every marker, because the measurer interpolates
    sub-frame timing from how the flash's brightness splits across adjacent
    capture frames. A counter drawn inside the region would modulate that and
    destroy the interpolation -- which matters here because the capture card
    tops out at 60 fps, so whole-frame quantisation alone would be 16.7 ms.

  * The background MOVES and is deliberately expensive to encode. A static clip
    compresses to nothing and would not reproduce the compute-bound behaviour
    that produced the drift in the first place: the point is to measure sync
    under realistic decoder load, not on an idle pipeline.

  * The flash is exactly ONE frame. A longer flash is easier to detect but
    blurs the edge being timed; one frame gives the sharpest possible event and
    still spans ~2 capture frames at 60 fps, which is what makes the sub-frame
    centroid work.

Usage:
    sync_disc.py make [-o FILE] [--minutes 5] [--standard ntsc|pal]
                      [--audio ac3|lpcm|mp2] [--period N] [--bitrate 6000k]
    sync_disc.py info

The output is a flat DVD-legal .VOB, which the core plays linearly -- no
dvdauthor, no IFOs. That is enough to measure every OUTPUT mode (progressive,
interlaced, film 24p, PAL). Wrapping it in a real ISO would only be needed to
measure the nav/seek paths.
"""

import argparse
import math
import os
import subprocess
import sys
import tempfile

# --- geometry, shared with tools/lipsync_measure.py -------------------------
W = 720
H = {'ntsc': 480, 'pal': 576}
FPS = {'ntsc': 30000 / 1001.0, 'pal': 25.0}
# Fraction of frame height used for the luma measurement. The counter strip
# lives below it and is never included.
MEAS_FRAC = 0.80
COUNTER_BITS = 16
FLASH_Y = 235          # studio white
BLACK_Y = 16           # studio black
TONE_HZ = 1000
TONE_MS = 12
SAMPLE_RATE = 48000


def meas_h(standard):
    return int(H[standard] * MEAS_FRAC) // 2 * 2


def gen_video(out, standard, nframes, period, easy=False):
    """Write yuv420p frames to `out`. Chroma is flat: only luma is measured."""
    import numpy as np
    h = H[standard]
    mh = meas_h(standard)
    x = np.arange(W, dtype=np.float32)
    y = np.arange(h, dtype=np.float32)
    xx, yy = np.meshgrid(x, y)
    chroma = np.full((h // 2) * (W // 2), 128, dtype=np.uint8).tobytes()

    cnt_y0 = mh + 4
    cnt_h = h - cnt_y0 - 4
    bit_w = W // COUNTER_BITS

    for n in range(nframes):
        if easy:
            # Nearly static: cheap to decode. The A/B against the demanding
            # background is what separates "the core has a rate error" from
            # "the core drops frames under decode load".
            frame = np.full((h, W), 110, dtype=np.float32)
            frame[:, (n % 8) * 90:(n % 8) * 90 + 20] = 150
        else:
            ph = n * 0.11
            # A smooth drifting pattern plus a hard-edged sweeping bar: the
            # gradient gives real residual, the bar forces real motion vectors.
            frame = (96 + 40 * np.sin(2 * math.pi * (xx / 48.0 + yy / 64.0 + ph))
                     ).astype(np.float32)
            bar = int((n * 7) % W)
            frame[:, bar:bar + 40] = 200
        frame = np.clip(frame, BLACK_Y, 220).astype(np.uint8)

        marker = n // period
        if n % period == 0:
            frame[:mh, :] = FLASH_Y            # the event being timed

        # counter strip: held for the whole marker interval
        strip = np.full((cnt_h, W), BLACK_Y, dtype=np.uint8)
        for b in range(COUNTER_BITS):
            if marker >> b & 1:
                strip[:, b * bit_w:(b + 1) * bit_w] = FLASH_Y
        frame[cnt_y0:cnt_y0 + cnt_h, :] = strip

        out.write(frame.tobytes())
        out.write(chroma)
        out.write(chroma)


def gen_audio(path, standard, nframes, period, offset_ms=0.0):
    """Silence with a tone burst starting exactly at each flash frame's PTS.

    `offset_ms` deliberately mis-aligns the audio. It exists to VALIDATE the
    measurement chain: a known injected error must come back as itself. An
    instrument that has never been shown to report a wrong answer correctly is
    not an instrument -- and this project has already lost a round to one
    (docs/lipsync_pickup.md's mis-calibrated osd_read.py voided rounds 4-6).
    """
    import numpy as np
    fps = FPS[standard]
    total = int(nframes / fps * SAMPLE_RATE) + SAMPLE_RATE
    buf = np.zeros(total, dtype=np.float32)
    burst_n = int(SAMPLE_RATE * TONE_MS / 1000.0)
    t = np.arange(burst_n, dtype=np.float32) / SAMPLE_RATE
    # Rectangular onset -- the ATTACK is the timed edge, so it must not be
    # ramped. A short decay avoids an ugly trailing click without moving it.
    burst = 0.5 * np.sin(2 * math.pi * TONE_HZ * t)
    burst *= np.minimum(1.0, np.linspace(1.0, 0.0, burst_n) * 4.0)
    off = int(round(offset_ms / 1000.0 * SAMPLE_RATE))
    for n in range(0, nframes, period):
        s = int(round(n / fps * SAMPLE_RATE)) + off
        if s + burst_n < total:
            buf[s:s + burst_n] += burst
    stereo = np.repeat((np.clip(buf, -1, 1) * 32767).astype('<i2'), 2)
    stereo.tofile(path)


def cmd_make(args):
    std = args.standard
    fps = FPS[std]
    nframes = int(args.minutes * 60 * fps)
    period = args.period or int(round(fps))          # ~1 s
    out = args.out or os.path.join(
        'releases', f'SYNC_{std.upper()}_{args.audio.upper()}.VOB')
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)

    print(f'sync_disc: {std} {W}x{H[std]} @ {fps:.3f} fps, {nframes} frames '
          f'({args.minutes} min), flash every {period} frames')
    print(f'  measurement region: rows 0..{meas_h(std) - 1}  '
          f'counter strip below it')

    with tempfile.TemporaryDirectory() as tmp:
        apath = os.path.join(tmp, 'a.raw')
        gen_audio(apath, std, nframes, period, args.audio_offset_ms)

        acodec = {'ac3': ['-c:a', 'ac3', '-b:a', '448k'],
                  'mp2': ['-c:a', 'mp2', '-b:a', '256k'],
                  'lpcm': ['-c:a', 'pcm_dvd']}[args.audio]
        cmd = [
            'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'rawvideo', '-pix_fmt', 'yuv420p',
            '-s', f'{W}x{H[std]}', '-r', f'{fps:.6f}', '-i', 'pipe:0',
            '-f', 's16le', '-ar', str(SAMPLE_RATE), '-ac', '2', '-i', apath,
            '-c:v', 'mpeg2video', '-b:v', args.bitrate, '-maxrate', '9000k',
            '-bufsize', '1835008', '-g', '15',
            '-pix_fmt', 'yuv420p', '-aspect', '4:3',
            *acodec, '-ar', str(SAMPLE_RATE),
            '-f', 'dvd', out,
        ]
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        try:
            gen_video(p.stdin, std, nframes, period, args.load == 'easy')
            p.stdin.close()
        except BrokenPipeError:
            pass
        rc = p.wait()
        if rc != 0:
            sys.exit(f'sync_disc: ffmpeg failed (rc={rc})')

    size = os.path.getsize(out)
    print(f'  wrote {out} ({size / 1e6:.1f} MB)')
    print(f'  markers: {nframes // period}, one per {period / fps:.3f} s')
    print('\nMeasure with:  tools/lipsync_measure.py source ' + out)
    return 0


def cmd_info(args):
    for std in ('ntsc', 'pal'):
        print(f'{std}: {W}x{H[std]} @ {FPS[std]:.3f} fps  '
              f'measurement rows 0..{meas_h(std) - 1}  '
              f'counter {COUNTER_BITS} bits x {W // COUNTER_BITS}px')
    print(f'tone: {TONE_HZ} Hz, {TONE_MS} ms, rectangular onset @ {SAMPLE_RATE} Hz')
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('make')
    p.add_argument('-o', '--out')
    p.add_argument('--minutes', type=float, default=5.0)
    p.add_argument('--standard', choices=('ntsc', 'pal'), default='ntsc')
    p.add_argument('--audio', choices=('ac3', 'lpcm', 'mp2'), default='ac3')
    p.add_argument('--period', type=int, help='frames between flashes')
    p.add_argument('--bitrate', default='6000k')
    p.add_argument('--load', choices=('hard', 'easy'), default='hard',
                   help="'easy' = nearly static, cheap to decode")
    p.add_argument('--audio-offset-ms', type=float, default=0.0,
                   help='inject a known A/V error, to validate the measurer')
    p.set_defaults(fn=cmd_make)
    sub.add_parser('info').set_defaults(fn=cmd_info)
    args = ap.parse_args()
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
