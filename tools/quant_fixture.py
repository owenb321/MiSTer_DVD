#!/usr/bin/env python3
# =============================================================================
# quant_fixture.py -- build the RTL fixture for the quantiser-matrix gate
#                     (bench/dvd/quant_matrix_tb.sv, docs/quant_matrix.md)
#
# The defect: a menu still's sequence header DOWNLOADS a custom quantiser
# matrix, and after a VBUF flush the vld is left mid-picture, resumes in that
# stale state and eats the landing stream's leading bytes -- including
# 00 00 01 B3 and the 128-byte download.  rtl/mpeg2/iquant.v then keeps
# default_values=1 (it clears only on a write to address 0x3F), so the WHOLE
# custom matrix is discarded and the picture is dequantised with the MPEG
# defaults: every AC coefficient 4x to 20.75x too large.
#
# To reproduce that faithfully the bench needs two elementary-stream cuts and
# the ground truth of what the disc actually downloaded:
#
#   <stem>.hex        cut A (title ES) then cut B (a whole menu still) --
#                     64-bit big-endian, one hex word per line, the order
#                     getbits_fifo's shift expects (first byte in [63:56]).
#   <stem>.meta.hex   b_word, pics_a, load_intra, load_non_intra,
#                     cut A's trailing alternate_scan, intra_dc_precision,
#                     q_scale_type, pics_b.
#   <stem>.qmat.hex   the 64 intra values in RASTER order (un-zigzagged with
#                     scan 0, per 13818-2 7.3.1 -- which is the order the
#                     matrix RAM is indexed in).
#   <stem>.qmatn.hex  ditto non-intra, when the header loads one.
#
# VALIDATION IS THE POINT, not a nicety -- same contract as seek_fixture.py.
# A cut B that downloads NO matrix would make the gate vacuous (nothing to
# lose), and a cut A containing 00 00 01 B7 pre-resyncs the vld for free, so
# the flush would have nothing stale to chew.  Both exit 1 naming the flag to
# move, rather than producing a fixture that passes for the wrong reason.
#
# --matrix-probe bit-patches the 64 downloaded bytes of the REAL stream to 64
# DISTINCT values.  Menu matrices are routinely near-flat (Elmo's is 8 then 4
# sixty-three times), and a flat matrix cannot detect a PERMUTATION -- which is
# the second bug here (iquant.v:85 un-zigzags with the live alternate_scan
# instead of scan 0).  It is still real disc bytes with one field substituted,
# and it announces itself loudly.
#
# Usage:
#   tools/quant_fixture.py <iso> [--vts N] [--still-index 0] \
#       [--cut-a-frac 0.30] [--sectors-a 120] [--matrix-probe] \
#       --out bench/dvd/test_vobs/quant_matrix
# =============================================================================
import sys, os, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                       # noqa: E402
from video_cadence_census import video_payload      # noqa: E402
from qmatrix_scan import ZIGZAG, BitReader          # noqa: E402

SEC = 2048


def die(msg):
    print(f"quant_fixture: {msg}", file=sys.stderr)
    return 1


def putbits(buf, pos, n, val):
    """Write n bits MSB-first at BIT offset pos.  The quantiser matrices are
    not byte aligned (they start 63 bits into the sequence header payload), so
    patching them needs a bit-level walk."""
    for k in range(n - 1, -1, -1):
        byte, shift = pos >> 3, 7 - (pos & 7)
        buf[byte] = (buf[byte] & ~(1 << shift)) | (((val >> k) & 1) << shift)
        pos += 1
    return pos


def seq_header_fields(es, j):
    """Parse the sequence header at byte offset j -> dict, or None."""
    try:
        r = BitReader(es, j + 4)
        r.u(12 + 12 + 4 + 4 + 18 + 1 + 10 + 1)
        intra_bit = r.p
        intra = nonintra = None
        if r.u(1):
            zz = [r.u(8) for _ in range(64)]
            intra = [0] * 64
            for k, v in enumerate(zz):
                intra[ZIGZAG[k]] = v
        nonintra_bit = r.p
        if r.u(1):
            zz = [r.u(8) for _ in range(64)]
            nonintra = [0] * 64
            for k, v in enumerate(zz):
                nonintra[ZIGZAG[k]] = v
        return dict(pos=j, intra=intra, nonintra=nonintra,
                    intra_bit=intra_bit + 1, nonintra_bit=nonintra_bit + 1)
    except IndexError:
        return None


def pic_coding_ext(es):
    """-> (n_pictures, last intra_dc_precision, q_scale_type, alternate_scan)."""
    n = idc = qst = alt = 0
    j = 0
    while True:
        j = es.find(b'\x00\x00\x01\xb5', j)
        if j < 0 or j + 8 > len(es):
            break
        if (es[j + 4] >> 4) == 8:                    # picture coding extension
            # Payload byte 2 = {f_code11[4], intra_dc_precision[2],
            # picture_structure[2]}; byte 3 = {tff, frame_pred_frame_dct,
            # concealment_mv, q_scale_type, intra_vlc_format, alternate_scan,
            # rff, chroma_420_type}.  ⚠ alternate_scan is bit 2 of byte 3, not
            # bit 7 -- bit 7 is top_field_first.  Cross-checked against
            # tools/video_cadence_census.py:scan_pictures, which reads tff and
            # rff out of the same byte.
            n += 1
            idc = (es[j + 6] >> 2) & 3
            qst = (es[j + 7] >> 4) & 1
            alt = (es[j + 7] >> 2) & 1
        j += 4
    return n, idc, qst, alt


def menu_still_cuts(es):
    """Split a menu VOB's ES into its individual SEQ..SEQ_END stills."""
    cuts, i = [], 0
    while True:
        s = es.find(b'\x00\x00\x01\xb3', i)
        if s < 0:
            break
        e = es.find(b'\x00\x00\x01\xb7', s)
        if e < 0:
            cuts.append(es[s:])
            break
        cuts.append(es[s:e + 4])
        i = e + 4
    return cuts


def iquant_default_intra():
    """The 64 default intra values in RASTER order, READ OUT OF rtl/mpeg2/iquant.v.

    Restating the table here would be a second copy to go stale -- the
    tools/acmod_scan.py rule: a table that cannot disagree with the RTL beats a
    correct one.  iquant.v's `default_intra_quant` function is indexed by the
    RAM address, which IS raster order, so the values are taken verbatim.
    """
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       '..', 'rtl', 'mpeg2', 'iquant.v')
    tab, seen = [0] * 64, 0
    inside = False
    with open(src) as fh:
        for line in fh:
            if 'function' in line and 'default_intra_quant' in line:
                inside = True
                continue
            if inside:
                if 'endfunction' in line:
                    break
                m = line.split("6'd")
                if len(m) == 2 and '=' in m[1]:
                    idx = int(m[1].split(':')[0])
                    val = int(m[1].split('=')[-1].strip().rstrip(';').split("'d")[-1])
                    tab[idx] = val
                    seen += 1
    if seen != 64:
        raise RuntimeError("iquant.v default_intra_quant: parsed %d/64 entries "
                           "-- the function's shape changed, fix this reader "
                           "rather than hardcoding the table" % seen)
    return tab


def pgcit_pgc(nav, vts, pgcn):
    """-> (abs_byte, parsed pgc) for VTSM PGCN `pgcn` of `vts`."""
    from dvd_vm_ref import DOM_VTSM
    srp = nav.pgcit(DOM_VTSM, vts)
    if not srp or pgcn < 1 or pgcn > len(srp):
        return None, None
    abs_byte = srp[pgcn - 1][1]
    return abs_byte, nav.pgc(abs_byte)


def cell_sectors(nav, abs_byte, pgc, cell):
    """-> (first_sector, last_sector) RBN of one cell (cell_playback_t @8/@20)."""
    import struct as _s
    if cell >= pgc['nr_cells']:
        return None
    e = nav.rd(abs_byte + pgc['cell_off'] + cell * 24, 24)
    return (_s.unpack('>I', e[8:12])[0], _s.unpack('>I', e[20:24])[0])


def build_junction(nav, a):
    """--junction: a MENU->MENU (keep_vbuf) junction cut from two real cells.

    The T2 Mission-Profiles shape: cut A = the tail of a MOTION transition cell
    whose sequence header downloads a custom quantiser matrix and which carries
    NO sequence_end_code; cut B = the still the transition links to, whose own
    header downloads nothing (so a correct decoder ends on the MPEG defaults).

    The variable is --trunc: how many bytes of cut A never reach the decoder.
    That models exactly what the reader drops when a natural menu verdict
    executes with up to 16 KB still sitting in its stream cache.  --trunc 0 is
    the fixed behaviour (the whole cell delivered), and it is the gate.
    """
    vts = a.junction_vts
    a_abs, a_pgc = pgcit_pgc(nav, vts, a.pgc_a)
    b_abs, b_pgc = pgcit_pgc(nav, vts, a.pgc_b)
    if a_pgc is None or b_pgc is None:
        return die(f"VTSM vts={vts} has no PGCN {a.pgc_a}/{a.pgc_b}")
    csa = cell_sectors(nav, a_abs, a_pgc, a.cell_a)
    csb = cell_sectors(nav, b_abs, b_pgc, a.cell_b)
    if csa is None or csb is None:
        return die("cell index out of range for that PGC")
    ext = nav.menu_vob[vts][0]

    # ---- cut A: the transition cell's tail, from its LAST sequence header ----
    es_a_full = b''.join(video_payload(nav.sec(ext + s))
                         for s in range(csa[0], csa[1] + 1))
    hpos = 0 if a.es_out else es_a_full.rfind(b'\x00\x00\x01\xb3')
    if hpos < 0:
        return die("cut A carries no sequence header")
    es_a = es_a_full[hpos:]
    ha = seq_header_fields(es_a, 0)
    if ha is None or ha['intra'] is None:
        return die("cut A's last sequence header downloads NO intra matrix -- "
                   "nothing for the junction to lose, the arm would be vacuous")
    if b'\x00\x00\x01\xb7' in es_a:
        return die("cut A contains a sequence_end_code -- it would resync the "
                   "parser for free and the junction would prove nothing")

    # Keep the header (with its download) + the LAST --tail-pics pictures: the
    # truncation happens at the END, and decoding 220 kB of intervening pictures
    # costs minutes of simulation without touching the measurement.
    picpos, q = [], 0
    while True:
        q = es_a.find(b'\x00\x00\x01\x00', q)
        if q < 0:
            break
        picpos.append(q)
        q += 4
    if len(picpos) < 1:
        return die("cut A has no picture start code")
    if len(picpos) > a.tail_pics and not a.es_out:
        # ⚠ Only for the RTL fixture. A reference decoder must be handed the cell
        # as the hardware sees it: splicing out the middle pictures would itself
        # be a discontinuity, and then the experiment measures the splice.
        head = es_a[:picpos[0]]                       # seq header .. first picture
        es_a = head + es_a[picpos[-a.tail_pics]:]     # .. + the last N pictures
    pics_a = len(picpos) if a.es_out else min(a.tail_pics, len(picpos))
    _, _, _, alt_a = pic_coding_ext(es_a)

    a_full_len = len(es_a)
    if a.trunc:
        if a.trunc >= len(es_a):
            return die(f"--trunc {a.trunc} >= cut A's {len(es_a)} bytes")
        es_a = es_a[:len(es_a) - a.trunc]

    # ---- cut B: the landing still's head (header + the start of its picture) --
    b_want = (csb[1] - csb[0] + 1) if a.es_out else a.b_sectors
    es_b_full = b''.join(video_payload(nav.sec(ext + csb[0] + k))
                         for k in range(min(b_want, csb[1] - csb[0] + 1)))
    s = es_b_full.find(b'\x00\x00\x01\xb3')
    if s < 0:
        return die("cut B carries no sequence header")
    es_b = es_b_full[s:]
    hb = seq_header_fields(es_b, 0)
    if hb is None:
        return die("cut B's sequence header is truncated; raise --b-sectors")
    pics_b, idc_b, qst_b, _ = pic_coding_ext(es_b)

    # ---- ground truth: what a CORRECT decoder ends up holding ----------------
    # The landing downloads a matrix -> that one.  It downloads none (the T2
    # slides) -> the MPEG defaults, because its sequence header pulses
    # quant_rst and iquant.v goes back to default_values=1.  Either way this is
    # a property of the disc, never of the fix.
    if hb['intra'] is not None:
        exp_intra = hb['intra']
        exp_src = "cut B's own download"
    else:
        exp_intra = iquant_default_intra()
        exp_src = "the MPEG defaults (cut B downloads none)"
    exp_nonintra = hb['nonintra'] if hb['nonintra'] is not None else [16] * 64

    if exp_intra == ha['intra']:
        return die("cut A and cut B resolve to the SAME matrix -- the arm could "
                   "not tell a clean junction from a fried one")

    # ---- assemble (cut A then cut B, contiguous: a keep_vbuf hop) ------------
    pad = -len(es_a) % 8
    es_a_p = es_a + b'\x00' * pad
    b_word = len(es_a_p) // 8
    es = bytes(es_a_p) + bytes(es_b)
    es += b'\x00\x00\x01\xb7' + b'\x00' * 64
    es += b'\x00' * (-len(es) % 8)

    with open(a.out + '.hex', 'w') as fh:
        for i in range(0, len(es), 8):
            fh.write(es[i:i + 8].hex() + '\n')
    meta = [b_word, pics_a, 1 if hb['intra'] is not None else 0,
            1 if hb['nonintra'] is not None else 0,
            alt_a, idc_b, qst_b, pics_b]
    with open(a.out + '.meta.hex', 'w') as fh:
        for w in meta:
            fh.write(f"{w & 0xFFFFFFFF:08x}\n")
    with open(a.out + '.qmat.hex', 'w') as fh:
        for v in exp_intra:
            fh.write(f"{v:02x}\n")
    with open(a.out + '.qmatn.hex', 'w') as fh:
        for v in exp_nonintra:
            fh.write(f"{v:02x}\n")
    # cut A's matrix, so a FRIED arm can be classified as "kept the source's
    # matrix" rather than merely "wrong".
    with open(a.out + '.qmata.hex', 'w') as fh:
        for v in ha['intra']:
            fh.write(f"{v:02x}\n")

    print(f"{os.path.basename(a.iso)}  VTSM{vts:02d} "
          f"PGC{a.pgc_a} cell{a.cell_a} -> PGC{a.pgc_b} cell{a.cell_b}")
    print(f"  cut A  RBN {csa[0]}..{csa[1]}  {a_full_len} B kept "
          f"({pics_a} pics, alternate_scan={alt_a}), --trunc {a.trunc} "
          f"-> {len(es_a)} B delivered")
    print(f"  cut B  RBN {csb[0]}..{csb[1]}  {len(es_b)} B ({pics_b} pics)")
    print(f"  expect {exp_src}: DC={exp_intra[0]} peak={max(exp_intra)}; "
          f"cut A's was DC={ha['intra'][0]} peak={max(ha['intra'])}")
    print(f"  {a.out}.hex  {len(es)} B, cut B at word {b_word}")

    if a.es_out:
        # ★ The RTL fixture above answers "what matrix does the hardware hold".
        # These raw streams answer the bigger question -- "is the BITSTREAM the
        # reader hands over actually damaging" -- and they answer it in a decoder
        # that shares no code with ours:
        #
        #   tools/quant_fixture.py <iso> --junction --trunc 300 --es-out /tmp/j
        #   ffmpeg -i /tmp/j_junction.m2v -f image2 -update 1 /tmp/last.png
        #
        # Measured on ULTIMATE_T2 (docs/dvd_menu_refinements.md §9): the landing
        # alone and the WHOLE transition + landing both decode clean, while
        # --trunc 300 reproduces the board's blocky first slide. ⚠ The damage is
        # OFFSET-DEPENDENT -- sweep --trunc, never conclude from one value.
        with open(a.es_out + '_landing.m2v', 'wb') as fh:
            fh.write(bytes(es_b))
        with open(a.es_out + '_junction.m2v', 'wb') as fh:
            fh.write(bytes(es_a) + bytes(es_b))
        print(f"  {a.es_out}_landing.m2v   {len(es_b)} B  (the landing alone)")
        print(f"  {a.es_out}_junction.m2v  {len(es_a) + len(es_b)} B  "
              f"(source minus {a.trunc} B, then the landing)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('iso')
    ap.add_argument('--vts', type=int, default=None)
    ap.add_argument('--cut-a-frac', type=float, default=0.30)
    ap.add_argument('--sectors-a', type=int, default=400)
    ap.add_argument('--still-index', type=int, default=0)
    ap.add_argument('--pics-a', type=int, default=2,
                    help='keep only the first N pictures of cut A (default 8). '
                         'The bench arms its flush a few pictures in, so a long '
                         'cut A is pure simulation time.')
    ap.add_argument('--menu-sectors', type=int, default=700)
    ap.add_argument('--matrix-probe', action='store_true',
                    help='patch the download to 64 DISTINCT values so a '
                         'permutation is detectable (announces itself)')
    ap.add_argument('--out', required=True)
    # ---- --junction: a menu->menu (keep_vbuf) splice from two real cells -----
    ap.add_argument('--junction', action='store_true',
                    help='build a MENU->MENU junction fixture (see build_junction)')
    ap.add_argument('--junction-vts', type=int, default=1)
    ap.add_argument('--pgc-a', type=int, default=14, help='source (transition) PGCN')
    ap.add_argument('--cell-a', type=int, default=1, help='source cell index')
    ap.add_argument('--pgc-b', type=int, default=20, help='landing (still) PGCN')
    ap.add_argument('--cell-b', type=int, default=0, help='landing cell index')
    ap.add_argument('--trunc', type=int, default=0,
                    help='bytes of cut A that never reach the decoder (the '
                         'reader cache the old code dropped). 0 = the fix.')
    ap.add_argument('--tail-pics', type=int, default=2,
                    help='pictures of cut A to keep before the truncation point')
    ap.add_argument('--b-sectors', type=int, default=8,
                    help='sectors of the landing cell to read (its header plus '
                         'the start of its picture is all the arm needs)')
    ap.add_argument('--es-out', default=None, metavar='STEM',
                    help='also write the RAW elementary streams (<STEM>_landing.m2v '
                         'and <STEM>_junction.m2v) so a reference decoder can be '
                         'asked whether the bitstream itself is damaging. Use a '
                         'large --b-sectors so the landing is a whole picture.')
    a = ap.parse_args()

    nav = IsoNav(a.iso)
    if a.junction:
        return build_junction(nav, a)
    vts = a.vts if a.vts is not None else nav.best_menu_vts
    if vts not in nav.menu_vob:
        return die(f"VTS {vts} has no menu VOB; --vts names one of "
                   f"{sorted(nav.menu_vob)}")

    # ---- cut B: a whole menu still ------------------------------------------
    ext, dl = nav.menu_vob[vts]
    nsec = min(a.menu_sectors, max(1, dl // SEC))
    menu_es = b''.join(video_payload(nav.sec(ext + k)) for k in range(nsec))
    stills = menu_still_cuts(menu_es)
    if not stills:
        return die("menu VOB carries no sequence header; --vts / --menu-sectors")
    if a.still_index >= len(stills):
        return die(f"--still-index {a.still_index} but only {len(stills)} stills")
    es_b = bytearray(stills[a.still_index])

    h = seq_header_fields(es_b, 0)
    if h is None:
        return die("cut B's sequence header is truncated; --menu-sectors")
    if h['intra'] is None:
        return die("cut B downloads NO intra quantiser matrix -- the gate would "
                   "be vacuous (nothing to lose). Move --still-index / --vts, or "
                   "pick another disc with tools/qmatrix_scan.py --first-hit")

    if a.matrix_probe:
        # 64 distinct values in ZIGZAG order; a permutation is then visible.
        probe_zz = [((k * 3) % 61) + 2 for k in range(64)]
        seen, uniq = set(), []
        v = 2
        for _ in range(64):                          # force strict distinctness
            while v in seen:
                v += 1
            seen.add(v); uniq.append(v); v += 1
        probe_zz = uniq
        p = h['intra_bit']
        for val in probe_zz:
            p = putbits(es_b, p, 8, val)
        h = seq_header_fields(es_b, 0)
        print("quant_fixture: ⚠ --matrix-probe PATCHED the intra download to 64 "
              "distinct values (real disc bytes, one field substituted)")
    if len(set(h['intra'])) <= 2:
        print("quant_fixture: note -- the download is near-flat "
              f"({len(set(h['intra']))} distinct values), so this fixture cannot "
              "detect a PERMUTATION. Use --matrix-probe for the scan arm.")

    pics_b, idc_b, qst_b, _ = pic_coding_ext(bytes(es_b))
    if pics_b < 1:
        return die("cut B has no picture coding extension")

    # ---- cut A: real title bytes, ending MID-PICTURE -------------------------
    parts = nav.groups.get(nav.best_vts) or []
    if not parts:
        return die("no title VOB to cut A from")
    aext, adl = parts[0]
    start = int((adl // SEC) * a.cut_a_frac)
    es_a = b''.join(video_payload(nav.sec(aext + start + k))
                    for k in range(a.sectors_a))
    sh = es_a.find(b'\x00\x00\x01\xb3')
    if sh < 0:
        return die("cut A has no sequence header; move --cut-a-frac")
    es_a = es_a[sh:]
    if b'\x00\x00\x01\xb7' in es_a:
        return die("cut A contains a sequence_end_code -- that pre-resyncs the "
                   "vld for free, so the flush would have nothing stale to "
                   "chew and the gate would be vacuous. Move --cut-a-frac")
    pics_a, _, _, alt_a = pic_coding_ext(es_a)
    if pics_a < 2:
        return die("cut A carries fewer than 2 pictures; raise --sectors-a")

    # Keep only the first --pics-a pictures, and end MID-PICTURE: leaving the
    # parser inside a picture is exactly the state a flush catches it in, and
    # it is what the stale-state hypothesis needs to be exercised at all.
    picpos, q = [], 0
    while True:
        q = es_a.find(b'\x00\x00\x01\x00', q)
        if q < 0:
            break
        picpos.append(q)
        q += 4
    if not picpos:
        return die("cut A has no picture start code; raise --sectors-a")
    keep = picpos[min(a.pics_a, len(picpos)) - 1]
    es_a = es_a[:keep + 400]
    pics_a = min(a.pics_a, len(picpos))

    # ---- assemble ------------------------------------------------------------
    es_a += b'\x00' * (-len(es_a) % 8)
    b_word = len(es_a) // 8
    es = bytes(es_a) + bytes(es_b)
    es += b'\x00\x00\x01\xb7' + b'\x00' * 64         # let the last picture commit
    es += b'\x00' * (-len(es) % 8)

    with open(a.out + '.hex', 'w') as fh:
        for i in range(0, len(es), 8):
            fh.write(es[i:i + 8].hex() + '\n')

    meta = [b_word, pics_a, 1, 1 if h['nonintra'] else 0,
            alt_a, idc_b, qst_b, pics_b]
    with open(a.out + '.meta.hex', 'w') as fh:
        for w in meta:
            fh.write(f"{w & 0xFFFFFFFF:08x}\n")
    with open(a.out + '.qmat.hex', 'w') as fh:
        for v in h['intra']:
            fh.write(f"{v:02x}\n")
    if h['nonintra']:
        with open(a.out + '.qmatn.hex', 'w') as fh:
            for v in h['nonintra']:
                fh.write(f"{v:02x}\n")

    print(f"{os.path.basename(a.iso)}  menu VTS{vts:02d} still {a.still_index}")
    print(f"  {a.out}.hex       {len(es)} B  (cut A {len(es_a)} B / {pics_a} pics, "
          f"cut B {len(es_b)} B / {pics_b} pics)")
    print(f"  {a.out}.meta.hex  b_word={b_word} intra_dc_precision={idc_b} "
          f"q_scale_type={qst_b} cutA_alternate_scan={alt_a}")
    print(f"  {a.out}.qmat.hex  64 raster values, {len(set(h['intra']))} distinct, "
          f"DC={h['intra'][0]} peak={max(h['intra'])}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
