#!/usr/bin/env python3
"""
check_p240_wiring.py — gate the native-240p wiring by READING dvd/emu.sv.

WHY THIS EXISTS.  Every piece of the 240p raster has a module-level bench, and not one
of them can see the thing most likely to be got wrong: which FACT emu puts on which
wire.  The raster is a sub-mode of the 15 kHz one, so `il_eff` splits into a role that
stays (the 15 kHz raster is up; pixel repetition is on) and a role that moves
(`fields_eff` -- the decoder emits interlaced fields).  Point a consumer at the wrong
one and every bench still passes, because no bench instantiates emu.

This is the `tools/check_subp_map_wiring.py` / `tools/acmod_scan.py` pattern: a table
that reads the answer out of the RTL cannot go stale, and that beats a correct one.
It runs in milliseconds from bench/dvd/run_p240.sh.

⚠⚠ THE ORDERING CHECK IS THE POINT OF THE FILE.  p240_eff = interlaced_eff & sif, so
p240_prev IMPLIES il_prev.  In the modeline walk's ternary chains a p240 arm placed
AFTER the il arm is dead code -- the raster silently stays line-doubled, the feature
does nothing, and absolutely nothing fails.  That is a one-line edit away at all times
and it is invisible to simulation of any single module.

Exit 0 = wired as designed.  Exit 1 = a named connection carries the wrong fact.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMU = os.path.join(ROOT, "dvd", "emu.sv")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", ln) for ln in text.split("\n"))


def norm(text):
    """collapse whitespace so a re-indent is not a failure"""
    return re.sub(r"\s+", " ", text)


def main():
    raw = open(EMU, encoding="utf-8").read()
    src = norm(strip_comments(raw))

    fails = []

    def want(label, pattern, why):
        if not re.search(pattern, src):
            fails.append("%s: %s" % (label, why))

    def reject(label, pattern, why):
        if re.search(pattern, src):
            fails.append("%s: %s" % (label, why))

    # ---------------------------------------------------------------- roles
    want("fields_eff",
         r"wire fields_eff = interlaced_eff & ~p240_eff;",
         "fields_eff must be `interlaced_eff & ~p240_eff` -- the one role of il_eff that "
         "moves at 240p (the decoder stops emitting interlaced fields)")

    want("p240_eff source",
         r"assign p240_eff = interlaced_eff & sif_det_s2;",
         "p240_eff must come from pal_detect's DEBOUNCED sif verdict (sif_det_s2) and the "
         "15 kHz raster")

    reject("p240_eff raw tap",
           r"assign p240_eff = [^;]*sif_v_(s2|dec)",
           "p240_eff must NOT be derived from the raw sif_v_dec/sif_v_s2 size tap -- that "
           "has no plausibility bound and no hold, and a content-derived raster edge "
           "without them is the self-feeding loop the reverted film-switch attempt died of")

    # ------------------------------------------------- consumers that MOVE
    for label, pat, why in [
        ("VGA_F1", r"assign VGA_F1 += fields_eff \?",
         "VGA_F1 is a FIELD flag: it must follow fields_eff (0 on the progressive raster)"),
        ("HDMI_BOB_DEINT", r"assign HDMI_BOB_DEINT += fields_eff &",
         "there is nothing to deinterlace on a progressive raster"),
        ("sif_v2x_eff", r"wire sif_v2x_eff += interlaced_eff & sif_v_s2 & ~p240_eff;",
         "THE feature: the nearest-neighbour vertical line repeat must be OFF at 240p, "
         "where the decoded 240 lines map 1:1"),
        ("crt_ov_map.interlaced", r"\.interlaced \( *fields_eff *\)",
         "crt_ov_map's +2 field-line walk must be off on a progressive raster"),
        ("spu_decode.interlaced", r"\.interlaced \( *fields_eff *\)",
         "spu_decode's +2 field-line walk must be off on a progressive raster"),
        ("cc_vbi.enable", r"\.enable +\( *fields_eff & ~status\[14\] *\)",
         "line 21 is a FIELD-1 service and cc_vbi decodes the interlaced v_pos packing"),
    ]:
        want(label, pat, why)

    # ------------------------------------------- consumers that must NOT move
    # These read il_eff/interlaced_eff for a role that is still true at 240p: the 15 kHz
    # raster is up, and PIXEL REPETITION IS STILL ON. Re-pointing them at fields_eff would
    # halve the overlay query coordinates and double the pixel clock the framework sees.
    for label, pat, why in [
        ("CE_PIXEL", r"assign CE_PIXEL = interlaced_eff \?",
         "pixrep is still on at 240p, so the framework still gets one enable per pair"),
        ("ov_h_gen", r"wire \[11:0\] ov_h_gen = il_eff \?",
         "the x2 pixrep inverse must stay -- 240p keeps pixel repetition"),
        ("sp_qx", r"wire \[11:0\] sp_qx = il_eff \?",
         "the x2 pixrep inverse must stay -- 240p keeps pixel repetition"),
        ("sif_hfill_eff", r"wire sif_hfill_eff = interlaced_eff & sif_h_s2;",
         "the HORIZONTAL fill must stay at 240p: disp_hstretch is a true 2-tap linear "
         "resample, and a CRT needs the full line width whatever the raster height is"),
        ("csync_smpte.en", r"\.en +\( *interlaced_eff *\)",
         "csync `en` is the 15 kHz raster, which 240p still is"),
    ]:
        want(label, pat, why)

    # ------------------------------------------------------- new connections
    want("csync_smpte.prog", r"\.prog +\( *p240_eff *\)",
         "the sync generator must be told to read v_pos as a plain line index and to stop "
         "offsetting the block by half a line")

    want("mode_realign.mode_edge", r"\.mode_edge +\( *il_switch \| p240_switch *\)",
         "a 240p engage changes the raster under live content, so it must take the same "
         "route as an il_eff change -- a reader re-align, NEVER straight into flush_ctl")

    n_act = len(re.findall(r"\.act_h_i *\( *act_h_eff *\)", src))
    if n_act != 3:
        fails.append("act_h_i: %d of 3 overlays take act_h_eff (transport_hud, seek_bar, "
                     "idle_logo must all bottom-anchor to the real active height; "
                     "idle_logo shows over LIVE content via the screensaver and Stop)"
                     % n_act)

    want("act_h_eff", r"wire \[11:0\] act_h_eff = p240_eff \? \(pal_eff \? 12'd288 : 12'd240\)",
         "the active height must be 240/288 on the progressive raster")

    want("half_scan", r"p240_dec_l \? \(pal_dec_l \? 16'd899 : 16'd749\)",
         "disp_sched's pickup-opportunity grid needs the 240p/288p scan half-periods")

    # ------------------------------------------------------------- ORDERING
    # p240_prev implies il_prev, so a p240 arm placed after an il arm is DEAD CODE.
    def order(label, tag_p240, tag_il, why):
        i_p, i_i = src.find(tag_p240), src.find(tag_il)
        if i_p < 0:
            fails.append("%s: the p240 arm is missing entirely (%s)" % (label, why))
        elif i_i < 0:
            fails.append("%s: the il arm is missing entirely" % label)
        elif i_p > i_i:
            fails.append("%s: the p240 arm comes AFTER the il arm, so it is DEAD -- "
                         "p240_prev implies il_prev. %s" % (label, why))

    order("walk step 2 (VERT_RES) NTSC",
          "p240_prev ? {4'b0, 12'd240, 4'b0, 12'd261}",
          "il_prev ? {4'b0, 12'd480, 4'b0, 12'd261}",
          "the raster would silently stay 480i and the feature would do nothing")
    order("walk step 2 (VERT_RES) PAL",
          "(pal_prev && p240_prev) ? {4'b0, 12'd288, 4'b0, 12'd311}",
          "(pal_prev && il_prev) ? {4'b0, 12'd576, 4'b0, 12'd311}",
          "the raster would silently stay 576i")
    order("walk step 4 (VID_MODE)",
          "p240_prev ? {4'b0, 12'd0, 13'b0, 3'b010}",
          "il_prev ? {4'b0, (pal_prev ? 12'd432 : 12'd429), 13'b0, 3'b011}",
          "the half-line and the interlaced bit would stay set")

    # -------------------------------------------------- the VID_MODE payload
    # {clip, pixrep, interlaced} = 010: pixrep ON (15.734 kHz line), interlaced OFF.
    want("VID_MODE 240p payload",
         r"p240_prev \? \{4'b0, 12'd0, 13'b0, 3'b010\}",
         "240p must write halfline 0 and VID_MODE 3'b010 -- pixel repetition ON "
         "(dropping it gives a 31.5 kHz line no 15 kHz display will take) and "
         "interlaced OFF (which is what stops syncgen's 262/263 alternation)")

    want("deinterlace", r"wire fields_prev = il_prev & ~p240_prev;",
         "the trick register's deinterlace bit must follow fields_prev -- 240p emits "
         "FRAMES even though il_prev is set")

    if fails:
        sys.stderr.write("check_p240_wiring: FAIL\n")
        for f in fails:
            sys.stderr.write("  - %s\n" % f)
        return 1
    print("check_p240_wiring: PASS (%s)" % os.path.relpath(EMU, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
