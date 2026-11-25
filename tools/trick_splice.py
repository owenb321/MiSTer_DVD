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

# tier -> jump seconds (docs/trick_play.md "Decided": 16x 40x 120x 480x at T = 250 ms)
TIER_S = [4.0, 10.0, 30.0, 120.0]


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
    """Cut one VOBU's ES the way dvd/trick_es_filter.sv does (byte-exact; the RTL bench
    bench/dvd/run_trick_es_filter.sh compares the two). Returns (bytes, why); bytes is
    None when nothing of the read is passed.

    - nothing before the first sequence header;
    - through the end of the first picture (frame), or of the second picture when the
      first is field-structured (the pair); the cut is the next picture start code;
    - a first picture that is not an I-picture: its headers pass and the picture does
      not. (A streaming filter has already passed the headers when it learns the type.
      A sequence header with no picture after it is harmless to the vld, which
      dispatches on whichever start code comes next. 0 such VOBUs in the 150-disc sweep.)
    - a read with no picture start code after the header passes whole;
    - a dangling 00 00 01 at the read's end is dropped."""
    s = es.find(b'\x00\x00\x01\xb3')
    if s < 0:
        return None, 'no_seq'
    starts = [p for p in pic_starts(es) if p > s]
    pics = [p for p in pictures(es) if p[0] > s]
    if starts and pics and pics[0][1] != 1:
        return es[s:starts[0]], 'first_not_I'
    n = 2 if (pics and pics[0][2] in (1, 2)) else 1
    if len(starts) > n:
        return es[s:starts[n]], 'cut' if n == 1 else 'cut_pair'
    out = es[s:]                                   # the read ends inside or at the frame
    if out.endswith(b'\x00\x00\x01'):              # a start code split by the read's end
        return out[:-3], 'whole_strip'
    return out, 'whole'


def walk(f, lo, hi, start, step_s, fwd, frames):
    """Yield (nav_lbn, es_chunk) along a fwda/bwda walk from `start`."""
    # fwda index per jump: the table runs 120, 60, 30, 10, 7.5, 7, 6.5 ... 1, 0.5 s.
    # (2.0 was 16 until 2026-11-24, which is the 1.5 s entry: the first decoder and
    # splice runs at "8x" were really 6x.)
    STEP = {0.5: 18, 1.0: 17, 2.0: 15, 10.0: 3, 30.0: 2, 60.0: 1, 120.0: 0}
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


# ---- the reader's walk (dvd/dvd_iso_reader.sv TRICK PLAY), for bench/dvd/run_trick_reader.sh
# The four tier rungs per direction: fwda index / bwda index (bwda runs short to long).
RUNG_FWD = [11, 3, 2, 0]           # 4, 10, 30, 120 s
RUNG_REV = [7, 15, 16, 18]


def _usable(e):
    return (e & 0x3FFFFFFF) not in (0x3FFFFFFF, 0)


def walk_cells(read_rbn, cells, cell, nav, tier, rev, frames):
    """The reader's trick walk. read_rbn(rbn, n) -> bytes; cells = [(first, last, lvobu)]
    in play order; starts at NAV pack `nav` inside cells[cell]. Yields
    (nav_rbn, last_rbn, crossed) per VOBU: the reader reads nav..last, then jumps.
    Target: the tier rung, each shorter tier rung, then next/prev_vobu (only when the
    shortest rung is not END_OF_CELL: the cell ends within it, so cross); usable when
    neither 0 nor END_OF_CELL and inside the current cell. Else the neighbouring
    cell: its first sector forward, its last VOBU back; past the PGC's ends, stop."""
    crossed = False
    for _ in range(frames):
        sec = read_rbn(nav, 1)
        if not is_nav_pack(sec):
            raise ValueError('rbn %d is not a NAV pack' % nav)
        d = sec[DSI:]
        yield nav, nav + be32(d, 0x0C), crossed
        crossed = False
        first, last, _ = cells[cell]
        cand = []
        for t in range(tier, -1, -1):
            cand.append(be32(d, 0x142 + 4 * RUNG_REV[t]) if rev else be32(d, 0xEE + 4 * RUNG_FWD[t]))
        r0 = be32(d, 0x142 + 4 * RUNG_REV[0]) if rev else be32(d, 0xEE + 4 * RUNG_FWD[0])
        if (r0 & 0x3FFFFFFF) != 0x3FFFFFFF:     # END_OF_CELL on the shortest rung: cross
            cand.append(be32(d, 0x13E if rev else 0x13A))
        tgt = None
        for e in cand:
            if _usable(e):
                off = e & 0x3FFFFFFF
                tgt = nav - off if rev else nav + off
                break
        if tgt is not None and (tgt >= first if rev else tgt <= last):
            nav = tgt
            continue
        cell = cell - 1 if rev else cell + 1
        if cell < 0 or cell >= len(cells):
            return
        nav = cells[cell][2] if rev else cells[cell][0]
        crossed = True


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
                kept += w not in ('first_not_I',)
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
