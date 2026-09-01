#!/usr/bin/env python3
"""Check the user manual against the core's actual OSD definition.

`parameter CONF_STR` in dvd/emu.sv is the normative source for the user-visible
surface: every OSD option, every gamepad button, and the list of file extensions
the core will load. This script extracts them and asserts each is documented in
the manual page that owns it.

It proves a term is MENTIONED, not that the prose around it is correct — that is
a human's job (and the docs-sweep skill's). What it does make impossible is
adding an OSD option and shipping without documenting it at all, which is the
drift that actually happens.

  python3 tools/docs_check.py            # check
  python3 tools/docs_check.py --list     # print what was parsed, then check

Exit status is 0 when everything is documented, 1 otherwise.

⚠ Parse the block by its terminator, never with a bare grep. emu.sv contains
commented-out CONF_STR history further down the file (a retired "Direct Video"
row, an older Audio row, a whole retired bitstream-options group). A loose grep
picks those up and invents options that do not exist — which is exactly the
mistake this script exists to prevent, made in the other direction.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMU = ROOT / "dvd" / "emu.sv"
CONTENT = ROOT / "site" / "content"

# Which manual page owns which part of the OSD surface.
OWNER = {
    "option": "playback/settings.md",
    "button": "playback/controls.md",
    "ext": "getting-started/loading.md",
}

# Options whose *values* are documented on another page. The option NAME must
# still appear on the settings page; this only exempts the value labels, which
# are explained in depth elsewhere.
VALUES_DOCUMENTED_ELSEWHERE = {
    "Player Language",     # 16 language names; the list is not worth restating
    "Title VTS Tens",      # 0-9
    "Title VTS Units",     # Auto/0-9
    "A/V Offset",          # 8 millisecond values
}


def extract_conf_str(text: str) -> list[str]:
    """Return the quoted string literals of the ACTIVE CONF_STR block."""
    m = re.search(r"^parameter\s+CONF_STR\s*=\s*\{", text, re.M)
    if not m:
        sys.exit("docs_check: no `parameter CONF_STR = {` found in dvd/emu.sv")

    # Walk forward to the matching close brace, tracking nesting, and stop
    # there. Everything after it is not the OSD definition.
    depth, i, n = 0, m.end() - 1, len(text)
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    else:
        sys.exit("docs_check: CONF_STR block is not terminated")

    block = text[m.end():i]

    # Strip comments before pulling literals, so a commented-out row cannot
    # masquerade as a live one.
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    block = re.sub(r"//[^\n]*", "", block)

    return re.findall(r'"([^"]*)"', block)


def parse(literals: list[str]):
    """Split CONF_STR literals into options, buttons and file extensions."""
    options: list[tuple[str, list[str]]] = []
    buttons: list[str] = []
    exts: list[str] = []

    for lit in literals:
        s = lit.rstrip(";")
        if not s:
            continue

        # "J1,Pause,Prev Chapter,..." — the gamepad button labels
        if re.fullmatch(r"J\d?", s.split(",")[0]):
            buttons = [b.strip() for b in s.split(",")[1:] if b.strip()]
            continue

        # "S0,MPGM2VVOBISOBINIMGDAT,Load Video" — concatenated 3-char extensions
        if re.fullmatch(r"S\d", s.split(",")[0]):
            parts = s.split(",")
            if len(parts) >= 2:
                blob = parts[1]
                exts = [blob[k:k + 3] for k in range(0, len(blob), 3)]
            continue

        # "O[27:26],Analog Out,Auto,Interlaced,..." / "P1O2,Debug Overlay,Off,On"
        # / "OX6,Audio Out,..." / "OB,480i Deint,Bob,Weave"
        head = s.split(",")[0]
        if re.fullmatch(r"(P\d)?O[X]?(\[[\d:]+\]|[0-9A-Za-z])", head):
            parts = [p.strip() for p in s.split(",")]
            if len(parts) >= 2 and parts[1]:
                options.append((parts[1], parts[2:]))
            continue

        # Everything else (title, page markers, R0 Reset, v,N, V version) is
        # structural and carries nothing to document.

    return options, buttons, exts


def page_text(rel: str) -> str:
    p = CONTENT / rel
    if not p.is_file():
        sys.exit(f"docs_check: manual page missing: site/content/{rel}")
    return p.read_text(encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true",
                    help="print the parsed OSD surface before checking")
    args = ap.parse_args()

    literals = extract_conf_str(EMU.read_text(encoding="utf-8"))
    options, buttons, exts = parse(literals)

    if not options or not buttons:
        sys.exit("docs_check: parsed no options or no buttons — the CONF_STR "
                 "format has probably changed; fix this script before trusting it")

    if args.list:
        print(f"CONF_STR: {len(options)} options, {len(buttons)} buttons, "
              f"{len(exts)} extensions")
        for name, vals in options:
            print(f"  option  {name:<22} {','.join(vals)}")
        print(f"  buttons {', '.join(buttons)}")
        print(f"  exts    {', '.join(exts)}")
        print()

    settings = page_text(OWNER["option"])
    controls = page_text(OWNER["button"])
    loading = page_text(OWNER["ext"])

    failures: list[str] = []

    for name, values in options:
        if name not in settings:
            failures.append(
                f"OSD option {name!r} is not documented in "
                f"site/content/{OWNER['option']}")
            continue
        if name in VALUES_DOCUMENTED_ELSEWHERE:
            continue
        for v in values:
            # Value labels can be reworded in prose; only flag a value that
            # appears nowhere on the page at all.
            if v and v not in settings:
                failures.append(
                    f"OSD option {name!r}: value {v!r} is not mentioned in "
                    f"site/content/{OWNER['option']}")

    for b in buttons:
        if b not in controls:
            failures.append(
                f"gamepad button {b!r} is not documented in "
                f"site/content/{OWNER['button']}")

    for e in exts:
        # Documented as ".iso" / ".vob" etc, case-insensitively.
        if e.lower() not in loading.lower():
            failures.append(
                f"file extension {e!r} is accepted by the core but not listed in "
                f"site/content/{OWNER['ext']}")

    if failures:
        print(f"docs_check: {len(failures)} problem(s)\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print("\nThe OSD is the contract. Update the manual page, or if an option "
              "was deliberately removed, remove it from CONF_STR too.",
              file=sys.stderr)
        return 1

    print(f"docs_check: OK — {len(options)} OSD options, {len(buttons)} buttons, "
          f"{len(exts)} file extensions all documented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
