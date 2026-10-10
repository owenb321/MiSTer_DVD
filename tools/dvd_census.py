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
#   tools/dvd_census.py --captions ...      # + scan the video ES for line-21 CC
#
# --captions adds the one feature that is NOT visible in the IFO at all: NTSC
# line-21 closed captions live in MPEG-2 user_data inside the VOB video stream,
# so no nav table mentions them (libdvdread can't see them either). That scan is
# delegated to tools/cc_scan.py, which opens the ES; it costs a few seconds per
# disc, hence the opt-in flag.
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
def census_iso(path, captions=False):
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
    # The disc forbids region 1 -- the region our SPRM20 constant claims
    # (docs/conformance.md 3rd-edition audit, A/B #2).
    f["region_excl_r1"] = bool(prohibit & 0x01) and prohibit != 0xFF

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
    lpcm_multich = False
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
                if (b1 & 7) > 1:          # channels-1 > 1  ->  more than stereo
                    lpcm_multich = True
    f["vts_with_tmap"] = tmap_vts
    f["has_tmap"]      = tmap_vts > 0
    f["audio_formats"] = sorted(audio_fmts)
    f["dts"]           = dts
    f["lpcm_24bit"]    = lpcm_24bit
    f["lpcm_96k"]      = lpcm_96k
    f["lpcm_multich"]  = lpcm_multich
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
        # player-parameter reads the 3rd-edition audit found hardcoded in
        # dvd_vm.sv sprm_read (decode_vmcmd names SPRM20 "REGION")
        if "SPRM14"       in m: vm["rd_sprm14"]       += 1
        if "SPRM15"       in m: vm["rd_sprm15"]       += 1
        if "REGION"       in m: vm["rd_sprm20"]       += 1
    f["vm_commands_scanned"] = vm_cmds
    f["vm_parental_cmd"] = vm["parental_cmd"] > 0
    f["vm_gprm_counter"] = vm["gprm_counter"] > 0
    f["vm_nav_timer"]    = vm["nav_timer"]    > 0
    f["vm_rnd"]          = vm["rnd"]          > 0
    f["vm_callss"]       = vm["callss"]       > 0
    f["vm_jumpss"]       = vm["jumpss"]       > 0
    f["vm_unknown_bits"] = vm["unknown_bits"]           # >0 = decode gap OR quirk
    f["vm_reads_sprm14"] = vm["rd_sprm14"] > 0
    f["vm_reads_sprm15"] = vm["rd_sprm15"] > 0
    f["vm_reads_sprm20"] = vm["rd_sprm20"] > 0

    # --- PGC header / cell-still axes (3rd-edition audit, 2026-10-01) ---------
    # pg_playback_mode@162 != 0 = random/shuffle programs (reader ignores it);
    # prohibited_ops@8 (u32) != 0 = PGC-level UOPs (not honoured, by decision);
    # still_time@163 != 0 = PGC still (untimed in the reader); an indefinite
    # (0xFF) cell still that also carries a cell command (the reader holds the
    # still and runs the command on Still off, as libdvdnav does, since
    # 2026-10-10 -- docs/dvd_nav.md "An indefinite still and its cell command";
    # the axis stays as the exposure count of that path).
    #
    # Re-rank pass (2026-10-06) splits two of them:
    #   * @162 is random when non-zero with bit 7 CLEAR (libdvdnav play.c:69
    #     picks a random first program among (mode & 0x7F) + 1) and shuffle when
    #     bit 7 is SET (libdvdnav does not implement shuffle either).
    #   * the 0xFF-still + cell-command cells used to be classed loop / non-loop
    #     (the reader ran a looping command before the still); since the reader
    #     holds every one, the class no longer drives behaviour and was retired.
    #     A cmd_nr past the PGC's cell commands is counted instead (libdvdnav:
    #     "Invalid Cell command", the still holds and the next cell plays).
    pgc_ax = collections.Counter()
    pb_list, still_cmds = [], []
    for dom, abs_byte, pgc in _iter_all_pgcs(nav):
        try:
            h = nav.rd(abs_byte, 236)
        except Exception:
            continue
        pbm = h[162]
        if pbm:
            pgc_ax["pbmode"] += 1
            pgc_ax["pb_shuffle" if pbm & 0x80 else "pb_random"] += 1
            if dom == DOM_TT:
                pgc_ax["pb_tt"] += 1
            pb_list.append("%s:0x%02x/%dpg" % (_DOM_NAME.get(dom, dom), pbm,
                                               pgc.get("nr_pgms", 0)))
        if _be32(h, 8) and dom == DOM_TT:
            pgc_ax["uop_tt"] += 1
        if h[163]:
            pgc_ax["pgc_still"] += 1
        cellc = pgc.get("cellc", [])
        for c in pgc.get("cells", []):
            if c["still"] == 0xFF and c["cmd_nr"]:
                pgc_ax["inf_still_cmd_tt" if dom == DOM_TT else "inf_still_cmd_menu"] += 1
                if 0 < c["cmd_nr"] <= len(cellc):
                    m = decode_vmcmd(cellc[c["cmd_nr"] - 1])
                else:
                    m = "cmd_nr %d > %d" % (c["cmd_nr"], len(cellc))
                    pgc_ax["inf_still_badcmd"] += 1
                still_cmds.append("%s:%s" % (_DOM_NAME.get(dom, dom), m))
    f["pgc_random_mode"]     = pgc_ax["pbmode"] > 0
    f["pgc_random"]          = pgc_ax["pb_random"] > 0
    f["pgc_shuffle"]         = pgc_ax["pb_shuffle"] > 0
    f["pgc_pbmode_title"]    = pgc_ax["pb_tt"] > 0
    f["pgc_pbmode_list"]     = pb_list
    f["pgc_uop_title"]       = pgc_ax["uop_tt"] > 0
    f["pgc_still_time"]      = pgc_ax["pgc_still"] > 0
    f["inf_still_cmd_title"] = pgc_ax["inf_still_cmd_tt"] > 0
    f["inf_still_cmd_menu"]  = pgc_ax["inf_still_cmd_menu"] > 0
    f["inf_still_badcmd"]    = pgc_ax["inf_still_badcmd"] > 0
    f["inf_still_cmds"]      = still_cmds

    # --- menu-key entries (3rd-edition audit item 10, 2026-10-06) -------------
    # The VM's Title / Menu / Chapter Menu keys jump to entry 2 (VMGM Title),
    # 3 (VTSM Root) and 7 (VTSM PTT). The reader matches entry_id bit 7 + low
    # nibble and, when NO SRP matches, takes SRP[0] = PGC 1
    # (dvd_iso_reader.sv S_SRP_EVAL). The book (3rd ed. p. 9-26, quoting the
    # spec: "the transition to Root menu is not actually executed") and
    # libdvdnav (get_ID -> set_PGCN fails -> domain restored) make a missing
    # entry a no-op. A domain with no PGCI_UT at all is a pgc_error instead,
    # which runs the VM's fallback chain -- not counted here.
    #   key_pgc1_*      : the UT exists but lacks the entry -> PGC 1 plays
    #   key_pgc1_*_root : ...and that PGC 1 is the Root menu (benign: lands on
    #                     the main menu, as the manual describes for Chapter)
    def _entries(lst):
        return {e & 0x0F for e, _ in (lst or []) if e & 0x80}

    def _srp0(lst):
        return (lst[0][0] & 0x8F) if lst else 0

    try:
        vm_lst = nav.pgcit(DOM_VMGM, 0)
    except Exception:
        vm_lst = None
    f["vmgm_title_menu"] = 2 in _entries(vm_lst)
    f["key_pgc1_title"]  = bool(vm_lst) and not f["vmgm_title_menu"]
    title_vts = sorted({t["vts"] for t in titles if t["vts"]})
    miss_root = miss_ptt = miss_ptt_root = miss_root_any = 0
    for vn in title_vts:
        try:
            lst = nav.pgcit(DOM_VTSM, vn)
        except Exception:
            lst = None
        if not lst:
            continue
        ids = _entries(lst)
        if 3 not in ids:
            miss_root += 1
        if 7 not in ids:
            miss_ptt += 1
            if _srp0(lst) == 0x83:
                miss_ptt_root += 1
    f["key_pgc1_menu"]      = miss_root > 0
    f["key_pgc1_cmenu"]     = miss_ptt > 0
    f["key_pgc1_cmenu_nonroot"] = miss_ptt > miss_ptt_root
    f["vtsm_title_sets"]    = len(title_vts)

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
    # --- line-21 closed captions (video ES, opt-in) --------------------------
    f["cc_scanned"] = False
    if captions:
        from cc_scan import scan_iso as cc_scan_iso, verdict as cc_verdict
        try:
            res, err = cc_scan_iso(path)
        except Exception:                                        # noqa: BLE001
            res, err = None, "scan failed"
        if res and not err:
            _, _, acc, _ = res
            f["cc_scanned"]   = acc["pics"] > 0
            f["cc_present"]   = acc["nonnull"] > 0      # live captions
            f["cc_carrier"]   = acc["cc_blocks"] > 0 and acc["nonnull"] == 0
            f["cc_pairs"]     = acc["pairs"]
            f["cc_nonnull"]   = acc["nonnull"]
            f["cc_field2"]    = acc["nonnull_field"][0] > 0
            f["cc_708"]       = acc["ga94_cc"] > 0
            f["cc_verdict"]   = cc_verdict(acc)[0]

    return f


_DOM_NAME = {DOM_FP: "FP", DOM_VMGM: "VMGM", DOM_VTSM: "VTSM", DOM_TT: "TT"}
# Cell commands that keep a 0xFF still's cell (or its PGC) looping: running
# them before the still looks the same as holding it (conformance.md, class C).
def _iter_all_pgcs(nav):
    """Yield (domain, pgc_abs_byte, parsed_pgc) for every menu and title PGC.
    Best-effort like _iter_all_commands (FP is not in a PGCIT, so not here)."""
    for dom, vlist in ((DOM_VMGM, [0]),
                       (DOM_VTSM, sorted(nav.vts_ifo.keys())),
                       (DOM_TT,   sorted(nav.vts_ifo.keys()))):
        for vn in vlist:
            try:
                lst = nav.pgcit(dom, vn)
            except Exception:
                continue
            for _, abs_byte in (lst or []):
                try:
                    yield dom, abs_byte, nav.pgc(abs_byte)
                except Exception:
                    continue


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
    ("has_chapters",  "Chapters / PTT  (max_chapters > 1)",        "supported (PTT, fj#127)"),
    ("multi_angle",   "Multi-angle titles",                        "supported (Phase 9)"),
    ("ptl_mait",      "PTL_MAIT parental table present",           "gap: parental"),
    ("vm_parental_cmd","SetTmpPML parental command used",          "gap: parental"),
    ("any_parental_id","Title has a non-trivial parental_id",      "gap: parental"),
    ("region_locked", "Region-locked (partial region mask)",       "never refused (by design)"),
    ("vm_nav_timer",  "NavTimer (SPRM9) set by a command",         "stored, never fires"),
    ("vm_gprm_counter","GPRM counter-mode (SetMode Counter)",      "supported (fj#119)"),
    ("vm_rnd",        "rnd set-op used (game entropy)",            "supported (fj#119)"),
    ("has_tmap",      "VTS_TMAPT time map present",                "supported (TMAP seek, #127)"),
    ("txtdt_mgi",     "TXTDT_MGI disc/title text names",           "closed (never shown)"),
    ("dts",           "DTS audio track present",                   "decoded (#148) + passthrough"),
    ("lpcm_24bit",    "LPCM 24-bit audio",                         "supported (#162)"),
    ("lpcm_96k",      "LPCM 96 kHz audio",                         "supported (#162)"),
    # --- 3rd-edition audit axes (docs/conformance.md, 2026-10-01) ---------
    ("lpcm_multich",  "LPCM with more than 2 channels",            "supported (#162)"),
    ("vm_reads_sprm20","Command reads SPRM20 (player region)",     "audit #2, done (#154)"),
    ("region_excl_r1","Region mask forbids region 1",              "audit #2, done (#154)"),
    ("vm_reads_sprm14","Command reads SPRM14 (video pref/aspect)", "audit #3, done (#154)"),
    ("vm_reads_sprm15","Command reads SPRM15 (audio caps)",        "audit #3, done (#154)"),
    ("pgc_random_mode","PGC random/shuffle playback mode",         "audit #9 (open)"),
    ("pgc_random",    "  ...random (bit 7 clear; libdvdnav does it)","audit #9 (open)"),
    ("pgc_shuffle",   "  ...shuffle (bit 7 set; libdvdnav doesn't)","audit #9 (open)"),
    ("pgc_pbmode_title","  ...on a title-domain PGC",              "audit #9 (open)"),
    ("vmgm_title_menu","VMGM Title menu authored (Title key target)","audit #10a (open)"),
    ("key_pgc1_title","Title key: VMGM lacks entry 2 -> PGC 1",    "audit #10b (open)"),
    ("key_pgc1_menu", "Menu key: a title VTSM lacks Root -> PGC 1", "audit #10b (open)"),
    ("key_pgc1_cmenu","Chapter key: a title VTSM lacks PTT -> PGC 1","audit #10b (open)"),
    ("key_pgc1_cmenu_nonroot","  ...and that PGC 1 is not the Root menu","audit #10b (open)"),
    ("pgc_uop_title", "Title PGC authors UOP prohibitions",        "not honoured (decision)"),
    ("pgc_still_time","PGC still time authored",                   "audit C (deferred)"),
    ("inf_still_cmd_title","0xFF cell still + cell command (title)","holds, then the command"),
    ("inf_still_cmd_menu", "0xFF cell still + cell command (menu)", "holds, then the command"),
    ("inf_still_badcmd",   "  ...its cmd_nr is past the cell commands","holds, then the next cell"),
    ("vm_callss",     "CallSS (menu call w/ resume)",              "supported"),
    ("vm_jumpss",     "JumpSS (system-space jump)",                "supported"),
    ("has_menu_goup", "Menu GoUp authored (B13 Return acts)",      "supported (B13)"),
    ("has_title_goup","Title-domain GoUp authored",                "supported (B13)"),
    ("vm_unknown_bits","VM command with un-decoded bits",          "decode/quirk"),
    # --captions only (rows read 0/N when the ES scan was not requested)
    ("cc_present",    "Line-21 captions (EIA-608 in user_data)",    "line-21 re-insertion"),
    ("cc_carrier",    "  ...CC carrier present but all-null",       "n/a"),
    ("cc_708",        "  ...CEA-708 (A/53 GA94 cc_data)",           "not decoded"),
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
        if f["pgc_pbmode_list"]: flags.append("PBMODE(%s)" % ",".join(f["pgc_pbmode_list"]))
        if f["inf_still_cmds"]:
            flags.append("STILLCMD(%s)" % "; ".join(f["inf_still_cmds"][:4]))
        if f.get("cc_present"):  flags.append("CC608(%d/%d pairs%s)"
                                              % (f["cc_nonnull"], f["cc_pairs"],
                                                 ",f2" if f.get("cc_field2") else ""))
        elif f.get("cc_carrier"): flags.append("CC-carrier-only")
        if f.get("cc_708"):      flags.append("CEA708")
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
        w = min(n, 40)                  # a 1,500-disc library needs a scaled bar
        k = (cnt * w + n - 1) // n if n else 0
        bar = "#" * k + "." * (w - k)
        print("  %-46s %4d/%-4d [%s] %s" % (label, cnt, n, bar, gap))
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
    ap.add_argument("--captions", action="store_true",
                    help="also scan the video ES for line-21 captions (slower)")
    args = ap.parse_args()

    isos = gather_isos(args.paths or [DEFAULT_DIR])
    if not isos:
        print("no .iso files found under %s" % args.paths)
        return 1

    vectors = []
    for path in isos:
        try:
            f = _derived(census_iso(path, captions=args.captions))
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
