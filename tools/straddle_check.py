#!/usr/bin/env python3
# straddle_check.py -- audit a DVD-Video ISO for IFO parse targets that cross a
# 2048-byte sector boundary or land within a few bytes of offset 2047.
#
# Enumerates EVERY PGC in:
#   - VMGM_PGCI_UT   (VIDEO_TS.IFO  VMGI_MAT@200)   domain "VMGM"
#   - each VTSM_PGCI_UT (VTS_xx_0.IFO VTSI_MAT@208) domain "VTSM"
#   - each VTS_PGCIT    (VTS_xx_0.IFO VTSI_MAT@204) domain "TT"
#
# For each PGC it checks these parse targets, absolute-byte, against the 2048 grid:
#   header sub-fields  nr_programs@2, nr_cells@3, playback_time@4(4B),
#                      next@156 prev@158 goup@160 mode@162 still@163,
#                      palette@164(64B), cmd_tbl_off@228, prog_map_off@230,
#                      cell_pb_off@232, cell_pos_off@234
#   command-table hdr  8 bytes @ (pgc+cmd_off): nr_pre@0(2B) nr_post@2 nr_cell@4 last@6
#   command-table body (pgc+cmd_off+8 .. +8+(npre+npost+ncell)*8)
#   program map        (pgc+pm_off, nr_programs bytes)
#   cell table         (pgc+cell_off, nr_cells*24 bytes)
#
# A target [lo,hi] "straddles" iff lo//2048 != hi//2048.
# "near"   iff its first byte's in-sector offset >= NEAR_LO (default 2040).
#
# It ALSO checks the PGCIT **SRP table** entries (srp_pgc_start @+4..+7), which
# POSITION each PGC and are read through the rbuf shadow at an ARBITRARY offset
# (LU[0].lang_start_byte -> not necessarily 8-aligned), so an SRP entry can straddle.
#
# RTL STATUS (post straddle-audit, dvd_iso_reader.sv branch feature/straddle-audit-
# symptom1): the rbuf shadow fetch is now SECTOR-CROSSING (fetch_xw), and the
# S_PGC_HDR give-up guard (pgc_off>2044) is retired, so ALL of these reads --
# pre-walk header bytes (@2/@3/@4-7), the @156.. window (walker), the command table
# (walker), AND the SRP srp_pgc_start -- are straddle-SAFE. Sections B/C below name
# what the PRE-fix reader would have misparsed (kept as a regression reference). A
# straddle flagged here is therefore expected to parse correctly on the fixed RTL;
# it is a red flag only if it regresses.
import sys, struct

SEC = 2048
NEAR_LO = 2040          # "within a few bytes of 2047"

def load(path):
    return open(path, 'rb')

def rd(f, a, n):
    f.seek(a); return f.read(n)

def u16(b, o): return struct.unpack('>H', b[o:o+2])[0]
def u32(b, o): return struct.unpack('>I', b[o:o+4])[0]

# ---- ISO9660 walk to VIDEO_TS, collect VMGI + VTS IFO LBAs ----
def walk_iso(f):
    lba = 16
    while True:
        d = rd(f, lba*SEC, SEC)
        assert d[1:6] == b'CD001', "not ISO9660"
        if d[0] == 1: break
        assert d[0] != 255, "no PVD"
        lba += 1
    root_lba = struct.unpack('<I', d[158:162])[0]   # ISO9660 dir records = LITTLE-endian
    root_len = struct.unpack('<I', d[166:170])[0]
    def wdir(dlba, dlen):
        nsec = (dlen + SEC-1)//SEC
        buf = b''.join(rd(f, (dlba+i)*SEC, SEC) for i in range(nsec))
        out = []
        for s in range(nsec):
            p = s*SEC
            while p < s*SEC + SEC:
                rl = buf[p]
                if rl == 0: break
                ext = struct.unpack('<I', buf[p+2:p+6])[0]
                dl  = struct.unpack('<I', buf[p+10:p+14])[0]
                fl  = buf[p+25]; nl = buf[p+32]; nm = buf[p+33:p+33+nl].upper()
                out.append((nm, ext, dl, fl)); p += rl
        return out
    vts_dir = None
    for nm, ext, dl, fl in wdir(root_lba, root_len):
        if nm.startswith(b'VIDEO_TS') and (fl & 2):
            vts_dir = (ext, dl)
    assert vts_dir, "no VIDEO_TS"
    vmgi = None; vts_ifo = {}
    for nm, ext, dl, fl in wdir(*vts_dir):
        if nm.startswith(b'VIDEO_TS.IFO'): vmgi = ext
        if nm.startswith(b'VTS_') and nm[6:12] == b'_0.IFO':
            try: vts_ifo[int(nm[4:6])] = ext
            except ValueError: pass
    return vmgi, vts_ifo

# ---- enumerate PGCs of one PGCIT; yields (pgcn, entry_id, pgc_abs) ----
def pgcs_of_pgcit(f, pit_abs):
    nr = u16(rd(f, pit_abs, 2), 0)
    for i in range(min(nr, 999)):
        srp = rd(f, pit_abs + 8 + i*8, 8)
        yield i+1, srp[0], pit_abs + u32(srp, 4)

# ---- SRP-table straddle: srp_pgc_start (@+4..+7) reposition each PGC and are read
# through the rbuf shadow at fetch_base=(pit_off+8+8*i)&0x7FF. Flag any SRP entry
# whose pgc_start_byte field spans a 2048 boundary (mis-read on the PRE-fix reader).
def srp_straddles_of_pgcit(f, pit_abs):
    nr = u16(rd(f, pit_abs, 2), 0)
    out = []
    for i in range(min(nr, 999)):
        ent_abs = pit_abs + 8 + i*8       # SRP[i]
        ps_abs  = ent_abs + 4             # srp_pgc_start_byte (BE u32)
        fl = span_flag(ps_abs, 4)         # 4-byte field
        if fl and fl["straddle"]:
            fl["srp_i"] = i
            fl["pgcn"]  = i + 1
            fl["ent_inlo"] = ent_abs % SEC
            out.append(fl)
    return out

def menu_pgcit_abs(f, ifo_lba, mat_off):
    """Resolve a PGCI_UT (VMGM@200 / VTSM@208) -> LU[0] menu PGCIT abs byte."""
    mat = rd(f, ifo_lba*SEC, SEC)
    ptr = u32(mat, mat_off)
    if not ptr: return None
    ut_abs = (ifo_lba + ptr)*SEC
    nr_lus = u16(rd(f, ut_abs, 2), 0)
    if not (1 <= nr_lus < 100): return None
    lu0 = u32(rd(f, ut_abs + 8, 8), 4)   # LU[0].lang_start_byte @ ut+12
    return ut_abs + lu0

def title_pgcit_abs(f, ifo_lba):
    ptr = u32(rd(f, ifo_lba*SEC, SEC), 204)   # VTSI_MAT.vts_pgcit @204
    if not (0 < ptr <= 0xFFFFF): return None
    return (ifo_lba + ptr)*SEC

# ---- straddle test for a byte span ----
def span_flag(abs_lo, length):
    if length <= 0: return None
    abs_hi = abs_lo + length - 1
    inlo = abs_lo % SEC
    stradd = (abs_lo // SEC) != (abs_hi // SEC)
    near = inlo >= NEAR_LO
    if stradd or near:
        return dict(abs_lo=abs_lo, abs_hi=abs_hi, inlo=inlo, straddle=stradd, near=near)
    return None

def analyse_pgc(f, domain, vts, pgcn, entry_id, pgc_abs):
    """Return (list of flagged-target dicts, info dict)."""
    h = rd(f, pgc_abs, 256)
    nr_pgms = h[2]; nr_cells = h[3]
    cmd_off = u16(h, 228); pm_off = u16(h, 230); cell_off = u16(h, 232)
    pgc_off = pgc_abs % SEC
    # true nr_pre/post/cell from the command table header (absolute read = ground truth)
    nr_pre = nr_post = nr_cellc = None
    if cmd_off:
        ct = rd(f, pgc_abs + cmd_off, 8)
        nr_pre, nr_post, nr_cellc = struct.unpack('>HHH', ct[0:6])
    info = dict(domain=domain, vts=vts, pgcn=pgcn, entry_id=entry_id,
                pgc_abs=pgc_abs, pgc_off=pgc_off, nr_pgms=nr_pgms,
                nr_cells=nr_cells, cmd_off=cmd_off, pm_off=pm_off,
                cell_off=cell_off, nr_pre=nr_pre, nr_post=nr_post, nr_cellc=nr_cellc)

    # (field-name, abs_offset, length, rtl_prewalk_single_sector?)
    targets = [
        ("hdr.nr_programs@2",   pgc_abs+2,   1, True),
        ("hdr.nr_cells@3",      pgc_abs+3,   1, True),
        ("hdr.playback_time@4", pgc_abs+4,   4, True),
        ("hdr.next_pgcn@156",   pgc_abs+156, 2, False),
        ("hdr.prev_pgcn@158",   pgc_abs+158, 2, False),
        ("hdr.goup_pgcn@160",   pgc_abs+160, 2, False),
        ("hdr.pg_mode@162",     pgc_abs+162, 1, False),
        ("hdr.still_time@163",  pgc_abs+163, 1, False),
        ("hdr.palette@164",     pgc_abs+164, 64, False),
        ("hdr.cmd_tbl_off@228", pgc_abs+228, 2, False),
        ("hdr.prog_map_off@230",pgc_abs+230, 2, False),
        ("hdr.cell_pb_off@232", pgc_abs+232, 2, False),
        ("hdr.cell_pos_off@234",pgc_abs+234, 2, False),
    ]
    if cmd_off:
        base = pgc_abs + cmd_off
        targets += [
            ("cmdtbl.nr_of_pre@+0",  base+0, 2, False),
            ("cmdtbl.nr_of_post@+2", base+2, 2, False),
            ("cmdtbl.nr_of_cell@+4", base+4, 2, False),
            ("cmdtbl.last_byte@+6",  base+6, 2, False),
        ]
        ncmd = (nr_pre or 0)+(nr_post or 0)+(nr_cellc or 0)
        if 0 < ncmd <= 511:
            targets.append(("cmdtbl.body(%dcmd)" % ncmd, base+8, ncmd*8, False))
    if pm_off and nr_pgms:
        targets.append(("program_map(%dB)" % nr_pgms, pgc_abs+pm_off, nr_pgms, False))
    if cell_off and nr_cells:
        targets.append(("cell_table(%dcell)" % nr_cells, pgc_abs+cell_off, nr_cells*24, False))

    flagged = []
    for name, alo, ln, prewalk in targets:
        fl = span_flag(alo, ln)
        if fl:
            fl["field"] = name
            fl["length"] = ln
            fl["prewalk"] = prewalk
            flagged.append(fl)
    return flagged, info

def rtl_genuine_bug(info):
    """Would the real dvd_iso_reader.sv actually misparse this PGC?

    ** MODEL REFRESHED 2026-07-31 -- re-verified against dvd/dvd_iso_reader.sv. **
    The old model here described the PRE-PR-#143 reader: a single-sector rbuf
    shadow, so nr_of_cells (rbuf[3]) was unreadable at pgc_off > 2044 and the FSM
    bailed to pgc_error. **That is no longer true.** PR #143 made the shadow fetch
    SECTOR-CROSSING (`fetch_xw`, dvd_iso_reader.sv ~L1945): mid-fetch, when
    fetch_base+fi exceeds 2047, the FSM refills parse_buf with sec_lba+1 and
    resumes the SAME fetch with fi preserved, so rbuf[0..7] reads correctly at any
    pgc_off. S_PGC_HDR's give-up guard was deleted with it (see its comment block).

    Keeping the stale model cost a false alarm: on the 2026-07-31 sweep prep it
    reported 7 "GENUINE ... FSM bails" PGCs at pgc_off=2046 (Weakest Link x5,
    Hogwarts Challenge, 24 Board Game) that the shipped reader handles fine.

    So there is now NO pgc_off-driven genuine risk in the pre-walk header window:
    @2..@7 cross safely, and everything @156.. was always walker-read. Report
    top-of-sector PGCs as an informational census (section C) only.
    """
    return []

def main(path):
    f = load(path)
    vmgi, vts_ifo = walk_iso(f)
    print("=" * 78)
    print("STRADDLE AUDIT: %s" % path)
    print("  VMGI(VIDEO_TS.IFO) lba=%s   VTS IFO count=%d" % (vmgi, len(vts_ifo)))
    print("  NEAR_LO=%d (flag first byte in-sector offset >= this); SEC=%d" % (NEAR_LO, SEC))
    print("=" * 78)

    pgc_sources = []   # (domain, vts, pit_abs)
    if vmgi is not None:
        p = menu_pgcit_abs(f, vmgi, 200)
        if p: pgc_sources.append(("VMGM", 0, p))
    for vn in sorted(vts_ifo):
        p = menu_pgcit_abs(f, vts_ifo[vn], 208)
        if p: pgc_sources.append(("VTSM", vn, p))
    for vn in sorted(vts_ifo):
        p = title_pgcit_abs(f, vts_ifo[vn])
        if p: pgc_sources.append(("TT", vn, p))

    total_pgc = 0
    all_flags = []       # (info, flagged-list)
    genuine   = []       # (info, reasons)
    for domain, vts, pit_abs in pgc_sources:
        for pgcn, eid, pgc_abs in pgcs_of_pgcit(f, pit_abs):
            total_pgc += 1
            flags, info = analyse_pgc(f, domain, vts, pgcn, eid, pgc_abs)
            if flags:
                all_flags.append((info, flags))
            reasons = rtl_genuine_bug(info)
            if reasons:
                genuine.append((info, reasons))

    print("\nEnumerated %d PGCs across %d PGCITs.\n" % (total_pgc, len(pgc_sources)))

    print("-" * 78)
    print("A) PARSE TARGETS THAT STRADDLE 2048 or LAND >= off %d  (task-spec checker)" % NEAR_LO)
    print("-" * 78)
    if not all_flags:
        print("  (none)")
    for info, flags in all_flags:
        dm = info["domain"] + (("_%02d" % info["vts"]) if info["vts"] else "")
        print("  [%s PGCN %d] entry=0x%02x pgc_abs=%d pgc_off=%d cells=%d cmd_off=%d nr_pre=%s"
              % (dm, info["pgcn"], info["entry_id"], info["pgc_abs"], info["pgc_off"],
                 info["nr_cells"], info["cmd_off"], info["nr_pre"]))
        for fl in flags:
            tag = "STRADDLE" if fl["straddle"] else "near2047"
            print("      %-22s abs=%d..%d in_sec=%d len=%d  %s%s"
                  % (fl["field"], fl["abs_lo"], fl["abs_hi"], fl["inlo"], fl["length"],
                     tag, "" if fl["prewalk"] else "  (walker-read: straddle-SAFE)"))

    print("\n" + "-" * 78)
    print("B) GENUINE RTL RISK  (pre-walk single-sector reads near sector end)")
    print("   -- these are the ones dvd_iso_reader.sv can actually misparse")
    print("-" * 78)
    if not genuine:
        print("  (none -- the rbuf shadow fetch is SECTOR-CROSSING since PR #143,")
        print("   so the pre-walk header window @2..@7 is safe at ANY pgc_off;")
        print("   see rtl_genuine_bug() for the re-verified model.)")
    for info, reasons in genuine:
        dm = info["domain"] + (("_%02d" % info["vts"]) if info["vts"] else "")
        print("  [%s PGCN %d] pgc_abs=%d pgc_off=%d cells=%d nr_pre=%s"
              % (dm, info["pgcn"], info["pgc_abs"], info["pgc_off"],
                 info["nr_cells"], info["nr_pre"]))
        for r in reasons:
            print("      -> %s" % r)

    # B2) SRP-table straddles (srp_pgc_start crosses 2048 -> PGC MIS-POSITIONED on
    # the pre-fix reader). This is the site the earlier checker missed.
    print("\n" + "-" * 78)
    print("B2) SRP-ENTRY STRADDLES  (srp_pgc_start @+4..+7 crosses 2048)")
    print("    -- the PRE-fix reader wrapped the high bytes to parse_buf[0] and")
    print("       positioned the PGC at a garbage offset (symptom-1-class dead-end)")
    print("-" * 78)
    srp_hits = []
    for domain, vts, pit_abs in pgc_sources:
        for fl in srp_straddles_of_pgcit(f, pit_abs):
            srp_hits.append((domain, vts, pit_abs, fl))
    if not srp_hits:
        print("  (none -- every SRP entry's pgc_start_byte is within one sector)")
    for domain, vts, pit_abs, fl in srp_hits:
        dm = domain + (("_%02d" % vts) if vts else "")
        print("  [%s PGCN %d] SRP[%d] pit_off=%d ent_inlo=%d  srp_pgc_start abs=%d..%d in_sec=%d STRADDLE"
              % (dm, fl["pgcn"], fl["srp_i"], pit_abs % SEC, fl["ent_inlo"],
                 fl["abs_lo"], fl["abs_hi"], fl["inlo"]))

    # C) top-of-sector danger census: PGC headers with pgc_off in [2040..2047]
    print("\n" + "-" * 78)
    print("C) PGC-HEADER TOP-OF-SECTOR CENSUS (pgc_off in [%d..2047])" % NEAR_LO)
    print("-" * 78)
    hits = []
    for domain, vts, pit_abs in pgc_sources:
        for pgcn, eid, pgc_abs in pgcs_of_pgcit(f, pit_abs):
            off = pgc_abs % SEC
            if off >= NEAR_LO:
                h = rd(f, pgc_abs, 4)
                hits.append((domain, vts, pgcn, pgc_abs, off, h[2], h[3]))
    if not hits:
        print("  (none)")
    for domain, vts, pgcn, pgc_abs, off, npg, ncl in hits:
        dm = domain + (("_%02d" % vts) if vts else "")
        flag = "  <== GENUINE (nr_of_cells unreadable)" if off > 2044 else ""
        print("  [%s PGCN %d] pgc_abs=%d pgc_off=%d nr_programs=%d nr_cells=%d%s"
              % (dm, pgcn, pgc_abs, off, npg, ncl, flag))

if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
        print()
