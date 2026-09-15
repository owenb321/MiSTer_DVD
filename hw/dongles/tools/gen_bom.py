#!/usr/bin/env python3
"""Build a BOM from the EXPORTED netlist, so it cannot drift from the schematic.

A hand-maintained BOM is the classic way to assemble a board that is not the one
you designed.  This reads what KiCad exported and groups by (value, footprint).

Manufacturer part numbers below are a STARTING POINT.  Distributor codes are
deliberately NOT invented here - look them up and paste them into the
`lcsc`/`supplier_pn` column before ordering.  See ../analog-5p1/README.md.
"""

import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ksym

# value -> (manufacturer part, description, sourcing note)
MPN = {
    "PCM5102A": ("PCM5102APWR", "Stereo DAC, 32-bit/384k, TSSOP-20",
                 "TI. The whole design assumes this part's BCK-PLL mode."),
    "AP2112K-3.3": ("AP2112K-3.3TRG1", "LDO 600mA 3.3V, SOT-25",
                    "Diodes Inc. Any 3.3V/>=200mA low-noise LDO in SOT-25 works."),
    "USB3_A_PLUG": ("see note", "USB 3.0 Standard-A PLUG, board mount",
                    "SOURCING RISK - see README. Alternative: USB3 Standard-B "
                    "RECEPTACLE + a stock A-to-B cable (pin numbers are "
                    "straight through)."),
    "3.5mm TRS": ("SJ1-3535NG", "3.5 mm stereo jack, TRS",
                  "CUI. THT part - confirm your assembler does through-hole, "
                  "or substitute an SMD jack."),
    "600R@100MHz": ("BLM18PG601SN1D", "Ferrite bead 600R @100MHz, 0603",
                    "Murata. Any 0603 bead >=600R at 100MHz."),
    "10uF": ("generic", "MLCC 10uF 16V X5R 0805", "Any reputable X5R/X7R."),
    "2.2uF": ("generic", "MLCC 2.2uF 16V X7R 0805",
              "Charge-pump caps - X7R preferred, do NOT use Y5V."),
    "1uF": ("generic", "MLCC 1uF 16V X7R 0805", ""),
    "100nF": ("generic", "MLCC 100nF 50V X7R 0603", ""),
    "1nF": ("generic", "MLCC 1nF 50V C0G/NP0 0603",
            "C0G preferred - these sit in the audio output path."),
    "33R": ("generic", "Resistor 33R 1% 0603", "0R is an acceptable substitute."),
    "100R": ("generic", "Resistor 100R 1% 0603", ""),
    "4k7": ("generic", "Resistor 4.7k 1% 0603",
            "MUTE INTERLOCK - must be <=4.7k to beat the FPGA's ~25k pull-up."),
    "10k": ("generic", "Resistor 10k 1% 0603", ""),
    "10k DNP": ("generic", "Resistor 10k 1% 0603",
                "DO NOT FIT. Escape hatch only - see schematic note at R8."),
}


def main(netlist, out_csv):
    root = ksym.parse_sexp(open(netlist, encoding="utf-8").read())[0]
    groups = {}
    for c in ksym.find_all(ksym.find_one(root, "components"), "comp"):
        ref = ksym.unq(ksym.find_one(c, "ref")[1])
        val = ksym.unq(ksym.find_one(c, "value")[1])
        fp = ksym.find_one(c, "footprint")
        fp = ksym.unq(fp[1]) if fp else ""
        groups.setdefault((val, fp), []).append(ref)

    def sortkey(refs):
        r = refs[0]
        pre = "".join(ch for ch in r if ch.isalpha())
        num = "".join(ch for ch in r if ch.isdigit())
        return (pre, int(num) if num else 0)

    rows = []
    for (val, fp), refs in sorted(groups.items(), key=lambda kv: sortkey(kv[1])):
        refs = sorted(refs, key=lambda r: (len(r), r))
        mpn, desc, note = MPN.get(val, ("", "", "UNMAPPED - fill this in"))
        rows.append({
            "qty": len(refs),
            "refs": ",".join(refs),
            "value": val,
            "description": desc,
            "footprint": fp.split(":")[-1],
            "mfr_pn": mpn,
            "supplier_pn": "",          # fill before ordering
            "fit": "DNP" if "DNP" in val else "fit",
            "notes": note,
        })

    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    total = sum(r["qty"] for r in rows if r["fit"] == "fit")
    print(f"wrote {out_csv}")
    print(f"  {len(rows)} line items, {total} parts to fit")
    unmapped = [r["value"] for r in rows if not r["description"]]
    if unmapped:
        print(f"  UNMAPPED values: {unmapped}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
