#!/usr/bin/env python3
"""
audio_check.py -- is every audio track the disc offers actually AUDIBLE?

The bug class this exists for reached us as user reports rather than as a test
failure: dvd/ac3 supports only acmod 2 (2/0) and 7 (3/2), so a MONO or QUAD
track sets err_unsupported -> ac3_err -> a self-heal reset every frame ->
SILENCE. A 505-disc census found 26 discs with an unsupported acmod on some
track and 11 on a DEFAULT track. Nothing in the harness could see it, because
silence looks exactly like a quiet passage.

★ THE DISC'S OTHER TRACKS ARE THE CONTROL. A quiet passage, a menu, a fade --
all of them silence EVERY track equally. A track that is digitally silent while
its siblings are audible, at the same instant of the same title, is not a quiet
passage: it is a track that did not decode. That within-disc comparison is what
makes this measurable without knowing anything about the content.

⚠ A CAPTURE CARD IS THE RIGHT INSTRUMENT HERE, unlike for drift. The harness's
standing rule is that a sampled card measures OFFSETS, not RATES -- because it
holds whole frames and beats against the source. Silence is neither: it is an
AMPLITUDE question, and amplitude is exactly what the card reports faithfully.

Usage:
    audio_check.py <iso-on-the-mister> [--secs 6] [--max-tracks 8]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mister as M              # noqa: E402
import hud_read as H            # noqa: E402

# MEASURED, and the margin matters. A decode failure produces EXACT digital
# silence, which reads -999 dBFS (a true zero sample block). Real but quiet
# programme material measured -66.0 dBFS on a film's second track -- only 4 dB
# from an earlier -70 guess, which would eventually have called a quiet passage
# a defect. -80 sits in the wide gap between the two and cannot reach either.
SILENT_DBFS = -80.0


def rms_dbfs(wav):
    import numpy as np
    import wave
    with wave.open(wav, 'rb') as w:
        n = w.getnframes()
        if n == 0:
            return -999.0, -999.0
        raw = w.readframes(n)
    a = np.frombuffer(raw, dtype='<i2').astype(np.float32) / 32768.0
    if a.size == 0:
        return -999.0, -999.0
    rms = float(np.sqrt((a * a).mean()))
    peak = float(np.abs(a).max())
    to_db = lambda v: (20.0 * __import__('math').log10(v)) if v > 1e-9 else -999.0
    return to_db(rms), to_db(peak)


def capture_audio(adev, afmt, secs, path):
    r = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                        '-f', afmt, '-ac', '2', '-ar', '48000', '-i', adev,
                        '-t', str(secs), path],
                       capture_output=True, timeout=secs + 60)
    if not os.path.exists(path):
        # Loud, not silent: a failed capture reads as digital silence and would
        # be reported as a FINDING. Never let that pass as data.
        sys.stderr.write(r.stderr.decode(errors='replace')[-300:] + '\n')
        return False
    return True


def board_audio_track(tmpdir, step):
    """Press Audio and read the track the core reports from the HUD popup.

    The popup is the core's own answer to "which track is selected and how many
    are there", so the loop follows the disc rather than assuming a count.
    """
    M.cmd_key(argparse.Namespace(names=['audio']))
    time.sleep(1.5)
    png = os.path.join(tmpdir, f'aud{step:02d}.png')
    rc, _ = M.ssh('''
rm -f /media/fat/screenshots/audc.png
echo 'screenshot audc.png' > /dev/MiSTer_cmd
for i in $(seq 1 16); do
  sleep 0.25
  if [ -f /media/fat/screenshots/audc.png ]; then
    a=$(stat -c %s /media/fat/screenshots/audc.png); sleep 0.2
    b=$(stat -c %s /media/fat/screenshots/audc.png)
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
exit 1
''', check=False)
    if rc != 0:
        return None, None, None
    r = subprocess.run(['scp', *M.SSH_OPTS, '-q',
                        f'{M.host()}:/media/fat/screenshots/audc.png', png],
                       capture_output=True)
    if r.returncode != 0:
        return None, None, None
    w, h, buf = H.load_image(png)
    res = H.decode(H.Frame(w, h, buf))
    pop = (res.get('popup_text') or '')
    m = re.search(r'AUDIO\s+(\d+)\s*/\s*(\d+)\s*(\S*)', pop)
    if not m:
        return None, None, pop
    return int(m.group(1)), int(m.group(2)), m.group(3)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('image', help='absolute path ON THE MISTER')
    ap.add_argument('--secs', type=float, default=6.0)
    ap.add_argument('--max-tracks', type=int, default=8)
    ap.add_argument('--adev')
    ap.add_argument('--afmt', choices=('alsa', 'pulse'))
    ap.add_argument('--red', action='store_true',
                    help='mute one track deliberately, to prove the finding path fires')
    ap.add_argument('--settle', type=float, default=6.0)
    args = ap.parse_args()

    _, auto_a, auto_fmt = M.capture_devices()
    adev = args.adev or auto_a
    afmt = args.afmt or auto_fmt
    if not adev:
        sys.exit('audio_check: no capture card found (set --adev, e.g. hw:0,0)')
    tmpdir = tempfile.mkdtemp(prefix='audiochk_')
    print(f'audio_check: {os.path.basename(args.image)}')
    print(f'  capture: {adev} ({afmt})   window: {args.secs}s per track')

    # Disc Menus Off so the main title auto-plays -- we need PROGRAMME material,
    # and a menu's audio (or lack of it) says nothing about the title's tracks.
    M.cmd_launch(argparse.Namespace(
        image=args.image, opt=['Debug Overlay=On', 'Disc Menus=Off',
                               'Video Output=Progressive'],
        delay=2, timeout=90, no_wait=False))
    time.sleep(args.settle + 6)

    rows, seen = [], set()
    for i in range(args.max_tracks):
        cur, total, lang = board_audio_track(tmpdir, i)
        if cur is None:
            print(f'  step {i}: no AUDIO popup on screen '
                  f'({"no HUD" if lang is None else repr(lang)})')
            break
        if cur in seen:
            break                      # wrapped around the disc's own list
        seen.add(cur)
        # ⚠ RED PROOF. The FINDING path must be shown to fire, or "all tracks
        # audible" means nothing. --red mutes the core for ONE track, so exactly
        # one reads silent while its siblings do not -- which is the signature
        # this tool exists to detect, produced on demand. It exercises the whole
        # pipeline: capture, level measurement, and the within-disc comparison.
        if args.red and len(seen) == 1:
            M.cmd_osd(argparse.Namespace(setting='Audio=Off'))
            time.sleep(3)
        wav = os.path.join(tmpdir, f'trk{cur}.wav')
        ok = capture_audio(adev, afmt, args.secs, wav)
        r, pk = rms_dbfs(wav) if ok else (-999.0, -999.0)
        if args.red and len(seen) == 1:
            M.cmd_osd(argparse.Namespace(setting='Audio=On'))
            time.sleep(2)
        rows.append(dict(track=cur, total=total, lang=lang, rms=r, peak=pk))
        print(f'  track {cur}/{total} {lang:<4} rms {r:7.1f} dBFS   '
              f'peak {pk:7.1f} dBFS' + ('   <- SILENT' if r < SILENT_DBFS else ''))
        if total and len(seen) >= total:
            break

    if not rows:
        print('\n  no audio tracks were reported by the core -- nothing to check')
        return 2

    silent = [r for r in rows if r['rms'] < SILENT_DBFS]
    audible = [r for r in rows if r['rms'] >= SILENT_DBFS]
    print()
    if args.red:
        ok = bool(silent and audible)
        print(f'  RED PROOF: {"PASS" if ok else "FAIL"} -- a deliberately muted '
              f'track {"was" if ok else "was NOT"} reported against its audible '
              'siblings')
        if not ok:
            print('    The within-disc comparison cannot fire. Do not trust a '
                  'clean run.')
        return 0 if ok else 3

    if silent and audible:
        # The within-disc control fired: same title, same instant, siblings loud.
        for r in silent:
            print(f'  !! FINDING: track {r["track"]}/{r["total"]} ({r["lang"]}) '
                  f'is digitally silent at {r["rms"]:.0f} dBFS while '
                  f'{len(audible)} other track(s) on the same title are audible')
        print('     Unsupported AC-3 acmod is the known cause of exactly this '
              '(dvd/ac3 supports acmod 2 and 7 only); confirm with '
              'tools/dvd_census.py --audio on this disc.')
        return 1
    if silent and not audible:
        # Cannot separate "all tracks broken" from "an authored silent passage".
        print('  INCONCLUSIVE: every track was silent, so there is no working '
              'control on this disc.')
        print('     Either the passage is authored silent, or audio is dead '
              'disc-wide. Re-run further into the title before concluding.')
        return 2
    print(f'  all {len(rows)} track(s) audible')
    return 0


if __name__ == '__main__':
    sys.exit(main())
