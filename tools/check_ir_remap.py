#!/usr/bin/env python3
"""Gate the IR remap table against the three files it makes claims about.

WHY THIS EXISTS
---------------
`main/support/dvd/dvd_ir.cpp` says things like "KEY_STOP -> KEY_Q (B14 Stop)".
That single row asserts a fact about three files it does not contain:

  1. stock Main's `ev2ps2[]`        -- KEY_Q must have a PS/2 scancode at all
                                       (most media keys are NONE in there, which
                                       is half the reason this feature exists);
  2. `dvd/kbd_map.sv`               -- that scancode must be decoded;
  3. `dvd/emu.sv`'s CONF_STR J1 list -- and the bit it sets must be B14.

Restating any of those in a comment is how a table goes stale silently: the RTL
moves, the comment does not, and nothing fails until a user reports that Stop
goes up a menu level. So this reads all three and FAILS if a row lies. It is the
same "a table that cannot go stale beats a correct one" pattern as
tools/check_subp_map_wiring.py and tools/acmod_scan.py.

⚠ PARSING TRAPS, each one already paid for elsewhere in this tree:

  * `input.cpp` holds FIVE 256-entry tables with identical `//NNN KEY_x`
    comments (ev2amiga, ev2ps2, ev2ps2_set1, ev2archie, shifted). A bare grep
    picks rows out of the wrong one, so this walks from the ev2ps2 declaration
    to its closing brace and reads only that slice.
  * `KEY_ZOOM` IS `KEY_FULL_SCREEN` and `KEY_SCREEN` IS `KEY_ASPECT_RATIO` --
    aliases, not distinct codes. Names are therefore resolved transitively and
    compared as NUMBERS, or a duplicate row hides behind two spellings.
  * Verilog comments quote scancodes and bit numbers freely, so kbd_map.sv is
    comment-stripped before its case arms are read.

Exit 0 = every row's claim holds. Exit 1 = a row lies, or a target the core
cannot reach.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

IR_CPP   = os.path.join(REPO, "main", "support", "dvd", "dvd_ir.cpp")
KBD_MAP  = os.path.join(REPO, "dvd", "kbd_map.sv")
EMU_SV   = os.path.join(REPO, "dvd", "emu.sv")

# Targets Main consumes BEFORE get_ps2_code(), so they legitimately have no
# ev2ps2 entry. Each carries the line that eats it, so the exemption can be
# re-checked rather than believed.
MAIN_RESERVED = {
    "KEY_MENU":       "user_io.cpp:4357 folds KEY_MENU into KEY_F12 (the OSD)",
    "KEY_F12":        "user_io.cpp:4357 the OSD toggle",
    "KEY_MUTE":       "user_io.cpp:4269 set_volume(0)",
    "KEY_VOLUMEUP":   "user_io.cpp:4279 set_volume(+1)",
    "KEY_VOLUMEDOWN": "user_io.cpp:4274 set_volume(-1)",
}

# The deny list must contain at least these, whatever else it grows.
DENY_MUST_CONTAIN = ["KEY_MUTE", "KEY_VOLUMEUP", "KEY_VOLUMEDOWN", "KEY_MENU", "KEY_DELETE"]


def die(msg):
    print("check_ir_remap: FAIL -- %s" % msg)
    sys.exit(1)


def strip_comments(text):
    """Remove /* */ and // comments. Load-bearing, not hygiene: a reverted file
    whose comment quotes the old code reads as correct to a grep."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


# ----------------------------------------------------------------- keycodes
def load_keycodes(ir_src):
    """KEY_* name -> number, resolved transitively so aliases collapse."""
    hdr = None
    for p in ("/usr/include/linux/input-event-codes.h",
              "/usr/include/linux/input.h"):
        if os.path.exists(p):
            hdr = open(p, encoding="utf-8", errors="replace").read()
            break
    if hdr is None:
        die("no <linux/input-event-codes.h> on this machine to resolve KEY_* names")

    raw = {}
    for name, val in re.findall(r"^#define\s+(KEY_\w+)\s+(\S+)", hdr, flags=re.M):
        raw[name] = val

    # dvd_ir.cpp's own #ifndef fallbacks: a name the build host lacks is still a
    # real target on the ARM toolchain, so honour them the same way the compiler
    # would (only when the header did not already define it).
    for name, val in re.findall(r"^#ifndef\s+(KEY_\w+)\s*\n#define\s+\1\s+(\S+)",
                                ir_src, flags=re.M):
        raw.setdefault(name, val)

    out = {}

    def resolve(name, depth=0):
        if name in out:
            return out[name]
        if depth > 8 or name not in raw:
            return None
        v = raw[name]
        if re.fullmatch(r"(0x[0-9a-fA-F]+|\d+)", v):
            n = int(v, 0)
        elif v.startswith("KEY_"):
            n = resolve(v, depth + 1)
        else:
            return None
        if n is not None:
            out[name] = n
        return n

    for name in raw:
        resolve(name)
    return out


# ------------------------------------------------------------- the ir table
def parse_ir_table(src):
    m = re.search(r"ir_tbl\[\]\s*=\s*\{(.*?)\n\};", src, flags=re.S)
    if not m:
        die("could not find ir_tbl[] in %s" % IR_CPP)
    body = strip_comments(m.group(1))
    rows = re.findall(
        r"\{\s*(KEY_\w+)\s*,\s*(KEY_\w+)\s*,\s*(KEY_\w+|0)\s*,\s*\"([^\"]*)\"\s*\}",
        body)
    if not rows:
        die("ir_tbl[] parsed but contains no rows -- the row shape changed")
    return rows


def parse_deny(src):
    m = re.search(r"ir_deny\[\]\s*=\s*\{(.*?)\};", src, flags=re.S)
    if not m:
        die("could not find ir_deny[] in %s" % IR_CPP)
    return re.findall(r"(KEY_\w+)", strip_comments(m.group(1)))


# ------------------------------------------------------------------ ev2ps2
NONE = 0xFF


def find_stock(explicit):
    for cand in (explicit,
                 os.environ.get("MAIN_MISTER_SRC"),
                 os.path.join(REPO, "main", ".build", "Main_MiSTer")):
        if cand and os.path.exists(os.path.join(cand, "input.cpp")):
            return cand
    return None


def parse_ev2ps2(stock):
    """keycode -> (ext, scancode) or None when the key has no PS/2 code."""
    src = open(os.path.join(stock, "input.cpp"), encoding="utf-8",
               errors="replace").read()
    i = src.find("ev2ps2[]")
    if i < 0:
        die("ev2ps2[] not found in %s/input.cpp" % stock)
    j = src.find("};", i)
    body = src[i:j]

    table = {}
    # Each row: <value expr>, //<keycode> <NAME>   -- the comment carries the
    # index, which is what lets us key on the number rather than counting rows.
    for line in body.split("\n"):
        m = re.match(r"^\s*(.+?),?\s*//\s*(\d+)\s", line)
        if not m:
            continue
        expr, code = m.group(1).strip(), int(m.group(2))
        if "NONE" in expr:
            table[code] = None
            continue
        h = re.search(r"0x([0-9a-fA-F]+)", expr)
        if not h:
            table[code] = None
            continue
        table[code] = ("EXT" in expr, int(h.group(1), 16))
    if len(table) < 200:
        die("ev2ps2[] parsed only %d rows -- the table shape changed" % len(table))
    return table


# --------------------------------------------------------------- kbd_map.sv
def parse_kbd_map():
    src = strip_comments(open(KBD_MAP, encoding="utf-8", errors="replace").read())
    m = re.search(r"if\s*\(\s*ps2_key\[8\]\s*\)\s*begin(.*?)end\s*else\s*begin(.*?)\n\s*end",
                  src, flags=re.S)
    if not m:
        die("could not split kbd_map.sv into its E0 / plain case blocks")

    def arms(block):
        out = {}
        for sc, bit in re.findall(r"8'h([0-9A-Fa-f]{2})\s*:\s*hit\[(\d+)\]", block):
            out[int(sc, 16)] = int(bit)
        return out

    ext, plain = arms(m.group(1)), arms(m.group(2))
    if not ext or not plain:
        die("kbd_map.sv case blocks parsed empty (%d ext, %d plain)" % (len(ext), len(plain)))
    return {(True, k): v for k, v in ext.items()} | {(False, k): v for k, v in plain.items()}


# ------------------------------------------------------------------- emu.sv
def parse_emu():
    src = open(EMU_SV, encoding="utf-8", errors="replace").read()

    m = re.search(r'"J1,([^"]*);"', src)
    if not m:
        die("could not find the CONF_STR J1 button list in emu.sv")
    names = [s.strip() for s in m.group(1).split(",") if s.strip()]
    # bit = button number + 3, so B1 (index 0) is bit 4.
    bit2btn = {i + 4: (i + 1, n) for i, n in enumerate(names)}

    body = strip_comments(src)
    digits = set()
    for sc, _d in re.findall(r"8'h([0-9A-Fa-f]{2})\s*:\s*\{?\s*ps2_dv\s*,?\s*ps2_digit\s*\}?\s*=\s*\{?\s*1'b1\s*,\s*4'd(\d+)",
                             body):
        digits.add(int(sc, 16))
    if not digits:
        # Fall back to the plain form `8'hXX: ps2_digit = 4'dN;`
        for sc, _d in re.findall(r"8'h([0-9A-Fa-f]{2})\s*:[^\n;]*4'd(\d+)", body):
            digits.add(int(sc, 16))
    return bit2btn, digits


# --------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stock", help="a stock Main_MiSTer checkout (for ev2ps2[])")
    ap.add_argument("--require-stock", action="store_true",
                    help="fail instead of skipping when no stock tree is found")
    ap.add_argument("--ir-cpp", help="an alternate dvd_ir.cpp (used by the RED "
                                     "arms in tools/tests to feed it a mutant)")
    args = ap.parse_args()

    global IR_CPP
    if args.ir_cpp:
        IR_CPP = args.ir_cpp
    ir_src = open(IR_CPP, encoding="utf-8", errors="replace").read()
    keys = load_keycodes(ir_src)
    rows = parse_ir_table(ir_src)
    deny = parse_deny(ir_src)
    bit2btn, digits = parse_emu()
    kbd = parse_kbd_map()

    def num(name):
        n = keys.get(name)
        if n is None:
            die("unknown keycode name %s (not in the UAPI header or the "
                "#ifndef fallbacks)" % name)
        return n

    errs = []

    # ---- in-repo arms: these ALWAYS run, so a bare checkout still gets a gate.
    seen = {}
    for frm, play, osd, why in rows:
        f = num(frm)
        if f in seen:
            errs.append("duplicate source %s (already bound by %s)" % (frm, seen[f]))
        seen[f] = frm

    sources = set(seen)
    for frm, play, osd, why in rows:
        for tgt in (play, osd):
            if tgt == "0":
                continue
            if num(tgt) in sources:
                errs.append("%s targets %s, which is itself a remap source "
                            "(the table would depend on row order)" % (frm, tgt))
        if not why.strip():
            errs.append("%s has an empty why string -- this gate goes vacuous "
                        "for that row" % frm)

    if not deny:
        errs.append("ir_deny[] is empty -- the reserved-key policy is unstated")
    for k in DENY_MUST_CONTAIN:
        if k not in deny:
            errs.append("ir_deny[] does not list %s" % k)
    for k in deny:
        if num(k) in sources:
            errs.append("%s is in ir_deny[] but the table claims it anyway" % k)

    # ---- the ev2ps2 arm needs a stock tree ---------------------------------
    stock = find_stock(args.stock)
    if not stock:
        msg = ("no stock Main_MiSTer found -- run main/build_main.sh, or pass "
               "--stock DIR, or set MAIN_MISTER_SRC")
        if args.require_stock:
            die("SKIP not allowed with --require-stock: " + msg)
        print("check_ir_remap: SKIP ev2ps2 arm -- %s" % msg)
    else:
        ev2ps2 = parse_ev2ps2(stock)

        # ⚠ THE `why` STRING DESCRIBES THE *PLAY* TARGET ONLY, and that asymmetry
        # is real rather than a shortcut. When the OSD is open, user_io_kbd()
        # hands the RAW keycode to menu_key_set() and the core's kbd_map.sv is
        # never consulted -- so "B3 Next Chapter" cannot describe an OSD target,
        # and several rows deliberately mean something different there (Back
        # cancels rather than going up a disc level; Channel +/- pages a list).
        # This checker's FIRST run against real data caught exactly that: it read
        # CHANNELUP's "B3" claim against its OSD column KEY_PAGEUP, which
        # kbd_map.sv binds to B2. The claim was fine; applying it to the wrong
        # column was not.
        for frm, play, osd, why in rows:
            # -- the OSD column: only sanity, because nothing in the core reads it
            if osd != "0":
                code = num(osd)
                ent = ev2ps2.get(code)
                if ent and ent[1] in (0xE1, 0xE2):
                    errs.append("%s -> %s (OSD): ev2ps2 gives the multi-byte "
                                "sentinel 0x%02X" % (frm, osd, ent[1]))

            # -- the play column: the full chain, ev2ps2 -> kbd_map -> CONF_STR
            if play in MAIN_RESERVED:
                continue                          # consumed before the PS/2 table
            code = num(play)
            ent = ev2ps2.get(code)
            if ent is None:
                errs.append("%s -> %s: no PS/2 scancode (ev2ps2[%d] is NONE), "
                            "so the core never sees it" % (frm, play, code))
                continue
            ext, sc = ent
            if sc in (0xE1, 0xE2):
                errs.append("%s -> %s: ev2ps2 gives the multi-byte sentinel "
                            "0x%02X, which kbd_map.sv cannot bind" % (frm, play, sc))
                continue
            if why.strip() == "digit":
                if sc not in digits:
                    errs.append("%s -> %s claims \"digit\" but 0x%02X is not one "
                                "of emu.sv's digit scancodes" % (frm, play, sc))
                continue
            bit = kbd.get((ext, sc))
            if bit is None:
                errs.append("%s -> %s: kbd_map.sv does not decode %s0x%02X"
                            % (frm, play, "E0 " if ext else "", sc))
                continue
            want = re.match(r"B(\d+)\b", why.strip())
            if want:
                btn = bit2btn.get(bit)
                if not btn:
                    errs.append("%s -> %s: hit[%d] is not a CONF_STR button"
                                % (frm, play, bit))
                elif btn[0] != int(want.group(1)):
                    errs.append("%s -> %s claims \"%s\" but reaches B%d %s"
                                % (frm, play, why.strip(), btn[0], btn[1]))

    if errs:
        for e in errs:
            print("check_ir_remap: FAIL -- %s" % e)
        print("check_ir_remap: %d problem(s)" % len(errs))
        return 1

    print("check_ir_remap: OK -- %d rows, %d reserved keys%s"
          % (len(rows), len(deny), "" if stock else " (ev2ps2 arm skipped)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
