#!/usr/bin/env python3
"""mpeg1_ps_ref.py — golden reference model for ps_demux's MPEG-1 system-stream path.

Mirrors the dvd/ps_demux.sv contract for an MPEG-1 (ISO 11172-1) system stream:

  * pack header 0xBA: marker nibble 0010 -> 12-byte pack (no stuffing-length
    byte).  An MPEG-2 marker (01xxxxxx) selects the DVD path (9 fixed bytes +
    stuffing-length byte) — packs re-latch the stream flavour each time.
  * PES packets: video = stream_id 0xE0 only; audio = 0xC0+track (MP2, whole
    payload passes, no sub-header strip); everything else >= 0xBB is skipped by
    its declared 2-byte length.
  * MPEG-1 PES optional header: 0xFF stuffing* -> optional 2-byte STD buffer
    field (top bits 01) -> 0x2X + 5-byte PTS | 0x3X + 5-byte PTS + 5-byte DTS |
    any other byte (spec: 0x0F) consumed with no timestamp.
  * PTS bit packing (identical to MPEG-2):
      b0[3:1]=pts[32:30]  b1=pts[29:22]  b2[7:1]=pts[21:15]
      b3=pts[14:7]        b4[7:1]=pts[6:0]

parse() returns (video_es, audio_es, vid_pts_list, aud_pts_list) where the pts
lists are the PES-header PTS values in arrival order (the RTL pulses
vid_pts_valid / aud_pts_valid at the same points).
"""


def _pts(b):
    return (((b[0] >> 1) & 7) << 30) | (b[1] << 22) | ((b[2] >> 1) << 15) \
           | (b[3] << 7) | (b[4] >> 1)


def parse(data: bytes, aud_track: int = 0):
    ves = bytearray()
    aes = bytearray()
    vpts = []
    apts = []
    i = 0
    n = len(data)
    mpeg1 = False
    while i + 3 < n:
        if not (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1):
            i += 1
            continue
        sid = data[i + 3]
        i += 4
        if sid == 0xBA:
            if i >= n:
                break
            if (data[i] >> 4) == 0b0010:          # MPEG-1 pack: 8 bytes after BA
                mpeg1 = True
                i += 8
            elif (data[i] >> 6) == 0b01:          # MPEG-2 pack: 9 fixed + stuffing
                mpeg1 = False
                if i + 9 < n:
                    i += 10 + (data[i + 9] & 7)
                else:
                    i = n
            # else: broken marker — resume hunting
            continue
        if sid == 0xB9:                            # program end
            continue
        if sid < 0xBB and sid != 0xBD and not (0xC0 <= sid <= 0xC7) and sid != 0xE0:
            continue                               # video-layer codes: hunt on
        if i + 2 > n:
            break
        plen = (data[i] << 8) | data[i + 1]
        i += 2
        end = min(i + plen, n)
        is_vid = (sid == 0xE0)
        is_aud = (0xC0 <= sid <= 0xC7) and ((sid & 7) == aud_track)
        if not (is_vid or is_aud):
            i = end                                # skip-by-length
            continue
        if mpeg1:
            while i < end and data[i] == 0xFF:     # stuffing
                i += 1
            if i < end and (data[i] >> 6) == 0b01:  # STD buffer field
                i += 2
            if i < end and (data[i] >> 4) == 0b0010:
                if i + 5 <= end:
                    (vpts if is_vid else apts).append(_pts(data[i:i + 5]))
                i += 5
            elif i < end and (data[i] >> 4) == 0b0011:
                if i + 5 <= end:
                    (vpts if is_vid else apts).append(_pts(data[i:i + 5]))
                i += 10                            # PTS + DTS
            else:
                i += 1                             # 0x0F (or junk) — consumed
        else:
            # MPEG-2 optional header: flags1 flags2 hdr_len [header...]
            if i + 3 > end:
                i = end
                continue
            flags2 = data[i + 1]
            hlen = data[i + 2]
            hdr = data[i + 3:i + 3 + hlen]
            if (flags2 >> 7) and len(hdr) >= 5:
                (vpts if is_vid else apts).append(_pts(hdr[0:5]))
            i += 3 + hlen
        if is_vid:
            ves += data[i:end]
        else:
            aes += data[i:end]
        i = end
    return bytes(ves), bytes(aes), vpts, apts


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    v, a, vp, ap = parse(open(sys.argv[1], "rb").read())
    print(f"video ES {len(v)} bytes ({len(vp)} PTS), "
          f"audio ES {len(a)} bytes ({len(ap)} PTS)")
