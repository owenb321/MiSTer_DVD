#!/usr/bin/env python3
# =============================================================================
# field_order_fixture.py -- build the RTL fixture for the FIELD-ORDER gate
#                           (bench/dvd/field_order_tb.sv)
#
# THE DEFECT THIS GATES: on a FIELD-coded picture (picture_structure 1=top or
# 2=bottom rather than 3=frame) ISO 13818-2 6.3.10 forces the top_field_first
# syntax element to 0, so it says nothing -- the display order is given by WHICH
# PARITY IS CODED FIRST in each pair. dvd/resample_addrgen.v ordered the two
# field images from top_field_first alone, so every field-coded picture was
# emitted BOTTOM-then-TOP. On film that is invisible (both fields of a 3:2 frame
# are the same instant); on true-interlaced field-coded content the two fields
# are distinct instants 1/59.94 s apart and the display order is inverted.
#
# The fixture carries an ES cut plus the TRUTH: for each picture, in DISPLAY
# order, which field must be shown first.
#
#   <stem>.hex    ES as 64-bit big-endian words, one per line -- getbits_fifo's
#                 shift order (first stream byte in bits [63:56]).
#   <stem>.truth  one 32-bit word per DISPLAYED picture: bit0 = first field is
#                 TOP. $readmemh'd by the bench.
#   <stem>.meta.hex  four words: n_display, n_field_pairs, n_top_first, n_frame.
#
# ★ THE TRUTH IS DERIVED FROM THE SPEC, NOT FROM THE RTL. Field order comes from
# the coded parity and the display order from 13818-2 6.1.1.11's reorder rule
# (a B displays immediately; an I/P displays the previously delayed anchor).
# Nothing here reads a signal the fix names, so the bench cannot agree with the
# implementation by construction -- the failure mode that kept dvd_vm_ref.py and
# field_parity_tb.sv green through real defects.
#
# ⚠ PAIRING IS vld.v's OWN RULE, replicated deliberately: second_field is preset
# at a sequence/GOP header (vld.v:2344-2348) and toggles at each picture header,
# and hdr_upd_slot (vld.v:2377) fires the picbuf update where it reads 1. That is
# a STRUCTURAL fact about which picture owns a picbuf slot, not a claim about the
# fix -- getting it wrong would mis-pair the fields and the truth would be noise.
#
# VALIDATION IS THE POINT. A cut with no field pictures would make the RED arm
# measure zero and the whole gate vacuous, so --require-field refuses it by
# default and names the flag to move rather than emitting a fixture that passes
# for the wrong reason.
#
# Usage:
#   tools/field_order_fixture.py <iso> --vts 1 --out bench/dvd/test_vobs/field_order
#   tools/field_order_fixture.py <iso> --frac 0.30 --sectors 400 --frame-coded
# =============================================================================
import sys, os, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                                    # noqa: E402
from video_cadence_census import video_payload                   # noqa: E402

SEC = 2048
B_TYPE = 3


def pictures(buf):
    """Walk start codes, replicating vld.v's second_field FSM.

    -> list of dicts for SLOT-OWNING pictures (a frame picture, or a field
    pair's first field) in CODED order: ct (coding type), ps, tff, first_top.
    """
    out = []
    second_field = 1
    i, n = 0, len(buf)
    while i + 4 <= n:
        j = buf.find(b'\x00\x00\x01', i)
        if j < 0 or j + 4 > n:
            break
        code = buf[j + 3]
        if code in (0xB3, 0xB8):                   # sequence / GOP header
            second_field = 1
        elif code == 0x00:                         # picture_start_code
            if j + 6 > n:
                break
            ct = (buf[j + 5] >> 3) & 0x07          # picture_coding_type
            k = buf.find(b'\x00\x00\x01\xb5', j)
            if k < 0 or k + 9 > n:
                i = j + 3
                continue
            e = buf[k + 4:k + 9]
            if (e[0] >> 4) != 0x8:                 # not a picture coding extension
                i = j + 3
                continue
            ps = e[2] & 0x03                       # 1=top 2=bottom 3=frame
            tff = (e[3] >> 7) & 1
            if ps == 3:
                owner = True
                second_field = 0
            else:
                owner = (second_field == 1)
                second_field ^= 1
            if owner:
                # THE SPEC RULE: a frame picture means what tff says; a field
                # picture displays the parity that was coded first.
                out.append({'ct': ct, 'ps': ps, 'tff': tff,
                            'first_top': tff if ps == 3 else (1 if ps == 1 else 0)})
            i = j + 3
            continue
        i = j + 3
    return out


def display_order(pics):
    """13818-2 6.1.1.11: a B displays immediately, an I/P displays the
    previously delayed anchor. Returns pics resequenced for display."""
    out, delayed = [], None
    for p in pics:
        if p['ct'] == B_TYPE:
            out.append(p)
        else:
            if delayed is not None:
                out.append(delayed)
            delayed = p
    if delayed is not None:
        out.append(delayed)
    return out


def cut(nav, sector_at, start, count):
    parts = []
    for k in range(count):
        s = sector_at(start + k)
        if s is None:
            break
        d = video_payload(nav.sec(s))
        if d:
            parts.append(d)
    es = b''.join(parts)
    sh = es.find(b'\x00\x00\x01\xb3')              # must start at a sequence header
    return es[sh:] if sh >= 0 else b''


def die(msg):
    print(f"field_order_fixture: {msg}", file=sys.stderr)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('iso')
    ap.add_argument('--vts', type=int, default=None)
    ap.add_argument('--frac', type=float, default=0.30)
    ap.add_argument('--sectors', type=int, default=400)
    ap.add_argument('--out', required=True)
    ap.add_argument('--frame-coded', action='store_true',
                    help="build the IMMOVABILITY control instead: refuse unless "
                         "the cut is FRAME-coded")
    a = ap.parse_args()

    nav = IsoNav(a.iso)
    vts = a.vts if a.vts is not None else nav.best_vts
    if vts is None or vts not in nav.groups:
        return die("no title VOBs")
    runs = [(ext, dl // SEC) for ext, dl in nav.groups[vts]]
    total = sum(n for _, n in runs)

    def sector_at(idx):
        for ext, n in runs:
            if idx < n:
                return ext + idx
            idx -= n
        return None

    es = cut(nav, sector_at, int(total * a.frac), a.sectors)
    if not es:
        return die("no sequence header in the cut -- move --frac")

    pics = pictures(es)
    if len(pics) < 8:
        return die(f"only {len(pics)} slot-owning pictures -- raise --sectors")

    n_field = sum(1 for p in pics if p['ps'] != 3)
    n_frame = len(pics) - n_field
    n_top = sum(1 for p in pics if p['first_top'])

    if a.frame_coded:
        if n_field:
            return die(f"cut has {n_field} FIELD pictures; --frame-coded wants a "
                       f"frame-coded control (move --frac/--vts)")
    else:
        if n_field < len(pics) * 0.5:
            return die(f"only {n_field}/{len(pics)} pictures are FIELD-coded -- the "
                       f"RED arm would measure ~0 and the gate would be vacuous. "
                       f"Move --vts/--frac, or pass --frame-coded for the control.")
        # A field-coded cut whose pairs are all BOTTOM-first cannot show the
        # defect either: the pre-fix core is accidentally right on those.
        n_topfield = sum(1 for p in pics if p['ps'] != 3 and p['first_top'])
        if n_topfield < n_field * 0.5:
            return die(f"only {n_topfield}/{n_field} field pairs are TOP-first; the "
                       f"pre-fix ordering is accidentally correct here")

    disp = display_order(pics)

    es += b'\x00\x00\x01\xb7' + b'\x00' * 64       # let the last picture commit
    es += b'\x00' * (-len(es) % 8)
    with open(a.out + '.hex', 'w') as fh:
        for i in range(0, len(es), 8):
            fh.write(es[i:i + 8].hex() + '\n')
    with open(a.out + '.truth', 'w') as fh:
        for p in disp:
            fh.write(f"{p['first_top']:08x}\n")
    with open(a.out + '.meta.hex', 'w') as fh:
        for w in (len(disp), n_field, n_top, n_frame):
            fh.write(f"{w & 0xFFFFFFFF:08x}\n")

    print(f"{os.path.basename(a.iso)}  VTS{vts:02d}")
    print(f"  {a.out}.hex    {len(es)} B, {len(pics)} slot-owning pictures")
    print(f"  {a.out}.truth  {len(disp)} displayed  "
          f"field={n_field} frame={n_frame} top-first={n_top} "
          f"({100.0*n_top/len(pics):.1f}%)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
