#!/usr/bin/env python3
"""vcd_fixtures.py — generate the committed VCD/SVCD test fixtures.

Sources (not committed):
  * a real VCD data-track .bin (MODE2/2352) — path in $VCD_TRACK_BIN
    (the LARGE track of a bin/cue rip, usually "Track 2")
  * ffmpeg (for the synthetic SVCD program stream)

Committed outputs (bench/dvd/test_vobs/, $readmemh one byte per line):
  vcd_head.hex           64 raw sectors: track head (pregap, zero-payload Form-2)
                         + the pregap->data transition + the first MPEG packs
  vcd_head.golden.hex    deblocked golden (tools/cd_deblock_ref.py model)
  vcd_mid.hex            64 raw mid-stream sectors (video+audio; exercises the
                         MPEG-1 PES header variants: 0xFF stuffing, STD field,
                         PTS, PTS+DTS, 0x0F no-timestamp)
  vcd_mid.golden.hex     deblocked golden = a flat MPEG-1 system stream (also
                         the ps_demux / full-chain / flat-seek input fixture)
  vcd_mid.ves.hex        golden video ES bytes   (tools/mpeg1_ps_ref.py model)
  vcd_mid.aes.hex        golden audio ES bytes   (track 0 = stream_id 0xC0)
  vcd_mid.vpts.hex       golden video PES PTS values (33-bit, one per line)
  vcd_mid.apts.hex       golden audio PES PTS values
  svcd_slice.hex         synthetic SVCD raw slice: 4 Form-1 "ISO track" sectors
                         + Form-2 sectors wrapping an ffmpeg NTSC-SVCD program
                         stream (480x480 MPEG-2 + MP2 44.1 kHz)
  svcd_slice.golden.hex  deblocked golden (must equal the wrapped PS bytes)

Generation-time cross-checks (fail loudly, nothing committed on failure):
  * mpeg1_ps_ref video/audio ES vs `ffmpeg -c copy` elementary extracts
    (substring match — ffmpeg may trim a leading partial access unit)
  * svcd golden == the exact PS payload that was wrapped

Run from the repo root:  VCD_TRACK_BIN=<track2.bin> tools/vcd_fixtures.py
"""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cd_deblock_ref import deblock, SECTOR  # noqa: E402
import mpeg1_ps_ref  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(REPO, "bench", "dvd", "test_vobs")

HEAD_SECTORS = list(range(0, 8)) + list(range(172, 228))   # 64 total
MID_BASE, MID_N = 50000, 64


def write_hex(name, data):
    path = os.path.join(OUTDIR, name)
    with open(path, "w") as f:
        f.writelines(f"{b:02x}\n" for b in data)
    print(f"  {name}: {len(data)} bytes")


def write_pts(name, values):
    path = os.path.join(OUTDIR, name)
    with open(path, "w") as f:
        f.writelines(f"{v:09x}\n" for v in values)
    print(f"  {name}: {len(values)} entries")


def read_sectors(f, secs):
    out = bytearray()
    for s in secs:
        f.seek(s * SECTOR)
        chunk = f.read(SECTOR)
        assert len(chunk) == SECTOR, f"short read at sector {s}"
        out += chunk
    return bytes(out)


def ffmpeg_es(ps: bytes, kind: str) -> bytes:
    """Demux one elementary stream from a PS with ffmpeg -c copy."""
    fmt = {"v": ("-map", "0:v:0", "-c:v", "copy", "-f", "mpeg1video"),
           "a": ("-map", "0:a:0", "-c:a", "copy", "-f", "mp2")}[kind]
    with tempfile.NamedTemporaryFile(suffix=".mpg") as src, \
         tempfile.NamedTemporaryFile(suffix=".es") as dst:
        src.write(ps)
        src.flush()
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src.name,
                        *fmt, dst.name], check=True)
        return open(dst.name, "rb").read()


def make_vcd():
    src = os.environ.get("VCD_TRACK_BIN", "")
    if not src or not os.path.isfile(src):
        sys.exit("set VCD_TRACK_BIN to a MODE2/2352 VCD data-track .bin")
    with open(src, "rb") as f:
        head = read_sectors(f, HEAD_SECTORS)
        mid = read_sectors(f, range(MID_BASE, MID_BASE + MID_N))

    write_hex("vcd_head.hex", head)
    write_hex("vcd_head.golden.hex", deblock(head))

    mid_ps = deblock(mid)
    assert mid_ps.startswith(b"\x00\x00\x01\xba"), "mid slice must start on a pack"
    write_hex("vcd_mid.hex", mid)
    write_hex("vcd_mid.golden.hex", mid_ps)

    ves, aes, vpts, apts = mpeg1_ps_ref.parse(mid_ps)
    assert ves and aes and vpts and apts, "mid slice lacks A/V/PTS coverage"

    # cross-check vs ffmpeg (it may trim a leading partial access unit / frame)
    fv = ffmpeg_es(mid_ps, "v")
    fa = ffmpeg_es(mid_ps, "a")
    assert fv in ves, "video ES mismatch vs ffmpeg -c copy"
    assert fa in aes, "audio ES mismatch vs ffmpeg -c copy"
    print(f"  cross-check ok: ffmpeg ES contained in model ES "
          f"(v {len(fv)}/{len(ves)}, a {len(fa)}/{len(aes)})")

    write_hex("vcd_mid.ves.hex", ves)
    write_hex("vcd_mid.aes.hex", aes)
    write_pts("vcd_mid.vpts.hex", vpts)
    write_pts("vcd_mid.apts.hex", apts)


def wrap_form2(ps: bytes, submode=0x62):
    """Wrap a program stream into MODE2/2352 Form-2 sectors (VCD/SVCD layout:
    one 2324-byte payload chunk per sector; final chunk zero-padded)."""
    out = bytearray()
    for off in range(0, len(ps), 2324):
        pay = ps[off:off + 2324].ljust(2324, b"\x00")
        sec = bytearray(b"\x00" + b"\xff" * 10 + b"\x00")   # sync
        sec += bytes([0, 2, 0, 2])                          # MSF (dummy) + mode 2
        sec += bytes([0, 0, submode, 0] * 2)                # XA subheader x2
        sec += pay
        sec += b"\x00" * 4                                  # EDC (unchecked)
        assert len(sec) == SECTOR
        out += sec
    return bytes(out)


def form1_sector(fill: int):
    """A Mode-2 Form-1 sector (fake ISO-track content — must be SKIPPED)."""
    sec = bytearray(b"\x00" + b"\xff" * 10 + b"\x00")
    sec += bytes([0, 2, 0, 2])
    sec += bytes([0, 0, 0x00, 0] * 2)                       # submode bit5 clear
    sec += bytes([fill]) * 2048
    sec += b"\x00" * 280                                    # EDC/ECC (unchecked)
    assert len(sec) == SECTOR
    return bytes(sec)


def make_svcd():
    with tempfile.NamedTemporaryFile(suffix=".mpg") as ps_f:
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error",
             "-f", "lavfi", "-i", "testsrc2=size=480x480:rate=30000/1001",
             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
             "-t", "1.2", "-target", "ntsc-svcd", ps_f.name],
            check=True)
        ps = open(ps_f.name, "rb").read()
    ps = ps[: (len(ps) // 2324) * 2324]        # whole payloads only
    assert ps.startswith(b"\x00\x00\x01\xba") and (ps[4] >> 6) == 0b01, \
        "SVCD fixture must be an MPEG-2 program stream"

    raw = b"".join(form1_sector(0x30 + i) for i in range(4)) + wrap_form2(ps)
    golden = deblock(raw)
    assert golden == ps, "SVCD deblock golden must equal the wrapped PS"
    write_hex("svcd_slice.hex", raw)
    write_hex("svcd_slice.golden.hex", golden)


if __name__ == "__main__":
    os.makedirs(OUTDIR, exist_ok=True)
    make_vcd()
    make_svcd()
    print("done")
