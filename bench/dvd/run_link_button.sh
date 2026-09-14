#!/usr/bin/env bash
# Gate for "a link's button field must survive the flush the link fires"
# (Scooby-Doo 2 Wickles Manor grid, 2026-09-14; docs/dvd_nav.md "Link button
# fields across a flush").
#
# The defect lived at the dvd_vm -> nav_pci seam: the VM pulses btn_force with a
# link's button number in the same cycle as the seek that link fires, the seek's
# load_flush resets nav_pci (pipe_rst_n), and the stored button went back to 1.
# libdvdnav keeps HL_BTNN_REG in the VM and never clears it on a jump. The fix
# exports the VM's SPRM8 button (dvd_vm.hl_btnn) and nav_pci re-seeds from it
# when its reset releases.
#
# Three arms, one per place the fix lives:
#   nav_pci_tb   T19  the consumer: sel_force -> reset -> real Scooby grid HLI
#                     (21 buttons, fosl=0) must arm on the link's button
#   dvd_vm_tb    T6   the producer: LinkCN 26 (button 16) exports 16; a select
#                     is remembered after the HLI tears down; a frozen (activated)
#                     SPRM8 is not overwritten by btn_sel drift
#   check_hl_btnn_wiring.py   the seam: emu.sv connects the two ports to ONE net
#                     (emu has no bench; a wrong value on a correct port is
#                     invisible to both module benches)
#
# --red additionally applies one targeted mutation per claim and requires the
# arm that owns the claim -- and only that arm -- to fail:
#   M1  nav_pci: seed deleted                         -> nav_pci_tb T19a/T19b
#   M2  dvd_vm : select write-back deleted            -> dvd_vm_tb T6b
#   M3  dvd_vm : hl_btnn exported as a constant 0     -> dvd_vm_tb T6a/b/c
#   M4  dvd_vm : write-back ignores sprm8_frozen      -> dvd_vm_tb T6c
#   W1  emu.sv : nav_pci .hl_btnn tied to 6'd0        -> wiring check
#   W2  emu.sv : nav_pci .hl_btnn connection dropped  -> wiring check
#
#   bench/dvd/run_link_button.sh          # GREEN arms
#   bench/dvd/run_link_button.sh --red    # GREEN + the mutation arms
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

pass() { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; rc=1; }

run_nav() {   # $1 = nav_pci.sv to use, $2 = label; echoes the T19 verdict lines
    iverilog -g2012 -o "$TMP/nav_$2" "$1" bench/dvd/nav_pci_tb.sv > "$TMP/nav_$2.log" 2>&1 \
        || { echo "  compile failed ($2)"; cat "$TMP/nav_$2.log" | head; return 2; }
    vvp "$TMP/nav_$2" > "$TMP/nav_$2.out" 2>&1
    grep -q "NAV_PCI_TB: ALL TESTS PASSED$" "$TMP/nav_$2.out"
}
run_vm() {    # $1 = dvd_vm.sv to use, $2 = label
    iverilog -g2012 -o "$TMP/vm_$2" "$1" bench/dvd/dvd_vm_tb.sv > "$TMP/vm_$2.log" 2>&1 \
        || { echo "  compile failed ($2)"; cat "$TMP/vm_$2.log" | head; return 2; }
    vvp "$TMP/vm_$2" > "$TMP/vm_$2.out" 2>&1
    grep -q "ALL TESTS PASS (dvd_vm_tb)" "$TMP/vm_$2.out"
}

echo "== GREEN"
if run_nav dvd/nav_pci.sv green; then pass "nav_pci_tb (T19 = the Scooby grid across the flush)"; else failed "nav_pci_tb"; grep -i "ERR\|FAIL" "$TMP/nav_green.out"; fi
grep -q "T19a: armed=1 btn_ns=21 sel=16" "$TMP/nav_green.out" && pass "T19a measured: 21-button grid armed on button 16" || failed "T19a did not arm the real grid fixture (fixture missing?)"
if run_vm dvd/dvd_vm.sv green; then pass "dvd_vm_tb (T6 = HL_BTNN export)"; else failed "dvd_vm_tb"; grep -i "FAIL" "$TMP/vm_green.out"; fi
if python3 tools/check_hl_btnn_wiring.py > "$TMP/wire.out" 2>&1; then pass "check_hl_btnn_wiring.py: $(cat "$TMP/wire.out")"; else failed "check_hl_btnn_wiring.py"; cat "$TMP/wire.out"; fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED (each mutation must be caught by its own arm)"
    # A mutation that does not change the file is a bench that cannot fail.
    mut() { sed "$2" "$1" > "$3"; if cmp -s "$1" "$3"; then echo "  mutation did not apply: $2"; rc=1; return 1; fi; }

    mut dvd/nav_pci.sv 's/if (hl_btnn != 6.d0) btn_sel <= hl_btnn;/\/\/ M1: no seed/' "$TMP/M1.sv" && {
        run_nav "$TMP/M1.sv" M1; r=$?
        if [ $r -eq 1 ] && grep -q "ERR T19a the link" "$TMP/nav_M1.out"; then pass "M1 nav_pci seed deleted -> T19a red"; else failed "M1 not caught"; fi; }

    mut dvd/dvd_vm.sv 's/if (btns_armed && !sprm8_frozen) sprm8 <= {btn_sel, 10.d0};/\/\/ M2: no write-back/' "$TMP/M2.sv" && {
        run_vm "$TMP/M2.sv" M2; r=$?
        if [ $r -eq 1 ] && grep -q "T6b" "$TMP/vm_M2.out" && ! grep -q "T6a\|T6c" "$TMP/vm_M2.out"; then pass "M2 select write-back deleted -> T6b red (T6a/T6c green)"; else failed "M2 not caught by exactly T6b"; grep FAIL "$TMP/vm_M2.out"; fi; }

    mut dvd/dvd_vm.sv 's/assign hl_btnn = sprm8\[15:10\];/assign hl_btnn = 6'"'"'d0; \/\/ M3/' "$TMP/M3.sv" && {
        run_vm "$TMP/M3.sv" M3; r=$?
        if [ $r -eq 1 ] && grep -q "T6a" "$TMP/vm_M3.out"; then pass "M3 hl_btnn tied to 0 -> T6a red"; else failed "M3 not caught"; fi; }

    mut dvd/dvd_vm.sv 's/if (btns_armed && !sprm8_frozen) sprm8 <= {btn_sel, 10.d0};/if (btns_armed) sprm8 <= {btn_sel, 10'"'"'d0}; \/\/ M4/' "$TMP/M4.sv" && {
        run_vm "$TMP/M4.sv" M4; r=$?
        if [ $r -eq 1 ] && grep -q "T6c" "$TMP/vm_M4.out" && ! grep -q "FAIL: T6a\|FAIL: T6b" "$TMP/vm_M4.out"; then pass "M4 frozen guard dropped -> T6c red (T6a/T6b green)"; else failed "M4 not caught by exactly T6c"; grep FAIL "$TMP/vm_M4.out"; fi; }

    mut dvd/emu.sv "s/\.hl_btnn    (vm_hl_btnn),/.hl_btnn    (6'd0),/" "$TMP/W1.sv" && {
        if ! python3 tools/check_hl_btnn_wiring.py "$TMP/W1.sv" > /dev/null 2>&1; then pass "W1 nav_pci .hl_btnn tied to 6'd0 -> wiring check red"; else failed "W1 not caught"; fi; }
    grep -v '^    \.hl_btnn    (vm_hl_btnn),' dvd/emu.sv > "$TMP/W2.sv"
    if ! cmp -s dvd/emu.sv "$TMP/W2.sv" && ! python3 tools/check_hl_btnn_wiring.py "$TMP/W2.sv" > /dev/null 2>&1; then pass "W2 nav_pci .hl_btnn dropped -> wiring check red"; else failed "W2 not caught"; fi
fi

if [ $rc -eq 0 ]; then echo "run_link_button: ALL GREEN"; else echo "run_link_button: FAILED"; fi
exit $rc
