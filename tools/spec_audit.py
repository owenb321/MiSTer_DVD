#!/usr/bin/env python3
# =============================================================================
# spec_audit.py -- measure DVD-Video ISOs against THIS CORE's implemented limits
# =============================================================================
# Phase 1 of docs/spec_hardening.md: turn "no test disc authors X" from an
# assumption into a measurement. Scans one ISO (or directories/globs of them)
# and reports, per disc, every axis where the disc's authoring approaches or
# exceeds the core's implemented limits -- so Phases 2-6 get re-ranked on
# evidence, and future rips get a standard pre-flight next to tools/css_scan.py
# (run css_scan FIRST: this tool assumes a decrypted rip; scrambled packs
# would garble the --deep VOB scan).
#
# It is a first-party oracle: it reuses OUR validated parsers, not libdvdread --
#   * IsoNav         from dvd_vm_ref.py   (ISO9660 walk, TT_SRPT, PGCIT/PGC)
#   * parse_vts_attr from nav_extract.py  (VTSI_MAT audio attributes)
#   * still_heuristic from iso_nav_check.py (the libdvdnav vm.c still detector
#                                            the RTL reproduces -- PR #165)
# and the --deep VOB scan mirrors the pack/PES walk of tools/css_scan.py +
# tools/spu_ref.py (SPU unit assembly by SPDSZ) and tools/nav_extract.py
# (PCI/HLI offsets, validated vs nav_types.h).
#
# Usage:
#   tools/spec_audit.py <iso-or-dir> [...]        # IFO-side audit (seconds/disc)
#   tools/spec_audit.py --deep <iso-or-dir> [...] # + full VOB scan (SPU sizes,
#                                                 #   HLI button groups, foac)
#   tools/spec_audit.py --json out.json ...       # also dump raw per-disc dicts
#
# Exit status: 0 = no disc exceeds any implemented cap, 1 = at least one
# EXCEEDS finding (scriptable as a ripper post-check, like css_scan).
# =============================================================================
import sys, os, glob, json, struct, argparse, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav, DOM_VMGM, DOM_VTSM, DOM_TT        # noqa: E402
from nav_extract import parse_vts_attr, AUDIO_FMT                # noqa: E402
from iso_nav_check import still_heuristic                        # noqa: E402

SEC = 2048

# =============================================================================
# The RTL caps table -- keep in sync with the RTL (each entry names the actual
# constant). "spec" columns cite libdvdread ifo_types.h / DVD Demystified via
# docs/spec_hardening.md's audit table.
# =============================================================================
CAP_PTT        = 256     # dvd/dvd_iso_reader.sv PTT_CAP (ptt_mem);  spec: nr_of_ptts u16
CAP_SPU        = 32768   # dvd/spu_decode.sv SPU_CAP;                spec: 53,220 B/frame
SPEC_SPU       = 53220   #   (DVD Demystified: max subpicture unit size)
CAP_MAXCELL    = 255     # dvd/dvd_iso_reader.sv MAXCELL;            spec: 255 (u8) exact
CAP_VM_CMDS    = 512     # dvd/dvd_vm.sv cmem 4096x8 (reader clamp 511);
SPEC_VM_BLOCK  = 128     #   spec: 128 pre + 128 post + 128 cell = 384 total/PGC
SPEC_VM_TOTAL  = 384
CAP_PBTIME     = 35999   # dvd/dvd_iso_reader.sv pb_c/cell_secs/still_secs (16-bit
                         #   seconds since spec-hardening Phase 6; was the 8-bit 255
                         #   clamp); spec: C_PBTM up to 9:59:59 = 35,999 s EXACT --
                         #   an EXCEEDS on this axis now means illegal BCD authoring
CAP_TITLE_SEL  = 99      # dvd/emu.sv P1 Debug "Title VTS" picker (two BCD digits,
                         #   status[39:32], PR #175; was the 4-bit O[31:28]);
                         #   spec: 99 VTS exact. Auto is unaffected.
CAP_VTS        = 99      # dvd/dvd_iso_reader.sv MAXGRP/MAXEXT = 100;  spec: 99 exact
CAP_PGCN_OLD   = 255     # pre-PR#164 8-bit PGCN (regression watch; now 16-bit >= spec 15)
# Behavioral (not capacity) -- census axes for Phases 3/4 + the audio gap:
#   * PGCI_UT language units: dvd/dvd_iso_reader.sv S_UT_HDR uses LU[0]
#     unconditionally (Phase 4)
#   * HLI button groups: dvd/nav_pci.sv always uses group 1 (Phase 3);
#     hl_gi.btngr_ns @PCI+0x6E bits[5:4], dsp_ty 3-bit fields
#   * MPEG audio (stream_id 0xC0-0xDF) is discarded by dvd/ps_demux.sv --
#     an MPEG-audio-only title plays SILENT (known gap, docs/conformance.md)

STILL_RATE = 30          # sect/s: below = still-shaped (libdvdnav vm.c heuristic,
                         # mirrored by still_heuristic / the RTL heur_hit_w)


def be16(b, o): return struct.unpack('>H', b[o:o+2])[0]
def be32(b, o): return struct.unpack('>I', b[o:o+4])[0]
def bcd(x):     return (x >> 4) * 10 + (x & 0x0F)
def bcd_secs(t): return bcd(t[0])*3600 + bcd(t[1])*60 + bcd(t[2])


# =============================================================================
# IFO-side audit (always on)
# =============================================================================
def _ut_lus(nav, dom, vts):
    """PGCI_UT language units: list of (lang_str, exists) -- Phase-4 census.
    Layout: nr_of_lus u16@0; LU[i]@8+8i = {lang_code 2B@0, lang_ext@2,
    exists@3, lang_start_byte u32@4} (ifo_types.h pgci_ut_t/pgci_lu_t)."""
    if dom == DOM_VMGM:
        if nav.vmgi_lba is None or not nav.vmgm_ut:
            return None
        ut_abs = (nav.vmgi_lba + nav.vmgm_ut) * SEC
    else:
        ifo = nav.vts_ifo.get(vts)
        if ifo is None:
            return None
        ptr = be32(nav.rd(ifo*SEC + 208, 4), 0)
        if not ptr:
            return None
        ut_abs = (ifo + ptr) * SEC
    nr = be16(nav.rd(ut_abs, 2), 0)
    if not (1 <= nr < 100):
        return None
    out = []
    for i in range(nr):
        lu = nav.rd(ut_abs + 8 + i*8, 8)
        out.append((lu[0:2].decode('ascii', 'replace'), lu[3]))
    return out


def _pgc_cmd_counts(nav, ab):
    """(nr_pre, nr_post, nr_cell) from a PGC's command table (0,0,0 if none)."""
    h = nav.rd(ab, 236)
    if len(h) < 236:
        return 0, 0, 0, 0
    cmd_off = be16(h, 228)
    if not cmd_off:
        return 0, 0, 0, h[3]
    ct = nav.rd(ab + cmd_off, 6)
    return be16(ct, 0), be16(ct, 2), be16(ct, 4), h[3]


def _pgc_cells(nav, ab):
    """Cell playback entries with sector spans (IsoNav.pgc omits sectors):
    yields (idx, pbtime_s, first, lvobu, last, still, cmd_nr, pgc_still,
    is_last_cell). 24-B cell_playback_t: category@0, still@2, cmd_nr@3,
    C_PBTM@4, first_sector@8, last_vobu_start@16, last_sector@20 (all BE)."""
    h = nav.rd(ab, 236)
    if len(h) < 236:
        return
    ncell = h[3]
    cell_off = be16(h, 232)
    pgc_still = h[163]
    if not cell_off or not ncell:
        return
    for i in range(ncell):
        e = nav.rd(ab + cell_off + i*24, 24)
        if len(e) < 24:
            return
        yield (i, bcd_secs(e[4:8]), e[4:8], be32(e, 8), be32(e, 16), be32(e, 20),
               e[2], e[3], pgc_still, i == ncell - 1)


def audit_ifo(nav, d):
    """Fill d with the IFO-side measurements + findings."""
    F = d["findings"]
    mat = nav.sec(nav.vmgi_lba)
    n_vts = be16(mat, 62)                                  # VMGI nr_of_title_sets @62
    d["n_vts"] = n_vts
    if n_vts > CAP_TITLE_SEL:
        F.append(("WARN", "title_sel",
                  "%d VTS > %d: OSD 'DVD Title' override (4-bit status[31:28]) "
                  "cannot reach VTS_%02d+; Auto unaffected" % (n_vts, CAP_TITLE_SEL,
                                                               CAP_TITLE_SEL + 1)))
    if n_vts > CAP_VTS:
        F.append(("EXCEEDS", "vts_count",
                  "%d VTS > MAXGRP headroom %d" % (n_vts, CAP_VTS)))

    # --- TT_SRPT: PTT (chapter) count per title vs PTT_CAP --------------------
    d["max_ptt"] = (0, 0)                                  # (count, title#)
    tsp = be32(mat, 196)
    if 0 < tsp <= 0xFFFFF:
        tt = nav.sec(nav.vmgi_lba + tsp)
        for i in range(min(be16(tt, 0), 99)):
            e = tt[8 + i*12: 8 + i*12 + 12]
            if len(e) < 12:
                break
            nptt = be16(e, 2)                              # title_info_t.nr_of_ptts @2
            if nptt > d["max_ptt"][0]:
                d["max_ptt"] = (nptt, i + 1)
    if d["max_ptt"][0] > CAP_PTT:
        F.append(("EXCEEDS", "ptt_mem",
                  "title %d has %d PTTs > PTT_CAP %d (graceful: HUD/user-skip "
                  "clamp only; VM JumpVTS_PTT stays exact)"
                  % (d["max_ptt"][1], d["max_ptt"][0], CAP_PTT)))

    # --- per-domain PGCIT walk: PGC counts, command tables, cells -------------
    doms = [("VMGM", DOM_VMGM, 0)]
    for vn in sorted(nav.vts_ifo):
        doms += [("VTSM", DOM_VTSM, vn), ("TT", DOM_TT, vn)]

    d["max_pgcs"]   = (0, "")          # (count, "dom vts")
    d["max_cmds"]   = (0, "", (0, 0, 0))  # (total, where, (pre,post,cell))
    d["cells_gt255"] = []              # (where, cell, secs, cmd_nr, is_last)
    d["still_cells"] = 0               # heuristic/explicit held cells (PR #165 class)
    d["max_still"]  = (0, "")          # (pbtime, where)
    for dnm, dm, vn in doms:
        try:
            lst = nav.pgcit(dm, vn)
        except Exception:
            lst = None
        if not lst:
            continue
        where_dom = "%s%s" % (dnm, (" VTS_%02d" % vn) if vn else "")
        if len(lst) > d["max_pgcs"][0]:
            d["max_pgcs"] = (len(lst), where_dom)
        for idx, (eid, ab) in enumerate(lst):
            pgcn = idx + 1
            where = "%s PGC %d" % (where_dom, pgcn)
            try:
                npre, npost, ncell_c, ncells = _pgc_cmd_counts(nav, ab)
            except Exception:
                continue
            tot = npre + npost + ncell_c
            if tot > d["max_cmds"][0]:
                d["max_cmds"] = (tot, where, (npre, npost, ncell_c))
            if tot > CAP_VM_CMDS:
                F.append(("EXCEEDS", "vm_cmds",
                          "%s: %d commands (pre=%d post=%d cell=%d) > cmem %d "
                          "-- commands past the clamp are DROPPED"
                          % (where, tot, npre, npost, ncell_c, CAP_VM_CMDS)))
            elif max(npre, npost, ncell_c) > SPEC_VM_BLOCK:
                F.append(("WARN", "vm_cmds_spec",
                          "%s: a command block exceeds the spec's 128/block "
                          "(pre=%d post=%d cell=%d; fits our cmem %d)"
                          % (where, npre, npost, ncell_c, CAP_VM_CMDS)))
            if ncells > CAP_MAXCELL:
                F.append(("EXCEEDS", "max_cells",
                          "%s: %d cells > MAXCELL %d" % (where, ncells, CAP_MAXCELL)))
            try:
                for (ci, pb, pb_raw, first, lvobu, last, cstill, cmd_nr, pstill,
                     is_last) in _pgc_cells(nav, ab):
                    eff, how = still_heuristic(cstill, pstill, is_last,
                                               first, lvobu, last, pb_raw)
                    if pb > CAP_PBTIME:
                        d["cells_gt255"].append((where, ci, pb, cmd_nr,
                                                 is_last, eff))
                    if eff:                    # explicit still or heuristic HOLD
                        d["still_cells"] += 1
                        if pb > d["max_still"][0]:
                            d["max_still"] = (pb, "%s cell %d" % (where, ci))
            except Exception:
                pass

    if d["max_pgcs"][0] > CAP_PGCN_OLD:
        F.append(("INFO", "pgcn15",
                  "%s has %d PGCs (>255: needs the PR #164 15-bit PGCN paths -- "
                  "regression watch)" % (d["max_pgcs"][1], d["max_pgcs"][0])))
    # pbtime > CAP_PBTIME: Phase 6 widened the duration machinery to the
    # C_PBTM spec max (35,999 s), so this axis only fires on ILLEGAL BCD
    # authoring now. The still-shaped/data-backed split is kept: still-shaped
    # over-cap cells would under-hold, data-backed ones end at data exhaustion.
    clamped_holds = [(w, ci, pb) for w, ci, pb, cmd, lst, eff
                     in d["cells_gt255"] if eff]
    benign = len(d["cells_gt255"]) - len(clamped_holds)
    for where, ci, pb in clamped_holds:
        F.append(("EXCEEDS", "pbtime_clamp",
                  "%s cell %d: STILL-SHAPED cell with pbtime %d s > %d s clamp "
                  "-- under-holds by ~%d s (Phase-6 repro)"
                  % (where, ci, pb, CAP_PBTIME, pb - CAP_PBTIME)))
    if benign:
        mx = max(pb for _, _, pb, _, _, eff in d["cells_gt255"] if not eff)
        F.append(("INFO", "pbtime_gt255",
                  "%d data-backed cell(s) with pbtime > %d s (max %d s) -- "
                  "clamp saturates harmlessly (cell ends at data exhaustion)"
                  % (benign, CAP_PBTIME, mx)))

    # --- PGCI_UT language units (Phase 4) --------------------------------------
    d["multi_lu"] = []                 # (domain, [(lang, exists), ...])
    for dnm, dm, vn in [("VMGM", DOM_VMGM, 0)] + \
                       [("VTSM VTS_%02d" % v, DOM_VTSM, v) for v in sorted(nav.vts_ifo)]:
        try:
            lus = _ut_lus(nav, dm, vn)
        except Exception:
            lus = None
        if lus and len(lus) > 1:
            d["multi_lu"].append((dnm, lus))
            F.append(("WARN", "multi_lu",
                      "%s PGCI_UT has %d language units (%s) -- reader uses "
                      "LU[0] unconditionally (Phase 4)"
                      % (dnm, len(lus), ",".join(l for l, _ in lus))))

    # --- audio attributes: MPEG-audio-only title VTS ---------------------------
    d["mpeg_only_vts"] = []
    for vn in sorted(nav.vts_ifo):
        if vn not in nav.groups:                # menu-only VTS: no title audio
            continue
        try:
            na, _, audio, _ = parse_vts_attr(nav.sec(nav.vts_ifo[vn]))
        except Exception:
            continue
        fmts = set(fmt for fmt, _, _, _, _ in audio[:na])
        if na and fmts and fmts <= {2, 3}:      # MPEG1 / MPEG2ext only
            d["mpeg_only_vts"].append(vn)
            F.append(("WARN", "mpeg_audio",
                      "VTS_%02d title audio is MPEG-audio only (%s) -- plays "
                      "SILENT (ps_demux discards 0xC0-0xDF; conformance.md gap)"
                      % (vn, ",".join(sorted(AUDIO_FMT.get(f, str(f)) for f in fmts)))))
    return d


# =============================================================================
# --deep: full VOB scan (SPU sizes, HLI button groups, foac)
# =============================================================================
def _video_ts_vob(nav):
    """VIDEO_TS.VOB (VMGM_VOBS) extent -- IsoNav._walk only keeps VTS_* files."""
    d = nav.sec(16)
    root_lba = struct.unpack('<I', d[158:162])[0]
    root_len = struct.unpack('<I', d[166:170])[0]

    def walk(dlba, dlen):
        nsec = (dlen + SEC - 1) // SEC
        buf = b''.join(nav.sec(dlba + i) for i in range(nsec))
        for s in range(nsec):
            p = s * SEC
            while p < s * SEC + SEC:
                rl = buf[p]
                if rl == 0:
                    break
                yield (buf[p+33:p+33+buf[p+32]].upper(),
                       struct.unpack('<I', buf[p+2:p+6])[0],
                       struct.unpack('<I', buf[p+10:p+14])[0], buf[p+25])
                p += rl

    vdir = None
    for nm, ext, dl, fl in walk(root_lba, root_len):
        if nm.startswith(b'VIDEO_TS') and (fl & 2):
            vdir = (ext, dl)
    if not vdir:
        return None
    for nm, ext, dl, fl in walk(*vdir):
        if nm.startswith(b'VIDEO_TS.VOB'):
            return (ext, dl)
    return None


def scan_domain(f, extents):
    """Scan a domain's VOB extents (in stream order) for SPU unit sizes and
    NAV-pack HLI features. Mirrors css_scan's pack walk + spu_ref's SPU unit
    assembly (units concatenate per substream by SPDSZ = the SPU's first u16)
    and nav_extract's PCI offsets (PCI data @0x2D; hl_gi @0x60 PCI-relative)."""
    st = {}                            # substream -> bytes remaining in unit
    r = {"max_spu": 0, "max_spu_sub": 0, "max_spu_at": 0, "spu_units": 0,
         "spu_trunc": 0, "nav": 0, "hli": 0, "btngr_sites": 0, "btngr_max": 0,
         "dsp_ty": set(), "foac": 0}
    pos = 0                            # running domain-relative sector index
    CHUNK = 4096 * SEC                 # 8 MB
    for lba, size in extents:
        f.seek(lba * SEC)
        left = (size // SEC) * SEC
        while left > 0:
            buf = f.read(min(CHUNK, left))
            if not buf:
                break
            left -= len(buf)
            n = len(buf) // SEC
            for si in range(n):
                o = si * SEC
                if not (buf[o] == 0 and buf[o+1] == 0 and buf[o+2] == 1
                        and buf[o+3] == 0xBA):
                    pos += 1
                    continue
                # NAV pack? (fixed layout: pack 14 B, system hdr 24 B, 01 BF, PCI)
                if (buf[o+0x26] == 0 and buf[o+0x27] == 0 and buf[o+0x28] == 1
                        and buf[o+0x29] == 0xBF and buf[o+0x2C] == 0x00):
                    r["nav"] += 1
                    pci = o + 0x2D
                    if ((buf[pci+0x60] << 8 | buf[pci+0x61]) & 3) != 0:
                        r["hli"] += 1
                        # Gate the button-feature axes on btn_ns > 0: junk-HLI
                        # NAV-shaped packs exist (found in a dummy VTS on a real
                        # disc: hli_ss=1 but btn_ns=0, fosl=47, garbage rects)
                        # and a "highlight" with zero buttons is meaningless.
                        if buf[pci+0x71] & 0x3F:             # btn_ns
                            gn = (buf[pci+0x6E] >> 4) & 3    # hl_gi.btngr_ns
                            if gn > r["btngr_max"]:
                                r["btngr_max"] = gn
                            if gn > 1:
                                r["btngr_sites"] += 1
                                r["dsp_ty"].add((buf[pci+0x6E] & 7,        # gr1
                                                 (buf[pci+0x6F] >> 4) & 7,  # gr2
                                                 buf[pci+0x6F] & 7))        # gr3
                            if buf[pci+0x75] & 0x3F:         # foac_btnn
                                r["foac"] += 1
                    pos += 1
                    continue
                # walk PES packets for private_stream_1 subpicture payloads
                p = o + 14 + (buf[o+13] & 7)
                end = o + SEC
                while p + 6 <= end:
                    if not (buf[p] == 0 and buf[p+1] == 0 and buf[p+2] == 1):
                        break
                    sid = buf[p+3]
                    ln = (buf[p+4] << 8) | buf[p+5]
                    if sid == 0xBD and ln >= 4 and (buf[p+6] & 0xC0) == 0x80:
                        pay = p + 9 + buf[p+8]               # skip PES opt header
                        pend = min(p + 6 + ln, end)
                        if pay < pend and 0x20 <= buf[pay] <= 0x3F:
                            sub = buf[pay]
                            chunk = pend - (pay + 1)
                            # A real SPU unit STARTS in a PTS-carrying PES
                            # (continuation PES have no PTS) -- keying only on
                            # byte count desyncs at truncated units (cell/ILVU
                            # boundaries) and mid-unit bytes get read as a bogus
                            # giant SPDSZ (found on Robin Hood: fake 59,785 B,
                            # garbage DCSQ, unit start with pts=None).
                            if buf[p+7] & 0x80:              # PTS flag: unit start
                                if st.get(sub, 0):
                                    r["spu_trunc"] += 1      # prior unit abandoned
                                if chunk >= 2:
                                    spdsz = (buf[pay+1] << 8) | buf[pay+2]
                                    r["spu_units"] += 1
                                    if spdsz > r["max_spu"]:
                                        r["max_spu"] = spdsz
                                        r["max_spu_sub"] = sub
                                        r["max_spu_at"] = pos
                                    st[sub] = max(spdsz - chunk, 0)
                            else:                            # continuation chunk
                                st[sub] = max(st.get(sub, 0) - chunk, 0)
                    p += 6 + ln
                pos += 1
    return r


def audit_deep(nav, d, verbose=False):
    F = d["findings"]
    doms = []                          # (label, extents)
    vmgm = _video_ts_vob(nav)
    if vmgm:
        doms.append(("VMGM", [vmgm]))
    for vn in sorted(nav.vts_ifo):
        mv = nav.menu_vob.get(vn)
        if mv:
            doms.append(("VTSM VTS_%02d" % vn, [mv]))
        parts = nav.groups.get(vn)
        if parts:
            doms.append(("TT VTS_%02d" % vn, sorted(parts)))  # parts by LBA

    d["deep"] = {}
    for label, extents in doms:
        mb = sum(sz for _, sz in extents) / 1e6
        if verbose:
            print("    scanning %-14s %8.1f MB ..." % (label, mb),
                  flush=True, end="")
        r = scan_domain(nav.f, extents)
        if verbose:
            print(" max_spu=%d nav=%d hli=%d trunc=%d"
                  % (r["max_spu"], r["nav"], r["hli"], r["spu_trunc"]))
        r["dsp_ty"] = sorted(r["dsp_ty"])
        d["deep"][label] = r
        if r["max_spu"] > SPEC_SPU:
            F.append(("WARN", "spu_size",
                      "%s: SPU of %d B exceeds even the spec max %d (substream "
                      "0x%02X @RBN %d) -- dropped by design"
                      % (label, r["max_spu"], SPEC_SPU, r["max_spu_sub"],
                         r["max_spu_at"])))
        elif r["max_spu"] > CAP_SPU:
            F.append(("EXCEEDS", "spu_cap",
                      "%s: SPU of %d B > SPU_CAP %d (substream 0x%02X @RBN %d) "
                      "-- DCSQ at the SPU tail is lost, subpicture+highlight "
                      "invisible (the twice-bitten PR #84 class; Phase 2)"
                      % (label, r["max_spu"], CAP_SPU, r["max_spu_sub"],
                         r["max_spu_at"])))
        if r["btngr_sites"]:
            F.append(("WARN", "btngr",
                      "%s: %d HLI NAV packs with btngr_ns=%d (>1 group; dsp_ty "
                      "%s) -- nav_pci always uses group 1 (Phase 3)"
                      % (label, r["btngr_sites"], r["btngr_max"],
                         r["dsp_ty"])))
        if r["foac"]:
            F.append(("INFO", "foac",
                      "%s: %d HLI NAV packs with foac != 0 (forced-activate "
                      "button census)" % (label, r["foac"])))
    return d


# =============================================================================
# report
# =============================================================================
SEV_ORDER = {"EXCEEDS": 0, "WARN": 1, "INFO": 2}


def verdict(d):
    sevs = set(s for s, _, _ in d["findings"])
    if "EXCEEDS" in sevs:
        return "EXCEEDS"
    if "WARN" in sevs:
        return "WARN"
    return "PASS"


def report_disc(d, deep):
    print("\n%s  --  %s" % (d["name"], verdict(d)))
    print("  VTS=%d  max PTTs/title=%d (title %d, cap %d)  max PGCs/PGCIT=%d (%s)"
          % (d["n_vts"], d["max_ptt"][0], d["max_ptt"][1], CAP_PTT,
             d["max_pgcs"][0], d["max_pgcs"][1] or "-"))
    mc = d["max_cmds"]
    print("  max PGC cmds=%d (%s; pre/post/cell=%d/%d/%d; cmem %d, spec %d/blk)"
          % (mc[0], mc[1] or "-", mc[2][0], mc[2][1], mc[2][2],
             CAP_VM_CMDS, SPEC_VM_BLOCK))
    print("  still-shaped cells=%d (max pbtime %d s%s)  cells>%ds=%d"
          % (d["still_cells"], d["max_still"][0],
             " @" + d["max_still"][1] if d["max_still"][1] else "",
             CAP_PBTIME, len(d["cells_gt255"])))
    if deep and d.get("deep"):
        worst = max(d["deep"].items(), key=lambda kv: kv[1]["max_spu"],
                    default=(None, None))
        if worst[0]:
            r = worst[1]
            print("  deep: max SPU=%d B (%s, sub 0x%02X; cap %d, spec %d)  "
                  "btngr>1 domains=%d  foac domains=%d"
                  % (r["max_spu"], worst[0], r["max_spu_sub"], CAP_SPU, SPEC_SPU,
                     sum(1 for v in d["deep"].values() if v["btngr_sites"]),
                     sum(1 for v in d["deep"].values() if v["foac"])))
    for sev, axis, msg in sorted(d["findings"], key=lambda f: SEV_ORDER[f[0]]):
        print("  [%s] %s: %s" % (sev, axis, msg))
    if not d["findings"]:
        print("  (all axes within the implemented caps)")


def report_summary(vecs, deep):
    print("\n" + "=" * 78)
    print("SPEC AUDIT SUMMARY  --  %d disc(s)   (caps: PTT_CAP=%d SPU_CAP=%d "
          "cmem=%d pb_c=%ds)" % (len(vecs), CAP_PTT, CAP_SPU, CAP_VM_CMDS,
                                 CAP_PBTIME))
    print("=" * 78)
    print("  %-42s %-8s %s" % ("disc", "verdict", "axes flagged"))
    print("  " + "-" * 74)
    for d in vecs:
        axes = sorted(set(a for _, a, _ in d["findings"]))
        print("  %-42s %-8s %s" % (d["name"][:42], verdict(d),
                                   ",".join(axes) or "-"))
    # per-axis prevalence (feeds the Phase 2-6 re-rank)
    ax = collections.Counter()
    for d in vecs:
        for a in set(a for _, a, _ in d["findings"]):
            ax[a] += 1
    if ax:
        print("\n  axis prevalence (discs flagging each / %d):" % len(vecs))
        for a, n in ax.most_common():
            print("    %-16s %d" % (a, n))


def gather(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(os.path.join(p, n) for n in os.listdir(p)
                          if n.lower().endswith(('.iso', '.img')))
        elif os.path.isfile(p):
            out.append(p)
        else:
            hits = sorted(glob.glob(p))
            if not hits:
                print("[warn] no match: %s" % p)
            out += [h for h in hits if os.path.isfile(h)]
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Audit DVD-Video ISOs against this core's implemented limits "
                    "(docs/spec_hardening.md Phase 1).")
    ap.add_argument("paths", nargs="+", help="ISO files, directories, or globs")
    ap.add_argument("--deep", action="store_true",
                    help="also scan every VOB (SPU sizes, HLI button groups, foac)")
    ap.add_argument("--json", help="write the raw per-disc dicts here")
    ap.add_argument("--quiet", action="store_true",
                    help="summary table only (skip per-disc blocks)")
    args = ap.parse_args()

    isos = gather(args.paths)
    if not isos:
        print("no ISO files found")
        return 2

    vecs = []
    for path in isos:
        name = os.path.basename(path)
        try:
            nav = IsoNav(path)
        except AssertionError as e:
            print("[skip] %s -- not ISO9660 (%s) [UDF-only image?]" % (name, e))
            continue
        except Exception as e:
            print("[err]  %s -- %s" % (name, e))
            continue
        d = {"path": path, "name": name, "findings": []}
        try:
            audit_ifo(nav, d)
        except Exception as e:
            print("[err]  %s -- IFO audit failed: %s" % (name, e))
            continue
        if args.deep:
            print("[deep] %s" % name, flush=True)
            try:
                audit_deep(nav, d, verbose=not args.quiet)
            except Exception as e:
                print("[err]  %s -- deep scan failed: %s" % (name, e))
        vecs.append(d)
        if not args.quiet:
            report_disc(d, args.deep)

    if vecs:
        report_summary(vecs, args.deep)
    if args.json and vecs:
        for d in vecs:                          # sets aren't JSON-serializable
            for r in d.get("deep", {}).values():
                r["dsp_ty"] = [list(t) for t in r["dsp_ty"]]
        with open(args.json, "w") as h:
            json.dump(vecs, h, indent=2)
        print("\nwrote raw vectors -> %s" % args.json)
    return 1 if any(verdict(d) == "EXCEEDS" for d in vecs) else 0


if __name__ == "__main__":
    sys.exit(main())
