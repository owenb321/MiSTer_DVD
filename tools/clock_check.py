#!/usr/bin/env python3
"""clock_check.py — judge every clock's INTRA-domain timing from clock_check.tsv.

Usage:
    tools/clock_check.py [output_files/clock_check.tsv]
    tools/clock_check.py --selftest

Normally run by tools/clock_check.sh, which produces the TSV with quartus_sta first.
Exit codes: 0 = no FAIL (WARNs allowed), 1 = FAIL, 2 = missing/unparseable input.

The rules (docs/timing.md "The checks"):
  * hold / removal < 0 inside a domain, at ANY corner -> FAIL. A hold violation does not
    get better at a lower clock rate or a cooler die, so no margin argument rescues it.
  * setup: clk_dec FAILs below 86 MHz and clk_mem below its 90 MHz run rate at either
    slow corner (the same gates as fmax_check.sh, which stays the gate build_release.sh
    runs; clk_mem was a WARN until the 2026-10-09 retime cleared it on 7 of 7 seeds);
    every other clock WARNs on negative slack at any corner.
  * recovery < 0 inside a domain -> WARN.
  * A clock missing from POLICY is judged by the generic rules and flagged, so a new PLL
    output is never silently skipped.
Crossings between clocks are deliberately out of scope: the sys_pll ones are timed on
purpose and their negative slack is expected (sys_top.sdc, docs/history.md §10).
"""
import csv
import sys

# raw TimeQuest name -> (short name, setup rule, setup MHz threshold)
#   setup rule: "fail_fmax" | "warn_fmax" | "warn_slack"
POLICY = {
    "emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk":
        ("clk_dec", "fail_fmax", 86.0),
    "emu|sys_pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk":
        ("clk_mem", "fail_fmax", 90.0),
    "emu|sys_pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk":
        ("clk_sys", "warn_slack", None),
    "pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk":
        ("clk_hdmi", "warn_slack", None),
    "sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk":
        ("h2f_user0", "warn_slack", None),
    "pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk":
        ("clk_audio", "warn_slack", None),
    "FPGA_CLK1_50": ("FPGA_CLK1_50", "warn_slack", None),
    "FPGA_CLK2_50": ("FPGA_CLK2_50", "warn_slack", None),
    "FPGA_CLK3_50": ("FPGA_CLK3_50", "warn_slack", None),
    "hdmi_sck": ("hdmi_sck", "warn_slack", None),
}

# Known setup misses outside our logic: short name -> (node prefix, slack floor ns, why).
# The waiver holds only while the worst path starts AND ends under the prefix and its
# slack stays at or above the floor; anything else WARNs as usual, so a regression, or
# the worst path moving into our own logic, is still reported.
KNOWN = {
    "clk_hdmi": ("ascal:ascal|", -3.0,
                 "stock ascal (sys/ascal.vhd, unmodified since the import) at the 1080p "
                 "148.5 MHz constraint; docs/timing.md \"clk_hdmi\""),
}


def fmax_mhz(period_ns, slack_ns):
    """Clock rate at which the worst same-edge path would have zero slack."""
    need = period_ns - slack_ns
    return 1000.0 / need if need > 0 else float("inf")


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            r["period_ns"] = float(r["period_ns"])
            r["slack_ns"] = None if r["slack_ns"] == "-" else float(r["slack_ns"])
            rows.append(r)
    if not rows:
        raise ValueError("no rows")
    return rows


def judge(rows):
    """Return (table rows, findings). A finding is (level, clock, message)."""
    clocks = {}
    for r in rows:
        clocks.setdefault(r["clock"], []).append(r)

    table, findings = [], []
    for raw in sorted(clocks, key=lambda c: (c not in POLICY, POLICY.get(c, (c,))[0])):
        rs = clocks[raw]
        short, rule, thresh = POLICY.get(raw, (raw, "warn_slack", None))
        period = rs[0]["period_ns"]

        worst = {}
        for kind in ("setup", "hold", "recovery", "removal"):
            ks = [r for r in rs if r["analysis"] == kind and r["slack_ns"] is not None]
            worst[kind] = min(ks, key=lambda r: r["slack_ns"]) if ks else None
        if all(w is None for w in worst.values()):
            # A PLL VCO phase or an unused board clock: nothing to time.
            continue
        if raw not in POLICY:
            findings.append(("INFO", short, "not in clock_check.py POLICY; judged by the generic rules"))

        s = worst["setup"]
        slow = [r for r in rs if r["analysis"] == "setup" and r["slack_ns"] is not None
                and r["corner"].lower().startswith("slow")]
        min_fmax = min((fmax_mhz(period, r["slack_ns"]) for r in slow), default=None)

        if s is not None:
            where = f'{s["from_node"]} -> {s["to_node"]} ({s["corner"]})'
            if rule in ("fail_fmax", "warn_fmax"):
                if min_fmax is not None and min_fmax < thresh:
                    lvl = "FAIL" if rule == "fail_fmax" else "WARN"
                    findings.append((lvl, short, f"setup {min_fmax:.2f} MHz < {thresh} at a slow corner: {where}"))
            elif s["slack_ns"] < 0:
                k = KNOWN.get(short)
                lvl = "WARN"
                if (k and s["from_node"].startswith(k[0]) and s["to_node"].startswith(k[0])
                        and s["slack_ns"] >= k[1]):
                    lvl = "INFO"
                    where += f" -- known, floor {k[1]} ns: {k[2]}"
                findings.append((lvl, short, f'setup slack {s["slack_ns"]:.3f} ns ({fmax_mhz(period, s["slack_ns"]):.2f} MHz vs {1000/period:.2f}): {where}'))

        for kind, lvl in (("hold", "FAIL"), ("removal", "FAIL"), ("recovery", "WARN")):
            w = worst[kind]
            if w is not None and w["slack_ns"] < 0:
                findings.append((lvl, short, f'{kind} slack {w["slack_ns"]:.3f} ns: {w["from_node"]} -> {w["to_node"]} ({w["corner"]})'))

        def cell(w):
            return "-" if w is None else f'{w["slack_ns"]:+.3f}'
        table.append((short, f"{1000/period:.2f}",
                      "-" if min_fmax is None else f"{min_fmax:.2f}",
                      cell(worst["setup"]), cell(worst["hold"]),
                      cell(worst["recovery"]), cell(worst["removal"])))
    return table, findings


def report(table, findings):
    hdr = ("clock", "runs MHz", "Fmax slow", "setup ns", "hold ns", "recov ns", "remov ns")
    w = [max(len(h), *(len(r[i]) for r in table)) for i, h in enumerate(hdr)]
    print("clock_check: intra-domain worst slack over every corner")
    print("  " + "  ".join(h.ljust(w[i]) for i, h in enumerate(hdr)))
    for r in table:
        print("  " + "  ".join(c.ljust(w[i]) for i, c in enumerate(r)))
    for lvl, clk, msg in findings:
        print(f"clock_check: {lvl} {clk}: {msg}")
    fails = sum(1 for f in findings if f[0] == "FAIL")
    warns = sum(1 for f in findings if f[0] == "WARN")
    verdict = "FAIL" if fails else "PASS"
    print(f"clock_check: {verdict} ({fails} fail, {warns} warn)")
    return 1 if fails else 0


def selftest():
    """Each arm flips one input and must produce exactly its own finding."""
    DEC, MEM, SYS = (k for k in list(POLICY)[:3])

    def rows(over=None):
        base = {
            (DEC, "setup"): 1.5, (DEC, "hold"): 0.1,      # 92 MHz
            (MEM, "setup"): 0.3, (MEM, "hold"): 0.1,      # 92.6 MHz
            (SYS, "setup"): 5.0, (SYS, "hold"): 0.2, (SYS, "recovery"): 3.0, (SYS, "removal"): 0.4,
        }
        base.update(over or {})
        period = {DEC: 12.345, MEM: 11.111, SYS: 37.037}
        out = []
        for corner in ("Slow 1100mV 100C Model", "Fast 1100mV -40C Model"):
            for (clk, kind), slack in base.items():
                out.append({"corner": corner, "clock": clk, "period_ns": period.get(clk, 10.0),
                            "analysis": kind, "npaths": "1", "slack_ns": slack,
                            "from_node": "a", "to_node": "b"})
        return out

    def levels(rs):
        return sorted((l, c) for l, c, _ in judge(rs)[1] if l != "INFO")

    arms = [
        ("clean", rows(), []),
        ("clk_dec below 86 MHz", rows({(DEC, "setup"): 12.345 - 1000 / 85.0}), [("FAIL", "clk_dec")]),
        ("clk_dec 87 MHz passes", rows({(DEC, "setup"): 12.345 - 1000 / 87.0}), []),
        ("clk_mem below 90 MHz fails", rows({(MEM, "setup"): 11.111 - 1000 / 89.0}), [("FAIL", "clk_mem")]),
        ("clk_mem 91 MHz passes", rows({(MEM, "setup"): 11.111 - 1000 / 91.0}), []),
        ("negative intra hold fails", rows({(SYS, "hold"): -0.05}), [("FAIL", "clk_sys")]),
        ("negative intra removal fails", rows({(SYS, "removal"): -0.01}), [("FAIL", "clk_sys")]),
        ("negative intra recovery warns", rows({(SYS, "recovery"): -0.5}), [("WARN", "clk_sys")]),
        ("negative setup on a generic clock warns", rows({(SYS, "setup"): -0.1}), [("WARN", "clk_sys")]),
    ]
    bad = 0
    for name, rs, want in arms:
        got = levels(rs)
        ok = got == sorted(want)
        bad += not ok
        print(f"  [{'ok' if ok else 'BAD'}] {name}: {got}")

    # A clock the policy has never heard of must be reported, not skipped.
    rs = rows()
    rs.append({"corner": "Slow 1100mV 100C Model", "clock": "new_pll|divclk", "period_ns": 10.0,
               "analysis": "setup", "npaths": "1", "slack_ns": -0.2, "from_node": "a", "to_node": "b"})
    f = judge(rs)[1]
    ok = ("INFO", "new_pll|divclk") in [(l, c) for l, c, _ in f] and ("WARN", "new_pll|divclk") in [(l, c) for l, c, _ in f]
    bad += not ok
    print(f"  [{'ok' if ok else 'BAD'}] unknown clock is reported and judged")

    # A domain with no paths at all (a VCO phase) produces no row and no finding.
    rs = rows()
    rs.append({"corner": "Slow 1100mV 100C Model", "clock": "vco|vcoph[0]", "period_ns": 1.2,
               "analysis": "setup", "npaths": "0", "slack_ns": None, "from_node": "-", "to_node": "-"})
    t, f = judge(rs)
    ok = all(r[0] != "vco|vcoph[0]" for r in t) and all(c != "vco|vcoph[0]" for _, c, _ in f)
    bad += not ok
    print(f"  [{'ok' if ok else 'BAD'}] pathless clock is skipped")

    # The clk_hdmi waiver: inside ascal and above the floor is INFO; past the floor, or a
    # path that leaves ascal, is a WARN again.
    HDMI = next(k for k, v in POLICY.items() if v[0] == "clk_hdmi")
    def hdmi(slack, frm, to):
        rs = rows()
        rs.append({"corner": "Slow 1100mV -40C Model", "clock": HDMI, "period_ns": 6.732,
                   "analysis": "setup", "npaths": "1", "slack_ns": slack, "from_node": frm, "to_node": to})
        return levels(rs)
    for name, got, want in [
        ("clk_hdmi in ascal above the floor is known", hdmi(-2.5, "ascal:ascal|a", "ascal:ascal|b"), []),
        ("clk_hdmi past the floor warns", hdmi(-3.2, "ascal:ascal|a", "ascal:ascal|b"), [("WARN", "clk_hdmi")]),
        ("clk_hdmi path leaving ascal warns", hdmi(-0.5, "emu:emu|x", "ascal:ascal|b"), [("WARN", "clk_hdmi")]),
    ]:
        ok = got == want
        bad += not ok
        print(f"  [{'ok' if ok else 'BAD'}] {name}: {got}")

    print("clock_check selftest: " + ("PASS" if not bad else f"FAIL ({bad} arm(s))"))
    return 1 if bad else 0


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
    path = argv[1] if len(argv) > 1 else "output_files/clock_check.tsv"
    try:
        rows = load(path)
    except (OSError, ValueError, KeyError) as e:
        print(f"clock_check: cannot read {path}: {e}", file=sys.stderr)
        return 2
    return report(*judge(rows))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
