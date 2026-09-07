#!/usr/bin/env python3
"""level_cmp.py -- compare our AC-3 s16 output against a reference decoder's WAV.

Used by run_ac3_level.sh.  Stdlib only (no numpy/ffmpeg).

★ The metric is the MEDIAN PER-SAMPLE RATIO over samples where the reference is
  loud, not peak or RMS.  That choice is measured, not stylistic:

  - peak is fragile -- it is one sample, and our bench decodes only the first few
    AC-3 frames of a stream while the reference decodes all of them, so the two
    peaks need not come from the same audio at all.
  - RMS is fragile for the same reason, and additionally because the leading
    silence is a different fraction of each capture.
  - the median ratio is immune to both: it only looks at samples that line up and
    are loud enough to carry a meaningful quotient, and it shrugs off the small
    number of slipped samples our bench's drain can produce.

  In practice this reads exactly 0.5000 pre-fix and 1.0000 post-fix on all three
  acmod classes, where peak/RMS disagreed by up to 26 dB on the same data.
"""
import math
import statistics
import sys
import wave


def wav_left(path):
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            raise SystemExit("level_cmp: expected 16-bit PCM in %s" % path)
        ch = w.getnchannels()
        frames = w.readframes(w.getnframes())
    out = []
    step = 2 * ch
    for i in range(0, len(frames) - step + 1, step):
        v = frames[i] | (frames[i + 1] << 8)
        if v >= 0x8000:
            v -= 0x10000
        out.append(v)
    return out


def txt_left(path):
    out = []
    for line in open(path):
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            out.append(int(parts[0]))
        except ValueError:
            pass
    return out


def compare(ref_wav, dut_txt, expect, tol_db, name):
    ref = wav_left(ref_wav)
    dut = txt_left(dut_txt)
    if not ref or not dut:
        print("  FAIL %s: empty capture (ref %d, dut %d)" % (name, len(ref), len(dut)))
        return False

    n = min(len(ref), len(dut))
    thr = max(map(abs, ref)) // 10
    ratios = [dut[i] / ref[i] for i in range(n) if abs(ref[i]) >= thr and ref[i] != 0]
    if len(ratios) < 20:
        print("  FAIL %s: only %d loud samples to compare" % (name, len(ratios)))
        return False

    med = statistics.median(ratios)
    exact = sum(1 for i in range(n) if ref[i] == dut[i])
    if med <= 0:
        print("  FAIL %s: median ratio %.4f" % (name, med))
        return False

    d = 20 * math.log10(med / expect)
    ok = abs(d) <= tol_db
    print("  %-14s median ratio %7.4f (%+6.2f dB vs expected %.4f)  "
          "bit-exact %5.1f%% of %d samples  [%s]"
          % (name, med, d, expect, 100.0 * exact / n, n, "ok" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    if len(sys.argv) != 6:
        print("usage: level_cmp.py <ref.wav> <dut.txt> <expected_ratio> <tol_db> <name>")
        sys.exit(2)
    sys.exit(0 if compare(sys.argv[1], sys.argv[2], float(sys.argv[3]),
                          float(sys.argv[4]), sys.argv[5]) else 1)
