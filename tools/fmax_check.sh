#!/usr/bin/env bash
# fmax_check.sh — verify the clk_dec (decoder, 81 MHz) domain Fmax from a Quartus STA report.
#
# The chroma-fringe / vertical-striping / garbled-green placement lottery is clk_dec
# failing setup: the domain must close >= 81 MHz at BOTH slow corners or the build is
# marginal (fringe risk on HW). This script is the ONLY sanctioned way to read that
# number out of DVD.sta.rpt.
#
#   PARSING RULE (learned the hard way, 2026-07-09): the Fmax Summary tables are sorted
#   by Fmax VALUE, so a clock's neighbors shift with every fit. Any `grep -A/-B` or
#   `tail`-based extraction reads a DIFFERENT clock's row sooner or later — the July 9
#   seed sweep did exactly that and logged junk (reported 99.89 MHz for a fit whose true
#   clk_dec was 81.13/77.38). Parse ROW-ANCHORED only: find the row that itself contains
#   the clk_dec divclk name, take its Restricted Fmax column.
#
# Usage:  tools/fmax_check.sh [path/to/DVD.sta.rpt]     (default output_files/DVD.sta.rpt)
#   FMAX_MIN=86.0   threshold in MHz (both slow corners must meet it)
# Exit codes: 0 = PASS, 1 = FAIL (below threshold), 2 = parse error / missing report.
#
# THRESHOLD (raised 81.0 -> 86.0, 2026-08-01, feature/fringe-sdc-clock-groups): after the
# sys_top.sdc clock-groups fix (docs/history.md §10) every seed in a full sweep closed
# clk_dec at 86.87-92.46 MHz worst-corner, while the builds that fringed on HW historically
# sat at 81-83. 86.0 is below the entire healthy distribution (any good fit passes without
# a sweep) and above the marginal class (a fit under 86 means the netlist has degraded —
# measure with tools/timing_paths.sh and fix the top cluster, don't just re-roll seeds).

set -u

RPT="${1:-output_files/DVD.sta.rpt}"
FMAX_MIN="${FMAX_MIN:-86.0}"
CLK_DEC='emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk'   # outclk_3 = clk_dec
CLK_MEM='emu|sys_pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk'   # outclk_1 = clk_mem (info only)

if [[ ! -f "$RPT" ]]; then
    echo "fmax_check: ERROR: STA report not found: $RPT" >&2
    exit 2
fi

# Mismatched-pair trap: after a seed sweep the on-disk .sof and .sta.rpt can come from
# DIFFERENT fits (the July 9 sweep packed a seed-7 .sof while the rpt was seed 12's;
# the Aug 1 exhausted margin sweep left a seed-17 rpt NEWER than the shipped seed-11
# .sof — so the check is bidirectional: a healthy compile flow produces the pair
# within minutes of each other, any large gap in EITHER direction means they are
# from different fits).
SOF="$(dirname "$RPT")/DVD.sof"
if [[ -f "$SOF" ]]; then
    rpt_t=$(stat -c %Y "$RPT" 2>/dev/null || echo 0)
    sof_t=$(stat -c %Y "$SOF" 2>/dev/null || echo 0)
    gap=$(( rpt_t - sof_t )); [[ $gap -lt 0 ]] && gap=$(( -gap ))
    if [[ $gap -gt 1800 ]]; then
        echo "fmax_check: WARNING: $RPT and $SOF timestamps differ by ${gap}s — the report may describe a different fit than the packed bitstream." >&2
    fi
fi

# Row-anchored extraction: walk the report, track which Fmax Summary table we are in
# (table title rows look like '; Slow 1100mV 100C Model Fmax Summary ;'), and when a row
# inside a slow-corner table contains the target clock name, take column 2 = Restricted
# Fmax. Emits "corner value" pairs. Plain substring match (index) — the clock name is
# full of regex metacharacters ([3], |, .) that would otherwise match other divclk rows.
extract() { # $1 = exact clock-name substring
    awk -v pat="$1" '
        /^; Slow 1100mV 100C Model Fmax Summary/ { corner = "100C"; next }
        /^; Slow 1100mV -40C Model Fmax Summary/ { corner = "-40C"; next }
        /^; (Fast|Multicorner|Setup|Hold)/       { corner = "" }
        corner != "" && index($0, pat) > 0 && / MHz / {
            n = split($0, f, ";")
            gsub(/^ +| +$/, "", f[3])       # f[2]=Fmax, f[3]=Restricted Fmax
            sub(/ MHz$/, "", f[3])
            print corner, f[3]
        }' "$RPT"
}

declare -A dec mem
while read -r corner val; do dec[$corner]="$val"; done < <(extract "$CLK_DEC")
while read -r corner val; do mem[$corner]="$val"; done < <(extract "$CLK_MEM")

if [[ -z "${dec[100C]:-}" || -z "${dec[-40C]:-}" ]]; then
    echo "fmax_check: ERROR: clk_dec row not found in both slow-corner Fmax tables of $RPT" >&2
    exit 2
fi

echo "clk_dec Restricted Fmax: ${dec[100C]} MHz @100C, ${dec[-40C]} MHz @-40C (target ${FMAX_MIN})"
[[ -n "${mem[100C]:-}" ]] && \
    echo "clk_mem (info, no gate):  ${mem[100C]} MHz @100C, ${mem[-40C]:-?} MHz @-40C (infra domain, never closes; validated empirically)"

if awk -v a="${dec[100C]}" -v b="${dec[-40C]}" -v m="$FMAX_MIN" 'BEGIN{ exit !(a >= m && b >= m) }'; then
    echo "fmax_check: PASS — clk_dec closes ${FMAX_MIN} MHz at both slow corners"
    exit 0
else
    echo "fmax_check: FAIL — clk_dec below ${FMAX_MIN} MHz (fringe-lottery build; re-sweep seeds or retime)"
    exit 1
fi
