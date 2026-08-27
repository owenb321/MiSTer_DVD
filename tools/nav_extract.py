#!/usr/bin/env python3
# nav_extract.py - extract + decode DVD NAV packs (PCI/HLI) from a menu VOB
# inside a DVD-Video ISO, and emit RTL test fixtures.
#
# Phase-3 disc menus (button highlights): dvd/nav_pci.sv consumes the PCI
# packet of each NAV pack (private_stream_2 0xBF, substream 0x00) and arms the
# HLI (highlight information) so the renderer can draw the selected button's
# rectangle and the gamepad can walk the button link graph. This tool is the
# golden reference: it walks the ISO the same way dvd_iso_reader does (root
# dir -> VIDEO_TS -> VTS_xx_0.VOB), scans the menu VOB for NAV packs, decodes
# every PCI/HLI field the RTL uses, and can dump raw NAV sectors as a $readmemh
# fixture for bench/dvd/nav_pci_tb.sv / ps_demux PS2 routing tests.
#
# Layout cross-checked against libdvdread nav_types.h / nav_read.c (fetched
# 2026-07-07). All offsets are relative to the PCI DATA start (the byte after
# the 0x00 substream id):
#   pci_gi @0x00: nv_pck_lbn@0, vobu_s_ptm@0x0C, vobu_e_ptm@0x10 (BE u32)
#   hli    @0x60:
#     hl_gi:  hli_ss u16@0x60 (low 2 bits: 0=no buttons 1=new 2=equal 3=equal
#             except cmds), hli_s_ptm@0x62, hli_e_ptm@0x66, btn_se_e_ptm@0x6A,
#             btn_md@0x6E-0x6F (btngr_ns = bits[5:4] of 0x6E), btn_ofn@0x70,
#             btn_ns@0x71 (low 6), nsl_btn_ns@0x72, fosl_btnn@0x74, foac_btnn@0x75
#     btn_coli @0x76: 3 groups x {sl_coli u32, ac_coli u32}; each u32 =
#             [Ci3 Ci2 Ci1 Ci0 A3 A2 A1 A0] nibbles (palette idx + alpha per
#             subpicture pixel class 3..0)
#     btni  @0x8E: 36 x 18 B:
#             b0-2:  btn_coln[1:0] x_start[9:0] zz x_end[9:0]
#             b3-5:  auto_action[1:0] y_start[9:0] zz y_end[9:0]
#             b6-9:  zz+up[5:0], zz+down, zz+left, zz+right (button numbers)
#             b10-17: 8-byte VM command (executed on activate)
#     (HLI ends @0x316; PCI data is 980 bytes total)
#
#   python3 tools/nav_extract.py disc.iso --vts 2            # dump VTS_02 menu HLI
#   python3 tools/nav_extract.py disc.iso --vts 2 --sector 6836  # start RBN
#   python3 tools/nav_extract.py disc.iso --vts 2 --hex out.hex --hex-count 4
import sys, struct, argparse

sys.path.insert(0, __import__('os').path.dirname(__file__))
from iso_nav_check import decode_vmcmd     # faithful vmcmd.c port


def walk_dir(f, dlba, dlen):
    nsec = (dlen + 2047) // 2048
    f.seek(dlba * 2048)
    buf = f.read(nsec * 2048)
    out = []
    for s in range(nsec):
        p = s * 2048
        while p < s * 2048 + 2048:
            rl = buf[p]
            if rl == 0:
                break
            ext = struct.unpack('<I', buf[p+2:p+6])[0]
            dl  = struct.unpack('<I', buf[p+10:p+14])[0]
            nl  = buf[p+32]
            nm  = buf[p+33:p+33+nl]
            out.append((nm.upper(), ext, dl))
            p += rl
    return out


def find_menu_vob(f, vts):
    f.seek(16 * 2048)
    pvd = f.read(2048)
    assert pvd[1:6] == b'CD001' and pvd[0] == 1, "not an ISO9660 image"
    root_lba = struct.unpack('<I', pvd[158:162])[0]
    root_len = struct.unpack('<I', pvd[166:170])[0]
    vdir = None
    for nm, ext, dl in walk_dir(f, root_lba, root_len):
        if nm.startswith(b'VIDEO_TS'):
            vdir = (ext, dl)
    assert vdir, "no VIDEO_TS"
    want = b'VTS_%02d_0.VOB' % vts if vts else b'VIDEO_TS.VOB'
    for nm, ext, dl in walk_dir(f, *vdir):
        if nm.startswith(want):
            return ext, dl
    raise SystemExit("menu VOB %s not found" % want.decode())


def find_title_vob(f, vts, part=1):
    """Locate a TITLE VOB (VTS_xx_<part>.VOB, part>=1) - the multiplexed
    program stream with the actual A/V + NAV packs, as opposed to the _0 menu
    VOB. Used to reach the Phase-9 multi-angle interleaved blocks."""
    f.seek(16 * 2048)
    pvd = f.read(2048)
    assert pvd[1:6] == b'CD001' and pvd[0] == 1, "not an ISO9660 image"
    root_lba = struct.unpack('<I', pvd[158:162])[0]
    root_len = struct.unpack('<I', pvd[166:170])[0]
    vdir = None
    for nm, ext, dl in walk_dir(f, root_lba, root_len):
        if nm.startswith(b'VIDEO_TS'):
            vdir = (ext, dl)
    assert vdir, "no VIDEO_TS"
    want = b'VTS_%02d_%d.VOB' % (vts, part)
    for nm, ext, dl in walk_dir(f, *vdir):
        if nm.startswith(want):
            return ext, dl
    raise SystemExit("title VOB %s not found" % want.decode())


def find_vts_ifo(f, vts):
    """Locate a VTS_xx_0.IFO (the VTSI file whose first sector is VTSI_MAT).
    Returns its start LBA. Phase-10 audio/subpicture stream-attribute parse."""
    f.seek(16 * 2048)
    pvd = f.read(2048)
    assert pvd[1:6] == b'CD001' and pvd[0] == 1, "not an ISO9660 image"
    root_lba = struct.unpack('<I', pvd[158:162])[0]
    root_len = struct.unpack('<I', pvd[166:170])[0]
    vdir = None
    for nm, ext, dl in walk_dir(f, root_lba, root_len):
        if nm.startswith(b'VIDEO_TS'):
            vdir = (ext, dl)
    assert vdir, "no VIDEO_TS"
    want = b'VTS_%02d_0.IFO' % vts
    for nm, ext, dl in walk_dir(f, *vdir):
        if nm.startswith(want):
            return ext
    raise SystemExit("VTS IFO %s not found" % want.decode())


def be32(b, o): return struct.unpack('>I', b[o:o+4])[0]
def be16(b, o): return struct.unpack('>H', b[o:o+2])[0]


# ---- Seamless-branch interleaved-block (ILVU) golden predictor ----------------
# Matrix "Follow the White Rabbit" chapters and T2 Ultimate extended scenes are
# authored as interleaved blocks with the PGC cell category `interleaved` bit
# (byte0 bit 2) set, block_mode=0/block_type=0 (NOT the multi-angle block_type==1
# encoding). This branch's ILVUs interleave physically with sibling-branch ILVUs
# inside the cell's [first..last] range; reading it linearly plays the sibling
# ILVUs too = "skipping". The correct branch is followed by chasing
# vobu_sri.next_vobu, which at each BLOCK|LAST VOBU jumps PAST the sibling ILVU to
# this branch's next ILVU (libdvdnav's default vobu_next path; NO sml_agli).
#
# This is the golden reference for dvd/dvd_iso_reader.sv (cc_interleaved /
# seamless_active snoop->arm->jump) and bench/dvd/iso_reader_ilvu_tb.sv.
def _dsi_fields(sec):
    """Return (is_nav, category, vobu_ea, next_vobu) from a 2048-B sector's DSI."""
    isnav = sec[0x400:0x404] == b'\x00\x00\x01\xbf' and sec[0x406] == 0x01
    if not isnav:
        return False, 0, 0, 0
    cat  = be16(sec, 0x427)     # sml_pbi.category (DSI-rel 0x20)
    ea   = be32(sec, 0x40F)     # dsi_gi.vobu_ea   (DSI-rel 0x08)
    nxt  = be32(sec, 0x541)     # vobu_sri.next_vobu (DSI-rel 0x13A)
    return True, cat, ea, nxt


def dump_ilvu(f, vts):
    """Follow each interleaved cell's next_vobu chain in PGCN 1, printing the
    played ILVU sequence and the skipped sibling ranges - the exact sector walk
    the RTL performs. Mirrors iso_nav_check.py's PGC cell parse (all BIG-ENDIAN)."""
    ifo_lba = find_vts_ifo(f, vts)
    f.seek(ifo_lba * 2048); mat = f.read(2048)
    vts_pgcit = be32(mat, 204)
    pgcit_abs = (ifo_lba + vts_pgcit) * 2048
    f.seek(pgcit_abs); pgcit = f.read(2048)
    # PGCN 1: SRP[0].pgc_start_byte @ pgcit+8+4
    pgc_start = be32(pgcit, 8 + 4)
    pa = pgcit_abs + pgc_start
    f.seek(pa); h = f.read(256)
    nr_cells = h[3]; cell_pb_off = be16(h, 232)
    vob_lba, _ = find_title_vob(f, vts, 1)   # VTSTT_VOBS base (parts are contiguous)
    print("VTS_%02d PGCN 1: nr_cells=%d  (title VOB base lba=%d)" % (vts, nr_cells, vob_lba))
    print("interleaved cells (category byte0 bit2) + their next_vobu ILVU chains:")

    def dsi_at(rbn):
        f.seek((vob_lba + rbn) * 2048)
        return _dsi_fields(f.read(2048))

    n_inter = 0
    for c in range(min(nr_cells, 255)):
        f.seek(pa + cell_pb_off + c * 24); e = f.read(24)
        b0 = e[0]
        interleaved = (b0 >> 2) & 1
        block_type  = (b0 >> 4) & 3
        if not interleaved or block_type == 1:      # skip normal + multi-angle cells
            continue
        n_inter += 1
        first = be32(e, 8); ile = be32(e, 12); last = be32(e, 20)
        rbn = first; played = 0; jumps = 0; skipped = 0; hops = 0; nav_ok = True
        chain = []
        while hops < 4000:
            good, cat, ea, nxt = dsi_at(rbn)
            if not good:
                nav_ok = False; break
            off = nxt & 0x3fffffff
            is_last = (cat & 0xf000) == 0x5000
            iend = rbn + ea                          # last sector of this VOBU
            played += (iend - rbn + 1)
            if off == 0x3fffffff:                    # END_OF_CELL -> play tail linearly
                played += (last - iend)
                chain.append((rbn, iend, None)); break
            tgt = rbn + off                          # next_vobu (always forward)
            if is_last and tgt > iend + 1:
                skipped += (tgt - iend - 1)
                jumps += 1
                chain.append((rbn, iend, tgt))
            rbn = tgt; hops += 1
            if rbn > last + 3000:
                nav_ok = False; break
        ok = nav_ok and chain and chain[-1][2] is None
        print("  cell %2d: first=%d ilvu_end=%d last=%d | ILVUs=%d jumps=%d "
              "played=%d skipped(sibling)=%d nav_ok=%s %s"
              % (c, first, ile, last, len(chain), jumps, played, skipped, nav_ok,
                 "OK" if ok else "*** CHAIN DID NOT REACH END_OF_CELL ***"))
    if n_inter == 0:
        print("  (no interleaved cells in PGCN 1 - this title is not seamless-branch)")


# ---- Phase 10: VTSI_MAT audio / subpicture stream attributes (BIG-ENDIAN) ----
# Offsets within the VTS IFO's first sector (VTSI_MAT), verified against
# libdvdread ifo_types.h vtsi_mat_t + confirmed byte-exact on MEN_IN_BLACK VTS_21:
#   nr_of_vts_audio_streams  u8  @515 (0x203)
#   vts_audio_attr[8]        8 B  @516 (0x204)   audio_attr_t
#   nr_of_vts_subp_streams   u8  @597 (0x255)
#   vts_subp_attr[32]        6 B  @598 (0x256)   subp_attr_t
# audio_attr_t byte0 = [format:3][mc_ext:1][lang_type:2][app_mode:2] (MSB->LSB);
#            byte1 = [quant:2][sfreq:2][unk:1][channels:3]; bytes2-3 = lang_code
#            (2 ASCII, valid when lang_type==1); byte5 = code_extension.
# subp_attr_t byte0 = [code_mode:3][zero:3][type:2]; bytes2-3 = lang_code.
AUDIO_NR_OFF, AUDIO_ATTR_OFF = 515, 516
SUBP_NR_OFF,  SUBP_ATTR_OFF  = 597, 598
AUDIO_FMT = {0: "AC3", 1: "?1", 2: "MPEG1", 3: "MPEG2ext",
             4: "LPCM", 5: "?5", 6: "DTS", 7: "?7"}


def parse_vts_attr(mat):
    """Decode the VTS audio + subpicture stream-attribute tables from a
    VTSI_MAT sector (2048 B). Returns (audio_list, subp_list) where each audio
    entry is (fmt_code, channels, lang_type, lang_bytes, code_ext) and each
    subp entry is (type, lang_bytes, code_ext)."""
    na = mat[AUDIO_NR_OFF]
    ns = mat[SUBP_NR_OFF]
    audio = []
    for i in range(na):
        a = mat[AUDIO_ATTR_OFF + i*8: AUDIO_ATTR_OFF + i*8 + 8]
        fmt   = (a[0] >> 5) & 7
        ltype = (a[0] >> 2) & 3
        ch    = (a[1] & 7) + 1
        audio.append((fmt, ch, ltype, a[2:4], a[5]))
    subp = []
    for i in range(ns):
        s = mat[SUBP_ATTR_OFF + i*6: SUBP_ATTR_OFF + i*6 + 6]
        typ = (s[0] >> 6) & 3
        subp.append((typ, s[2:4], s[5]))
    return na, ns, audio, subp


def _lang_str(ltype, lang):
    return lang.decode('latin1') if ltype in (1, 2) and lang[0] else "--"


def dump_vts_attr(f, vts, hexpath=None):
    ifo_lba = find_vts_ifo(f, vts)
    f.seek(ifo_lba * 2048)
    mat = f.read(2048)
    na, ns, audio, subp = parse_vts_attr(mat)
    print("VTS_%02d_0.IFO LBA=%d  (VTSI_MAT)" % (vts, ifo_lba))
    print("nr_of_vts_audio_streams @%d = %d" % (AUDIO_NR_OFF, na))
    for i, (fmt, ch, lt, lang, cx) in enumerate(audio):
        print("  audio %d: %-8s %dch  lang_type=%d lang=%s code_ext=%d"
              % (i, AUDIO_FMT[fmt], ch, lt, _lang_str(lt, lang), cx))
    print("nr_of_vts_subp_streams @%d = %d" % (SUBP_NR_OFF, ns))
    for i, (typ, lang, cx) in enumerate(subp):
        print("  subp  %d: type=%d lang=%s code_ext=%d"
              % (i, typ, _lang_str(1, lang), cx))
    if hexpath:
        with open(hexpath, 'w') as h:
            h.write("// VTSI_MAT sector (2048 B) from VTS_%02d_0.IFO\n"
                    "// generated by tools/nav_extract.py --vts-attr --vts %d --attr-hex\n"
                    "// EXPECTED: audio_ntracks=%d subp_ntracks=%d\n"
                    % (vts, vts, na, ns))
            for i, (fmt, ch, lt, lang, cx) in enumerate(audio):
                h.write("//   audio %d: fmt=%d ch=%d lang_type=%d lang=%02x%02x\n"
                        % (i, fmt, ch, lt, lang[0], lang[1]))
            for i, (typ, lang, cx) in enumerate(subp):
                h.write("//   subp  %d: type=%d lang=%02x%02x\n"
                        % (i, typ, lang[0], lang[1]))
            for i in range(0, 2048, 16):
                h.write(" ".join("%02x" % x for x in mat[i:i+16]) + "\n")
        print("wrote VTSI_MAT sector -> %s" % hexpath)


# DSI packet (private_stream_2 substream 0x01). Offsets are relative to the DSI
# DATA start (the byte after the 0x01 substream id) - the same convention
# dvd/nav_dsi.sv uses for its byte index. Cross-checked against libdvdread
# nav_types.h (dsi_gi_t / sml_agli_t / vobu_sri_t, fetched 2026-07-07):
#   dsi_gi @0x00:  nv_pck_scr@0x00 nv_pck_lbn@0x04 vobu_ea@0x08
#                  vobu_1stref_ea@0x0C vobu_2ndref_ea@0x10 vobu_3rdref_ea@0x14
#                  vobu_vob_idn u16@0x18  vobu_c_idn u8@0x1B
#                  c_eltm (dvd_time_t: hh mm ss ff, BCD) @0x1C
#   sml_pbi  @0x20 (seamless playback info, 148 B)
#   sml_agli @0xB4: data[9] x {address u32, size u16}  (seamless angle offsets)
#   vobu_sri @0xEA: next_video u32@0xEA, fwda[19]@0xEE, next_vobu@0x13A,
#                   prev_vobu@0x13E, bwda[19]@0x142, prev_video@0x18E
#   synci    @0x192
# In a 2048 B NAV sector the DSI DATA starts at 0x407 (libdvdread DSI_START_BYTE
# = 1031); the 0x01 substream id is at 0x406, the 00 00 01 BF PES header at 0x400.
DSI_DATA_OFF = 0x407
SRI_END_OF_CELL = 0x3FFFFFFF


def bcd(x): return (x >> 4) * 10 + (x & 0x0F)


# VOBU_SRI forward/backward time-interval table (libdvdread nav_print.c):
# seconds ahead/back for entry i = stime[i]/2.  fwda[i] is that many seconds
# FORWARD; bwda mirrors it (bwda[i] label = stime[18-i]/2 seconds BACK).
STIME = [240, 120, 60, 20, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]


def sri_offset(entry):
    """Decode an fwda/bwda VOBU_SRI entry -> (valid, offset_sectors).
    low-30-bits all ones (0x3fffffff / 0x7fffffff / 0xbfffffff / 0xffffffff)
    is the END_OF_CELL "no target" sentinel (see dvd-reference-source-repos)."""
    if (entry & 0x3FFFFFFF) == 0x3FFFFFFF:
        return (False, 0)
    return (True, entry & 0x3FFFFFFF)


def dsi_seek_map(dsi):
    """Golden fwda/bwda -> target-sector (RBN) map for a DSI packet.  Returns
    a list of (dir, seconds, entry_hex, valid, target_rbn) tuples; RTL must
    reproduce target_rbn = nv_pck_lbn +/- (entry & 0x3fffffff) byte-exact."""
    lbn = be32(dsi, 0x04)
    rows = []
    for i in range(19):
        v = be32(dsi, 0xEE + i * 4)
        ok, off = sri_offset(v)
        rows.append(("fwd", STIME[i] / 2.0, v, ok, (lbn + off) if ok else None))
    for i in range(19):
        v = be32(dsi, 0x142 + i * 4)
        ok, off = sri_offset(v)
        tgt = (lbn - off) if ok else None
        rows.append(("bwd", STIME[18 - i] / 2.0, v, ok, tgt))
    return lbn, rows


# ---------------------------------------------------------------------------
# GOLDEN MODEL for dvd/dpad_seek.sv (O[45] "D-Pad Seek", Left/Right = -/+10 s,
# Down/Up = -/+60 s). The RTL must reproduce dpad_resolve() offset-for-offset.
# Mirrors the FSM exactly: greedy decomposition over the COARSE ladder
# {120,60,30,10} s = forward table indices {0,1,2,3}, descending one rung on
# END_OF_CELL and crediting the leftover seconds, then the FINE rungs 4..15
# (first valid one, then STOP -- a bounded partial jump), then the structural
# +/-1-VOBU fallback. The backward mirror of forward index a is table address
# (37 - a), i.e. bwda entry (18 - a).
# ---------------------------------------------------------------------------
DPAD_RUNG_U = {0: 12, 1: 6, 2: 3, 3: 1}     # coarse rung -> units of 10 s
DPAD_MAXTERMS = 8


def _sri_entry(dsi, fwd, ridx):
    """One VOBU_SRI entry by FORWARD-equivalent index (0..18)."""
    if fwd:
        return be32(dsi, 0xEE + ridx * 4)
    return be32(dsi, 0x142 + (18 - ridx) * 4)


def _dpad_pick(units_left):
    if units_left >= 12: return 0
    if units_left >= 6:  return 1
    if units_left >= 3:  return 2
    return 3


def dpad_resolve(dsi, units, fwd):
    """units = |request| in units of 10 s (1..24). Returns (offset|None, trace)."""
    off, terms, units_left, trace = 0, 0, units, []
    ridx = _dpad_pick(units_left)
    while True:
        ent = _sri_entry(dsi, fwd, ridx)
        ok, o = sri_offset(ent)
        ok = ok and bool(ent & 0x80000000)
        name = "%s[%d]=%gs" % ("fwda" if fwd else "bwda-mirror", ridx,
                               STIME[ridx] / 2.0)
        if ok:
            off += o
            trace.append("%s +%d" % (name, o))
            if ridx >= 4:
                trace.append("(fine rung -> stop)")
                break
            use = DPAD_RUNG_U[ridx]
            last = (units_left <= use) or (terms + 1 >= DPAD_MAXTERMS)
            terms += 1
            units_left = units_left - use if units_left > use else 0
            if last:
                break
            ridx = _dpad_pick(units_left)
        else:
            trace.append("%s EOC" % name)
            if ridx >= 15:
                if off:
                    trace.append("(partial, keep)")
                elif fwd:
                    nxv = be32(dsi, 0x13A)
                    ok2, o2 = sri_offset(nxv)
                    if ok2 and (nxv & 0x80000000):
                        off, _t = o2, trace.append("next_vobu +%d" % o2)
                    else:
                        off = be32(dsi, 0x08) + 1
                        trace.append("vobu_ea+1 +%d" % off)
                else:
                    pvv = be32(dsi, 0x13E)
                    ok2, o2 = sri_offset(pvv)
                    if ok2 and (pvv & 0x80000000):
                        off = o2
                        trace.append("prev_vobu -%d" % o2)
                    else:
                        trace.append("DEAD END -> no-op")
                        return None, trace
                break
            ridx += 1
    return (off if off else None), trace


def dump_dpad(dsi):
    """The four D-pad gestures for one DSI packet, as the RTL resolves them."""
    lbn = be32(dsi, 0x04)
    out = ["  dpad_seek (golden for dvd/dpad_seek.sv): nv_pck_lbn=%d" % lbn]
    for label, units, fwd in (("Right +10s", 1, True), ("Up    +60s", 6, True),
                              ("Left  -10s", 1, False), ("Down  -60s", 6, False)):
        off, trace = dpad_resolve(dsi, units, fwd)
        if off is None:
            out.append("    %s -> NO-OP            [%s]" % (label, "; ".join(trace)))
        else:
            tgt = lbn + off if fwd else max(0, lbn - off)
            out.append("    %s -> RBN %-8d off=%-7d [%s]"
                       % (label, tgt, off, "; ".join(trace)))
    return out


def parse_dsi(dsi):
    """dsi = 979 B DSI data (from the byte after the 0x01 substream id)."""
    out = []
    c = dsi[0x1C:0x20]                          # c_eltm dvd_time_t (BCD)
    out.append("  dsi_gi: nv_pck_scr=%d nv_pck_lbn=%d vobu_ea=%d "
               "vob_idn=%d c_idn=%d"
               % (be32(dsi, 0x00), be32(dsi, 0x04), be32(dsi, 0x08),
                  be16(dsi, 0x18), dsi[0x1B]))
    out.append("  c_eltm: %02d:%02d:%02d.%02d  (raw %02x %02x %02x %02x)"
               % (bcd(c[0]), bcd(c[1]), bcd(c[2]), bcd(c[3] & 0x3F),
                  c[0], c[1], c[2], c[3]))
    out.append("  vobu_1st/2nd/3rd_ref_ea = %d / %d / %d"
               % (be32(dsi, 0x0C), be32(dsi, 0x10), be32(dsi, 0x14)))

    def sri(o):
        v = be32(dsi, o)
        return "END_OF_CELL" if v == SRI_END_OF_CELL else "0x%08x" % v
    out.append("  vobu_sri: next_video=%s next_vobu=%s prev_vobu=%s prev_video=%s"
               % (sri(0xEA), sri(0x13A), sri(0x13E), sri(0x18E)))
    # fwda/bwda: 19 relative-VOBU pointers each (top bit = valid/has-video)
    fwda = [be32(dsi, 0xEE + i*4) for i in range(19)]
    bwda = [be32(dsi, 0x142 + i*4) for i in range(19)]
    out.append("  fwda[0..3] = %s ..." % " ".join("0x%08x" % x for x in fwda[:4]))
    out.append("  bwda[0..3] = %s ..." % " ".join("0x%08x" % x for x in bwda[:4]))
    # sml_agli: seamless angle offsets (9 angles)
    agl = []
    for i in range(9):
        a = be32(dsi, 0xB4 + i*6)
        s = be16(dsi, 0xB4 + i*6 + 4)
        if a or s:
            agl.append("a%d=0x%08x/%d" % (i+1, a, s))
    out.append("  sml_agli: %s" % (" ".join(agl) if agl else "(none)"))
    # Phase-9 multi-angle map: sml_pbi.category ILVU flags + per-angle next-ILVU
    # target sector (RBN). The angle jump only fires at a BLOCK|LAST VOBU.
    lbn_a, cat, is_last, arows = angle_map(dsi)
    out.append("  sml_pbi.category=0x%04x [%s]%s"
               % (cat, ilvu_flags(cat), "  (angle jump point)" if is_last else ""))
    if arows:
        out.append("  angle map (nv_pck_lbn=%d):" % lbn_a)
        for ang, a, sign, tgt in arows:
            out.append("    angle %d  0x%08x (%s%d) -> RBN %d"
                       % (ang, a, sign, a & 0x3FFFFFFF, tgt))
    # Phase-8 seek map: fwda/bwda -> target VOBU sector (RBN). This is the
    # golden reference bench/dvd/nav_seek_map_tb.sv checks the RTL against.
    lbn, rows = dsi_seek_map(dsi)
    out.append("  seek map (nv_pck_lbn=%d):" % lbn)
    for d, s, v, ok, tgt in rows:
        if ok:
            out.append("    %s %6.1fs  0x%08x -> RBN %d" % (d, s, v, tgt))
        else:
            out.append("    %s %6.1fs  0x%08x -> END_OF_CELL" % (d, s, v))
    # Hold-to-seek scrub tiers (dvd/scrub_ctrl.sv): the four accelerating jumps
    # per direction and the nav_dsi tbl_raddr each maps to. Golden for scrub_ctrl.
    out.append("  scrub tiers (dvd/scrub_ctrl.sv, nv_pck_lbn=%d):" % lbn)
    for tier, secs in enumerate([10.0, 30.0, 60.0, 120.0]):
        fi, bi = 3 - tier, 15 + tier               # fwda / bwda indices
        fok, foff = sri_offset(be32(dsi, 0xEE + fi * 4))
        bok, boff = sri_offset(be32(dsi, 0x142 + bi * 4))
        ft = ("RBN %d" % (lbn + foff)) if fok else "END_OF_CELL(+/-1 VOBU)"
        bt = ("RBN %d" % (max(lbn - boff, 0))) if bok else "END_OF_CELL(+/-1 VOBU)"
        out.append("    tier %d (%5.0fs): fwd raddr=%d -> %s | bwd raddr=%d -> %s"
                   % (tier, secs, fi, ft, 34 + tier, bt))
    return out


# DSI_ILVU flag nibble in sml_pbi.category (dvdnav_internal.h):
DSI_ILVU_PRE, DSI_ILVU_BLOCK = 1 << 15, 1 << 14
DSI_ILVU_FIRST, DSI_ILVU_LAST = 1 << 13, 1 << 12
DSI_ILVU_MASK = 0xF000


def ilvu_flags(cat):
    fl = []
    if cat & DSI_ILVU_PRE:   fl.append("PRE")
    if cat & DSI_ILVU_BLOCK: fl.append("BLOCK")
    if cat & DSI_ILVU_FIRST: fl.append("FIRST")
    if cat & DSI_ILVU_LAST:  fl.append("LAST")
    return "|".join(fl) if fl else "-"


def angle_map(dsi):
    """Golden multi-angle (Phase 9) decode of a DSI packet. Returns
    (nv_pck_lbn, category, is_last_of_ilvu, [(angle#, addr, sign, target_rbn), ...]).
    At a BLOCK|LAST VOBU the current angle's next ILVU is at
    nv_pck_lbn +/- (sml_agli.data[angle-1].address & 0x3fffffff)  (bit31 = sign,
    0x7fffffff = none) -- faithful to libdvdnav dvdnav.c ~L452-468. This is the
    reference bench/dvd/iso_reader_angle_tb.sv validates the RTL's jump math
    against, byte-exact on the real MiB VTS_14 fixture."""
    lbn = be32(dsi, 0x04)
    cat = be16(dsi, 0x20)
    is_last = (cat & DSI_ILVU_MASK) == (DSI_ILVU_BLOCK | DSI_ILVU_LAST)
    rows = []
    for i in range(9):
        a = be32(dsi, 0xB4 + i*6)
        if a == 0:
            continue
        off = a & 0x3FFFFFFF
        neg = bool(a & 0x80000000) and a != 0x7FFFFFFF
        tgt = lbn - off if neg else lbn + off
        rows.append((i+1, a, '-' if neg else '+', tgt))
    return lbn, cat, is_last, rows


def is_nav_pack(sec):
    # PS pack start + a private_stream_2 PES with substream 0x00 (PCI) at the
    # fixed NAV layout: pack hdr 14 B, system hdr 24 B, then 00 00 01 BF.
    if sec[0:4] != b'\x00\x00\x01\xba':
        return False
    return sec[0x26:0x2a] == b'\x00\x00\x01\xbf' and sec[0x2c] == 0x00


def parse_pci(pci, verbose_cmds):
    out = []
    ss = be16(pci, 0x60) & 3
    out.append("  pci_gi: lbn=%d vobu_s_ptm=%d vobu_e_ptm=%d  hli_ss=%d"
               % (be32(pci, 0), be32(pci, 0x0C), be32(pci, 0x10), ss))
    if ss == 0:
        return out, 0
    btngr_ns = (pci[0x6E] >> 4) & 3
    btn_ns   = pci[0x71] & 0x3F
    out.append("  hl_gi: s_ptm=%d e_ptm=%d se_e_ptm=%d btngr_ns=%d btn_ofn=%d "
               "btn_ns=%d nsl=%d fosl=%d foac=%d"
               % (be32(pci, 0x62), be32(pci, 0x66), be32(pci, 0x6A), btngr_ns,
                  pci[0x70], btn_ns, pci[0x72] & 0x3F,
                  pci[0x74] & 0x3F, pci[0x75] & 0x3F))
    for g in range(3):
        sl = be32(pci, 0x76 + g*8)
        ac = be32(pci, 0x76 + g*8 + 4)
        if sl or ac:
            out.append("  btn_coli[grp%d]: sel=%08x (Ci3..0=%x%x%x%x A3..0=%x%x%x%x) "
                       "act=%08x"
                       % (g+1, sl,
                          (sl>>28)&15, (sl>>24)&15, (sl>>20)&15, (sl>>16)&15,
                          (sl>>12)&15, (sl>>8)&15, (sl>>4)&15, sl&15, ac))
    for b in range(btn_ns):
        e = pci[0x8E + b*18 : 0x8E + b*18 + 18]
        w0 = (e[0] << 16) | (e[1] << 8) | e[2]
        w1 = (e[3] << 16) | (e[4] << 8) | e[5]
        coln  = (w0 >> 22) & 3
        x1    = (w0 >> 12) & 0x3FF
        x2    = w0 & 0x3FF
        aact  = (w1 >> 22) & 3
        y1    = (w1 >> 12) & 0x3FF
        y2    = w1 & 0x3FF
        up, dn, lf, rt = e[6] & 0x3F, e[7] & 0x3F, e[8] & 0x3F, e[9] & 0x3F
        out.append("  btn %2d: rect x%d..%d y%d..%d coln=%d auto=%d "
                   "links(u/d/l/r)=%d/%d/%d/%d%s"
                   % (b+1, x1, x2, y1, y2, coln, aact, up, dn, lf, rt,
                      ("  cmd: " + e[10:18].hex(' ') + "  " +
                       decode_vmcmd(e[10:18])) if verbose_cmds else ""))
    return out, btn_ns


# ---- Subpicture display-mode substream mapping (golden predictor) -------------
# DVD maps a LOGICAL subpicture stream (SPRM2 / SetSTN low bits) to a PHYSICAL
# substream id (0x20+N) that depends on the video display mode. The mapping lives
# in the PGC: subp_control[subpN] (32-bit, one per logical stream) at PGC offset
# 0x1C + subpN*4. Per libdvdnav vmget.c vm_get_subp_stream:
#   present = subp_control[subpN] >> 31
#   4:3          : streamN = (ctl >> 24) & 0x1f
#   16:9 wide    : streamN = (ctl >> 16) & 0x1f
#   16:9 letterbx: streamN = (ctl >>  8) & 0x1f
#   16:9 pan&scan: streamN = (ctl      ) & 0x1f    ; substream = 0x20 + streamN
# This is why the Matrix "Follow the White Rabbit" icon (PGCN 6, SetSTN logical
# stream 1) rides substream 0x22 (wide) / 0x23 (letterbox) — NOT 0x21. Our reader
# must parse subp_control and apply this mapping (see docs/dvd_nav.md).
def dump_subp_map(f, vts, pgcn):
    ifo_lba = find_vts_ifo(f, vts)
    f.seek(ifo_lba * 2048); mat = f.read(2048)
    aspect = (mat[0x200] >> 2) & 3          # vts_video_attr @0x200: 0=4:3, 3=16:9
    pgcit_abs = (ifo_lba + be32(mat, 204)) * 2048
    f.seek(pgcit_abs); pgcit = f.read(2048)
    pa = pgcit_abs + be32(pgcit, 8 + (pgcn - 1) * 8 + 4)
    f.seek(pa); pgc = f.read(0x9C)
    print("VTS_%02d PGCN %d subp_control map (video aspect=%s):"
          % (vts, pgcn, "16:9" if aspect == 3 else "4:3" if aspect == 0 else "?"))
    for subpN in range(16):
        ctl = be32(pgc, 0x1C + subpN * 4)
        if not (ctl & (1 << 31)):
            continue
        m43 = (ctl >> 24) & 0x1f; wide = (ctl >> 16) & 0x1f
        lb  = (ctl >>  8) & 0x1f; ps   = ctl & 0x1f
        print("  logical %2d: ctl=0x%08x -> substream 4:3=0x%02x wide=0x%02x "
              "letterbox=0x%02x pan&scan=0x%02x" %
              (subpN, ctl, 0x20 + m43, 0x20 + wide, 0x20 + lb, 0x20 + ps))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('iso')
    ap.add_argument('--vts', type=int, default=0,
                    help='VTS number (0 = VIDEO_TS.VOB / VMGM)')
    ap.add_argument('--sector', type=int, default=0,
                    help='start RBN within the menu VOB')
    ap.add_argument('--count', type=int, default=2048,
                    help='sectors to scan')
    ap.add_argument('--max-dumps', type=int, default=6,
                    help='full HLI dumps to print (rest summarized)')
    ap.add_argument('--cmds', action='store_true', help='decode button commands')
    ap.add_argument('--dpad', action='store_true',
                    help='golden D-pad fixed-time seek targets per NAV pack '
                         '(the reference dvd/dpad_seek.sv must reproduce)')
    ap.add_argument('--dsi', action='store_true',
                    help='also decode the DSI packet (substream 0x01) of each NAV pack')
    ap.add_argument('--hex', help='write raw NAV sectors to a $readmemh fixture')
    ap.add_argument('--hex-count', type=int, default=2,
                    help='NAV sectors to write to --hex')
    ap.add_argument('--title-vob', type=int, default=0, metavar='PART',
                    help='scan VTS_xx_<PART>.VOB title stream (>=1) instead of '
                         'the _0 menu VOB -- for Phase-9 multi-angle ILVU blocks')
    ap.add_argument('--angles', action='store_true',
                    help='only report NAV packs that carry an ILVU/angle block '
                         '(sml_pbi.category ILVU flags or a populated sml_agli)')
    ap.add_argument('--ilvu', action='store_true',
                    help='seamless-branch golden predictor: follow each PGCN-1 '
                         'interleaved cell (category byte0 bit2) via next_vobu and '
                         'print the played/skipped sector chain (needs --vts)')
    ap.add_argument('--subp-map', type=int, metavar='PGCN',
                    help='dump the subpicture display-mode substream mapping '
                         '(pgc->subp_control) for a PGC (needs --vts)')
    ap.add_argument('--vts-attr', action='store_true',
                    help='Phase 10: dump the VTS audio/subpicture stream-attribute '
                         'tables (counts, codec, channels, language) from the '
                         'VTS_xx_0.IFO VTSI_MAT (needs --vts)')
    ap.add_argument('--attr-hex', metavar='FILE',
                    help='with --vts-attr, write the VTSI_MAT sector to a '
                         '$readmemh fixture (with expected counts in a comment)')
    a = ap.parse_args()

    f = open(a.iso, 'rb')
    if a.ilvu:
        dump_ilvu(f, a.vts)
        return
    if a.subp_map is not None:
        dump_subp_map(f, a.vts, a.subp_map)
        return
    if a.vts_attr:
        dump_vts_attr(f, a.vts, a.attr_hex)
        return
    if a.title_vob:
        vob_lba, vob_len = find_title_vob(f, a.vts, a.title_vob)
    else:
        vob_lba, vob_len = find_menu_vob(f, a.vts)
    nsec = vob_len // 2048
    print("menu VOB: lba=%d len=%d bytes (%d sectors)  scanning RBN %d..%d"
          % (vob_lba, vob_len, nsec, a.sector, min(nsec, a.sector + a.count) - 1))

    navs = hlis = 0
    dumped = 0
    hexed = []
    last_sig = None
    for rbn in range(a.sector, min(nsec, a.sector + a.count)):
        f.seek((vob_lba + rbn) * 2048)
        sec = f.read(2048)
        if not is_nav_pack(sec):
            continue
        navs += 1
        pci = sec[0x2D:0x2D + 980]          # PCI data (after the substream id)
        ss = be16(pci, 0x60) & 3

        # ---- D-pad fixed-time seek golden ------------------------------------
        if a.dpad:
            has_dsi = sec[0x400:0x404] == b'\x00\x00\x01\xbf' and sec[0x406] == 0x01
            if not has_dsi:
                continue
            if dumped < a.max_dumps:
                print("NAV pack @RBN %d:" % rbn)
                print("\n".join(dump_dpad(sec[DSI_DATA_OFF:DSI_DATA_OFF + 979])))
                dumped += 1
            continue

        # ---- Phase-9 angle mode: report/extract ILVU (angle) NAV packs -------
        if a.angles:
            has_dsi = sec[0x400:0x404] == b'\x00\x00\x01\xbf' and sec[0x406] == 0x01
            if not has_dsi:
                continue
            dsi = sec[DSI_DATA_OFF:DSI_DATA_OFF + 979]
            _, cat, is_last, arows = angle_map(dsi)
            if (cat & DSI_ILVU_MASK) == 0 and not arows:
                continue
            hlis += 1
            if a.hex and len(hexed) < a.hex_count:
                hexed.append((rbn, sec))
            if dumped < a.max_dumps:
                print("NAV pack @RBN %d: category=0x%04x [%s]%s"
                      % (rbn, cat, ilvu_flags(cat),
                         "  <== ANGLE JUMP POINT" if is_last else ""))
                print("\n".join(parse_dsi(dsi)))
                dumped += 1
            continue

        if ss:
            hlis += 1
            if a.hex and len(hexed) < a.hex_count:
                hexed.append((rbn, sec))
        # summarize runs of identical HLI (menus repeat the same HLI per VOBU)
        sig = pci[0x60:0x316]
        if sig != last_sig and (ss or dumped == 0) and dumped < a.max_dumps:
            print("NAV pack @RBN %d:" % rbn)
            lines, _ = parse_pci(pci, a.cmds)
            print("\n".join(lines))
            if a.dsi and sec[0x400:0x404] == b'\x00\x00\x01\xbf' \
                    and sec[0x406] == 0x01:
                print("\n".join(parse_dsi(sec[DSI_DATA_OFF:DSI_DATA_OFF + 979])))
            dumped += 1
        last_sig = sig
    print("\nscanned: %d NAV packs, %d with HLI (buttons)" % (navs, hlis))

    if a.hex and hexed:
        with open(a.hex, 'w') as h:
            h.write("// NAV sectors (2048 B each) from %s VTS_%02d menu VOB\n"
                    "// RBNs: %s  (generated by tools/nav_extract.py)\n"
                    % (a.iso.split('/')[-1], a.vts, [r for r, _ in hexed]))
            for _, sec in hexed:
                for i in range(0, 2048, 16):
                    h.write(" ".join("%02x" % x for x in sec[i:i+16]) + "\n")
        print("wrote %d NAV sectors -> %s" % (len(hexed), a.hex))


if __name__ == '__main__':
    main()
