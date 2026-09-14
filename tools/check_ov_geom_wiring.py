#!/usr/bin/env python3
"""
check_ov_geom_wiring.py — gate the OVERLAY GEOMETRY wiring by READING dvd/emu.sv.

WHY THIS EXISTS.  The three overlays (transport_hud, seek_bar, idle_logo) each have a
module-level bench, and each of those benches is handed the active window as a plusarg.
Not one of them can see the thing that was actually wrong for a year: what emu PUT ON
THAT WIRE.  The modules were correct for the frame they were told about; emu told them
about a frame that does not exist on the progressive output, where a VCD presents a
352x240 window and an SVCD a 480x480 one.  That is the tools/check_p240_wiring.py /
tools/check_subp_map_wiring.py pattern -- emu has no bench, so the connection is gated by
reading it out of the file, and a table that reads the answer out of the RTL cannot go
stale.

⚠ THE POINT IS THE *VALUE*, NOT THE PORT.  A port that is present but fed a constant 720
(or the raster resolution instead of the decoded size) reproduces the exact reported bug
and every module bench still passes.  So both the expressions and the three connections
are checked, and bench/dvd/run_ov_geom.sh mutates each of them.

Exit 0 = wired as designed.  Exit 1 = a named connection carries the wrong fact.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMU = os.path.join(ROOT, "dvd", "emu.sv")

OVERLAYS = ("transport_hud", "seek_bar", "idle_logo")


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

    # ------------------------------------------------------- the two values
    # The window is min(decoded size, raster resolution), with a size of 0 (idle, or just
    # after a flush) meaning the full raster -- syncgen's own rule, replicated.
    want("act_vres",
         r"wire \[11:0\] act_vres += p240_eff \? \(pal_eff \? 12'd288 : 12'd240\) "
         r": \(pal_eff \? 12'd576 : 12'd480\);",
         "act_vres must be the modeline's ACTIVE COUNT (240/288 on the progressive "
         "raster, 480/576 otherwise) -- it is the resolution half of the window")

    want("vsz_eff",
         r"wire \[13:0\] vsz_eff += sif_v2x_eff \? \{vsz_s2\[12:0\], 1'b0\} : vsz_s2;",
         "vsz_eff must apply the SAME forward transform mpeg2video does "
         "(eff_vertical_size): when the 2x line repeat is on, the window is the DOUBLED "
         "height, not the decoded one")

    want("act_h_eff",
         r"assign +act_h_eff = \(vsz_eff == 14'd0 \|\| vsz_eff >= \{2'b0, act_vres\}\) \? "
         r"act_vres : vsz_eff\[11:0\];",
         "the active HEIGHT must be min(decoded height, resolution), with 0 = the full "
         "raster -- a plain resolution here is what hid the whole HUD on a 240-line VCD "
         "over the progressive output")

    want("act_w_eff",
         r"assign +act_w_eff = \(sif_hfill_eff \|\| hsz_s2 == 14'd0 \|\| hsz_s2 >= 14'd720\) \? "
         r"12'd720 : hsz_s2\[11:0\];",
         "the active WIDTH must be min(decoded width, 720) in OVERLAY coordinates, forced "
         "to 720 whenever the SIF horizontal fill is on -- a constant 720 here is what ran "
         "the HUD off the right of a 480-wide SVCD")

    # ⚠ Both must be DECLARED without an initialiser and assigned later: the terms they
    # need (hsz_s2/vsz_s2/sif_*) are only in scope far below the declaration site.
    for w in ("act_h_eff", "act_w_eff"):
        want("%s declaration" % w, r"wire \[11:0\] %s;" % w,
             "%s must be forward-declared near fields_eff and assigned beside the SIF "
             "detect (the pal_eff/p240_eff pattern)" % w)

    # -------------------------------------------------- the six connections
    for port, val in (("act_h_i", "act_h_eff"), ("act_w_i", "act_w_eff")):
        n = len(re.findall(r"\.%s *\( *%s *\)" % (port, val), src))
        if n != len(OVERLAYS):
            fails.append(
                "%s: %d of %d overlays take %s. transport_hud, seek_bar and idle_logo must "
                "ALL anchor to the real window -- and idle_logo is not idle-only, the "
                "screensaver and Stop show it over a mounted, playing title."
                % (port, n, len(OVERLAYS), val))

    # ⚠ The old literals must be gone from the overlay modules themselves, or a module
    # could take the port and ignore it.
    for mod, lit in (("transport_hud", "X0"), ("seek_bar", "X0")):
        path = os.path.join(ROOT, "dvd", "%s.sv" % mod)
        body = norm(strip_comments(open(path, encoding="utf-8").read()))
        if re.search(r"localparam \[11:0\] %s += 12'd104;" % lit, body):
            fails.append("%s.sv: the fixed X0 = 104 box origin is still there -- the box "
                         "must be centred in act_w_i" % mod)
        if not re.search(r"localparam \[11:0\] HS2_MIN += 12'd544;", body):
            fails.append("%s.sv: HS2_MIN (the 544 knee) is missing -- the HUD and the seek "
                         "bar must share one rule or they will not line up" % mod)

    if fails:
        print("check_ov_geom_wiring: FAIL")
        for f in fails:
            print("  - %s" % f)
        return 1
    print("check_ov_geom_wiring: PASS (dvd/emu.sv + the three overlays)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
