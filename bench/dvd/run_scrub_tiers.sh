#!/usr/bin/env bash
#
# run_scrub_tiers.sh -- the gate on the hold-to-scrub CONTENT RATE
# (dvd/scrub_ctrl.sv; docs/dvd_nav.md "Seeking / Phase 8a").
#
# The step used to be a fraction of the title span, so the shorter the title the
# slower the scrub (0.58 content-seconds per second on a 3-minute clip, 0.19 on a
# 30-second one, against 29 for a 2 h feature). It is now an absolute rate:
# lin_blk10 >> LSn for a linear file, and span >> (SHn + duration bucket) for a
# DVD title, anchored so a ~2 h title's step is BIT-IDENTICAL to what shipped.
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
