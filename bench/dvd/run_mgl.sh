#!/usr/bin/env bash
#
# run_mgl.sh — the issue #48 gate ("MGL loading not working").
#
# Two core-side defects that an MGL launch exposes, both of which end in a picture
# that never recovers:
#
#   iso_reader_mount_tb   an empty/failed mount must stop the reader, not send it
#                         walking LBA 0,1,2,... of an empty slot for ever
#   ps_demux_esrecover_tb the raw-elementary-stream verdict must not be a one-way
#                         door: a flush that lands mid-PES must re-sync on the next
#                         pack instead of shoving PES/audio/nav at the video decoder
#
# The Main-side half of the fix (the InfoMessage-during-MGL freeze) is not
# simulatable here -- it lives in main/support/dvd/dvd_launch.cpp and is gated on
# hardware. Design: docs/mgl_launch.md.
#
# Default: the GREEN suite; everything must pass.
#
# --red: there is no plusarg model for these -- the pre-fix behaviour is three
# reverted RTL lines, and modelling it in the bench would just restate the RTL. The
# measured RED numbers are recorded in each bench's header, and reproducing them
# means reverting those lines by hand. Both benches measure a property of what the
# hardware DOES (requests issued, bytes demuxed onto which port), not a signal the
# fix names, so neither can become a golden model that agrees with its own RTL.
#
set -e
cd "$(dirname "$0")/../.."

echo "### build"
iverilog -g2012 -o bench/dvd/iso_reader_mount_sim \
  dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv bench/dvd/iso_reader_mount_tb.sv
iverilog -g2012 -o bench/dvd/ps_demux_esrecover_sim \
  dvd/ps_demux.sv bench/dvd/ps_demux_esrecover_tb.sv

echo
echo "### 1. mount: empty image, re-mount, mount-over-in-flight-read"
vvp bench/dvd/iso_reader_mount_sim

echo
echo "### 2. ps_demux: raw-ES verdict must be escapable"
vvp bench/dvd/ps_demux_esrecover_sim

echo
echo "### run_mgl.sh: ALL GREEN"
