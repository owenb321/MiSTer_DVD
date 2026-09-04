#!/usr/bin/env bash
# run_kbd.sh — keyboard / TV-remote transport control (issue #35) suite.
#
# Why each suite is here:
#
#   1. kbd_map_tb     — the decoder itself. The three contracts that matter are
#                       (a) EVERY bit is a one-cycle pulse, including [14:13]
#                       which emu.sv feeds to dpad_seek (a held request would
#                       hold the coalesce window open forever); (b) the E0 bit
#                       DISCRIMINATES, because six of our scancodes are
#                       bit-identical to numpad digits; (c) no digit produces
#                       output at all. Mutation-checked: five targeted RTL
#                       mutations (level-not-pulse, numpad-8 leak, fire-on-break,
#                       digit leak, Esc unbound) are each caught.
#   2. dpad_seek_tb   — where the keyboard's Fast Fwd/Rewind keys actually land.
#                       T19a replays a SuperDock IR long-press (9 taps a second,
#                       measured from Retro Remake's DockIR firmware) and proves
#                       it resolves to ONE seek; T19b proves the window still
#                       closes, so coalescing cannot swallow a deliberate second
#                       press. T0-T18 unchanged = the shipped D-Pad Seek gate.
#   3. nav_pci_tb     — T10 is the numpad digit -> menu button path. emu.sv's
#                       digit block and kbd_map now share the set-2 scancode
#                       space, so this is the guard that the two stay disjoint.
#   4. scrub_ctrl_tb  — must pass COMPLETELY UNCHANGED. That is the gate proving
#                       the gamepad's hold-to-scrub was not touched: this feature
#                       deliberately modifies neither scrub_ctrl.sv nor
#                       dpad_seek.sv, only what drives their inputs.
#   5. transport_hud_tb / seek_bar_tb — the HUD readout and position bar a
#                       keyboard-initiated seek now pops, unregressed.
#
# ⚠ NOT covered by any bench, by construction: emu.sv's joy_eff substitution and
# the `joy_prev <= joy_eff` line. There is no emu-level testbench, so those are
# review-only plus Quartus elaboration. Diff that region deliberately.

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

run kbd_map_tb       dvd/kbd_map.sv
run dpad_seek_tb     dvd/dpad_seek.sv dvd/nav_dsi.sv
run nav_pci_tb       dvd/nav_pci.sv
run scrub_ctrl_tb    dvd/scrub_ctrl.sv
run transport_hud_tb dvd/transport_hud.sv
run seek_bar_tb      dvd/seek_bar.sv

if [ $rc -eq 0 ]; then echo "RUN_KBD: ALL SUITES PASSED"; else echo "RUN_KBD: FAILURES"; fi
exit $rc
