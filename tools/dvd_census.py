#!/usr/bin/env python3
# =============================================================================
# dvd_census.py -- batch DVD-Video feature census over an ISO library
# =============================================================================
# Phase 2 of the conformance plan (docs/conformance.md). Scans every ISO in a
# directory and emits (a) a per-disc feature vector and (b) an aggregate
# PREVALENCE table that ranks the open conformance gaps by how many real discs
# actually exercise them -- so Phase 3 closes gaps in measured-prevalence order
# instead of by guess.
#
# It is a first-party oracle: it reuses OUR validated parsers, not libdvdread --
#   * IsoNav          from dvd_vm_ref.py  (ISO9660 walk, TT_SRPT, PGC/PGCIT,
#                                          PGC command-block decode)
#   * decode_vmcmd    from iso_nav_check.py (the vmcmd.c mnemonic printer)
#   * parse_vts_attr  from nav_extract.py  (VTSI_MAT audio/subp attributes)
# so what it reports is what our reader/VM would *see*, and every offset is one
# we already validated against ifo_types.h on hardware.
#
# The exotic IFO tables that our RTL does NOT yet parse (PTL_MAIT, TXTDT_MGI,
# VTS_TMAPT) only need PRESENCE detection for a prevalence census -- that is a
# single nonzero master-table pointer, no struct walk. Those pointers live at
# fixed VMGI/VTSI_MAT offsets (validated vs ifo_types.h below).
#
# VM-feature flags (parental / nav-timer / rnd / GPRM-counter / Call/JumpSS) are
# detected by string-matching decode_vmcmd's output across FP + every menu +
# every title PGC command block -- reusing the validated printer instead of
# re-decoding bits.
#
# Usage:
#   tools/dvd_census.py <iso-or-dir> [<iso-or-dir> ...]
#   tools/dvd_census.py                     # defaults to $DVD_ISO_DIR
#   tools/dvd_census.py --json out.json ... # also dump the raw vectors
#
# What each detected feature maps to in docs/conformance.md "Prioritized gap
# list" is printed alongside the prevalence table.
# =============================================================================
import sys, os, struct, json, collections, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav, DOM_FP, DOM_VMGM, DOM_VTSM, DOM_TT  # noqa: E402
from iso_nav_check import decode_vmcmd                             # noqa: E402
from nav_extract import parse_vts_attr, AUDIO_FMT                  # noqa: E402

DEFAULT_DIR = os.environ.get("DVD_ISO_DIR", os.path.expanduser("~/dvd-isos"))

# ---- master-table pointer offsets (BIG-ENDIAN u32), validated vs ifo_types.h -
# VMGI_MAT: first_play_pgc@132 tt_srpt@196 vmgm_pgci_ut@200 ptl_mait@204
#           vts_atrt@208 txtdt_mgi@212 ; vmg_category@34 (region) ; n_vts@62
VMGI_PTL_MAIT   = 204
VMGI_TXTDT_MGI  = 212
VMGI_CATEGORY   = 34
VMGI_NR_TITLESETS = 62
# VTSI_MAT: vts_ptt_srpt@200 vts_pgcit@204 vtsm_pgci_ut@208 vts_tmapt@212
VTSI_VTS_TMAPT  = 212


def _be32(b, off):
    return struct.unpack('>I', b[off:off+4])[0]


def _be16(b, off):
    return struct.unpack('>H', b[off:off+2])[0]


# =============================================================================
# per-disc census
# =============================================================================
def census_iso(path):
    """Return a feature dict for one ISO (or raise for a non-ISO / UDF-only)."""
    nav = IsoNav(path)                      # asserts CD001 -> ISO9660 only
    f = {"path": path, "name": os.path.basename(path)}

    # --- VMGI master table ---------------------------------------------------
    mat = nav.sec(nav.vmgi_lba)
    f["n_vts"]        = _be16(mat, VMGI_NR_TITLESETS)
    f["ptl_mait"]     = _be32(mat, VMGI_PTL_MAIT)  != 0   # parental mgmt table
    f["txtdt_mgi"]    = _be32(mat, VMGI_TXTDT_MGI) != 0   # disc/title text names
    # region: vmg_category bits [23:16] = mask of PROHIBITED regions (1=block).
    # A region-locked disc has some bit set; region-free (all-play) = 0xFF? No:
    # 0x00 in the mask means "all regions allowed". libdvdnav prints the mask as
    # (category>>16)&0xff; allowed regions = bits that are 0.
    cat = _be32(mat, VMGI_CATEGORY)
    prohibit = (cat >> 16) & 0xFF
    f["region_mask"]  = prohibit
    f["region_locked"] = prohibit not in (0x00, 0xFF)  # some-but-not-all blocked

    # --- TT_SRPT: per-title chapters (nr_of_ptts) + angles (nr_of_angles) -----
    # title_info_t (12 B): pb_ty@0 nr_of_angles@1 nr_of_ptts@2 parental_id@4
    #                      title_set_nr@6 vts_ttn@7 title_set_sector@8
    titles = []
    tsp = _be32(mat, 196)
    if 0 < tsp <= 0xFFFFF:
        tt = nav.sec(nav.vmgi_lba + tsp)
        nsr = min(_be16(tt, 0), 99)
        for i in range(nsr):
            e = tt[8 + i*12: 8 + i*12 + 12]
            if len(e) < 12:
                break
            titles.append({"angles":  e[1],
                           "chapters": _be16(e, 2),
                           "parental": _be16(e, 4),
                           "vts":     e[6]})
    f["n_titles"]     = len(titles)
    f["max_chapters"] = max((t["chapters"] for t in titles), default=0)
    f["max_angles"]   = max((t["angles"]   for t in titles), default=0)
    f["multi_angle"]  = f["max_angles"] > 1
    f["any_parental_id"] = any(t["parental"] not in (0, 0xFFFF) for t in titles)

    # --- per-VTS: TMAP presence + audio/subp attributes ----------------------
    tmap_vts = 0
    audio_fmts = set()
    lpcm_24bit = False
    lpcm_96k   = False
    dts        = False
    max_audio  = 0
    max_subp   = 0
    for vn, ifo_lba in sorted(nav.vts_ifo.items()):
        vmat = nav.sec(ifo_lba)
        if _be32(vmat, VTSI_VTS_TMAPT) != 0:
            tmap_vts += 1
        na, ns, audio, subp = parse_vts_attr(vmat)
        max_audio = max(max_audio, na)
        max_subp  = max(max_subp, ns)
        for idx, (fmt, ch, lt, lang, cx) in enumerate(audio):
            audio_fmts.add(AUDIO_FMT.get(fmt, "?%d" % fmt))
            if fmt == 6:
                dts = True
            if fmt == 4:  # LPCM: byte1 = [quant:2][freq:2][.][ch:3]
                b1 = vmat[516 + idx*8 + 1]
                if (b1 >> 6) & 3 == 2:
                    lpcm_24bit = True
                if (b1 >> 4) & 3 == 1:
                    lpcm_96k = True
    f["vts_with_tmap"] = tmap_vts
    f["has_tmap"]      = tmap_vts > 0
    f["audio_formats"] = sorted(audio_fmts)
    f["dts"]           = dts
    f["lpcm_24bit"]    = lpcm_24bit
    f["lpcm_96k"]      = lpcm_96k
    f["max_audio_streams"] = max_audio
    f["max_subp_streams"]  = max_subp

    # --- VM command-feature scan across FP + all menus + all titles ----------
    vm = collections.Counter()
    vm_cmds = 0
    for cmd in _iter_all_commands(nav):
        vm_cmds += 1
        m = decode_vmcmd(cmd)
        if "SetTmpPML"    in m: vm["parental_cmd"]   += 1
        if "SetMode Counter" in m: vm["gprm_counter"] += 1
        if "NVTMR ="      in m: vm["nav_timer"]       += 1
        if " rnd "        in m: vm["rnd"]             += 1
        if "CallSS"       in m: vm["callss"]          += 1
        if "JumpSS"       in m: vm["jumpss"]          += 1
        if "unknown bits" in m: vm["unknown_bits"]    += 1
    f["vm_commands_scanned"] = vm_cmds
    f["vm_parental_cmd"] = vm["parental_cmd"] > 0
    f["vm_gprm_counter"] = vm["gprm_counter"] > 0
    f["vm_nav_timer"]    = vm["nav_timer"]    > 0
    f["vm_rnd"]          = vm["rnd"]          > 0
    f["vm_callss"]       = vm["callss"]       > 0
    f["vm_jumpss"]       = vm["jumpss"]       > 0
    f["vm_unknown_bits"] = vm["unknown_bits"]           # >0 = decode gap OR quirk

    # --- GoUp (Return key) authoring: nonzero goup_pgc_nr per domain ---------
    # menu_goup = PGCs where the B13 Return key acts as authored menu-back;
    # title_goup = title-domain parents (Scene It question->hub shape).
    menu_goup = title_goup = 0
    try:
        lst = nav.pgcit(DOM_VMGM, 0)
        for _, ab in (lst or []):
            if (nav.pgc(ab) or {}).get("goup"): menu_goup += 1
    except Exception:
        pass
    for vn in sorted(nav.vts_ifo.keys()):
        for dom in (DOM_VTSM, DOM_TT):
            try:
                lst = nav.pgcit(dom, vn)
                for _, ab in (lst or []):
                    if (nav.pgc(ab) or {}).get("goup"):
                        if dom == DOM_TT: title_goup += 1
                        else:             menu_goup  += 1
            except Exception:
                continue
    f["menu_goup_pgcs"]  = menu_goup
    f["title_goup_pgcs"] = title_goup
    f["has_menu_goup"]   = menu_goup  > 0
    f["has_title_goup"]  = title_goup > 0
    return f


def _iter_all_commands(nav):
    """Yield every 8-byte VM command from FP + every menu PGC + every title PGC
    (pre/post/cell blocks). Best-effort: skips domains a disc lacks."""
    def emit_pgc(pgc):
        if not pgc:
            return
        for blk in ("pre", "post", "cellc"):
            for cmd in pgc.get(blk, []):
                if len(cmd) == 8:
                    yield cmd
    # First Play
    try:
        yield from emit_pgc(nav.fp_pgc())
    except Exception:
        pass
    # VMGM menus
    try:
        lst = nav.pgcit(DOM_VMGM, 0)
        for _, abs_byte in (lst or []):
            yield from emit_pgc(nav.pgc(abs_byte))
    except Exception:
        pass
    # per-VTS: VTSM menus + title PGCs
    for vn in sorted(nav.vts_ifo.keys()):
        for dom in (DOM_VTSM, DOM_TT):
            try:
                lst = nav.pgcit(dom, vn)
                for _, abs_byte in (lst or []):
                    yield from emit_pgc(nav.pgc(abs_byte))
            except Exception:
                continue


# =============================================================================
# aggregate prevalence report
# =============================================================================
# (feature-key, human label, conformance.md gap #) -- ordered by the doc's
# current best-guess gap list so the printed table reads as a verification of
# (or correction to) that ordering.
PREVALENCE_ROWS = [
    ("has_chapters",  "Chapters / PTT  (max_chapters > 1)",        "gap 1"),
    ("multi_angle",   "Multi-angle titles",                        "gap (Phase 9 done)"),
    ("ptl_mait",      "PTL_MAIT parental table present",           "gap 2"),
    ("vm_parental_cmd","SetTmpPML parental command used",          "gap 2"),
    ("any_parental_id","Title has a non-trivial parental_id",      "gap 2"),
    ("region_locked", "Region-locked (partial region mask)",       "gap 2"),
    ("vm_nav_timer",  "NavTimer (SPRM9) set by a command",         "gap 3"),
    ("vm_gprm_counter","GPRM counter-mode (SetMode Counter)",      "gap 3"),
    ("vm_rnd",        "rnd set-op used (game entropy)",            "gap 3"),
    ("has_tmap",      "VTS_TMAPT time map present",                "retired (Phase 8b)"),
    ("txtdt_mgi",     "TXTDT_MGI disc/title text names",           "gap 4"),
    ("dts",           "DTS audio track present",                   "passthrough only"),
    ("lpcm_24bit",    "LPCM 24-bit audio",                         "gap 4"),
    ("lpcm_96k",      "LPCM 96 kHz audio",                         "gap 4"),
    ("vm_callss",     "CallSS (menu call w/ resume)",              "supported"),
    ("vm_jumpss",     "JumpSS (system-space jump)",                "supported"),
    ("has_menu_goup", "Menu GoUp authored (B13 Return acts)",      "supported (B13)"),
    ("has_title_goup","Title-domain GoUp authored",                "supported (B13)"),
    ("vm_unknown_bits","VM command with un-decoded bits",          "decode/quirk"),
]


def _derived(f):
    """Add booleans that are thresholds over raw counts."""
    f["has_chapters"] = f["max_chapters"] > 1
    return f


def report(vectors):
    n = len(vectors)
    print("\n" + "=" * 78)
    print("DVD-VIDEO FEATURE CENSUS  --  %d disc(s)" % n)
    print("=" * 78)

    # per-disc summary line
    for f in vectors:
        print("\n%s" % f["name"])
        print("  VTS=%d titles=%d  max_chapters=%d  max_angles=%d  "
              "audio=%s(<=%dstr) subp<=%d"
              % (f["n_vts"], f["n_titles"], f["max_chapters"], f["max_angles"],
                 ",".join(f["audio_formats"]) or "-", f["max_audio_streams"],
                 f["max_subp_streams"]))
        flags = []
        if f["ptl_mait"]:        flags.append("PTL_MAIT")
        if f["vm_parental_cmd"]: flags.append("SetTmpPML")
        if f["region_locked"]:   flags.append("region=0x%02x" % f["region_mask"])
        if f["has_tmap"]:        flags.append("TMAP(%d)" % f["vts_with_tmap"])
        if f["txtdt_mgi"]:       flags.append("TXTDT")
        if f["dts"]:             flags.append("DTS")
        if f["lpcm_24bit"]:      flags.append("LPCM24")
        if f["lpcm_96k"]:        flags.append("LPCM96k")
        if f["vm_nav_timer"]:    flags.append("NavTimer")
        if f["vm_gprm_counter"]: flags.append("GPRMcounter")
        if f["vm_rnd"]:          flags.append("rnd")
        if f["vm_unknown_bits"]: flags.append("UNKBITS=%d" % f["vm_unknown_bits"])
        print("  scanned %d VM commands. flags: %s"
              % (f["vm_commands_scanned"], " ".join(flags) or "(none)"))

    # aggregate prevalence
    print("\n" + "=" * 78)
    print("PREVALENCE  (discs exercising each feature / %d)  ->  gap priority" % n)
    print("=" * 78)
    print("  %-42s %8s   %s" % ("feature", "discs", "conformance.md"))
    print("  " + "-" * 72)
    for key, label, gap in PREVALENCE_ROWS:
        cnt = sum(1 for f in vectors if f.get(key))
        bar = "#" * cnt + "." * (n - cnt)
        print("  %-42s %3d/%-3d [%s] %s" % (label, cnt, n, bar, gap))
    print("\nNote: prevalence is measured over the local library only -- a small,")
    print("curated set. Treat counts as a coarse prior for gap ordering, not a")
    print("catalog-wide statistic. Add more ISOs to sharpen it.")


# =============================================================================
def gather_isos(paths):
    isos = []
    for p in paths:
        if os.path.isdir(p):
            for nm in sorted(os.listdir(p)):
                if nm.lower().endswith(".iso"):
                    isos.append(os.path.join(p, nm))
        elif os.path.isfile(p):
            isos.append(p)
    return isos


def main():
    ap = argparse.ArgumentParser(description="Batch DVD-Video feature census.")
    ap.add_argument("paths", nargs="*", default=[DEFAULT_DIR],
                    help="ISO files or directories (default: %s)" % DEFAULT_DIR)
    ap.add_argument("--json", help="also write the raw per-disc vectors here")
    args = ap.parse_args()

    isos = gather_isos(args.paths or [DEFAULT_DIR])
    if not isos:
        print("no .iso files found under %s" % args.paths)
        return 1

    vectors = []
    for path in isos:
        try:
            f = _derived(census_iso(path))
            vectors.append(f)
            print("[ok]   %s" % os.path.basename(path))
        except AssertionError as e:
            print("[skip] %s -- not ISO9660 (%s) [UDF-only image?]"
                  % (os.path.basename(path), e))
        except Exception as e:
            print("[err]  %s -- %s" % (os.path.basename(path), e))

    if vectors:
        report(vectors)
    if args.json and vectors:
        with open(args.json, "w") as h:
            json.dump(vectors, h, indent=2)
        print("\nwrote raw vectors -> %s" % args.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
