#!/usr/bin/env python3
# =============================================================================
# video_cadence_census.py -- is a disc FILM-sourced or VIDEO-sourced?
# =============================================================================
# Complements tools/dvd_census.py, which censuses IFO/nav FEATURES and never
# looks at the video elementary stream. What decides film-vs-video is the
# MPEG-2 picture coding extension, and the core keys on exactly one bit:
#
#   dvd/resample_addrgen.v  det_video : sustained progressive_frame == 0
#                           det_ntsc  : progressive_frame == 1 && rff toggling
#                           det_pal   : sustained progressive_frame == 1
#
# so this tool reads those same fields and reports what the core's detectors
# would conclude. Field offsets are taken from OUR decoder (rtl/mpeg2/vld.v
# STATE_PICTURE_CODING_EXT0: picture_structure @2, tff @4, rff @10,
# progressive_frame @12) rather than from the spec, so the census and the RTL
# cannot drift apart.
#
# WHY IT EXISTS: `Analog Out = Native Fields` (docs/analog_dual_raster.md) only
# shows its benefit on TRUE-INTERLACED (video-sourced) content -- on film the
# derive path is nearly as good. Picking a test disc by intuition ("a concert
# is probably video") is a guess; this measures it.
#
# ★ SAMPLES DEEP, NOT HEADS. The Thayer's Quest diagnosis was derailed for
# rounds because every early ES sample happened to land on frame-coded VOB
# lead-ins while the body of the disc was field-coded. So this walks windows
# spread across the WHOLE title and reports the per-window spread, not just an
# aggregate -- a disc that is 50/50 is telling you something a mean would hide.
#
# Usage:
#   tools/video_cadence_census.py <iso> [<iso> ...]
#   tools/video_cadence_census.py --vts 3 --windows 16 <iso>
#   tools/video_cadence_census.py $DVD_ISO_DIR/*.iso
# =============================================================================
import sys, os, argparse, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav  # noqa: E402

SEC = 2048


def video_payload(sec):
    """Light Program-Stream demux of ONE 2048-byte DVD sector -> video ES bytes.

    Mirrors dvd/ps_demux.sv: pack header is 14 bytes + stuffing (low 3 bits of
    byte 13), then PES packets consumed by their own 16-bit length. Consuming
    nav/padding packets by LENGTH (rather than hunting the next start code) is
    what stops a 00 00 01 pattern inside an NV_PCK payload from desyncing us --
    the same real-VOB robustness fix ps_demux needed.
    """
    if len(sec) < 14 or sec[0:4] != b'\x00\x00\x01\xba':
        return b''
    p = 14 + (sec[13] & 0x07)
    out = []
    while p + 6 <= len(sec):
        if sec[p:p+3] != b'\x00\x00\x01':
            break
        sid = sec[p+3]
        ln = (sec[p+4] << 8) | sec[p+5]
        body = sec[p+6:p+6+ln]
        if len(body) < 3:
            break
        if 0xE0 <= sid <= 0xEF:                      # video PES
            hdl = body[2]                            # PES_header_data_length
            out.append(body[3+hdl:])
        p += 6 + ln
    return b''.join(out)


def scan_pictures(buf, acc):
    """Find picture coding extensions and record the four display flags."""
    i = 0
    n = len(buf)
    while True:
        i = buf.find(b'\x00\x00\x01\xb5', i)
        if i < 0 or i + 9 > n:
            break
        e = buf[i+4:i+9]
        if (e[0] >> 4) != 0x8:                       # not picture_coding_extension
            i += 4
            continue
        pic_struct = e[2] & 0x03                     # vld.v EXT0 offset 2, width 2
        tff        = (e[3] >> 7) & 1                 #            offset 4
        rff        = (e[3] >> 1) & 1                 #            offset 10
        prog_frame = (e[4] >> 7) & 1                 #            offset 12
        acc['n'] += 1
        acc['prog'] += prog_frame
        acc['rff'] += rff
        acc['tff'] += tff
        if pic_struct != 3:
            acc['field_pic'] += 1                    # 1=top,2=bottom,3=frame
        if acc['last_rff'] is not None and rff != acc['last_rff']:
            acc['rff_toggle'] += 1
        acc['last_rff'] = rff
        i += 4


def new_acc():
    return {'n': 0, 'prog': 0, 'rff': 0, 'tff': 0, 'field_pic': 0,
            'rff_toggle': 0, 'last_rff': None}


def census_iso(path, vts_sel=None, windows=12, win_sectors=1200):
    nav = IsoNav(path)
    vts = vts_sel if vts_sel is not None else nav.best_vts
    if vts is None or vts not in nav.groups:
        return None, "no title VOBs"

    # Flatten the VTS's VOB parts into one (lba, nsec) run list.
    runs = [(ext, dl // SEC) for ext, dl in nav.groups[vts]]
    total = sum(n for _, n in runs)
    if total < windows * win_sectors:
        win_sectors = max(200, total // (windows * 2) or 200)

    def sector_at(idx):
        for ext, n in runs:
            if idx < n:
                return ext + idx
            idx -= n
        return None

    per_window = []
    overall = new_acc()
    # Skip the first and last 3%: VOB lead-ins are often frame-coded even on a
    # field-coded disc (the Thayer trap), and the tail is usually credits.
    lo, hi = int(total * 0.03), int(total * 0.97)
    span = max(1, hi - lo)
    for w in range(windows):
        start = lo + (span * w) // windows
        acc = new_acc()
        for k in range(win_sectors):
            s = sector_at(start + k)
            if s is None:
                break
            data = video_payload(nav.sec(s))
            if data:
                scan_pictures(data, acc)
        if acc['n']:
            per_window.append(acc)
            for key in ('n', 'prog', 'rff', 'tff', 'field_pic', 'rff_toggle'):
                overall[key] += acc[key]
    return (vts, total, overall, per_window), None


def verdict(acc):
    n = acc['n']
    if not n:
        return "NO PICTURES", "could not sample any video"
    pf = acc['prog'] / n
    rf = acc['rff'] / n
    tog = acc['rff_toggle'] / n
    if pf < 0.10:
        return "VIDEO (true interlaced)", \
               "det_video engages -> the ideal Native Fields test disc"
    if pf > 0.90 and tog > 0.20:
        return "FILM (3:2 soft telecine)", \
               "det_ntsc engages; Native Fields gains little here"
    if pf > 0.90 and rf < 0.05:
        return "FILM/PROGRESSIVE (25p or 30p)", \
               "sustained progressive_frame; Native Fields gains little"
    if pf > 0.90:
        return "FILM (progressive, irregular rff)", "mostly progressive_frame"
    return "MIXED", "neither detector would sit engaged -- inspect per-window"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('isos', nargs='+')
    ap.add_argument('--vts', type=int, default=None, help="force a VTS number")
    ap.add_argument('--windows', type=int, default=12)
    ap.add_argument('--win-sectors', type=int, default=1200)
    ap.add_argument('--per-window', action='store_true',
                    help="print the per-window spread (the anti-'heads' check)")
    a = ap.parse_args()

    rows = []
    for path in a.isos:
        name = os.path.basename(path)
        try:
            res, err = census_iso(path, a.vts, a.windows, a.win_sectors)
        except Exception as ex:                                  # noqa: BLE001
            print(f"{name:44s}  ERROR: {ex}")
            continue
        if err:
            print(f"{name:44s}  {err}")
            continue
        vts, total, acc, per_window = res
        v, why = verdict(acc)
        n = acc['n'] or 1
        rows.append((name, vts, acc, v, why))
        print(f"{name:44s} VTS{vts:02d} {total*2048//(1024*1024):5d}MB  "
              f"pics={acc['n']:6d}  prog_frame={100*acc['prog']/n:5.1f}%  "
              f"field_pics={100*acc['field_pic']/n:5.1f}%  "
              f"rff={100*acc['rff']/n:5.1f}%  rff_toggle={100*acc['rff_toggle']/n:5.1f}%")
        print(f"{'':44s}   => {v}  ({why})")
        if a.per_window:
            sp = " ".join(f"{100*w['prog']/max(1,w['n']):.0f}" for w in per_window)
            print(f"{'':44s}   per-window prog_frame%%: {sp}")

    if len(rows) > 1:
        print("\n=== Native Fields test candidates (lowest progressive_frame%% first) ===")
        for name, vts, acc, v, _ in sorted(
                rows, key=lambda r: r[2]['prog'] / max(1, r[2]['n'])):
            n = acc['n'] or 1
            print(f"  {100*acc['prog']/n:5.1f}%  {name:44s} {v}")


if __name__ == '__main__':
    main()
