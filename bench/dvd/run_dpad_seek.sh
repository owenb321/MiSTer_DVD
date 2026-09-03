#!/usr/bin/env bash
# run_dpad_seek.sh — O[45] "D-Pad Seek" (fixed-time D-pad seeking) suite.
#
# One command for the whole feature's regression surface:
#   1. dpad_seek_tb     — the resolver against the REAL nav_dsi, driven from a
#                         synthetic DSI payload (test_vobs/ is gitignored, so
#                         nothing load-bearing may depend on the disc fixtures).
#                         Covers the exact fwda/bwda lookups, both cascade tiers,
#                         both structural fallbacks, coalescing, linear mode, and
#                         the STALE-TABLE TRAP (T0 demonstrates the hazard,
#                         T10 proves the gate blocks it).
#   2. scrub_ctrl_tb    — the jump mode, plus TESTS 1-8 unchanged = the
#                         regression gate on the shipped hold-to-seek path.
#   3. nav_dsi_tb       — DSI parse (SKIPS without the gitignored MiB fixture).
#   4. transport_hud_tb — the "SEEK FWD/BACK nnS" popup after the pop_type
#                         3->4 bit widening, and types 0-7 unregressed.
#   5. hud_frame_tb     — full-raster render + interlace-identity proof.
#   6. seek_bar_tb      — the position bar a jump pops.
#   7. iso_reader_seek_tb — the reader's raw-RBN seek contract. UNCHANGED by
#                         this feature (dpad_seek drives the same seek_rbn_pulse
#                         scrub_ctrl always drove); run as the guard that it is.
#
#   9. seek_time_tb     — the seek-PREVIEW clock: what time a pending gesture
#                         will land on, from the D-pad's own delta, a chapter's
#                         authored start, or per-cell interpolation of an RBN.
#                         Also mutation-proven, nine faults.
#   8. lin_rate_tb      — the blocks-per-10 s rate a flat .mpg/.VOB needs (the
#                         step lin_mode now takes from a port, issue #39) plus
#                         the linear-mode HUD clock built on the same divider.
#                         Stimulus is a stream model, and every check is
#                         mutation-proven against nine targeted RTL faults.
#
# The LINEAR raw-RBN seek that lin_mode targets is already covered by
# iso_reader_raw_tb — see bench/dvd/run_vcd.sh, not duplicated here.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

rc=0
run() {
    local name=$1; shift
    echo "== $name =="
    iverilog -g2012 -o "bench/dvd/${name}_sim" "$@" "bench/dvd/${name}.sv"
    vvp "bench/dvd/${name}_sim" | tail -4 || rc=1
}

run dpad_seek_tb      dvd/dpad_seek.sv dvd/nav_dsi.sv
run lin_rate_tb       dvd/lin_rate.sv dvd/secs_bcd.sv
run scrub_ctrl_tb     dvd/scrub_ctrl.sv
run nav_dsi_tb        dvd/nav_dsi.sv
run transport_hud_tb  dvd/transport_hud.sv
run hud_frame_tb      dvd/transport_hud.sv dvd/subpic_blend.sv
run seek_bar_tb       dvd/seek_bar.sv
run seek_time_tb      dvd/seek_time.sv dvd/secs_bcd.sv
run iso_reader_seek_tb dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv

if [ $rc -eq 0 ]; then echo "RUN_DPAD_SEEK: ALL SUITES PASSED";
else echo "RUN_DPAD_SEEK: FAILURES"; fi
exit $rc
