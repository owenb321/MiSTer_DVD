#!/usr/bin/env bash
# timing_paths.sh — wrapper for tools/timing_paths.tcl (top intra-clock setup paths).
#
#   [USE_DOCKER=1] [TIMING_CLOCK=dec|mem|<clock>] [TIMING_TEMP=100|-40] [TIMING_OUT=file] \
#       tools/timing_paths.sh [npaths]     (default 100 paths, clk_dec, slow 100 °C)
#
# Needs a completed fit on disk (db/ + output_files/) — it does NOT refit; it opens the
# existing timing netlist. Output: output_files/clk_<dec|mem>_paths.txt unless TIMING_OUT
# says otherwise (a path inside the repo: Docker mounts only the repo). See timing_paths.tcl.

set -u
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"

cd "$(dirname "$0")/.."
exec quartus_sta -t tools/timing_paths.tcl "${1:-100}"
