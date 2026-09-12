#!/usr/bin/env bash
#
# run_scrub_tiers.sh -- the gate on the hold-to-scrub CONTENT RATE
# (dvd/scrub_ctrl.sv; docs/dvd_nav.md "Seeking / Phase 8a").
#
# The step used to be a fraction of the title span, so the shorter the title the
# slower the scrub (0.58 content-seconds per second on a 3-minute clip, 0.19 on a
# 30-second one, against 29 for a 2 h feature). It is now an absolute rate, and
# ONE rate whatever is mounted: ~15 / 60 / 240 / 960 content-seconds per second,
# from (lin_blk10 * 6) >> LSn on a linear file and span >> (SHn + duration
# bucket) on a DVD. T19 is the arm that pins them together.
#
# It also gates how that tier READS: dvd/transport_hud.sv draws it as 2..5
# arrows, because the field used to print "xN" from the tier ordinal -- "x1" for
# a tier moving ~29 content-seconds per wall second, which is what "x1" most
# specifically is not.
#
#   ./bench/dvd/run_scrub_tiers.sh          # GREEN
#   ./bench/dvd/run_scrub_tiers.sh --red    # ...then a mutation per arm
#
# Each mutant sed-copies the module into a scratch dir and rebuilds the bench
# against it; a mutant that does NOT fail means the arm is not measuring what it
# claims (memory: bench-that-cannot-fail).
set -u -o pipefail
cd "$(dirname "$0")/../.."

IV="iverilog -g2012"
rc=0
SCR=$(mktemp -d)
trap 'rm -rf "$SCR"' EXIT

echo "### GREEN"
$IV -o "$SCR/scrub_sim" dvd/scrub_ctrl.sv bench/dvd/scrub_ctrl_tb.sv || rc=1
vvp "$SCR/scrub_sim" | tail -12 || rc=1

# The HUD readout of the same tier: 2..5 arrows, never "xN".
$IV -o "$SCR/hud_sim" dvd/transport_hud.sv bench/dvd/transport_hud_tb.sv || rc=1
vvp "$SCR/hud_sim" | grep -E "arrows|direction only|TRANSPORT_HUD_TB" || rc=1

# ...and the ONE emu connection the benches cannot see. transport_hud has no way
# to know a D-pad gesture is not a scrub: emu decides, on one line, and a wrong
# FACT on a port connection is invisible to every module-level test (the issue
# #81 lesson, and tools/check_subp_map_wiring.py is the precedent for gating it
# by reading the file). Feeding dpad_pend_n here -- the TAP COUNT, which is what
# it used to be -- would draw four taps as the fastest scrub tier.
echo "-- emu wiring"
if grep -qE '\.scrub_tier +\(hold_freeze \? hud_tier_w : 2.d0\)' dvd/emu.sv; then
  echo "  ok  emu feeds no tier on the D-pad arm"
else
  echo "  FAIL: dvd/emu.sv must feed .scrub_tier 2'd0 while a D-pad gesture is pending"
  echo "        (a tap count would render as a speed); found:"
  grep -n "\.scrub_tier" dvd/emu.sv | sed 's/^/        /'
  rc=1
fi

# a mutant must FAIL the bench, and must fail the arm NAMED for it
mutant() {   # label, sed_expr, expected failing arm (grep string)
  local label=$1 sedx=$2 want=$3
  local mut="$SCR/scrub_ctrl.sv"
  sed "$sedx" dvd/scrub_ctrl.sv > "$mut"
  if cmp -s "$mut" dvd/scrub_ctrl.sv; then
    echo "  MUTANT $label: sed did not change the file -- STALE"; rc=1; return
  fi
  $IV -o "$SCR/mut_sim" "$mut" bench/dvd/scrub_ctrl_tb.sv >/dev/null 2>&1 \
    || { echo "  MUTANT $label: caught (compile)"; return; }
  local out; out=$(vvp "$SCR/mut_sim" 2>&1)
  if echo "$out" | grep -q "ALL TESTS PASSED"; then
    echo "  MUTANT $label: NOT CAUGHT -- the bench cannot see this defect"; rc=1
  elif echo "$out" | grep -q "$want"; then
    echo "  MUTANT $label: caught by \"$want\""
  else
    echo "  MUTANT $label: caught, but NOT by \"$want\" -- check which arm owns it"
    echo "$out" | grep "FAIL:" | sed 's/^/      /'
    rc=1
  fi
}

if [ "${1:-}" = "--red" ]; then
  echo "### RED arms (one per claim)"
  # Arm 1: the linear step is the measured rate, not the span.
  mutant "linear falls back to the span" \
         's/wire \[31:0\] step      = lin_rate_ok ? step_lin : step_span;/wire [31:0] step      = step_span;/' \
         "linear: tier 0"
  # ...and the valid flag is what gates it, not the value.
  mutant "an untrusted rate is used anyway" \
         's/wire \[31:0\] step      = lin_rate_ok ? step_lin : step_span;/wire [31:0] step      = step_lin;/' \
         "linear: an untrusted rate"
  # Arm 2: the duration bucket actually biases the shift.
  mutant "the duration bucket is inert" \
         's/(sh_sum > 8'"'"'sd31)     ? 5'"'"'d31 : sh_sum\[4:0\];/(sh_sum > 8'"'"'sd31)     ? 5'"'"'d31 : sh;/' \
         "rate: a 3-minute clip"
  # ...anchored where the hardware-signed-off feel lives.
  # The claim the ladder change exists for: both sources ramp at one speed.
  mutant "the linear lattice is unscaled" \
         's/parameter LIN_K  = 3'"'"'d6,/parameter LIN_K  = 3'"'"'d1,/' \
         "parity:"
  mutant "the ladders drift apart" \
         's/parameter LS0    = 5'"'"'d6,/parameter LS0    = 5'"'"'d5,/' \
         "parity:"
  mutant "the anchor moved off 2 h" \
         's/parameter SECS_REF = 5'"'"'d12,/parameter SECS_REF = 5'"'"'d10,/' \
         "anchor: 4096 s"
  # The floor that stops a step rounding to zero.
  mutant "the step may round to zero" \
         's/wire \[31:0\] step_span = (span >> sh_eff) | 32'"'"'d1;/wire [31:0] step_span = (span >> sh_eff);/' \
         "FAIL:"
fi

[ $rc -eq 0 ] && echo "RUN_SCRUB_TIERS: ALL GREEN" || echo "RUN_SCRUB_TIERS: FAILURES"
exit $rc
