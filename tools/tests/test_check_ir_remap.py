#!/usr/bin/env python3
"""RED arms for tools/check_ir_remap.py.

A checker that only ever passes is worth nothing -- it has to be shown capable
of failing, and failing for the RIGHT reason. Each arm below feeds it a mutated
dvd_ir.cpp and requires a specific complaint, so a checker that degraded into
"exit 0 whatever happens" is caught here rather than years later when a row has
quietly gone stale.

⚠ SPLIT, stated honestly. The arms that need stock Main's ev2ps2[] can only run
where a stock tree exists, and they SKIP loudly otherwise -- the same rule the
checker itself follows. That is not a hole in practice: main/build_main.sh runs
the checker with --require-stock, where the tree is guaranteed. The in-repo arms
(duplicate rows, chaining, the deny list, empty why strings) are hermetic and
always run, so a bare checkout still gets a real gate.
"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECKER = os.path.join(ROOT, "tools", "check_ir_remap.py")
IR_CPP = os.path.join(ROOT, "main", "support", "dvd", "dvd_ir.cpp")

fails = 0


def find_stock():
    """The same search the checker does, plus the worktree case.

    ⚠ In a git WORKTREE, main/.build/ is not checked out -- it is a build
    artifact of the main checkout. `--git-common-dir` names that checkout's
    .git, so its parent is where the stock tree really is. Without this the
    ev2ps2 arms skip in every worktree, which is where most work happens.
    """
    cands = [os.environ.get("MAIN_MISTER_SRC"),
             os.path.join(ROOT, "main", ".build", "Main_MiSTer")]
    try:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                                cwd=ROOT, capture_output=True, text=True)
        if common.returncode == 0:
            base = os.path.dirname(os.path.abspath(
                os.path.join(ROOT, common.stdout.strip())))
            cands.append(os.path.join(base, "main", ".build", "Main_MiSTer"))
    except OSError:
        pass
    for cand in cands:
        if cand and os.path.exists(os.path.join(cand, "input.cpp")):
            return cand
    return None


STOCK = find_stock()


def run(ir_cpp=None, stock=STOCK, extra=()):
    cmd = [sys.executable, CHECKER]
    if ir_cpp:
        cmd += ["--ir-cpp", ir_cpp]
    if stock:
        cmd += ["--stock", stock]
    cmd += list(extra)
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def red(name, sub, expect, need_stock=False):
    """Apply `sub` (a function str->str) to dvd_ir.cpp and require a failure."""
    global fails
    if need_stock and not STOCK:
        print("  SKIP %-26s (no stock Main_MiSTer for the ev2ps2 arm)" % name)
        return
    src = open(IR_CPP, encoding="utf-8").read()
    mutated = sub(src)
    if mutated == src:
        print("  FAIL %-26s mutation matched nothing (the anchor moved)" % name)
        fails += 1
        return
    d = tempfile.mkdtemp()
    try:
        path = os.path.join(d, "dvd_ir.cpp")
        open(path, "w", encoding="utf-8").write(mutated)
        rc, out = run(ir_cpp=path)
        if rc == 0:
            print("  FAIL %-26s checker PASSED against a broken table" % name)
            fails += 1
        elif expect not in out:
            print("  FAIL %-26s caught, but not by \"%s\"" % (name, expect))
            print("       " + "\n       ".join(out.strip().split("\n")[:3]))
            fails += 1
        else:
            print("  RED  %-26s -> \"%s\"" % (name, expect))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def green(name, cond, note=""):
    global fails
    if cond:
        print("  ok   %-26s %s" % (name, note))
    else:
        print("  FAIL %-26s %s" % (name, note))
        fails += 1


print("=== check_ir_remap: the real table must pass ===")
rc, out = run()
green("real dvd_ir.cpp passes", rc == 0, out.strip().split("\n")[-1])
if STOCK:
    print("  ok   %-26s %s" % ("stock tree found", STOCK))
else:
    # Not a failure: a bare checkout legitimately has no stock tree, and the
    # real gate runs from build_main.sh with --require-stock. But say so
    # loudly -- a silent half-run reads exactly like a full one.
    print("  SKIP %-26s the ev2ps2 arms below cannot run here" % "no stock tree")

print("\n=== the #ifndef fallbacks must match the kernel ===")
# ⚠ THESE ARE NEVER EXERCISED WHERE THEY COMPILE. The guards exist for older ARM
# toolchain headers (the dvd_vcd.cpp <limits.h> lesson); on any host new enough
# to define the code, #ifndef makes the fallback dead. So a WRONG constant would
# compile cleanly here, pass every host test, and silently map the wrong key on
# the only build that uses it. Compare them against the header instead.
# ⚠ Share the checker's own search rather than repeating it -- a second copy
# would drift, and the cross-toolchain sysroot case (the one that broke the
# container build) lives only in the checker.
_spec = importlib.util.spec_from_file_location("check_ir_remap", CHECKER)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
_hdr = None
for _c in _mod.keycode_header_candidates():
    if _c and os.path.exists(_c):
        _hdr = open(_c, encoding="utf-8").read()
        break
if not _hdr:
    print("  SKIP no input-event-codes.h to compare against")
else:
    _real = dict(re.findall(r"#define\s+(KEY_[A-Z0-9_]+)\s+(0x[0-9a-fA-F]+|\d+)", _hdr))
    _src = open(IR_CPP, encoding="utf-8").read()
    _pairs = re.findall(
        r"#ifndef\s+(KEY_[A-Z0-9_]+)\s*\n#define\s+\1\s+(0x[0-9a-fA-F]+|\d+)", _src)
    green("fallbacks were found", len(_pairs) > 0, "%d guard(s)" % len(_pairs))
    for _name, _val in _pairs:
        if _name not in _real:
            print("  SKIP %-26s this header does not define it either" % _name)
            continue
        green(_name, int(_val, 0) == int(_real[_name], 0),
              "%s" % hex(int(_val, 0)))

print("\n=== RED: in-repo arms (always run) ===")

# A second row for a key that already has one. First match wins, so the new row
# is dead code that looks live -- no behaviour test can see it.
red("duplicate-source",
    lambda s: s.replace('{ KEY_STOPCD,           KEY_Q,          0,              "B14 Stop" },',
                        '{ KEY_STOPCD,           KEY_Q,          0,              "B14 Stop" },\n\t{ KEY_STOP, KEY_ESC, 0, "B13 Return" },'),
    "duplicate source")

# Point a row at a key that is itself a source: the table's meaning would then
# depend on row order.
red("target-is-a-source",
    lambda s: s.replace('{ KEY_MEDIA_TOP_MENU,   KEY_T,',
                        '{ KEY_MEDIA_TOP_MENU,   KEY_TITLE,'),
    "is itself a remap source")

# Claim a key the deny list reserves for Main.
red("claims-a-reserved-key",
    lambda s: s.replace('{ KEY_INFO,             KEY_D,          0,              "B9 Display" },',
                        '{ KEY_INFO,             KEY_D,          0,              "B9 Display" },\n\t{ KEY_MUTE, KEY_D, 0, "B9 Display" },'),
    "the table claims it anyway")

# Quietly drop a key from the deny list -- the policy would stop being stated.
red("deny-list-shrunk",
    lambda s: re.sub(r"^\tKEY_MENU,.*\n", "", s, flags=re.M),
    "does not list KEY_MENU")

# Blank a why string. Behaviour is unchanged, so only this can catch it -- and
# without it the checker goes vacuous for that row.
red("blank-why",
    lambda s: s.replace('{ KEY_ANGLE,            KEY_G,          0,              "B6 Angle" },',
                        '{ KEY_ANGLE,            KEY_G,          0,              "" },'),
    "empty why string")

print("\n=== RED: arms that need stock Main's ev2ps2[] ===")

# The headline claim: a row that names the wrong button.
red("wrong-button-claimed",
    lambda s: s.replace('{ KEY_STOP,             KEY_Q,          0,              "B14 Stop" },',
                        '{ KEY_STOP,             KEY_Q,          0,              "B5 Menu" },'),
    "but reaches B14", need_stock=True)

# Target a key that HAS no PS/2 scancode. This is the whole failure class the
# feature exists to fix, pointed back at itself: KEY_PLAY is NONE in ev2ps2.
red("target-has-no-scancode",
    lambda s: s.replace('{ KEY_INFO,             KEY_D,', '{ KEY_INFO,             KEY_PLAY,'),
    "no PS/2 scancode", need_stock=True)

# Target the multi-byte PS/2 Pause sentinel, which kbd_map.sv cannot bind --
# the exact reason the remote's own Pause button is inert without this feature.
red("target-is-multibyte",
    lambda s: s.replace('{ KEY_INFO,             KEY_D,', '{ KEY_INFO,             KEY_PAUSE,'),
    "multi-byte sentinel", need_stock=True)

# Target a key with a scancode that kbd_map.sv simply does not decode.
red("target-not-decoded",
    lambda s: s.replace('{ KEY_INFO,             KEY_D,', '{ KEY_INFO,             KEY_W,'),
    "does not decode", need_stock=True)

print("\n=== RED: --require-stock must refuse to skip ===")
rc, out = run(stock=None, extra=["--require-stock"])
# With MAIN_MISTER_SRC set in the environment the checker legitimately finds a
# tree anyway, so only assert the refusal when there is genuinely nothing.
if STOCK:
    print("  SKIP %-26s (a stock tree is discoverable here)" % "require-stock-refuses")
else:
    green("--require-stock exits 1", rc == 1)
    green("...and says why", "SKIP not allowed" in out)

print()
if fails:
    print("test_check_ir_remap: %d FAILURE(S)" % fails)
    sys.exit(1)
print("test_check_ir_remap: ALL GREEN")
