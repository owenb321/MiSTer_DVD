#!/usr/bin/env python3
"""Rehearse integration steps 50-53 against copies of the real stock files.

★★ WHY THIS EXISTS AND WHY IT IS NOT JUST "DOES IT APPLY". Step 51's PLACEMENT
is the design (INTEGRATION.md "Steps 50-53"): the hook must sit after the three
map-loading blocks and before `if (!input[dev].num)`, and above all it must be
UPSTREAM of `ev->code >= 256` -- which is the joystick split that drops 39 of a
Media Center receiver's keycodes. A hook below that line applies cleanly, passes
every host test in main/tests/, compiles, and FIXES NOTHING. So this asserts the
ordering, not merely that the anchors matched.

⚠ It runs the SHIPPED step code, lifted verbatim out of apply_integration.py,
rather than a copy of it -- a rehearsal of a transcription would prove nothing
about what build_main.sh actually does.

⚠ The shared main/.build/Main_MiSTer tree is already patched by whatever build
made it, so it must NOT be re-patched in place. Copies are a faithful rehearsal
anyway: its input.cpp is pristine (no earlier step touches that file) and its
cfg.h/cfg.cpp already carry step 21's lines, which is exactly the state steps
52/53 anchor on.

Skips loudly with no stock tree; build_main.sh is the standing gate.
"""

import io
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AI = os.path.join(ROOT, "main", "integration", "apply_integration.py")


def find_stock():
    """Same search as tools/check_ir_remap.py, worktree case included."""
    cands = [os.environ.get("MAIN_MISTER_SRC"),
             os.path.join(ROOT, "main", ".build", "Main_MiSTer")]
    try:
        r = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                           cwd=ROOT, capture_output=True, text=True)
        if r.returncode == 0:
            base = os.path.dirname(os.path.abspath(
                os.path.join(ROOT, r.stdout.strip())))
            cands.append(os.path.join(base, "main", ".build", "Main_MiSTer"))
    except OSError:
        pass
    for c in cands:
        if c and os.path.exists(os.path.join(c, "input.cpp")):
            return c
    return None


SRC = find_stock()
if not SRC:
    print("  SKIP no stock Main_MiSTer -- steps 50-53 cannot be rehearsed here")
    print("test_ir_integration: ALL GREEN")
    sys.exit(0)

text = io.open(AI, encoding="utf-8").read()

# Helper functions (read/write/insert_after/replace_once/fail) come from the
# file's preamble, cut before the first path assignment so nothing with a side
# effect runs. The preamble consumes argv, so hand it a plausible one.
ns = {}
saved, sys.argv = sys.argv, ["apply_integration.py", SRC]
exec(compile(text[:text.index("uio_path = os.path.join")], AI, "exec"), ns)
sys.argv = saved
ns["os"] = os

tmp = tempfile.mkdtemp()
try:
    for f in ("input.cpp", "cfg.h", "cfg.cpp"):
        shutil.copy(os.path.join(SRC, f), os.path.join(tmp, f))

    marker = "# ------------------------------------------------------------------- IR remap"
    if marker not in text:
        print("  FAIL steps 50-53 block not found in apply_integration.py")
        print("test_ir_integration: 1 FAILURE(S)")
        sys.exit(1)
    blk = text[text.index(marker):text.index('print("[integration] done")')]
    blk = blk.replace('os.path.join(ROOT, "input.cpp")',
                      repr(os.path.join(tmp, "input.cpp")))
    blk = blk.replace("cfgh_path", repr(os.path.join(tmp, "cfg.h")))
    blk = blk.replace("cfgc_path", repr(os.path.join(tmp, "cfg.cpp")))

    out = io.StringIO()
    real, sys.stdout = sys.stdout, out
    try:
        exec(compile(blk, "apply_integration.py:steps50-53", "exec"), ns)
    finally:
        sys.stdout = real

    fails = 0

    def chk(name, cond, note=""):
        global fails
        if cond:
            print("  ok   %-28s %s" % (name, note))
        else:
            print("  FAIL %-28s %s" % (name, note))
            fails += 1

    read = ns["read"]
    i = read(os.path.join(tmp, "input.cpp"))

    def ordering(body):
        """(after the map loads, before !num, upstream of the >= 256 split)."""
        adv = body.find("input[dev].has_advanced_map = true;")
        hook = body.find("// dvd:ir")
        num = body.find("if (!input[dev].num)")
        split = body.find("ev->code >= 256")
        return (adv >= 0 and hook > adv,
                num >= 0 and hook < num,
                split >= 0 and hook < split)

    for want, why in (('#include "support/dvd/dvd_ir.h"', "step 50 include"),
                      ("// dvd:ir", "step 51 marker"),
                      ("dvd_ir_target(ev->code, user_io_osd_is_visible())",
                       "step 51 call")):
        chk(why, i.count(want) == 1, "x%d" % i.count(want))

    # The block replace_once() consumed must be back, once.
    chk("advanced-map block intact",
        i.count("input_advanced_load(dev);") == 1)

    a_ok, b_ok, c_ok = ordering(i)
    chk("hook after the map loads", a_ok)
    chk("hook before !input[dev].num", b_ok)
    # The one that matters most: ceiling (1) IS this split.
    chk("hook UPSTREAM of >= 256", c_ok, "a hook below it fixes nothing")

    # ⚠⚠ THE OSD PREDICATE, PINNED BY NAME AND BY REJECTION. menu_present() is
    # `menustate != MENU_NONE1/NONE2`, which is ALSO true while a transient
    # InfoMessage is up -- and this core raises those from its own poll ticks.
    # Rows whose OSD column is 0 mean "pass through untouched", so with
    # menu_present() they went SILENTLY INERT whenever a message was on screen.
    # Found on hardware, not by any bench, via the remap trace.
    chk("OSD predicate is osd_is_visible", "user_io_osd_is_visible()" in i)
    chk("and NOT menu_present()", "dvd_ir_target(ev->code, menu_present())" not in i,
        "true for a transient InfoMessage")

    # The user's own binding must still outrank the table.
    chk("user binding still wins", "ir_user_bound" in i)
    # Define buttons must still capture RAW codes.
    chk("mapping session exempt", "!mapping && dvd_ir_active()" in i)

    for f, want, why in (("cfg.h", "uint8_t dvd_ir_remap;", "step 52 field"),
                         ("cfg.cpp", '"DVD_IR_REMAP"', "step 53 row")):
        body = read(os.path.join(tmp, f))
        chk(why, body.count(want) == 1, "x%d" % body.count(want))
        chk("step 21 survives in " + f, "dvd_hdmi_bitstream" in body)

    # ★ ANTI-VACUITY. An ordering assertion that cannot fail is worse than none:
    # it reads as protection. So cut the hook out of the APPLIED file and paste
    # it back in the two wrong places, and require the matching arm to go red.
    # This simulates the outcome (the hook ended up somewhere else) rather than
    # one particular way of getting there, so it stays true however a future
    # session moves it.
    h0 = i.find("\tif (ev->type == EV_KEY && !mapping && dvd_ir_active())")
    h1 = i.find("\n\tif (!input[dev].num)", h0)
    hook_text, stripped = i[h0:h1], i[:h0] + i[h1:]
    chk("hook is extractable", h0 > 0 and h1 > h0 and "// dvd:ir" in hook_text)

    # (a) too early -- before the map-loading blocks, the kbdmap site.
    at = stripped.find("\tif (!input[dev].has_map)")
    red_a = stripped[:at] + hook_text + stripped[at:]
    chk("RED: hook moved too early", ordering(red_a)[0] is False,
        "map[]/mmap[] not yet loaded")

    # (b) below the joystick split -- applies, compiles, fixes NOTHING.
    at = stripped.find("\t\tif (assign_btn)")
    red_b = stripped[:at] + hook_text + stripped[at:]
    chk("RED: hook moved below >= 256", ordering(red_b)[2] is False,
        "the failure this gate exists for")

    # Idempotence: apply_integration.py's whole contract is that a second run is
    # a no-op. Re-run the same block over the already-patched copies.
    real, sys.stdout = sys.stdout, io.StringIO()
    try:
        exec(compile(blk, "apply_integration.py:steps50-53", "exec"), ns)
    finally:
        sys.stdout = real
    i2 = read(os.path.join(tmp, "input.cpp"))
    chk("re-running is a no-op", i2 == i)

finally:
    shutil.rmtree(tmp, ignore_errors=True)

print()
if fails:
    print("test_ir_integration: %d FAILURE(S)" % fails)
    sys.exit(1)
print("test_ir_integration: ALL GREEN")
