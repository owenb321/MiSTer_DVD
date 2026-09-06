#!/usr/bin/env python3
"""av_mode_diff.py -- measure the A/V offset DIFFERENCE between two output modes,
using two captures of the same disc content and no markers.

WHY THIS EXISTS: lipsync_measure.py needs an authored marker disc, so it cannot
measure a real film. But the field report is a COMPARISON -- "Film 24p is ~800 ms
out, Interlaced is fine" -- and a comparison can be measured without ever knowing
either absolute value:

    capture A (mode 1) and capture B (mode 2) of the SAME content, then
        lag_a = argmax xcorr(audio_A,  audio_B)      how far B's AUDIO trails A's
        lag_v = argmax xcorr(video_A,  video_B)      how far B's VIDEO trails A's
    A/V offset difference between the modes = lag_v - lag_a

Any constant in the capture chain -- the v4l2-vs-ALSA skew, encoder delay, the
card's own buffering -- appears in BOTH captures and CANCELS. Nothing about the
source needs to be known, so this works on an ordinary film.

⚠ Both captures must cover the SAME content. Launch each mode fresh so the disc
starts at the same place, and capture the same span.
⚠ This measures a DIFFERENCE. If both modes are equally wrong it reads zero -- so a
null here means "the modes agree", not "everything is in sync".
"""
import subprocess, sys, os
import numpy as np

SR = 8000           # audio decode rate
ENV_HZ = 200        # ENVELOPE rate after decimation -- 5 ms resolution, ample for ~800 ms
FPS = 25            # video analysis rate, overridable with --fps
# ⚠ 10 was the default until 2026-09-06 and it is NOT always enough. On APOLLO_13
# (docs/film_24p_plan.md §14.9.30 round 1) 10 fps left the video lag ambiguous
# between 0 and -1000 ms, the two features DISAGREED, and the luma margin was
# +0.075 -- i.e. the quantisation was the same order as the effect. At 25 fps both
# features agree and the half-split resolves. If the halves disagree, raise it
# further before believing any single figure.
# ⚠ np.correlate(mode='full') is naive O(n*m): 70 s of 8 kHz audio is 5.6e5 samples,
# i.e. ~3e11 multiply-adds, which does not finish. Decimate the envelope to ENV_HZ
# and correlate via FFT.


def audio_env(path):
    """Mono envelope at SR, as a normalised float array."""
    cmd = ['ffmpeg', '-v', 'error', '-i', path, '-vn',
           '-ac', '1', '-ar', str(SR), '-f', 's16le', '-']
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    a = np.frombuffer(raw, dtype='<i2').astype(np.float32)
    a = np.abs(a)
    # 50 ms smoothing -- we want the loudness contour, not the waveform
    k = np.ones(int(SR * 0.05), dtype=np.float32)
    a = np.convolve(a, k / k.sum(), mode='same')
    # decimate to ENV_HZ by block-mean (the envelope is already band-limited)
    step = SR // ENV_HZ
    n = (len(a) // step) * step
    return a[:n].reshape(-1, step).mean(axis=1)


def video_luma(path, feature='motion', fps=None):
    """Per-frame video feature at FPS.

    ⚠ 'luma' (mean brightness) is a SMOOTH, highly self-similar signal: on the first
    APOLLO_13 pair its correlation peak beat the best sidelobe by only 0.085, which is
    not enough to trust a lag to +/-100 ms. 'motion' -- the mean absolute difference
    between consecutive frames -- is spiky (it peaks at cuts and on camera movement)
    and discriminates far better. Both are offered so the two can be cross-checked:
    a lag that only appears under one feature is a correlation artefact.
    """
    cmd = ['ffmpeg', '-v', 'error', '-i', path, '-an',
           '-vf', f'fps={fps or FPS},scale=64:48,format=gray', '-f', 'rawvideo', '-']
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    n = 64 * 48
    f = np.frombuffer(raw[:len(raw) // n * n], dtype=np.uint8).reshape(-1, n).astype(np.float32)
    if feature == 'luma':
        return f.mean(axis=1)
    return np.abs(np.diff(f, axis=0)).mean(axis=1)


def best_lag(x, y, rate, max_lag_s=20.0):
    """Lag in seconds by which y trails x (positive = y later)."""
    x = x - x.mean(); y = y - y.mean()
    x /= (np.linalg.norm(x) or 1); y /= (np.linalg.norm(y) or 1)
    n = int(max_lag_s * rate)
    # FFT cross-correlation: same result as np.correlate(x, y, 'full'), O(n log n)
    L = len(x) + len(y) - 1
    nfft = 1 << (L - 1).bit_length()
    c = np.fft.irfft(np.fft.rfft(x, nfft) * np.conj(np.fft.rfft(y, nfft)), nfft)
    c = np.concatenate((c[-(len(y) - 1):], c[:len(x)]))
    mid = len(y) - 1
    lo, hi = max(0, mid - n), min(len(c), mid + n + 1)
    seg = c[lo:hi]
    k = int(np.argmax(seg)) + lo
    peak = float(seg.max())
    # ⚠ SHARPNESS, done properly. The first version took "the largest value that is
    # not the peak", which on a smooth correlation is the sample NEXT to the peak and
    # is therefore always ~equal to it (measured 0.988 vs 0.988) -- a check that can
    # never fire. Exclude a guard band around the peak and compare against the best
    # SIDELOBE: that is what distinguishes a real alignment from an ambiguous one.
    guard = max(1, int(0.5 * rate))          # +/-0.5 s around the peak
    kk = k - lo
    mask = np.ones(len(seg), dtype=bool)
    mask[max(0, kk - guard):min(len(seg), kk + guard + 1)] = False
    side = float(seg[mask].max()) if mask.any() else 0.0
    return (mid - k) / rate, peak, side


def main():
    argv = [a for a in sys.argv[1:]]
    fps = FPS
    if '--fps' in argv:
        i = argv.index('--fps')
        fps = int(argv[i + 1]); del argv[i:i + 2]
    if len(argv) < 2:
        sys.exit('usage: av_mode_diff.py [--fps N] <captureA.mkv> <captureB.mkv>')
    A, B = argv[0], argv[1]
    for p in (A, B):
        if not os.path.exists(p):
            sys.exit(f'missing {p}')
    print(f'A = {os.path.basename(A)}\nB = {os.path.basename(B)}\n')
    ea, eb = audio_env(A), audio_env(B)
    la, pa, sa = best_lag(ea, eb, ENV_HZ)
    # cross-check the video lag under TWO independent features; if they disagree the
    # correlation is not resolving the alignment and no A/V figure can be quoted.
    results = {}
    for feat in ('motion', 'luma'):
        va, vb = video_luma(A, feat, fps), video_luma(B, feat, fps)
        results[feat] = best_lag(va, vb, fps)
        l_, p_, s_ = results[feat]
        print(f'  video lag [{feat:6}]      : {l_*1000:+9.1f} ms   peak {p_:.3f} '
              f'sidelobe {s_:.3f}  margin {p_-s_:+.3f}')
    lv, pv, sv = results['motion']
    if abs(results['motion'][0] - results['luma'][0]) > 0.2:
        print('  ⚠ THE TWO VIDEO FEATURES DISAGREE by '
              f'{abs(results["motion"][0]-results["luma"][0])*1000:.0f} ms -- the video '
              'alignment is NOT resolved; the A/V figure below is unreliable.')
    va, vb = video_luma(A, 'motion', fps), video_luma(B, 'motion', fps)
    print(f'  audio lag (B trails A) : {la*1000:+9.1f} ms   peak {pa:.3f} '
          f'sidelobe {sa:.3f}  margin {pa-sa:+.3f}')
    d = (lv - la) * 1000
    print(f'\n  A/V OFFSET DIFFERENCE  : {d:+9.1f} ms')
    print('  (positive = B has audio EARLIER relative to its video than A does)')

    # ---- STABILITY: split each stream in half and re-measure independently.
    # A real alignment repeats on both halves; an ambiguous correlation peak does
    # not. This is the check that decides whether the number above is a measurement.
    print('\n  stability (independent halves):')
    ok = True
    for tag, sl in (('1st half', slice(0, None)), ('2nd half', slice(None, None))):
        pass
    for tag, frac in (('1st half', 0), ('2nd half', 1)):
        def half(z):
            m = len(z) // 2
            return z[:m] if frac == 0 else z[m:]
        ha, _, _ = best_lag(half(ea), half(eb), ENV_HZ)
        hv, _, _ = best_lag(half(va), half(vb), fps)
        hd = (hv - ha) * 1000
        print(f'    {tag}: audio {ha*1000:+8.1f}  video {hv*1000:+8.1f}  '
              f'=> diff {hd:+8.1f} ms')
        if abs(hd - d) > 150:
            ok = False
    if not ok:
        print('    ⚠ HALVES DISAGREE by >150 ms -- treat the figure above as unproven.')
    else:
        print('    halves agree -- the figure is stable.')

    if pa - sa < 0.02 or pv - sv < 0.02:
        print('\n  ⚠ WEAK PEAK MARGIN -- the correlation peak barely beats its sidelobes;')
        print('    the two captures may not cover enough common content.')
    if abs(d) < 100:
        print('\n  => the two modes agree within 100 ms: no mode-dependent A/V difference.')
    else:
        print(f'\n  => the modes DIFFER by {d:+.0f} ms of A/V offset.')


if __name__ == '__main__':
    main()
