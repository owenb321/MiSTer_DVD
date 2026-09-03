#!/usr/bin/env python3
# =============================================================================
# seek_fixture.py -- build the RTL fixture for the post-seek reference re-align
#                    (issue #45, bench/dvd/seek_realign_tb.sv)
#
# A seek is a DISCONTINUITY in the bitstream: the VBUF is flushed, the reader
# jumps, and the decoder resumes at a VOBU boundary somewhere else in the title.
# The bug being measured is that the decoder's REFERENCE FRAMES survive that
# discontinuity, so the landing GOP's leading B-pictures motion-compensate
# against the OLD scene.
#
# To reproduce it faithfully the bench needs two elementary-stream cuts from
# DIFFERENT points of a real title, plus enough structural metadata to know
# what the correct answer is:
#
#   <stem>.hex       cut A words, then cut B words -- 64-bit big-endian, one
#                    hex word per line, the format getbits_fifo's shift order
#                    expects (first stream byte in bits [63:56]).
#   <stem>.meta.hex  seven 32-bit words, $readmemh'd into a small TB array.
#
# Each cut starts at a SEQUENCE HEADER (00 00 01 B3): the vld refuses picture
# start codes until sequence_header_seen, so a cut beginning mid-GOP would make
# the bench and the disc disagree about which picture index they are on. Cut A
# is padded to an 8-byte boundary before cut B is appended, so cut B starts on
# a whole word index -- that index is the bench's jump target. The file ends
# with 00 00 01 B7 plus filler because getbits reads whole 64-bit words through
# a 129-bit window: without bytes BEHIND the last picture the pipeline starves
# and that picture never commits (same reason tools/cc_scan.py pads).
#
# VALIDATION IS THE POINT, not a nicety. The bench asserts an exact violation
# count, so a fixture whose cut B has a CLOSED first GOP -- or no leading B's
# at all -- would make the RED arm measure zero and the whole gate vacuous.
# Those cases exit 1 here, naming the flag to move, rather than producing a
# fixture that passes for the wrong reason.
#
# Usage:
#   tools/seek_fixture.py <iso> [--vts N] \
#       [--cut-a-frac 0.10] [--sectors-a 120] \
#       [--cut-b-frac 0.60] [--sectors-b 200] \
#       [--require-field] [--require-still] \
#       --out bench/dvd/test_vobs/seek_realign
# =============================================================================
import sys, os, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                       # noqa: E402
from video_cadence_census import video_payload      # noqa: E402
from film_evidence_probe import parse_pictures      # noqa: E402

SEC = 2048
I_TYPE, P_TYPE, B_TYPE = 1, 2, 3


def gop_headers(buf):
    """Offset -> closed_gop for every group_start_code in the cut.

    The GOP header is 00 00 01 B8 then 27 bits: 25 of time_code, then
    closed_gop, then broken_link. So closed_gop is bit 6 of the fourth payload
    byte, counting from the MSB (ISO 13818-2 6.2.2.6).
    """
    out, i = {}, buf.find(b'\x00\x00\x01\xb8')
    while i >= 0:
        if i + 8 <= len(buf):
            out[i] = (buf[i + 7] >> 6) & 1
        i = buf.find(b'\x00\x00\x01\xb8', i + 4)
    return out


def leading_bs(pics, gops):
    """(count, closed_gop) for the FIRST GOP of a cut.

    "Leading" B-pictures are the ones an OPEN GOP codes after its I but
    displays BEFORE it -- temporal_reference below the I's. They are exactly
    the pictures whose forward reference lies in the previous GOP, i.e. the
    ones that read a stale slot after a seek. Everything else in the GOP
    predicts from anchors decoded after the landing and is safe.
    """
    first = [p for p in pics if p['gop'] == pics[0]['gop']]
    if not first or first[0]['ct'] != I_TYPE:
        return 0, None, first
    i_tr = first[0]['tr']
    n = 0
    for p in first[1:]:
        if p['ct'] != B_TYPE or p['tr'] >= i_tr:
            break
        n += 1
    off = min((o for o in gops), default=None)
    return n, (gops[off] if off is not None else None), first


def cut(nav, sector_at, start, count):
    es = b''.join(d for d in (video_payload(nav.sec(sector_at(start + k)))
                              for k in range(count)
                              if sector_at(start + k) is not None) if d)
    sh = es.find(b'\x00\x00\x01\xb3')
    return es[sh:] if sh >= 0 else b''


def die(msg):
    print(f"seek_fixture: {msg}", file=sys.stderr)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('iso')
    ap.add_argument('--vts', type=int, default=None)
    ap.add_argument('--cut-a-frac', type=float, default=0.10)
    ap.add_argument('--sectors-a', type=int, default=400)
    ap.add_argument('--cut-b-frac', type=float, default=0.60)
    ap.add_argument('--sectors-b', type=int, default=400)
    # Sector counts are a SEARCH width (a sequence header must fall inside one);
    # picture counts are what the fixture actually keeps. Trimming matters:
    # Icarus compiles the TB's ES array as flops, so an oversized fixture is a
    # compile cliff, not free headroom (memory: icarus-large-array-compile-cliff).
    ap.add_argument('--pics-a', type=int, default=5)
    ap.add_argument('--pics-b', type=int, default=14)
    ap.add_argument('--require-field', action='store_true',
                    help="cut B must be FIELD-coded (exercises the once-per-frame "
                         "anchor count; a field-coded I frame is two I pictures)")
    ap.add_argument('--require-still', action='store_true',
                    help="cut B must be a still cell (I pictures only, terminated "
                         "by a sequence end) -- the menu arm")
    ap.add_argument('--out', required=True, help='fixture stem, no extension')
    a = ap.parse_args()

    nav = IsoNav(a.iso)
    vts = a.vts if a.vts is not None else nav.best_vts
    runs = [(ext, dl // SEC) for ext, dl in nav.groups[vts]]
    total = sum(n for _, n in runs)

    def sector_at(idx):
        for ext, n in runs:
            if idx < n:
                return ext + idx
            idx -= n
        return None

    es_a = cut(nav, sector_at, int(total * a.cut_a_frac), a.sectors_a)
    es_b = cut(nav, sector_at, int(total * a.cut_b_frac), a.sectors_b)
    if not es_a:
        return die("no sequence header in cut A -- move --cut-a-frac")
    if not es_b:
        return die("no sequence header in cut B -- move --cut-b-frac")

    def trim(es, keep):
        pics = parse_pictures(es)
        if len(pics) > keep:
            es = es[:pics[keep]['off']]
            pics = parse_pictures(es)
        return es, pics

    es_a, pics_a = trim(es_a, a.pics_a)
    es_b, pics_b = trim(es_b, a.pics_b)
    if not pics_a or not pics_b:
        return die("a cut decoded to zero pictures -- widen --sectors-a/--sectors-b")

    # Cut A must not end its own sequence before the flush: a 00 00 01 B7 sends
    # the vld down STATE_LAST_FRAME, which CLEARS prev_i_p_frame_valid and
    # rotates the slots -- i.e. it re-aligns the references for free and the
    # bench would be measuring the wrong discontinuity.
    if b'\x00\x00\x01\xb7' in es_a:
        return die("cut A contains a sequence end -- it would pre-clear the "
                   "references; move --cut-a-frac or shorten --sectors-a")

    n_lead, closed, first_gop = leading_bs(pics_b, gop_headers(es_b))
    if first_gop and first_gop[0]['ct'] != I_TYPE:
        return die(f"cut B's first picture is type {first_gop[0]['ct']}, not I -- "
                   "a seek always lands on a VOBU/GOP boundary; move --cut-b-frac")
    if closed:
        return die("cut B's first GOP is CLOSED -- its leading B's do not predict "
                   "across the boundary, so the defect cannot appear; move --cut-b-frac")
    if n_lead == 0:
        return die("cut B's first GOP has no leading B-pictures -- the RED arm "
                   "would measure zero and the gate would be vacuous; move --cut-b-frac")

    field_b = 1 if any(p['pstruct'] != 3 for p in pics_b) else 0
    if a.require_field and not field_b:
        return die("cut B is frame-coded; --require-field wants a field-coded VTS")
    if a.require_still and any(p['ct'] != I_TYPE for p in pics_b):
        return die("cut B is not a still cell; --require-still wants I pictures only")

    # Assemble. Cut A padded to a word boundary so cut B's start is a word index.
    es_a += b'\x00' * (-len(es_a) % 8)
    b_word = len(es_a) // 8
    es = es_a + es_b
    es += b'\x00\x00\x01\xb7' + b'\x00' * 64          # let the last picture commit
    es += b'\x00' * (-len(es) % 8)

    with open(a.out + '.hex', 'w') as fh:
        for i in range(0, len(es), 8):
            fh.write(es[i:i + 8].hex() + '\n')

    meta = [b_word, len(pics_a), first_gop[0]['ct'], n_lead,
            1 if closed else 0, len(pics_b), field_b]
    with open(a.out + '.meta.hex', 'w') as fh:
        for w in meta:
            fh.write(f"{w & 0xFFFFFFFF:08x}\n")

    print(f"{os.path.basename(a.iso)}  VTS{vts:02d}")
    print(f"  {a.out}.hex       {len(es)} B  (cut A {len(es_a)} B / {len(pics_a)} pics, "
          f"cut B {len(es_b)} B / {len(pics_b)} pics)")
    print(f"  {a.out}.meta.hex  b_word={b_word} lead_b={n_lead} closed={closed} "
          f"field={field_b}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
