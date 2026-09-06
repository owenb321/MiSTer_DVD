#!/usr/bin/env python3
# =============================================================================
# pts_map.py -- the golden model for PTS -> picture association.
# =============================================================================
# The MPEG rule (13818-1 2.4.3.7): a PES packet's PTS belongs to the first
# access unit (picture) whose start code lies at or after the first byte of
# that PES packet's payload. The core implements this by BYTE POSITION: the
# demux marks the first payload byte of every PTS-bearing video PES, that byte's
# position in the elementary stream is stamped beside the PTS, and the VLD tags
# the first picture start code it parses at or past the stamp.
#
# This tool walks a Program Stream the same way dvd/ps_demux.sv does and writes
# a simulation fixture:
#
#   STEM.hex          the video ES as 64-bit words, starting at a sequence header
#   STEM.marks.hex    one line per PTS-bearing video PES: {es_offset, pts}
#   STEM.golden.hex   one line per picture start code, in CODED order:
#                       {es_offset[31:0], pts_valid, second_field, pts[32:0]}
#
# es_offset is the byte offset OF THE START CODE PREFIX (00 00 01 00) within
# STEM.hex. The bench derives the same number from getbits_fifo's bit position
# and the two must agree exactly; anything else means the RTL is not counting
# every bit that moved.
#
# It reads either a DVD ISO (the largest VTS unless --vts, a contiguous sector
# window like tools/film_evidence_probe.py) or a raw Program Stream file
# (.VOB/.mpg) with --file, so both once-per-VOBU DVD muxes and per-picture
# ffmpeg muxes can be cut. MPEG-1 system streams (VCD) are not handled here.
#
# Usage:
#   tools/pts_map.py <iso> [--vts N] [--start-frac F] [--sectors N] --cut STEM
#   tools/pts_map.py --file clip.VOB [--skip BYTES] [--bytes N] --cut STEM
#   tools/pts_map.py <iso|--file f> --stats     # PTS density report only
# =============================================================================
import sys, os, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

SEC = 2048


def walk_ps(buf):
    """Program Stream -> (es_bytes, marks). marks = [(es_offset, pts)] for every
    video PES that carried a PTS; es_offset is the offset of that PES's first
    payload byte in the concatenated ES. Mirrors ps_demux: packs by stuffing
    length, PES packets by their 16-bit length, nothing else hunted."""
    es, marks = [], []
    es_len = 0
    p = 0
    n = len(buf)
    while p + 4 <= n:
        i = buf.find(b'\x00\x00\x01', p)
        if i < 0 or i + 4 > n:
            break
        sid = buf[i + 3]
        if sid == 0xBA:                                   # pack header
            if i + 14 > n:
                break
            p = i + 14 + (buf[i + 13] & 0x07)
            continue
        if sid == 0xB9:                                   # MPEG program end
            break
        if i + 6 > n:
            break
        ln = (buf[i + 4] << 8) | buf[i + 5]
        body = buf[i + 6:i + 6 + ln]
        p = i + 6 + ln
        if not (0xE0 <= sid <= 0xEF) or len(body) < 3:
            continue
        flags = body[1]
        hdl = body[2]
        payload = body[3 + hdl:]
        if (flags & 0x80) and hdl >= 5:                   # PTS present
            b = body[3:8]
            pts = (((b[0] >> 1) & 0x07) << 30) | (b[1] << 22) | ((b[2] >> 1) << 15) \
                  | (b[3] << 7) | (b[4] >> 1)
            if payload:
                marks.append((es_len, pts))
            # a PTS on a PES with no payload marks nothing (ps_demux: S_HUNT)
        es.append(payload)
        es_len += len(payload)
    return b''.join(es), marks


def picture_starts(es):
    """Every picture start code, in coded order: (offset, second_field)."""
    pics = []
    i = es.find(b'\x00\x00\x01\x00')
    while i >= 0:
        second = 0
        # picture_structure lives in the coding extension that follows
        j = es.find(b'\x00\x00\x01', i + 4)
        while j >= 0 and j + 4 <= len(es) and es[j + 3] == 0xB5:
            if (es[j + 4] >> 4) == 0x8 and j + 7 <= len(es):
                second = 1 if (es[j + 6] & 0x03) == 2 else 0  # bottom field, i.e. 2nd of a top-first pair
                break
            j = es.find(b'\x00\x00\x01', j + 4)
        pics.append((i, second))
        i = es.find(b'\x00\x00\x01\x00', i + 4)
    return pics


def assign(pics, marks):
    """The MPEG rule: each mark tags the first picture start at/after it; a
    picture takes the LATEST mark at or before it that no earlier picture
    consumed. Returns [(offset, pts_or_None, second)]. Note picture_structure 2
    is only a hint for 'second field' when the pair is top-first; the RTL uses
    second_field from the vld, and the bench checks the tag, not the parity."""
    out = []
    mi = 0
    pending = None                       # latest unconsumed mark <= this offset
    for off, second in pics:
        while mi < len(marks) and marks[mi][0] <= off:
            pending = marks[mi][1]       # a later mark supersedes an unconsumed one
            mi += 1
        out.append((off, pending, second))
        pending = None
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('iso', nargs='?')
    ap.add_argument('--file', default=None, help="raw Program Stream instead of an ISO")
    ap.add_argument('--skip', type=int, default=0, help="--file: bytes to skip first")
    ap.add_argument('--bytes', type=int, default=2 * 1024 * 1024, help="--file: bytes to read")
    ap.add_argument('--vts', type=int, default=None)
    ap.add_argument('--start-frac', type=float, default=0.0)
    ap.add_argument('--sectors', type=int, default=240)
    ap.add_argument('--cut', default=None, metavar='STEM')
    ap.add_argument('--stats', action='store_true')
    a = ap.parse_args()

    if a.file:
        with open(a.file, 'rb') as fh:
            fh.seek(a.skip)
            buf = fh.read(a.bytes)
        # start on a pack boundary so the walk does not begin mid-PES
        i = buf.find(b'\x00\x00\x01\xba')
        buf = buf[i:] if i >= 0 else b''
        src = os.path.basename(a.file)
    elif a.iso:
        from dvd_vm_ref import IsoNav
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
        start = int(total * a.start_frac)
        secs = []
        for k in range(a.sectors):
            s = sector_at(start + k)
            if s is None:
                break
            secs.append(nav.sec(s))
        buf = b''.join(secs)
        src = f"{os.path.basename(a.iso)} VTS{vts:02d} sectors {start}..{start + len(secs)}"
    else:
        ap.error("give an ISO or --file")

    es, marks = walk_ps(buf)
    if not es:
        print("no video ES found")
        return 1

    # Start the cut at the first PTS-bearing PES whose payload begins with a
    # sequence header, so (a) the vld's sequence_header_seen is satisfied from
    # byte 0 and (b) the first mark sits at offset 0 -- no stamp lies before the
    # cut. DVD VOBUs start exactly this way; ffmpeg muxes usually do too.
    origin = None
    for off, _ in marks:
        if es[off:off + 4] == b'\x00\x00\x01\xb3':
            origin = off
            break
    if origin is None:
        print("no PTS-bearing PES starting on a sequence header in this window")
        return 1
    es = es[origin:]
    marks = [(o - origin, pts) for o, pts in marks if o >= origin]
    pics = picture_starts(es)
    gold = assign(pics, marks)

    n_tag = sum(1 for _, pts, _ in gold if pts is not None)
    if a.stats or not a.cut:
        print(f"{src}: {len(es)} B ES, {len(marks)} PTS marks, {len(pics)} pictures, "
              f"{n_tag} tagged ({len(es) // max(1, len(marks))} B/PTS)")
        if not a.cut:
            return 0

    es_p = es + b'\x00' * (-len(es) % 8)
    with open(a.cut + '.hex', 'w') as fh:
        for i in range(0, len(es_p), 8):
            fh.write(es_p[i:i + 8].hex() + '\n')
    with open(a.cut + '.marks.hex', 'w') as fh:
        for off, pts in marks:
            fh.write(f"{(off << 40) | pts:018x}\n")
    with open(a.cut + '.golden.hex', 'w') as fh:
        for off, pts, second in gold:
            v = (off << 40) | ((1 if pts is not None else 0) << 39) | (second << 38) \
                | (pts if pts is not None else 0)
            fh.write(f"{v:018x}\n")
    print(f"  {a.cut}.hex         {len(es)} B of video ES ({src})")
    print(f"  {a.cut}.marks.hex   {len(marks)} PTS marks")
    print(f"  {a.cut}.golden.hex  {len(pics)} pictures, {n_tag} tagged")
    if n_tag == 0 or n_tag == len(pics) and len(pics) > 1 and len(marks) == len(pics):
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
