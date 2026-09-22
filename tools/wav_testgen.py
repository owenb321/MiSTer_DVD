#!/usr/bin/env python3
"""wav_testgen.py — listenable test material for the WAV/CD-DA hardware gate.

`tools/wav_ref.py` generates SIMULATION fixtures: deterministic xorshift noise,
perfect for bit-exact comparison and useless to listen to. This generates the
other half — files whose *sound* answers each hardware question directly, so the
gate is a measurement rather than "does it seem OK".

Every design choice here exists to make one gate item unambiguous:

  * A CHROMATIC LADDER, one semitone per 10 s step. A 10-second D-pad jump must
    move exactly ONE step. That is the audible form of the 48 kHz step fix: the
    parked branch reused the 44.1 kHz constant (861 blocks/10 s) for both rates,
    so at 48 kHz a "10 s" jump moved ~9.1 s — which drifts off the step boundary
    and is obvious here, where against a stopwatch it is not.
  * LEFT and RIGHT AN OCTAVE APART. A channel swap is then instantly audible
    instead of invisible. This is the ear-side check on the pair-alignment
    invariant (`bpos ≡ wav_doff mod 4`): land a seek one byte out and L/R swap
    for the rest of playback, which no spectrum view would show.
  * A SHORT GAP at each step boundary, so steps can be counted without perfect
    pitch, and so the HUD clock / progress bar can be read against a known
    position (step N starts at exactly N x 10 s).
  * A 440 Hz A as step 0, so pitch is checkable against any tuner or phone app —
    which is the real test of the 44.1 kHz -> 48 kHz sample-repeat path.

  usage: tools/wav_testgen.py <outdir> [--minutes N]
"""

import argparse
import math
import os
import struct

STEP_S = 10.0          # one semitone per 10 s == one D-pad short jump
GAP_MS = 60            # boundary marker
AMP = 0.25             # -12 dBFS, comfortable and clip-free with two tones


def wav_bytes(rate, channels, data):
    """Canonical 44-byte RIFF/WAVE header + payload (16-bit)."""
    block_align = channels * 2
    fmt = struct.pack('<HHIIHH', 1, channels, rate, rate * block_align,
                      block_align, 16)
    body = (b'fmt ' + struct.pack('<I', len(fmt)) + fmt +
            b'data' + struct.pack('<I', len(data)) + data)
    return b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WAVE' + body


def ladder(rate, seconds, stereo=True):
    """Chromatic ladder; right channel an octave up. Phase-continuous within a
    step so there are no clicks except the deliberate boundary gaps."""
    n = int(rate * seconds)
    gap = int(rate * GAP_MS / 1000.0)
    out = bytearray()
    ph_l = ph_r = 0.0
    for i in range(n):
        step = int(i / (rate * STEP_S))
        pos = i - int(step * rate * STEP_S)
        f_l = 440.0 * (2.0 ** (step / 12.0))
        f_r = f_l * 2.0
        ph_l += 2.0 * math.pi * f_l / rate
        ph_r += 2.0 * math.pi * f_r / rate
        if pos < gap:                       # boundary marker
            l = r = 0.0
        else:
            l = math.sin(ph_l) * AMP
            r = math.sin(ph_r) * AMP
        li = max(-32768, min(32767, int(l * 32767)))
        ri = max(-32768, min(32767, int(r * 32767)))
        if stereo:
            out += struct.pack('<hh', li, ri)
        else:
            out += struct.pack('<h', li)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('outdir')
    ap.add_argument('--minutes', type=float, default=3.0)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    secs = a.minutes * 60.0

    for rate, name in ((44100, 'WAVTEST_441.wav'), (48000, 'WAVTEST_48.wav')):
        blob = wav_bytes(rate, 2, ladder(rate, secs))
        open(os.path.join(a.outdir, name), 'wb').write(blob)
        print(f'  {name:26s} {rate} Hz stereo  {len(blob)/1e6:.1f} MB  '
              f'{int(secs/STEP_S)} steps of {STEP_S:.0f}s')

    # A shape the core must REFUSE with UNSUPPORTED IMAGE rather than play as
    # noise. Mono is the cheapest to make and the most likely to be hit in real
    # life (a voice memo, a ripped sound effect).
    blob = wav_bytes(44100, 1, ladder(44100, 10.0, stereo=False))
    open(os.path.join(a.outdir, 'WAVTEST_REJECT_MONO.wav'), 'wb').write(blob)
    print(f'  {"WAVTEST_REJECT_MONO.wav":26s} 44100 Hz MONO -- must be REFUSED')


if __name__ == '__main__':
    main()
