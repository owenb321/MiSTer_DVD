#!/usr/bin/env python3
"""vcd_timeline.py — header-only timing map of a VCD / SVCD / CD-i Digital Video image.

Prints how a disc's MPEG stream is laid out in time: where each MPEG segment
starts and ends, the first and last video/audio PTS of each, every place the
PTS clock restarts, the audio and video formats per segment, and how far ahead
of the stream clock (SCR) each stream is multiplexed. It exists for issue #188:
a Philips CD-i Digital Video disc plays a ~10 s intro and then restarts both PTS
clocks at the movie, which a single-segment VCD never does.

It reads HEADERS ONLY (pack, PES, sequence and MP2 frame headers) and never
prints or writes picture or sound data, so its output is safe to paste into a
bug report, the same rule tools/dvd_report.py's audit() enforces.

Input, detected from the first bytes:
  * a raw 2352-byte sector image (.bin/.img, Mode 2) — the core's own deblock
    contract: only Mode-2 Form-2 payload bytes [24, 2348) pass
    (tools/cd_deblock_ref.py), so this sees exactly the stream the core sees;
  * a RIFF/CDXA .DAT file (the same sectors behind a 44-byte header);
  * a plain MPEG program/system stream (.mpg, .dat already extracted).

Usage:
    python3 tools/vcd_timeline.py <image.bin> [--json] [--track N]

Needs only Python 3 (no packages); runs on Windows, macOS and Linux.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cd_deblock_ref import SECTOR, PAY_LO, PAY_HI  # noqa: E402
from mpeg1_ps_ref import _pts                       # noqa: E402

SYNC = bytes([0x00] + [0xFF] * 10 + [0x00])
TICK = 90000.0
RESTART_BACK = 90000          # a PTS step back of more than 1 s starts a segment
RESTART_FWD = 10 * 90000      # ... or forward by more than 10 s
CHUNK = 4 << 20

MP2_KBPS = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
MP2_HZ = [44100, 48000, 32000]
MP2_MODE = ["stereo", "joint", "dual", "mono"]
FPS = {1: "23.976", 2: "24", 3: "25", 4: "29.97", 5: "30", 6: "50", 7: "59.94", 8: "60"}


def disc_label(f, raw):
    """The CD-i disc label or ISO 9660 PVD at sector 16 (names and dates only)."""
    if not raw:
        return None
    f.seek(16 * SECTOR)
    sec = f.read(SECTOR)
    if len(sec) < SECTOR:
        return None
    for off in (24, 16):                       # Mode 2 Form 1, then Mode 1
        p = sec[off:off + 2048]
        kind = {b"CD-I ": "CD-i", b"CD001": "ISO 9660"}.get(p[1:6])
        if kind:
            txt = lambda o, n: p[o:o + n].decode("latin1").strip(" \0")  # noqa: E731
            # The CD-i disc label keeps the ISO 9660 PVD's field offsets.
            return {"format": kind, "system": txt(8, 32), "volume": txt(40, 32),
                    "volume_set": txt(190, 128), "publisher": txt(318, 128),
                    "application": txt(574, 128), "created": txt(813, 16)}
    return None


def payload_chunks(f, raw, start):
    """Yield (payload, base, marks): a plain stream gives its file offset as
    base; a raw image gives marks, the (payload offset, sector) of each sector."""
    f.seek(start)
    if not raw:
        pos = start
        while True:
            b = f.read(CHUNK)
            if not b:
                return
            yield b, pos, None
            pos += len(b)
    sec_no = start // SECTOR
    per = CHUNK // SECTOR
    while True:
        blk = f.read(per * SECTOR)
        if len(blk) < SECTOR:
            return
        out = bytearray()
        marks = []                             # (payload offset, sector number)
        for k in range(len(blk) // SECTOR):
            s = blk[k * SECTOR:(k + 1) * SECTOR]
            if s[15] == 2 and (s[18] & 0x20):  # Mode 2 Form 2: the core passes it
                marks.append((len(out), sec_no + k))
                out += s[PAY_LO:PAY_HI]
        sec_no += len(blk) // SECTOR
        if out:
            yield bytes(out), None, marks


class Seg:
    def __init__(self, n, where):
        self.n = n
        self.start = where
        self.end = where
        self.v = []                            # (pts, scr)
        self.a = []
        self.a_untagged = 0
        self.v_untagged = 0
        self.vfmt = set()
        self.afmt = set()
        self.end_codes = 0

    def summary(self):
        def rng(xs):
            if not xs:
                return None
            return [round(xs[0][0] / TICK, 3), round(xs[-1][0] / TICK, 3)]

        def lead(xs):
            d = sorted(p - s for p, s in xs if s is not None
                       and abs(p - s) < 60 * TICK)
            if not d:
                return None
            q = lambda f: round(d[min(len(d) - 1, int(f * len(d)))] / TICK, 3)  # noqa: E731
            return {"min": q(0), "p50": q(0.5), "p99": q(0.99), "max": q(1)}

        return {
            "segment": self.n, "from": self.start, "to": self.end,
            "video_pts": rng(self.v), "audio_pts": rng(self.a),
            "video_pes_with_pts": len(self.v), "video_pes_without": self.v_untagged,
            "audio_pes_with_pts": len(self.a), "audio_pes_without": self.a_untagged,
            "video_format": sorted(self.vfmt), "audio_format": sorted(self.afmt),
            "video_pts_minus_scr_s": lead(self.v), "audio_pts_minus_scr_s": lead(self.a),
            "first_audio_minus_first_video_s":
                round((self.a[0][0] - self.v[0][0]) / TICK, 3)
                if self.a and self.v else None,
            "end_codes": self.end_codes,
        }


def scan(path, aud_track=0):
    f = open(path, "rb")
    head = f.read(64)
    raw = head[:12] == SYNC
    start = 0
    if head[:4] == b"RIFF" and head[8:12] == b"CDXA":
        raw, start = True, 44
    label = disc_label(f, raw and start == 0)
    unit = "sector" if raw else "byte"

    segs = []
    restarts = []
    state = {"seg": None, "scr": None, "last_v": None, "last_a": None,
             "ended": False, "mpeg1": False}

    def seg_for(where, pts, kind):
        """Return the current segment, opening a new one on a restart."""
        cur = state["seg"]
        last = state["last_v"] if kind == "v" else state["last_a"]
        new = cur is None
        if not new and last is not None and pts is not None:
            # 33-bit PTS: a stream that starts just below zero wraps to ~95443 s.
            d = (pts - last + (1 << 32)) % (1 << 33) - (1 << 32)
            if d < -RESTART_BACK or d > RESTART_FWD:
                new = True
        if not new and state["ended"] and pts is not None and kind == "v":
            new = True
        if new:
            if cur is not None:
                restarts.append({
                    "at": where, "stream": "video" if kind == "v" else "audio",
                    "from_s": None if last is None else round(last / TICK, 3),
                    "to_s": None if pts is None else round(pts / TICK, 3),
                    "after_end_code": state["ended"]})
            cur = Seg(len(segs) + 1, where)
            segs.append(cur)
            state.update(seg=cur, last_v=None, last_a=None, ended=False)
        return cur

    carry = b""
    carry_marks = []
    for data, base, marks in payload_chunks(f, raw, start):
        if marks is not None:
            marks = [(o + len(carry), s) for o, s in marks]
        buf = carry + data
        allmarks = carry_marks + (marks or [])
        mi = 0

        def where_of(i):
            nonlocal mi
            if base is not None:
                return base - len(carry) + i
            while mi + 1 < len(allmarks) and allmarks[mi + 1][0] <= i:
                mi += 1
            return allmarks[mi][1] if allmarks else 0

        i = 0
        n = len(buf)
        # Anything that runs past the buffer breaks out and is carried into
        # the next chunk, so a header is never read across a chunk boundary.
        while i < n - 4:
            j = buf.find(b"\x00\x00\x01", i)
            if j < 0:
                i = max(i, n - 3)
                break
            i = j
            if i + 4 > n:
                break
            sid = buf[i + 3]
            if sid == 0xBA:
                if i + 14 > n:
                    break
                b = buf[i + 4]
                if b >> 4 == 0b0010:
                    state["mpeg1"] = True
                    state["scr"] = _pts(buf[i + 4:i + 9])
                    i += 12
                elif b >> 6 == 0b01:
                    state["mpeg1"] = False
                    p = buf[i + 4:i + 10]
                    state["scr"] = ((p[0] >> 3 & 7) << 30 | (p[0] & 3) << 28
                                    | p[1] << 20 | (p[2] >> 3) << 15
                                    | (p[2] & 3) << 13 | p[3] << 5 | p[4] >> 3)
                    i += 14 + (buf[i + 13] & 7)
                else:
                    i += 4
                continue
            if sid == 0xB9:
                state["ended"] = True
                if state["seg"]:
                    state["seg"].end_codes += 1
                i += 4
                continue
            if sid < 0xBB:
                i += 4
                continue
            if i + 6 > n:
                break
            plen = (buf[i + 4] << 8) | buf[i + 5]
            end = i + 6 + plen
            if end > n:
                break
            is_v = sid == 0xE0
            is_a = 0xC0 <= sid <= 0xC7 and (sid & 7) == aud_track
            if not (is_v or is_a):
                i = end
                continue
            k = i + 6
            pts = None
            if state["mpeg1"]:
                while k < end and buf[k] == 0xFF:
                    k += 1
                if k < end and buf[k] >> 6 == 0b01:
                    k += 2
                if k < end and buf[k] >> 4 in (0b0010, 0b0011):
                    pts = _pts(buf[k:k + 5])
                    k += 5 if buf[k] >> 4 == 0b0010 else 10
                else:
                    k += 1
            else:
                if k + 3 <= end:
                    hl = buf[k + 2]
                    if buf[k + 1] >> 7:
                        pts = _pts(buf[k + 3:k + 8])
                    k += 3 + hl
            w = where_of(i)
            seg = seg_for(w, pts, "v" if is_v else "a")
            seg.end = w
            es = buf[k:end]
            if is_v:
                if pts is None:
                    seg.v_untagged += 1
                else:
                    seg.v.append((pts, state["scr"]))
                    state["last_v"] = pts
                q = es.find(b"\x00\x00\x01\xb3")
                if 0 <= q and q + 8 <= len(es):
                    h = es[q + 4:q + 8]
                    seg.vfmt.add("%dx%d@%s" % ((h[0] << 4) | (h[1] >> 4),
                                               ((h[1] & 15) << 8) | h[2],
                                               FPS.get(h[3] & 15, "?")))
                if b"\x00\x00\x01\xb7" in es:
                    state["ended"] = True
                    seg.end_codes += 1
            else:
                if pts is None:
                    seg.a_untagged += 1
                else:
                    seg.a.append((pts, state["scr"]))
                    state["last_a"] = pts
                q = 0
                while True:
                    q = es.find(b"\xff", q)
                    if q < 0 or q + 4 > len(es):
                        break
                    h1, h2, h3 = es[q + 1], es[q + 2], es[q + 3]
                    br, sr = h2 >> 4, (h2 >> 2) & 3
                    # MPEG-1 Layer II, confirmed by the next frame's header so a
                    # stray 0xFF in the sound data never reads as a format.
                    if (h1 & 0xF6) == 0xF4 and 0 < br < 15 and sr < 3:
                        flen = 144000 * MP2_KBPS[br] // MP2_HZ[sr] + ((h2 >> 1) & 1)
                        nxt = es[q + flen:q + flen + 3]
                        if len(nxt) == 3 and nxt[0] == 0xFF and nxt[1] == h1 \
                                and nxt[2] >> 2 == h2 >> 2:
                            seg.afmt.add("MP2 %dk %d Hz %s" % (
                                MP2_KBPS[br], MP2_HZ[sr], MP2_MODE[h3 >> 6]))
                            break
                    q += 1
            i = end
        carry = buf[i:]
        carry_marks = [(o - i, s) for o, s in allmarks if o >= i] or \
            ([(0, allmarks[-1][1])] if allmarks else [])

    return {"file": os.path.basename(path), "unit": unit, "label": label,
            "segments": [s.summary() for s in segs], "restarts": restarts}


def show(r):
    print("file   ", r["file"])
    lab = r["label"]
    if lab:
        print("label  ", ", ".join("%s=%s" % (k, v) for k, v in lab.items() if v))
    print("%d MPEG segment(s), %d PTS restart(s); positions are %ss"
          % (len(r["segments"]), len(r["restarts"]), r["unit"]))
    for s in r["segments"]:
        print("\nsegment %d: %s %d .. %d" % (s["segment"], r["unit"], s["from"], s["to"]))
        for k in ("video_pts", "audio_pts", "first_audio_minus_first_video_s",
                  "video_format", "audio_format", "video_pts_minus_scr_s",
                  "audio_pts_minus_scr_s", "end_codes"):
            print("  %-34s %s" % (k, s[k]))
        print("  %-34s %d with PTS, %d without / %d with, %d without"
              % ("video PES / audio PES", s["video_pes_with_pts"], s["video_pes_without"],
                 s["audio_pes_with_pts"], s["audio_pes_without"]))
    for x in r["restarts"]:
        print("\nrestart at %s %d: %s PTS %s s -> %s s%s"
              % (r["unit"], x["at"], x["stream"], x["from_s"], x["to_s"],
                 " (after an end code)" if x["after_end_code"] else ""))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    track = 0
    if "--track" in sys.argv:
        track = int(sys.argv[sys.argv.index("--track") + 1])
        args = [a for a in args if a != str(track)]
    r = scan(args[0], track)
    if "--json" in sys.argv:
        print(json.dumps(r, indent=1))
    else:
        show(r)


if __name__ == "__main__":
    main()
