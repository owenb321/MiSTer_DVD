#!/usr/bin/env python3
# =============================================================================
# cc_scan.py -- line-21 closed-caption (EIA-608 / CEA-708) census over an ISO
# =============================================================================
# DVD-Video carries NTSC line-21 closed captions NOT as subpicture, but as
# MPEG-2 *user data* inside the video elementary stream: a 0x000001B2 block
# attached to each coded picture, holding the two caption bytes that a real
# player re-injects onto line 21 of its analog output.
#
#   00 00 01 B2   user_data_start_code
#   43 43         user_identifier "CC"        <- the DVD/ATSC-A/53 "CC" format
#   01            user_data_type_code
#   F8            caption_block_size
#   bit7 odd_field_first | bit6 filler | bit5:1 cc_count | bit0 extra_field
#   then 2*cc_count caption_field_blocks of 3 bytes:
#        bit7:1 filler 0x7f | bit0 field_odd , cc_byte_1 , cc_byte_2
#
# (Layout per ffmpeg mpeg12dec.c mpeg_decode_user_data. This tool does NOT take
#  it on faith: it VALIDATES the filler bits and the 608 odd-parity of every
#  byte pair, and reports the pass rate, so a disc that uses some other framing
#  shows up as a low-validity signature rather than as silent garbage.)
#
# Our vld currently DISCARDS these blocks -- rtl/mpeg2/vld.v:679,
#   CODE_USER_DATA_START: next = STATE_NEXT_START_CODE
# hunts straight to the next start code. So the bytes are already flowing
# through ps_demux into the decoder and are thrown away at the last moment;
# nothing upstream has to change to get at them.
#
# WHY A SEPARATE SCANNER: dvd_census.py is an IFO/nav oracle and never opens the
# video ES -- captions are invisible to it, exactly as they are invisible to
# libdvdread. This mirrors video_cadence_census.py instead (same sector demux,
# same deep-window sampling), and dvd_census.py --captions calls in here so the
# prevalence table can carry a caption row.
#
# ★ SAMPLES DEEP, NOT HEADS -- the Thayer's Quest trap. Captions also stop and
# start (a feature is captioned; its FBI warning and logos are not), so an
# all-or-nothing answer off the first megabyte is worthless. Windows are spread
# across the whole title and the per-window hit spread is reported.
#
# Usage:
#   tools/cc_scan.py <iso> [<iso> ...]
#   tools/cc_scan.py --text <iso>          # decode a sample of the caption text
#   tools/cc_scan.py --per-window <iso>
#   tools/cc_scan.py --vts 3 --windows 20 <iso>
# =============================================================================
import sys, os, argparse, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                          # noqa: E402
from video_cadence_census import video_payload, SEC    # noqa: E402

# ---- user_identifier signatures -------------------------------------------
SIG_CC   = b'CC'          # 0x4343 -- DVD / A/53 line-21 caption block
SIG_GA94 = b'GA94'        # ATSC A/53: type 0x03 = cc_data (608 *and* 708)
SIG_DTG1 = b'DTG1'        # DVB active-format description (not captions)

# EIA-608 basic character set: ASCII with the documented substitutions.
CC_SPECIAL = {0x2A: 'a', 0x5C: 'e', 0x5E: 'i', 0x5F: 'o', 0x60: 'u',
              0x7B: 'c', 0x7C: '/', 0x7D: 'N', 0x7E: 'n', 0x7F: '#'}


def odd_parity(b):
    """EIA-608 bytes carry odd parity in bit 7."""
    return bin(b).count('1') & 1 == 1


def user_data_blocks(buf):
    """Yield every user_data payload (bytes after 0x000001B2) in an ES buffer.

    user_data runs to the next start code -- 13818-2 forbids 00 00 01 inside it,
    so a plain find() for the terminator is exact, not a heuristic.
    """
    i = 0
    while True:
        i = buf.find(b'\x00\x00\x01\xb2', i)
        if i < 0:
            break
        j = buf.find(b'\x00\x00\x01', i + 4)
        yield buf[i + 4: j if j >= 0 else len(buf)]
        i = (j if j >= 0 else len(buf))


def parse_cc_block(p, acc):
    """Parse one 'CC' user_data payload; append byte pairs to acc. True if valid."""
    if len(p) < 5 or p[0:2] != SIG_CC:
        return False
    acc['cc_blocks'] += 1
    acc['type_code'][p[2]] += 1
    acc['block_size'][p[3]] += 1
    flags = p[4]
    cc_count = (flags >> 1) & 0x1F
    acc['odd_first'] += (flags >> 7) & 1
    acc['extra_field'] += flags & 1
    acc['filler_bit'] += (flags >> 6) & 1        # spec says 0; nonzero = odd framing
    n = 2 * cc_count
    if len(p) < 5 + 3 * n:
        acc['truncated'] += 1
        n = (len(p) - 5) // 3
    ok = True
    for k in range(n):
        m, b1, b2 = p[5 + 3 * k: 8 + 3 * k]
        # marker byte: filler 0x7f in bits 7:1, field-odd in bit 0
        if (m >> 1) != 0x7F:
            acc['bad_marker'] += 1
            ok = False
        fld = m & 1                               # 1 = field 1 (CC1/CC2)
        acc['pairs'] += 1
        acc['field'][fld] += 1
        c1, c2 = b1 & 0x7F, b2 & 0x7F
        if c1 or c2:
            acc['nonnull'] += 1
            # Parity is only meaningful over pairs that carry data: field-2 pad
            # is 0x80 0x80 on most discs but 0x00 0x00 on some (which fails odd
            # parity by construction and would peg the rate at a flat 50%).
            if odd_parity(b1) and odd_parity(b2):
                acc['parity_ok'] += 1
            acc['nonnull_field'][fld] += 1
            # XDS lives in field 2 and opens with a 0x01-0x0F control class
            if fld == 0 and 0x01 <= c1 <= 0x0F:
                acc['xds'] += 1
        if fld == 1:
            acc['stream1'].append((c1, c2))
    return ok


def decode_608_text(pairs, limit=600):
    """Very light EIA-608 field-1 text extraction -- enough to PROVE captions
    are real text and not a structurally-valid all-null carrier. Control codes
    become separators; no roll-up/pop-on state machine is modelled here."""
    out, last = [], None
    for c1, c2 in pairs:
        if c1 == 0 and c2 == 0:
            continue
        if 0x10 <= c1 <= 0x1F:                   # control pair (PAC / midrow / cmd)
            if (c1, c2) == last:                 # 608 doubles every control pair
                last = None
                continue
            last = (c1, c2)
            if out and out[-1] != ' ':
                out.append(' ')
            continue
        last = None
        for c in (c1, c2):
            if c == 0:
                continue
            out.append(CC_SPECIAL.get(c, chr(c) if 0x20 <= c < 0x7F else ''))
        if len(out) > limit:
            break
    return ''.join(out)


def new_acc():
    return {'pics': 0, 'ud_blocks': 0, 'cc_blocks': 0, 'other_sig': collections.Counter(),
            'ga94': 0, 'ga94_cc': 0, 'dtg1': 0,
            'type_code': collections.Counter(), 'block_size': collections.Counter(),
            'odd_first': 0, 'extra_field': 0, 'filler_bit': 0, 'truncated': 0,
            'bad_marker': 0, 'pairs': 0, 'parity_ok': 0, 'nonnull': 0, 'xds': 0,
            'field': collections.Counter(), 'nonnull_field': collections.Counter(),
            'stream1': []}


def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, collections.Counter):
            dst[k].update(v)
        elif isinstance(v, list):
            if len(dst[k]) < 4000:
                dst[k].extend(v)
        else:
            dst[k] += v


def scan_buf(buf, acc):
    # Self-check: a disc reporting zero captions must still prove we SAW video,
    # else a demux miss reads identically to an uncaptioned disc.
    acc['pics'] += buf.count(b'\x00\x00\x01\x00')
    for p in user_data_blocks(buf):
        acc['ud_blocks'] += 1
        if p[0:2] == SIG_CC:
            parse_cc_block(p, acc)
        elif p[0:4] == SIG_GA94:
            acc['ga94'] += 1
            if len(p) > 4 and p[4] == 0x03:      # A/53 user_data_type_code 3
                acc['ga94_cc'] += 1
        elif p[0:4] == SIG_DTG1:
            acc['dtg1'] += 1
        else:
            acc['other_sig'][bytes(p[:4]).hex()] += 1


def scan_iso(path, vts_sel=None, windows=12, win_sectors=1200):
    """Return ((vts, total_sectors, acc, per_window), None) or (None, reason)."""
    nav = IsoNav(path)
    vts = vts_sel if vts_sel is not None else nav.best_vts
    if vts is None or vts not in nav.groups:
        return None, "no title VOBs"

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

    lo, hi = int(total * 0.03), int(total * 0.97)
    span = max(1, hi - lo)
    overall, per_window = new_acc(), []
    for w in range(windows):
        start = lo + (span * w) // windows
        acc = new_acc()
        # Accumulate the window's ES CONTIGUOUSLY before scanning: a CC block is
        # ~40-200 bytes and straddles sector boundaries constantly, so the
        # per-sector scan video_cadence_census.py can afford (9-byte extension)
        # would drop them.
        chunk = []
        for k in range(win_sectors):
            s = sector_at(start + k)
            if s is None:
                break
            d = video_payload(nav.sec(s))
            if d:
                chunk.append(d)
        if chunk:
            scan_buf(b''.join(chunk), acc)
        per_window.append(acc)
        merge(overall, acc)
    return (vts, total, overall, per_window), None


def verdict(acc):
    if acc['pics'] == 0:
        return "NO VIDEO SAMPLED", "demux found no picture start codes -- not a caption result"
    if acc['cc_blocks'] == 0 and acc['ga94_cc'] == 0:
        if acc['ud_blocks'] == 0:
            return "NO CAPTIONS", "no user_data blocks at all in the sampled ES"
        return "NO CAPTIONS", "user_data present but no CC/GA94 caption signature"
    if acc['cc_blocks'] and acc['nonnull'] == 0:
        return "CARRIER ONLY", "CC blocks present but every byte pair is null padding"
    frac = acc['nonnull'] / max(1, acc['pairs'])
    kind = "608 line-21" if acc['cc_blocks'] else "A/53 GA94"
    return ("CAPTIONED (%s)" % kind,
            "%.1f%% of byte pairs carry data" % (100 * frac))


def print_disc(name, res, show_text=False, per_window=False):
    vts, total, acc, wins = res
    v, why = verdict(acc)
    pairs = max(1, acc['pairs'])
    print("%-44s VTS%02d %5dMB  pics=%d ud=%d cc_blk=%d pairs=%d nonnull=%d(%.1f%%)"
          % (name, vts, total * SEC // (1024 * 1024), acc['pics'],
             acc['ud_blocks'], acc['cc_blocks'], acc['pairs'], acc['nonnull'],
             100 * acc['nonnull'] / pairs))
    print("%-44s   => %s  (%s)" % ("", v, why))
    if acc['cc_blocks']:
        print("%-44s   f1=%d f2=%d  parity_ok(nonnull)=%.1f%%  bad_marker=%d  xds=%d  "
              "extra_field=%d  type=%s size=%s"
              % ("", acc['nonnull_field'][1], acc['nonnull_field'][0],
                 100 * acc['parity_ok'] / max(1, acc['nonnull']),
                 acc['bad_marker'], acc['xds'],
                 acc['extra_field'],
                 ",".join("0x%02x" % k for k in acc['type_code']),
                 ",".join("0x%02x" % k for k in acc['block_size'])))
    if acc['ga94'] or acc['dtg1'] or acc['other_sig']:
        extra = []
        if acc['ga94']:
            extra.append("GA94=%d (cc_data=%d)" % (acc['ga94'], acc['ga94_cc']))
        if acc['dtg1']:
            extra.append("DTG1=%d" % acc['dtg1'])
        for sig, n in acc['other_sig'].most_common(3):
            extra.append("other[%s]=%d" % (sig, n))
        print("%-44s   other user_data: %s" % ("", "  ".join(extra)))
    if per_window:
        sp = " ".join(str(w['nonnull']) for w in wins)
        print("%-44s   per-window nonnull pairs: %s" % ("", sp))
    if show_text and acc['stream1']:
        txt = decode_608_text(acc['stream1'])
        if txt.strip():
            print("%-44s   CC1 text sample: %s" % ("", txt[:400]))


def main():
    ap = argparse.ArgumentParser(
        description="Census line-21 (EIA-608) closed captions in DVD video ES.")
    ap.add_argument('isos', nargs='+')
    ap.add_argument('--vts', type=int, default=None, help="force a VTS number")
    ap.add_argument('--windows', type=int, default=12)
    ap.add_argument('--win-sectors', type=int, default=1200)
    ap.add_argument('--per-window', action='store_true')
    ap.add_argument('--text', action='store_true',
                    help="decode a sample of CC1 text (proof the data is real)")
    a = ap.parse_args()

    paths = []
    for p in a.isos:
        if os.path.isdir(p):
            paths += [os.path.join(p, n) for n in sorted(os.listdir(p))
                      if n.lower().endswith('.iso')]
        else:
            paths.append(p)

    hits = 0
    for path in paths:
        name = os.path.basename(path)
        try:
            res, err = scan_iso(path, a.vts, a.windows, a.win_sectors)
        except Exception as ex:                                   # noqa: BLE001
            print("%-44s  ERROR: %s" % (name, ex))
            continue
        if err:
            print("%-44s  %s" % (name, err))
            continue
        print_disc(name, res, a.text, a.per_window)
        if res[2]['nonnull']:
            hits += 1
    print("\n%d/%d disc(s) carry live line-21 captions." % (hits, len(paths)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
