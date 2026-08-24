#!/usr/bin/env bash
# timing_paths.sh — wrapper for tools/timing_paths.tcl (top intra-clk_dec setup paths).
#
#   [USE_DOCKER=1] tools/timing_paths.sh [npaths]     (default 100)
#
# Needs a completed fit on disk (db/ + output_files/) — it does NOT refit; it opens the
# existing timing netlist. Output: output_files/clk_dec_paths.txt. See timing_paths.tcl.

set -u
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"

cd "$(dirname "$0")/.."
exec quartus_sta -t tools/timing_paths.tcl "${1:-100}"
