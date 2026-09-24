#!/usr/bin/env python3
"""How much of a receiver's keymap does dvd_ir.cpp's table actually cover?

★ THIS NEEDS NO BUTTON PRESSES. An evdev device publishes the set of keycodes it
can emit as the `B: KEY=` bitmap in /proc/bus/input/devices, so for an rc-core
receiver that IS the keymap's whole vocabulary. Intersecting it with the remap
table answers "will this handset work out of the box" directly, and it answers it
for every button rather than for the ones someone remembered to press.

⚠ It is the KEYMAP's vocabulary, not the HANDSET's. A button the physical remote
does not have still shows up here; a button it has that the keymap does not
decode does not. So a covered key is "the player will act on it if the remote
sends it", which is the half this core is responsible for.

Usage:
    ir_coverage.py --bitmap "fff 0 0 4200 ..."      # from /proc/bus/input/devices
"""

import argparse
import importlib.util
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load_checker():
    spec = importlib.util.spec_from_file_location(
        "cir", os.path.join(HERE, "check_ir_remap.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bitmap", required=True,
                    help='the "B: KEY=" hex words from /proc/bus/input/devices')
    ap.add_argument("--floor", type=int, default=100,
                    help="ignore uncovered codes below this (plain letters/digits)")
    args = ap.parse_args()

    # The bitmap prints the HIGHEST word first, so reverse before indexing.
    words = [int(w, 16) for w in args.bitmap.split()][::-1]
    codes = {wi * 32 + b
             for wi, w in enumerate(words)
             for b in range(32) if (w >> b) & 1}

    m = load_checker()
    src = io.open(os.path.join(ROOT, "main/support/dvd/dvd_ir.cpp"),
                  encoding="utf-8").read()
    kc = m.load_keycodes(src)
    name_of = {}
    for n, v in kc.items():
        name_of.setdefault(v, []).append(n)

    body = m.strip_comments(src)
    tbl = re.search(r"ir_tbl\[\]\s*=\s*\{(.*?)\n\};", body, re.S).group(1)
    mapped = {kc[r] for r in re.findall(r"\{\s*(KEY_[A-Z0-9_]+)\s*,", tbl) if r in kc}

    hit = sorted(codes & mapped)
    miss = sorted(c for c in (codes - mapped) if c >= args.floor)

    print("keymap declares %d keycodes; the remap table covers %d"
          % (len(codes), len(hit)))
    print("\ncovered -- these drive the player:")
    for c in hit:
        print("   %-5d %s" % (c, "/".join(sorted(name_of.get(c, ["?"])))))
    # ★ CLASSIFY the uncovered rather than just listing them. "Not in the table"
    # is only acceptable if it is one of: a key the core already binds natively,
    # a key ir_deny[] reserves for Main, or one the source explicitly records as
    # considered-and-unbound. Anything else is an OVERSIGHT, and this is what
    # tells the two apart.
    deny = set()
    md = re.search(r"ir_deny\[\]\s*=\s*\{(.*?)\};", body, re.S)
    if md:
        for nm in re.findall(r"KEY_[A-Z0-9_]+", md.group(1)):
            if nm in kc:
                deny.add(kc[nm])

    # The "considered and DELIBERATELY left unbound" list is a COMMENT, so read it
    # from the raw source rather than the comment-stripped body.
    unbound = set()
    mu = re.search(r"DELIBERATELY left unbound(.*?)\n\n", src, re.S)
    if mu:
        for nm in re.findall(r"KEY_[A-Z0-9_]+", mu.group(1)):
            if nm in kc:
                unbound.add(kc[nm])
    native = {kc[n] for n in ("KEY_ENTER", "KEY_UP", "KEY_DOWN", "KEY_LEFT",
                              "KEY_RIGHT") if n in kc}

    print("\ndeclared but NOT covered (>= %d), with why:" % args.floor)
    oversight = []
    for c in miss:
        nm = "/".join(sorted(name_of.get(c, ["?"])))
        if c in native:
            why = "the core already binds it natively"
        elif c in deny:
            why = "ir_deny[] -- reserved for Main"
        elif c in unbound:
            why = "considered, deliberately unbound"
        else:
            why = "*** UNEXPLAINED ***"
            oversight.append(c)
        print("   %-5d %-28s %s" % (c, nm, why))

    print()
    if oversight:
        print("%d UNEXPLAINED -- these are oversights, not decisions" % len(oversight))
        return 1
    print("every declared key is covered, native, denied or deliberately unbound")
    return 0


if __name__ == "__main__":
    sys.exit(main())
