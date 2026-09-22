#!/usr/bin/env python3
"""cdda_toc_ref.py — golden model for the CD-DA track table (dvd/cdda_toc.sv).

ONE model, both sides. The Main builds this blob from a real TOC
(main/support/dvd/dvd_cdda.cpp) and the core parses it back
(dvd/cdda_toc.sv); this file is the independent statement of the wire format
that neither of them can quietly drift away from, plus the expected
track-lookup answers the testbench scores against.

⚠ It is written from the FORMAT, not from either implementation. A model
derived from the RTL agrees with the RTL by construction and proves nothing —
that is exactly how tools/dvd_vm_ref.py sat agreeing with a real navigation bug
for months (CLAUDE.md, POST-only PGC dispatch).

  usage: tools/cdda_toc_ref.py <outdir>
"""

import os
import struct
import sys

MAGIC = b"CDTC"
VERSION = 1
HDR = 44           # the synthetic WAV header the Main prepends
RAW = 2352         # one CD frame
BLK = 2048         # one sd block


def build_blob(track_starts, total_blocks):
    """The exact bytes the Main sends over the ioctl-download channel."""
    b = bytearray()
    b += MAGIC
    b += bytes([VERSION, len(track_starts), 0, 0])
    b += struct.pack('<I', total_blocks)
    for s in track_starts:
        b += struct.pack('<I', s)
    return bytes(b)


def image_layout(tracks):
    """tracks = [(lba, len_sectors), ...] -> (starts_in_blocks, total_blocks).

    Audio sectors are concatenated behind the 44-byte header, so track i's first
    audio byte is at 44 + vsec_i*2352 and its block is that divided by 2048.
    """
    starts, vsec = [], 0
    for _lba, n in tracks:
        starts.append((HDR + vsec * RAW) // BLK)
        vsec += n
    total_bytes = HDR + vsec * RAW
    total_blocks = (total_bytes + BLK - 1) // BLK
    return starts, total_blocks


def lookup(starts, total_blocks, blk):
    """Which 1-based track is block `blk` in? 0 = outside the table."""
    for i, s in enumerate(starts):
        hi = starts[i + 1] if i + 1 < len(starts) else total_blocks
        if s <= blk < hi:
            return i + 1
    return 0


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 1
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)

    # A disc shaped like the maintainer's: 4 audio tracks, gaps between them on
    # disc, ~42 minutes. The gaps matter -- they are why the virtual layout is
    # not just the disc layout shifted.
    tracks = [(37, 53805), (53992, 48100), (102242, 26488), (128730, 61737)]
    starts, total = image_layout(tracks)
    blob = build_blob(starts, total)

    open(os.path.join(out, 'toc.bin'), 'wb').write(blob)
    with open(os.path.join(out, 'toc.hex'), 'w') as f:
        for x in blob:
            f.write(f'{x:02x}\n')

    # Expected lookups, including every boundary -- an off-by-one at a track
    # edge is the defect this table exists to avoid.
    probes = []
    for i, s in enumerate(starts):
        hi = starts[i + 1] if i + 1 < len(starts) else total
        probes += [s, s + 1, hi - 1]
    probes += [0, total - 1]
    probes = sorted(set(p for p in probes if 0 <= p < total))

    with open(os.path.join(out, 'probes.hex'), 'w') as f:
        for p in probes:
            f.write(f'{p:08x} {lookup(starts, total, p):02x}\n')

    with open(os.path.join(out, 'toc.meta'), 'w') as f:
        f.write(f'{len(starts)} {total} {len(blob)} {len(probes)}\n')

    print(f'  {len(starts)} tracks, total {total} blocks, blob {len(blob)} bytes')
    for i, s in enumerate(starts):
        hi = starts[i + 1] if i + 1 < len(starts) else total
        print(f'   track {i+1}: blocks {s}..{hi-1}  ({(hi-s)*BLK/176400:.0f} s)')
    print(f'  {len(probes)} lookup probes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
