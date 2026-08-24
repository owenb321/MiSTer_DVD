#!/usr/bin/env python3
"""
gen_mp2_tables.py — generate the MP2 decoder ROM images (dvd/mp2/*.mem) from
the golden model's tables (tools/mp2_ref.py), so RTL and model are pinned to
identical values by construction.

Outputs (all $readmemh format, one entry per line, repo-root-relative paths
matching the dvd/hud_font.mem convention):
  dvd/mp2/mp2_nrom.mem   2048 x 16-bit two's complement  N[i][k] Q1.14,
                         address = {i[5:0], k[4:0]}
  dvd/mp2/mp2_drom.mem   512 x 18-bit two's complement   D[j] Q2.16
  dvd/mp2/mp2_scfrom.mem 64 x 22-bit unsigned            SCF[idx] Q1.20
                         (idx 63 = 0, never coded)

Run from the repo root:  python3 tools/gen_mp2_tables.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mp2_ref import N_Q14, SCF_Q20          # noqa: E402
from mp2_window import D_Q16                # noqa: E402


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "dvd", "mp2")
    os.makedirs(out, exist_ok=True)

    with open(os.path.join(out, "mp2_nrom.mem"), "w") as f:
        for i in range(64):
            for k in range(32):
                v = N_Q14[i][k] & 0xFFFF
                f.write(f"{v:04x}\n")

    with open(os.path.join(out, "mp2_drom.mem"), "w") as f:
        for v in D_Q16:
            f.write(f"{v & 0x3FFFF:05x}\n")

    with open(os.path.join(out, "mp2_scfrom.mem"), "w") as f:
        for v in SCF_Q20:
            assert 0 <= v < (1 << 22)
            f.write(f"{v:06x}\n")
        f.write(f"{0:06x}\n")   # idx 63

    print(f"wrote mp2_nrom.mem (2048), mp2_drom.mem (512), mp2_scfrom.mem (64) to {out}")


if __name__ == "__main__":
    main()
