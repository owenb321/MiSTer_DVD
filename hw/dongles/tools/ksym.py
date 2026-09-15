#!/usr/bin/env python3
"""Minimal KiCad s-expression reader: pull pin geometry out of a .kicad_sym library.

Why this exists: the schematic generators in this directory attach a wire stub and a
net label to every pin.  That is only correct if the stub lands exactly on the pin's
connection point, so the pin positions are READ FROM THE INSTALLED SYMBOL LIBRARY
rather than transcribed.  A transcribed pin table is the classic way to ship a board
whose netlist does not match its schematic.
"""

import os
import sys

SYMDIR = os.environ.get("KICAD_SYMBOL_DIR", "/usr/share/kicad/symbols")


def parse_sexp(text):
    """Parse s-expressions into nested lists.  Atoms stay strings; quoted strings
    keep their contents (with escapes resolved) and are tagged by a leading \0 so a
    quoted "1" is distinguishable from a bare token if that ever matters."""
    out = []
    stack = [out]
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "(":
            new = []
            stack[-1].append(new)
            stack.append(new)
            i += 1
        elif c == ")":
            stack.pop()
            i += 1
        elif c == '"':
            i += 1
            buf = []
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                    buf.append(text[i])
                else:
                    buf.append(text[i])
                i += 1
            i += 1
            stack[-1].append("\0" + "".join(buf))
        elif c.isspace():
            i += 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "()":
                j += 1
            stack[-1].append(text[i:j])
            i = j
    return out


def unq(a):
    return a[1:] if isinstance(a, str) and a.startswith("\0") else a


def find_all(node, tag):
    return [x for x in node if isinstance(x, list) and x and unq(x[0]) == tag]


def find_one(node, tag):
    r = find_all(node, tag)
    return r[0] if r else None


class Symbol:
    """A flattened symbol: name plus its pins (including those in sub-units)."""

    def __init__(self, name, pins):
        self.name = name
        self.pins = pins  # list of dicts: number, name, x, y, angle, length, etype

    def pin(self, number):
        for p in self.pins:
            if p["number"] == str(number):
                return p
        raise KeyError(f"{self.name}: no pin {number!r} "
                       f"(have {[p['number'] for p in self.pins]})")

    def pin_by_name(self, name):
        hits = [p for p in self.pins if p["name"] == name]
        if len(hits) != 1:
            raise KeyError(f"{self.name}: pin name {name!r} matched {len(hits)}")
        return hits[0]


_cache = {}


def load(lib, symname):
    """Load 'symname' from '<SYMDIR>/<lib>.kicad_sym', following 'extends'."""
    key = (lib, symname)
    if key in _cache:
        return _cache[key]
    path = os.path.join(SYMDIR, lib + ".kicad_sym")
    with open(path, "r", encoding="utf-8") as f:
        root = parse_sexp(f.read())[0]

    top = {}
    for s in find_all(root, "symbol"):
        top[unq(s[1])] = s
    if symname not in top:
        raise KeyError(f"{lib}: no symbol {symname!r}")

    node = top[symname]
    ext = find_one(node, "extends")
    if ext:
        base = load(lib, unq(ext[1]))
        pins = list(base.pins)
    else:
        pins = []
        # pins live in the sub-unit symbols, e.g. "PCM5102A_1_1"
        for sub in find_all(node, "symbol"):
            for p in find_all(sub, "pin"):
                at = find_one(p, "at")
                ln = find_one(p, "length")
                nm = find_one(p, "name")
                nu = find_one(p, "number")
                pins.append({
                    "etype": unq(p[1]),
                    "x": float(at[1]),
                    "y": float(at[2]),
                    "angle": float(at[3]) if len(at) > 3 else 0.0,
                    "length": float(ln[1]) if ln else 2.54,
                    "name": unq(nm[1]) if nm else "",
                    "number": unq(nu[1]) if nu else "",
                })
    sym = Symbol(symname, pins)
    _cache[key] = sym
    return sym


if __name__ == "__main__":
    lib, name = sys.argv[1], sys.argv[2]
    s = load(lib, name)
    print(f"{lib}:{name}  ({len(s.pins)} pins)")
    for p in sorted(s.pins, key=lambda q: (len(q["number"]), q["number"])):
        print(f"  {p['number']:>4}  {p['name']:<14} "
              f"at=({p['x']:7.2f},{p['y']:7.2f}) ang={p['angle']:5.0f} "
              f"len={p['length']:4.2f}  {p['etype']}")
