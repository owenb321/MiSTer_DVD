#!/usr/bin/env python3
"""trick_splice.py - offline model of trick play's spliced video stream (docs/trick_play.md).

Builds, from a real ISO, the video elementary stream the decoder would receive in trick
play: per VOBU, read [nv_pck .. nv_pck + vobu_1stref_ea], keep the video ES, cut it with
the ES filter, jump by fwda/bwda at the tier's rung, repeat. Then decodes the result with
ffmpeg and checks one clean picture per VOBU.

The ES filter (the rule the RTL must implement):
  pass from the VOBU's first sequence header through the end of the first reference
  frame (one frame picture, or two complementary field pictures), and drop from the next
  picture start code to the end of the read. A VOBU with 1stref_ea == 0 is skipped.

  tools/trick_splice.py disc.iso                       # every tier, forward + reverse
  tools/trick_splice.py disc.iso --tier 2 --dir fwd --frames 60 --at 0.3 -o out.m2v
  tools/trick_splice.py disc.iso --raw                 # control: no filter (cut sectors)

The --raw control feeds the decoder the cut sectors as read. It shows whether the filter
is load-bearing on this disc.
"""
import argparse, os, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nav_extract import be32, is_nav_pack, STIME, sri_offset      # noqa: E402
from trick_scan import title_extents, video_es, pictures, SEC, DSI  # noqa: E402

# tier -> jump seconds (docs/trick_play.md "Decided": 2x 8x 40x 120x at T = 250 ms)
TIER_S = [0.5, 2.0, 10.0, 30.0]


def pic_starts(es):
    """Offsets of every picture start code (00 00 01 00), recognised from its 4 bytes
    alone, as the RTL's start-code detector does. A header truncated by the end of the
    read still counts: missing it was the first model's bug (2026-11-22, 6 of 193 runs:
    a split 00 00 01 00 ahead of the next sequence header)."""
    out, i = [], 0
    while True:
        i = es.find(b'\x00\x00\x01\x00', i)
        if i < 0:
            return out
        out.append(i)
        i += 4


def es_filter(es):
    """Cut one VOBU's ES to [first sequence header .. end of the first reference frame].
    Returns (bytes, why) - bytes is None when the VOBU must be skipped."""
    s = es.find(b'\x00\x00\x01\xb3')
    if s < 0:
        return None, 'no_seq'
    pics = [p for p in pictures(es) if p[0] > s]
    if not pics or pics[0][1] != 1:
        return None, 'first_not_I'
    n = 1
    if pics[0][2] in (1, 2):                       # field picture: keep its pair
        if len(pics) < 2 or pics[1][2] not in (1, 2) or pics[1][2] == pics[0][2]:
            return None, 'field_pair_incomplete'
        n = 2
    starts = [p for p in pic_starts(es) if p > s]
    if len(starts) > n:
        return es[s:starts[n]], 'cut'
    out = es[s:]                                   # the read ends inside or at the frame
    if out.endswith(b'\x00\x00\x01'):              # a start code split by the read's end
        out = out[:-3]
        return out, 'whole_strip'
    return out, 'whole'


def walk(f, lo, hi, start, step_s, fwd, frames):
    """Yield (nav_lbn, es_chunk) along a fwda/bwda walk from `start`."""
    STEP = {0.5: 18, 1.0: 17, 2.0: 16, 10.0: 3, 30.0: 2, 60.0: 1, 120.0: 0}
    ridx = STEP[step_s]
    pos, got, guard = start, 0, 0
    while lo <= pos < hi and got < frames and guard < frames * 20:
        guard += 1
        f.seek(pos * SEC)
        nav = f.read(SEC)
        if not is_nav_pack(nav):
            pos += 1 if fwd else -1
            continue
        d = nav[DSI:]
        ref = be32(d, 0x0C)
        if ref:
            f.seek(pos * SEC)
            yield pos, video_es(f.read((ref + 1) * SEC))
            got += 1
        # the rung, falling back one rung at a time to the shortest, then next/prev VOBU
        moved = False
        for r in range(ridx, 19):
            ent = be32(d, 0xEE + r * 4) if fwd else be32(d, 0x142 + (18 - r) * 4)
            ok, off = sri_offset(ent)
            if ok and off:
                pos += off if fwd else -off
                moved = True
                break
        if not moved:
            ent = be32(d, 0x13A if fwd else 0x13E)
            ok, off = sri_offset(ent)
            if ok and off:
                pos += off if fwd else -off
            elif fwd:
                pos += be32(d, 0x08) + 1
            else:
                return                             # backward dead end


def decode(path):
    """ffmpeg decode: (frames, error lines)."""
    p = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'mpegvideo', '-i', path,
                        '-f', 'null', '-'], capture_output=True, text=True)
    q = subprocess.run(['ffprobe', '-v', 'quiet', '-count_frames', '-select_streams', 'v:0',
                        '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0',
                        '-f', 'mpegvideo', path], capture_output=True, text=True)
    n = int(q.stdout.strip() or 0)
    errs = [l for l in p.stderr.splitlines() if l.strip()]
    return n, errs


def run(iso, tier, fwd, frames, at, raw, out=None):
    with open(iso, 'rb') as f:
        ext = title_extents(f)
        vts = max(ext, key=lambda v: sum(d for _, d in ext[v]))
        lo = min(e for e, _ in ext[vts])
        hi = max(e + (d + SEC - 1) // SEC for e, d in ext[vts])
        start = lo + int((hi - lo) * at)
        while start < hi:                          # first nav pack at/after the point
            f.seek(start * SEC)
            if is_nav_pack(f.read(SEC)):
                break
            start += 1
        es, kept, why = bytearray(), 0, {}
        for _, chunk in walk(f, lo, hi, start, TIER_S[tier], fwd, frames):
            if raw:
                es += chunk
                kept += 1
                continue
            cut, w = es_filter(chunk)
            why[w] = why.get(w, 0) + 1
            if cut is not None:
                es += cut
                kept += 1
    es += b'\x00\x00\x01\xb7'                      # sequence_end_code
    path = out or tempfile.mktemp(suffix='.m2v')
    open(path, 'wb').write(es)
    n, errs = decode(path)
    if not out:
        os.unlink(path)
    return kept, n, errs, why


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('isos', nargs='+')
    ap.add_argument('--tier', type=int, choices=range(4))
    ap.add_argument('--frames', type=int, default=40)
    ap.add_argument('--at', type=float, default=0.3, help='start, fraction into the feature')
    ap.add_argument('--raw', action='store_true', help='control: no ES filter')
    ap.add_argument('--dir', choices=('fwd', 'rev', 'both'), default='both')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    bad = 0
    for iso in a.isos:
        for tier in ([a.tier] if a.tier is not None else range(4)):
            for fwd in {'fwd': (True,), 'rev': (False,), 'both': (True, False)}[a.dir]:
                kept, n, errs, why = run(iso, tier, fwd, a.frames, a.at, a.raw, a.out)
                ok = n == kept and not errs and kept > 0
                bad += not ok
                print('%-40s %4gs %s  vobus %3d  decoded %3d  errors %3d  %s  %s'
                      % (os.path.basename(iso)[:40], TIER_S[tier], 'fwd' if fwd else 'rev',
                         kept, n, len(errs), why, 'OK' if ok else 'FAIL'))
                for e in errs[:3]:
                    print('      ' + e)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
