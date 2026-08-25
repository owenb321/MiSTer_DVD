#!/usr/bin/env python3
"""cd_deblock_ref.py — golden reference model for the in-fabric raw-2352 deblocker.

Models dvd/dvd_iso_reader.sv's raw mode BYTE-EXACTLY, including its deliberate
policy deviations from tools/vcd_to_vob.sh:

  * ONLY Mode-2 Form-2 payload bytes pass (window [24, 24+2324) of each sector).
    Form-1 sectors (ISO filesystem track of single-bin images) are skipped
    entirely, as are non-Mode-2 sectors.  Rationale: all VCD/SVCD AV sectors are
    Form 2; passing filesystem bytes could false-sync the PS demux hunter.
  * Zero-payload Form-2 pregap sectors (submode 0x20) pass as zeros — harmless
    to the start-code hunter, and exactly what the RTL does.
  * The stream position is a free-running mod-2352 byte counter (`raw_pos`).
    The per-sector pass flag (`raw_sec_pass`) is latched from the mode byte at
    position 15 and the XA submode byte at position 18 (bit 5 = Form 2), and is
    CLEARED at every wrap 2351->0 — so a stream entered mid-sector (seek, RIFF
    CDXA header skip) drops the partial first sector and starts clean at the
    next sector boundary.

The RTL streams ceil(file_size/2048) 2048-byte blocks; bytes past EOF in the
final partial block are whatever the block server delivers (the framework pads;
testbenches define them).  `deblock()` therefore takes the already-padded byte
buffer, mirroring what the cache write port sees.

Usage as a filter (whole-file convert, e.g. for ffmpeg cross-checks):
    tools/cd_deblock_ref.py <track.bin> <out.mpg> [--start-pos N]

Library use (testbench fixture generation):
    from cd_deblock_ref import deblock
    out = deblock(raw_bytes, start_pos=0)
"""

import sys

SECTOR = 2352
PAY_LO = 24          # payload window [24, 24+2324)
PAY_HI = 24 + 2324


def deblock(data: bytes, start_pos: int = 0) -> bytes:
    """Byte-exact model of the RTL raw-mode filter.

    data      : the byte stream as delivered to the cache write port
                (i.e. the file, padded to a 2048 multiple if you want to model
                the final partial block — pass the raw file for pure sector work)
    start_pos : initial value of the mod-2352 position counter.  0 for a mount
                at file start; (SECTOR - phase) % SECTOR when the stream enters
                `phase` bytes into a sector (seek / RIFF CDXA header skip).
    """
    out = bytearray()
    pos = start_pos % SECTOR
    m2 = False        # raw_m2:      mode byte @15 == 2
    sec_pass = False  # raw_sec_pass: m2 && submode@18 bit5 (Form 2)
    for b in data:
        if pos == 15:
            m2 = (b == 2)
        elif pos == 18:
            sec_pass = m2 and bool(b & 0x20)
        if sec_pass and PAY_LO <= pos < PAY_HI:
            out.append(b)
        if pos == SECTOR - 1:
            pos = 0
            sec_pass = False
        else:
            pos += 1
    return bytes(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    start_pos = 0
    for a in sys.argv[1:]:
        if a.startswith("--start-pos"):
            start_pos = int(a.split("=", 1)[1]) if "=" in a else 0
    if len(args) != 2:
        sys.exit(__doc__)
    data = open(args[0], "rb").read()
    out = deblock(data, start_pos)
    open(args[1], "wb").write(out)
    nsec = len(data) // SECTOR
    print(f"{args[0]}: {nsec} raw sectors in -> {len(out)} payload bytes "
          f"({len(out) // 2324} full Form-2 payloads)")


if __name__ == "__main__":
    main()
