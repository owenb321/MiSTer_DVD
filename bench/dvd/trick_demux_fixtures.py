#!/usr/bin/env python3
"""trick_demux_fixtures.py <outdir> [iso]

Fixtures for bench/dvd/run_trick_demux.sh (ps_demux's aud_drop, docs/trick_play.md):
  syn.ps / syn.vid   synthetic packs carrying video, MP2 (0xC0), AC-3 (0xBD 0x80) and a
                     subpicture (0xBD 0x20): the expected video ES alongside
  disc.ps / disc.vid the raw sectors of 6 trick-play reads of a real disc (the reader's
                     fetches, tools/trick_splice.py walk) and their video ES
The video ES is tools/trick_scan.py video_es over the same sectors.
"""
import os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools'))
from trick_scan import video_es, title_extents, SEC     # noqa: E402
from trick_splice import walk, TIER_S                   # noqa: E402
from nav_extract import is_nav_pack                      # noqa: E402


def pes(sid, payload, sub=b''):
    """An MPEG-2 PES with a PTS (5 bytes)."""
    body = bytes([0x81, 0x80, 0x05, 0x21, 0x00, 0x01, 0x00, 0x01]) + sub + payload
    return b'\x00\x00\x01' + bytes([sid]) + struct.pack('>H', len(body)) + body


def pack(*pkts):
    """One 2048-byte MPEG-2 pack: header, the packets, then a padding stream."""
    s = b'\x00\x00\x01\xba' + bytes([0x44, 0, 4, 0, 4, 1, 0x01, 0x89, 0xC3, 0xF8])
    for p in pkts:
        s += p
    pad = SEC - len(s) - 6
    assert pad >= 0
    return s + b'\x00\x00\x01\xbe' + struct.pack('>H', pad) + b'\xff' * pad


def synthetic():
    out = b''
    for i in range(8):
        v = bytes((i * 31 + k * 7) & 0xFE | 0x02 for k in range(300))     # no start codes
        out += pack(pes(0xE0, v),
                    pes(0xC0, b'\xff\xfd' + b'\x55' * 200),               # MP2, track 0
                    pes(0xBD, b'\x0b\x77' + b'\x66' * 200, b'\x80\x01\x00\x01'),  # AC-3 0
                    pes(0xBD, b'\x00\x40' + b'\x77' * 100, b'\x20'))     # subpicture 0
    return out


def disc(iso):
    with open(iso, 'rb') as f:
        ext = title_extents(f)
        vts = max(ext, key=lambda v: sum(d for _, d in ext[v]))
        lo = min(e for e, _ in ext[vts])
        hi = max(e + (d + SEC - 1) // SEC for e, d in ext[vts])
        start = lo + int((hi - lo) * 0.3)
        while start < hi:
            f.seek(start * SEC)
            if is_nav_pack(f.read(SEC)):
                break
            start += 1
        out = b''
        # walk() yields each read's video ES; re-read the same sectors raw
        from nav_extract import be32
        from trick_scan import DSI
        for nav, _ in walk(f, lo, hi, start, TIER_S[1], True, 6):
            f.seek(nav * SEC)
            ref = be32(f.read(SEC)[DSI:], 0x0C)
            f.seek(nav * SEC)
            out += f.read((ref + 1) * SEC)
        return out


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    s = synthetic()
    open(os.path.join(d, 'syn.ps'), 'wb').write(s)
    open(os.path.join(d, 'syn.vid'), 'wb').write(video_es(s))
    if len(sys.argv) > 2:
        p = disc(sys.argv[2])
        open(os.path.join(d, 'disc.ps'), 'wb').write(p)
        open(os.path.join(d, 'disc.vid'), 'wb').write(video_es(p))
        print('disc: %d sectors' % (len(p) // SEC))


if __name__ == '__main__':
    main()
