#!/usr/bin/env bash
# netlist_canary.sh -- fail a build whose netlist proves a data path is DEAD.
#
# WHY THIS EXISTS (2026-09-07). dvd/emu.sv declared dec_pts_in/dec_pts_in_valid,
# connected them to mpeg2video, and NEVER INSTANTIATED THE CDC THAT DRIVES THEM.
# mpeg2video's own comment said the PTS was "already crossed into clk (emu
# pts_cdc)". Quartus tied both low, the decoder never received a video PTS, and
# the whole PTS-scheduled display ran open-loop on extrapolation -- through TWO
# hardware rounds and a set of telemetry readings that all looked healthy.
#
# Nothing else could have caught it:
#   * It is not an implicit net. The wire was properly declared, so `default_nettype
#     none` and the Quartus 10236 gate (see the implicit-net-silent-kill lesson) are
#     both silent -- those catch a MISSING DECLARATION, this was a MISSING DRIVER.
#   * No bench sees it. pts_assoc_tb and pts_chain_tb drive pts_in directly, and
#     there is no emu-level bench.
#   * The telemetry could not see it either, because every A/V instrument
#     referenced the clock to itself.
#
# But the NETLIST said so plainly, in one line: a 33-bit PTS register whose bits
# were all "Merged with" bit 0. Registers only merge when their inputs are
# provably identical, so a wide data register collapsing to one bit means it is
# carrying a constant. That is the check.
#
# Deliberately NOT a scan of the "Stuck at GND/VCC" table: that table has hundreds
# of legitimate entries (tied-off options, unused generics) and a wholesale grep
# would be noise a reader learns to ignore. This is an allowlist of registers that
# are load-bearing for a DATA PATH, in the spirit of the clk_dec Fmax gate and the
# dead-stripped dsi_tbl lesson (nav_dsi fitting in 16 ALMs / 0 memory bits).
#
# Add a row when a new wide register must carry live data end to end. Keep it
# short: a canary list that grows into a checklist stops being read.
set -u
RPT=${1:-output_files/DVD.map.rpt}
[ -f "$RPT" ] || { echo "netlist_canary: no map report at $RPT"; exit 2; }

# name-in-report                            what it means if it collapsed
CANARIES=(
  "pts_assoc:pts_assoc|tag_pts|the picture PTS tag is constant -- no video PTS reaches the decoder"
  "pts_assoc:pts_assoc|head_pts|the PTS association queue head is constant -- ps_demux PTS never crosses to clk_dec"
)

fail=0
for row in "${CANARIES[@]}"; do
  inst=${row%%|*}; rest=${row#*|}; reg=${rest%%|*}; why=${rest#*|}
  # "Merged with ...|<reg>[0]" on a bit of the same register = constant-folded.
  if grep -q "${inst}|${reg}\[[0-9]" "$RPT" && \
     grep "${inst}|${reg}\[" "$RPT" | grep -q "Merged with .*${reg}\[0\]"; then
    echo "netlist_canary: FAIL ${inst}|${reg} -- ${why}"
    fail=1
  fi
done

[ $fail -eq 0 ] && echo "netlist_canary: PASS (${#CANARIES[@]} data paths carry live values)"
exit $fail
