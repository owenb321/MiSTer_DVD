#!/usr/bin/env python3
"""hil_timeline.py -- put a capture-card recording on the disc's own clock: for every
captured frame, WHICH authored picture (cell, PTS) is on screen, and what the audio did
(docs/hil_play_harness.md).

    tools/hil_timeline.py align <cap.mkv> <iso> <vts> <pgcn> [--cells 4 5 6 7] -o run.json
    tools/hil_timeline.py report run.json            # stalls, junctions, audio gaps

`align` cuts each cell's sectors out of the image (the LBA range disc_timing.py reports),
decodes them with ffmpeg into small grey thumbnails stamped with their MPEG PTS, decodes
the capture the same way, and matches every capture frame against every reference
picture by normalised correlation. A capture frame carries:

    t        capture time (s, container PTS)
    cell     the matched cell, pts the matched picture's PTS (s)
    score    the correlation (1.0 = identical); margin = score minus the best match at
             least 3 pictures away (small = a static shot, the PTS is uncertain)
    flat     the frame is uniform (black/one colour): no match is attempted

A frame whose best score is below --min-score is reported unmatched (`cell: null`),
never as the nearest guess -- an instrument that always finds a picture would report a
picture when the core showed something else.

This needs no instrument in the core, so it scores every build alike, including the
controls that predate any harness telemetry.

The audio half reports the capture's envelope (10 ms dBFS bins) and every run of exact
digital zero (>= 50 ms): the "gunshot missing" signature (issue #176, the saloon) is a
run of exact zero where the reference cell has sound.
"""
import argparse
import json
import os
import re
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc_timing as DT  # noqa: E402

TW, TH = 48, 32            # thumbnail; small enough that a 2 min capture matches in seconds
# The compared region, as fractions of the PICTURE (the capture's active area, found by
# cropdetect; the reference's full frame): clear of overscan, the scaler's edges, the
# HUD blocks in the top-left corner and the transport bar along the bottom.
BAND = (0.06, 0.20, 0.94, 0.84)        # x0, y0, x1, y1
TIE = 0.01                 # scores this close are the same picture as far as matching goes
ENV_BIN = 480              # 10 ms at 48 kHz
SHOWINFO = re.compile(r'n:\s*(\d+)\s+pts:\s*(-?\d+)\s+pts_time:\s*(-?[\d.]+)')


def _vf(box=None):
    x0, y0, x1, y1 = BAND
    pre = 'crop=%d:%d:%d:%d,' % box if box else ''
    return (pre + 'crop=iw*%.3f:ih*%.3f:iw*%.3f:ih*%.3f,scale=%d:%d:flags=area,'
            'format=gray,showinfo' % (x1 - x0, y1 - y0, x0, y0, TW, TH))


def active_box(src):
    """The capture's active picture (w, h, x, y): the output scaler pillar- or letterboxes
    the picture inside the captured raster. Majority vote of cropdetect over the file."""
    p = subprocess.run(['ffmpeg', '-hide_banner', '-nostats', '-i', src, '-an', '-vf',
                        'select=not(mod(n\\,15)),cropdetect=limit=24:round=2:reset=1',
                        '-f', 'null', '-'], capture_output=True, text=True)
    votes = {}
    for m in re.finditer(r'crop=(\d+):(\d+):(\d+):(\d+)', p.stderr):
        k = tuple(int(x) for x in m.groups())
        votes[k] = votes.get(k, 0) + 1
    if not votes:
        sys.exit('cropdetect found no active area in %s' % src)
    return max(votes, key=votes.get)


def thumbs(src, data=None, box=None):
    """Decode `src` (a path, or '-' with `data` on stdin) to (pts_s[], thumbs[N,TH*TW])."""
    cmd = ['ffmpeg', '-hide_banner', '-nostats', '-copyts']
    if data is not None:
        cmd += ['-f', 'mpeg']
    cmd += ['-i', src, '-an', '-vf', _vf(box), '-fps_mode', 'passthrough',
            '-f', 'rawvideo', '-']
    p = subprocess.run(cmd, input=data, capture_output=True)
    frames = np.frombuffer(p.stdout, dtype=np.uint8)
    n = len(frames) // (TW * TH)
    pts = [float(m.group(3)) for m in SHOWINFO.finditer(p.stderr.decode('utf-8', 'replace'))]
    if n == 0 or len(pts) != n:
        sys.exit('ffmpeg decoded %d frames but reported %d pts for %s:\n%s'
                 % (n, len(pts), src, p.stderr.decode('utf-8', 'replace')[-800:]))
    return np.array(pts), frames[:n * TW * TH].reshape(n, TW * TH).astype(np.float32)


def audio(src, data=None):
    """Mono float audio at 48 kHz and the first sample's PTS (s)."""
    cmd = ['ffmpeg', '-hide_banner', '-nostats', '-copyts']
    if data is not None:
        cmd += ['-f', 'mpeg']
    cmd += ['-i', src, '-vn', '-ac', '1', '-ar', '48000', '-af', 'ashowinfo',
            '-f', 's16le', '-']
    p = subprocess.run(cmd, input=data, capture_output=True)
    m = SHOWINFO.search(p.stderr.decode('utf-8', 'replace'))
    a = np.frombuffer(p.stdout, dtype=np.int16)
    return a, (float(m.group(3)) if m else None)


def normalise(t):
    t = t - t.mean(axis=1, keepdims=True)
    n = np.linalg.norm(t, axis=1)
    flat = n < 1e-3 * TW * TH * 4          # std below ~1 grey level per pixel
    t[~flat] /= n[~flat, None]
    return t, flat


def cut_cell(iso, lba_first, lba_last):
    with open(iso, 'rb') as f:
        f.seek(lba_first * 2048)
        return f.read((lba_last - lba_first + 1) * 2048)


def envelope(a):
    n = len(a) // ENV_BIN
    x = a[:n * ENV_BIN].astype(np.float64).reshape(n, ENV_BIN) / 32768.0
    return 20 * np.log10(np.sqrt((x ** 2).mean(axis=1)) + 1e-9)


def zero_runs(a, t0, min_s=0.05):
    """Runs of EXACT digital zero (both channels mixed to mono, so a zero run here is
    zero in both) of at least min_s, as [(start_s, len_s)]."""
    z = np.concatenate(([0], (a == 0).astype(np.int8), [0]))
    d = np.diff(z)
    starts, ends = np.flatnonzero(d == 1), np.flatnonzero(d == -1)
    keep = (ends - starts) >= int(min_s * 48000)
    return [(round(t0 + s / 48000, 3), round((e - s) / 48000, 3))
            for s, e in zip(starts[keep], ends[keep])]


def cmd_align(a):
    timing = DT.dump(a.iso, a.vts, a.pgcn, set(a.cells))
    cells = [c for c in timing['cells'] if not a.cells or c['cell'] in a.cells]
    ref_pts, ref_cell, ref_t, ref_audio = [], [], [], {}
    for c in cells:
        data = cut_cell(a.iso, c['lba_first'], c['lba_last'])
        pts, th = thumbs('-', data)
        ref_pts.append(pts)
        ref_cell.append(np.full(len(pts), c['cell']))
        ref_t.append(th)
        au, au0 = audio('-', data)
        ref_audio[c['cell']] = {'t0': au0, 'env_db': [round(float(x), 1) for x in envelope(au)]}
        print('ref cell %d: %d pictures, pts %.3f..%.3f (authored first_ptm %.3f)'
              % (c['cell'], len(pts), pts.min(), pts.max(), (c['first_ptm'] or 0) / 9e4),
              file=sys.stderr)
    ref_pts, ref_cell = np.concatenate(ref_pts), np.concatenate(ref_cell)
    R, rflat = normalise(np.concatenate(ref_t))
    box = tuple(a.box) if a.box else active_box(a.capture)
    print('capture active area w,h,x,y = %s' % (box,), file=sys.stderr)
    cap_t, C = thumbs(a.capture, box=box)
    C, cflat = normalise(C)
    print('capture: %d frames, %.1f s' % (len(cap_t), cap_t[-1] - cap_t[0]), file=sys.stderr)

    Rm = R[~rflat]
    ridx = np.flatnonzero(~rflat)
    frames, prev = [], None
    for i0 in range(0, len(C), 2048):
        S = C[i0:i0 + 2048] @ Rm.T
        for k in range(S.shape[0]):
            i = i0 + k
            row = {'t': round(float(cap_t[i]), 4)}
            if cflat[i]:
                row.update(cell=None, flat=True)
                prev = None
                frames.append(row)
                continue
            j = int(np.argmax(S[k]))
            best = float(S[k, j])
            # Continuity: footage authored twice (a hit and a miss branch sharing shots)
            # matches two cells equally. Among matches within TIE of the best, keep the
            # one that continues the previous frame (same cell, PTS 0..0.5 s on).
            if prev is not None:
                near = np.flatnonzero(S[k] >= best - TIE)
                cont = near[(ref_cell[ridx[near]] == prev[0])
                            & (ref_pts[ridx[near]] >= prev[1] - 0.05)
                            & (ref_pts[ridx[near]] <= prev[1] + 0.5)]
                if len(cont):
                    j = int(cont[np.argmin(ref_pts[ridx[cont]] - prev[1])])
            jj = ridx[j]
            far = (ref_cell[ridx] != ref_cell[jj]) | (np.abs(ref_pts[ridx] - ref_pts[jj]) > 0.1)
            second = float(S[k][far].max()) if far.any() else -1.0
            if best < a.min_score:
                row.update(cell=None, score=round(best, 3))
                prev = None
            else:
                row.update(cell=int(ref_cell[jj]), pts=round(float(ref_pts[jj]), 4),
                           score=round(float(S[k, j]), 3), margin=round(best - second, 3))
                prev = (int(ref_cell[jj]), float(ref_pts[jj]))
            frames.append(row)

    au, au_t0 = audio(a.capture)
    au_t0 = au_t0 or 0.0
    env = envelope(au)
    out = {'capture': os.path.basename(a.capture), 'timing': timing, 'box': box,
           'thumb': [TW, TH], 'min_score': a.min_score, 'frames': frames,
           'ref_audio': ref_audio,
           'audio': {'t0': au_t0, 'bin_s': ENV_BIN / 48000,
                     'env_db': [round(float(x), 1) for x in env],
                     'zero_runs': zero_runs(au, au_t0)}}
    with open(a.out, 'w') as f:
        json.dump(out, f)
    print('wrote %s' % a.out, file=sys.stderr)


def segments(frames):
    """Collapse frames into runs on one cell with steadily advancing PTS, plus the
    unmatched and flat stretches between them."""
    segs, cur = [], None
    for r in frames:
        key = 'flat' if r.get('flat') else (r['cell'] if r['cell'] is not None else 'none')
        if cur and cur['key'] == key:
            cur['t1'] = r['t']
            if 'pts' in r:
                cur['pts1'] = r['pts']
            cur['n'] += 1
        else:
            cur = {'key': key, 't0': r['t'], 't1': r['t'], 'n': 1,
                   'pts0': r.get('pts'), 'pts1': r.get('pts')}
            segs.append(cur)
    return segs


def pace_steps(frames, min_s=0.1):
    """Where display pace broke within a cell: the offset t - pts of consecutive
    CONFIDENT matches (margin > 0.02) on one cell steps by more than min_s. A step up is
    a picture held too long (a stall); a step down is pictures never shown (a skip).
    Low-margin frames (a static shot) are passed over, never compared, so a still shot
    cannot fake either."""
    out, prev = [], None
    for r in frames:
        if r.get('cell') is None:
            prev = None
            continue
        if r.get('margin', 0) <= 0.02:
            continue
        if prev and prev['cell'] == r['cell']:
            step = (r['t'] - r['pts']) - (prev['t'] - prev['pts'])
            if abs(step) > min_s:
                out.append({'t': prev['t'], 'cell': r['cell'], 'pts': prev['pts'],
                            'to_pts': r['pts'], 'step_s': round(step, 3),
                            'kind': 'stall' if step > 0 else 'skip'})
        prev = r
    return out


def junctions(frames, timing):
    """Each change of cell on screen: the last picture shown of the old cell against its
    last authored picture, the time with neither on screen, and where the new one began."""
    cells = {c['cell']: c for c in timing['cells']}
    out, last = [], None
    for r in frames:
        if r.get('cell') is None:
            continue
        if last and r['cell'] != last['cell']:
            out.append({'t_old': last['t'], 'old': last['cell'], 'old_pts': last['pts'],
                        'old_end_ptm': (cells[last['cell']].get('end_ptm') or 0) / 9e4,
                        't_new': r['t'], 'new': r['cell'], 'new_pts': r['pts'],
                        'new_first_ptm': (cells[r['cell']].get('first_ptm') or 0) / 9e4,
                        'gap_s': round(r['t'] - last['t'], 3)})
        last = r
    return out


LOUD_DB, QUIET_DB = -35.0, -60.0


def audio_vs_ref(d, max_off=0.3):
    """Place each matched frame's reference audio at its capture time, find the A/V
    offset that best lines the two envelopes up, then list where the reference is loud
    and the capture is not."""
    env = np.array(d['audio']['env_db'])
    bs, t0 = d['audio']['bin_s'], d['audio']['t0']
    # ref[i] = the reference envelope expected at capture bin i (nan where unknown)
    ref, cellat, ptsat = np.full(len(env), np.nan), np.zeros(len(env), int), np.zeros(len(env))
    fr = [r for r in d['frames'] if r.get('cell') is not None]
    for r, nx in zip(fr, fr[1:] + [None]):
        ra = d['ref_audio'].get(str(r['cell'])) or d['ref_audio'].get(r['cell'])
        if not ra or ra['t0'] is None:
            continue
        span = min(0.1, (nx['t'] - r['t']) if nx else 1 / 60)
        i0, i1 = int((r['t'] - t0) / bs), int((r['t'] + span - t0) / bs)
        for i in range(max(i0, 0), min(i1 + 1, len(env))):
            p = r['pts'] + (t0 + i * bs - r['t'])
            k = int((p - ra['t0']) / bs)
            if 0 <= k < len(ra['env_db']):
                ref[i], cellat[i], ptsat[i] = ra['env_db'][k], r['cell'], p
    ok = ~np.isnan(ref)
    if ok.sum() < 200:
        return {'av_offset_s': None, 'corr': None, 'missing': []}
    best, lag = -2.0, 0
    for L in range(-int(max_off / bs), int(max_off / bs) + 1):
        a_idx = np.flatnonzero(ok)
        b_idx = a_idx + L
        m = (b_idx >= 0) & (b_idx < len(env))
        x, y = ref[a_idx[m]], env[b_idx[m]]
        c = np.corrcoef(x, y)[0, 1]
        if c > best:
            best, lag = c, L
    zero = np.zeros(len(env), bool)
    for t, n in d['audio']['zero_runs']:
        zero[int((t - t0) / bs):int((t + n - t0) / bs) + 1] = True
    missing, run = [], None
    for i in np.flatnonzero(ok):
        j = i + lag
        bad = 0 <= j < len(env) and ref[i] > LOUD_DB and env[j] < QUIET_DB
        if bad and run and i - run['i1'] <= 3 and cellat[i] == run['cell']:
            run.update(i1=i, pts1=ptsat[i], peak=max(run['peak'], ref[i]), zero=run['zero'] and zero[j])
        elif bad:
            if run:
                missing.append(run)
            run = {'i0': i, 'i1': i, 'cell': int(cellat[i]), 'pts0': ptsat[i], 'pts1': ptsat[i],
                   'peak': ref[i], 'zero': bool(zero[j])}
    if run:
        missing.append(run)
    return {'av_offset_s': round(lag * bs, 3), 'corr': round(best, 3),
            'missing': [{'t': round(t0 + m['i0'] * bs, 3), 'cell': m['cell'],
                         'pts0': round(m['pts0'], 3), 'pts1': round(m['pts1'], 3),
                         'len_s': round((m['i1'] - m['i0'] + 1) * bs, 3),
                         'ref_peak_db': round(float(m['peak']), 1), 'exact_zero': m['zero']}
                        for m in missing if (m['i1'] - m['i0'] + 1) * bs >= 0.05]}


def cmd_report(a):
    d = json.load(open(a.run))
    fr = d['frames']
    print('capture %s: %d frames' % (d['capture'], len(fr)))
    print('\nsegments (capture time -> cell, PTS):')
    for s in segments(fr):
        if s['t1'] - s['t0'] < a.min_seg and s['key'] in ('none', 'flat'):
            continue
        what = ('cell %s pts %s..%s' % (s['key'], s['pts0'], s['pts1'])
                if isinstance(s['key'], int) else s['key'])
        print('  %8.3f..%8.3f  %5.2f s  %s' % (s['t0'], s['t1'], s['t1'] - s['t0'], what))
    print('\ncell junctions on screen (old cell\'s last picture -> new cell\'s first):')
    for j in junctions(fr, d['timing']):
        print('  t=%8.3f cell %2d pts %7.3f (ends %7.3f) -> %5.3f s -> cell %2d pts %7.3f (starts %7.3f)'
              % (j['t_old'], j['old'], j['old_pts'], j['old_end_ptm'], j['gap_s'],
                 j['new'], j['new_pts'], j['new_first_ptm']))
    ps = pace_steps(fr)
    print('\ndisplay pace steps > 0.1 s within a cell (stall = held, skip = never shown): %d'
          % len(ps))
    for s in ps:
        print('  t=%8.3f cell %d pts %.3f -> %.3f  %s %+.3f s' % (
            s['t'], s['cell'], s['pts'], s['to_pts'], s['kind'], s['step_s']))
    rep = audio_vs_ref(d)
    print('\naudio: capture vs reference, placed by the video mapping')
    if rep['av_offset_s'] is None:
        print('  no matched segment long enough to compare')
    else:
        print('  A/V offset (audio later than picture): %+.3f s, envelope corr %.2f'
              % (rep['av_offset_s'], rep['corr']))
    for g in rep['missing']:
        print('  t=%8.3f cell %2d pts %7.3f..%7.3f: reference sound (peak %5.1f dB), capture'
              ' %s for %.3f s' % (g['t'], g['cell'], g['pts0'], g['pts1'], g['ref_peak_db'],
                                 'EXACT ZERO' if g['exact_zero'] else 'silent', g['len_s']))
    zr = d['audio']['zero_runs']
    print('\naudio exact-zero runs >= 50 ms: %d' % len(zr))
    for t, n in zr:
        print('  t=%8.3f  %.3f s' % (t, n))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('align')
    p.add_argument('capture')
    p.add_argument('iso')
    p.add_argument('vts', type=int)
    p.add_argument('pgcn', type=int)
    p.add_argument('--cells', type=int, nargs='*', default=[])
    p.add_argument('--min-score', type=float, default=0.80)
    p.add_argument('--box', type=int, nargs=4, metavar=('W', 'H', 'X', 'Y'),
                   help='the capture\'s active picture (default: cropdetect)')
    p.add_argument('-o', '--out', required=True)
    p = sub.add_parser('report')
    p.add_argument('run')
    p.add_argument('--min-seg', type=float, default=0.10)
    a = ap.parse_args()
    {'align': cmd_align, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
