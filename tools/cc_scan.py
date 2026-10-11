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
#   then 2*cc_count + extra_field caption_field_blocks of 3 bytes:
#        bit7:1 filler 0x7f | bit0 "field_odd" , cc_byte_1 , cc_byte_2
#
# (Layout per ffmpeg mpeg12dec.c mpeg_decode_user_data. This tool does NOT take
#  it on faith: it VALIDATES the filler bits and the 608 odd-parity of every
#  byte pair, and reports the pass rate, so a disc that uses some other framing
#  shows up as a low-validity signature rather than as silent garbage.)
#
# ★ THE FIELD IS THE ENTRY'S POSITION, NOT ITS MARKER BIT (issue #166). Entries
# alternate field by field starting on odd_field_first; entry k belongs to
# field 1 iff odd_field_first XOR (k odd). About a fifth of captioned discs
# (161/847 in the 2026-10-10 library sweep, e.g. I_ROBOT, CASTLE_IN_THE_SKY)
# write marker 0xFF on EVERY entry, so the marker bit cannot tell the fields
# apart. Until #166 this tool sorted by the marker and reported such a disc as
# "f1 = every entry, f2 = 0" -- a field-1 count equal to the whole entry count,
# which is impossible, and which the RTL inherited. The report now prints the
# field-1 share and flags anything far from one half.
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


def entry_field(odd_first, k):
    """Field of caption entry k in a block: 1 = field 1 (CC1/CC2).

    Position, not marker -- see the header and docs/closed_captions.md §1. The
    RTL (rtl/mpeg2/vld.v, user_data snoop) implements this same rule; the bench
    golden is generated from here, so the two must stay in step."""
    return odd_first ^ (k & 1)


def parse_cc_block(p, acc):
    """Parse one 'CC' user_data payload; append byte pairs to acc. True if valid."""
    if len(p) < 5 or p[0:2] != SIG_CC:
        return False
    acc['cc_blocks'] += 1
    acc['type_code'][p[2]] += 1
    acc['block_size'][p[3]] += 1
    flags = p[4]
    cc_count = (flags >> 1) & 0x1F
    odd_first = (flags >> 7) & 1
    extra = flags & 1
    acc['odd_first'] += odd_first
    acc['extra_field'] += extra
    acc['filler_bit'] += (flags >> 6) & 1        # spec says 0; nonzero = odd framing
    # 2*cc_count + extra_field entries. The extra entry is real: on 105 of 847
    # captioned discs it carries caption bytes at least once in the sample.
    n = 2 * cc_count + extra
    if len(p) < 5 + 3 * n:
        acc['truncated'] += 1
        n = (len(p) - 5) // 3
    ok = True
    for k in range(n):
        m, b1, b2 = p[5 + 3 * k: 8 + 3 * k]
        # marker byte: filler 0x7f in bits 7:1. Bit 0 is NOT the field (see the
        # header); it is counted only to classify the disc's framing.
        if (m >> 1) != 0x7F:
            acc['bad_marker'] += 1
            ok = False
        fld = entry_field(odd_first, k)           # 1 = field 1 (CC1/CC2)
        acc['marker_field'][m & 1] += 1
        if (m & 1) != fld:
            acc['marker_disagree'] += 1
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
            if extra and k == n - 1:
                acc['extra_data'] += 1
            # XDS lives in field 2 and opens with a 0x01-0x0F control class
            if fld == 0 and 0x01 <= c1 <= 0x0F:
                acc['xds'] += 1
        if fld == 1:
            acc['stream1'].append((c1, c2))
        acc['raw'].append((fld, b1, b2))
    return ok


def framing(acc):
    """'A' = markers follow the position rule (alternate fe/ff), 'B' = markers
    disagree with it (all ff on every disc seen), plus the field-1 share, which
    must be about one half on ANY framing: one entry per displayed field."""
    share = acc['field'][1] / max(1, acc['pairs'])
    if acc['marker_disagree'] == 0:
        kind = 'A'
    elif acc['marker_field'][0] == 0:
        kind = 'B'
    else:
        kind = 'mixed'
    return kind, share


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


# =============================================================================
# RTL fixture writer
# =============================================================================
def write_fixture(path, outdir, vts_sel=None, nblocks=6, start_frac=0.40,
                  name="cc", need_extra_data=False):
    """Carve a small REAL elementary stream carrying CC blocks + its golden pairs.

    The stream is real disc bytes throughout: for each caption block found we keep
    the run from its GOP header (00 00 01 B8) through the end of the user_data, and
    concatenate those runs. That gives the VLD genuine GOP headers to parse and
    genuine user_data to walk, in a few hundred bytes instead of the ~200 KB a
    contiguous multi-GOP capture would cost -- small enough to commit.

    Writes  <name>_es.hex     : 64-bit big-endian words, getbits_fifo's shift order
            <name>_golden.hex : one line per pair, "<field> <b1> <b2>" (hex), the
                                field by POSITION (entry_field), as the RTL must
    need_extra_data: the LAST block must be one whose extra_field entry carries
    caption bytes -- the case the pre-#166 RTL dropped. Such blocks are rare
    (3 in ~14k sectors on CASTLE_IN_THE_SKY), so the carve keeps scanning for one
    rather than hoping start_frac lands on it.
    """
    nav = IsoNav(path)
    vts = vts_sel if vts_sel is not None else nav.best_vts
    runs = [(ext, dl // SEC) for ext, dl in nav.groups[vts]]
    total = sum(n for _, n in runs)

    def sector_at(idx):
        for ext, n in runs:
            if idx < n:
                return ext + idx
            idx -= n
        return None

    chunks, golden = [], []
    start = int(total * start_frac)
    k = 0
    buf = b''
    have_extra = not need_extra_data
    while len(chunks) < nblocks and k < 400000:
        s_ = sector_at(start + k)
        if s_ is None:
            break
        buf += video_payload(nav.sec(s_))
        k += 1
        # scan what we have for complete GOP-header -> end-of-user_data runs
        i = 0
        consumed = 0
        while True:
            g = buf.find(b'\x00\x00\x01\xb8', i)
            if g < 0:
                break
            u = buf.find(b'\x00\x00\x01\xb2', g)
            if u < 0 or u - g > 64:
                i = g + 4
                continue
            e = buf.find(b'\x00\x00\x01', u + 4)
            if e < 0:
                break                                  # need more bytes
            payload = buf[u + 4:e]
            if payload[0:2] == SIG_CC:
                acc = new_acc()
                parse_cc_block(payload, acc)
                # Require live caption bytes: a fixture full of 0x80 0x80 null
                # padding would pass a broken extractor that emitted constants.
                last_slot = len(chunks) == nblocks - 1
                if acc['pairs'] and acc['nonnull'] and (have_extra or not last_slot
                                                        or acc['extra_data']):
                    have_extra = have_extra or acc['extra_data'] > 0
                    chunks.append(buf[g:e])
                    for fld, b1, b2 in acc['raw']:
                        golden.append((fld, b1, b2))
                    if len(chunks) >= nblocks:
                        break
            i = e
            consumed = e
        if consumed:
            buf = buf[consumed:]

    if len(chunks) < nblocks or not have_extra:
        raise SystemExit("only %d/%d caption blocks%s found to build a fixture from"
                         % (len(chunks), nblocks,
                            "" if have_extra else " (none with a data-carrying extra entry)"))

    # sequence_end, then a tail of filler. The tail is not cosmetic: getbits_fifo
    # keeps a 24-bit window and reads whole 64-bit words, so without bytes BEHIND
    # the last caption byte the pipeline starves before it can present it and the
    # final pair of the last block never reaches getbits[23:16]. A real stream
    # always continues; the fixture has to say so.
    es = b''.join(chunks) + b'\x00\x00\x01\xb7' + b'\x00' * 64
    es += b'\x00' * ((-len(es)) % 8)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, name + "_es.hex"), "w") as f:
        for w in range(0, len(es), 8):
            f.write(es[w:w+8].hex() + "\n")
    with open(os.path.join(outdir, name + "_golden.hex"), "w") as f:
        for fld, b1, b2 in golden:
            f.write("%d %02x %02x\n" % (fld, b1, b2))
    f1 = sum(1 for fld, _, _ in golden if fld)
    print("fixture: %d blocks, %d ES bytes, %d golden pairs (%d field 1) -> %s/%s_*.hex"
          % (len(chunks), len(es), len(golden), f1, outdir, name))


def new_acc():
    return {'pics': 0, 'ud_blocks': 0, 'cc_blocks': 0, 'other_sig': collections.Counter(),
            'ga94': 0, 'ga94_cc': 0, 'dtg1': 0,
            'type_code': collections.Counter(), 'block_size': collections.Counter(),
            'odd_first': 0, 'extra_field': 0, 'filler_bit': 0, 'truncated': 0,
            'bad_marker': 0, 'pairs': 0, 'parity_ok': 0, 'nonnull': 0, 'xds': 0,
            'extra_data': 0, 'marker_disagree': 0,
            'field': collections.Counter(), 'nonnull_field': collections.Counter(),
            'marker_field': collections.Counter(),
            'stream1': [], 'raw': []}


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
        kind, share = framing(acc)
        print("%-44s   f1=%d f2=%d  parity_ok(nonnull)=%.1f%%  bad_marker=%d  xds=%d  "
              "extra_field=%d(data %d)  type=%s size=%s"
              % ("", acc['nonnull_field'][1], acc['nonnull_field'][0],
                 100 * acc['parity_ok'] / max(1, acc['nonnull']),
                 acc['bad_marker'], acc['xds'],
                 acc['extra_field'], acc['extra_data'],
                 ",".join("0x%02x" % k for k in acc['type_code']),
                 ",".join("0x%02x" % k for k in acc['block_size'])))
        print("%-44s   framing %s (marker vs position disagree=%d)  field-1 share=%.2f"
              % ("", kind, acc['marker_disagree'], share))
        # One entry per displayed field, alternating: the share is 0.5 to within
        # one extra entry per block. Anything else means the field rule is wrong
        # for this disc -- the #166 symptom read 1.00.
        if abs(share - 0.5) > 0.05:
            print("%-44s   ⚠ field-1 share %.2f is not ~0.5: the field rule does not fit "
                  "this disc's framing" % ("", share))
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
    ap.add_argument('--fixture', metavar='OUTDIR',
                    help="carve an RTL testbench fixture (ES + golden pairs) here")
    ap.add_argument('--fixture-name', default='cc',
                    help="fixture file prefix: <name>_es.hex, <name>_golden.hex")
    ap.add_argument('--fixture-at', type=float, default=0.40,
                    help="where in the title to start carving (fraction)")
    ap.add_argument('--need-extra-data', action='store_true',
                    help="end the fixture on a block whose extra_field entry carries data")
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

    if a.fixture:
        write_fixture(paths[0], a.fixture, a.vts, start_frac=a.fixture_at,
                      name=a.fixture_name, need_extra_data=a.need_extra_data)
        return 0

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
