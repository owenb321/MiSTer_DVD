#!/usr/bin/env bash
# run_player_regs.sh -- the player parameters SPRM14/15/20 (feature/player-regs,
# docs/dvd_vm.md "Player parameters SPRM14/15/20").
#
#   bench/dvd/run_player_regs.sh          GREEN: the mapping, the VM's reads, the
#                                         reader's region mask, the emu seam
#   bench/dvd/run_player_regs.sh --red    + one mutation per claim, each caught by
#                                         the arm written for it
#
# Four layers, because each bench is handed its inputs:
#   player_regs_tb       the mapping (mask -> SPRM20, output path x Analog Aspect ->
#                        SPRM14, Passthru/codebooks -> SPRM15)
#   dvd_vm_tb [S26]      the VM reads its cfg ports live (a region-check block)
#   iso_reader_vm_tb     T1: the disc's mask is held when First Play loads, and its
#                        PRE reads SPRM20 through player_regs; T10: a remount clears it
#   check_player_regs_wiring.py   emu.sv, which has no bench
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
pass()   { echo "  ok   $*"; }
failed() { echo "  FAIL $*"; rc=1; }

# $1 out, $2 player_regs.sv, $3 dvd_vm.sv, $4 dvd_iso_reader.sv, $5 bench
iv() { iverilog -g2012 -I rtl/mpeg2 -I dvd -o "$1" "$2" "$3" "$4" dvd/bcd_time_add.sv "$5" > "$1.log" 2>&1; }
PR=dvd/player_regs.sv; VM=dvd/dvd_vm.sv; RD=dvd/dvd_iso_reader.sv

# run every bench against the given sources; $1 label prefix, $2 pr, $3 vm, $4 rd
run_all() {
    local out=""
    for b in player_regs_tb dvd_vm_tb iso_reader_vm_tb; do
        if ! iv "$TMP/$1_$b" "$2" "$3" "$4" "bench/dvd/$b.sv"; then
            echo "COMPILE-FAIL $b"; head -3 "$TMP/$1_$b.log"; continue
        fi
        timeout 900 vvp "$TMP/$1_$b" > "$TMP/$1_$b.out" 2>&1
        cat "$TMP/$1_$b.out"
    done
}

echo "== GREEN"
run_all g $PR $VM $RD > "$TMP/green.out"
for spec in "player_regs_tb|RESULT: PASS (player_regs)" "dvd_vm_tb|ALL TESTS PASS (dvd_vm_tb)" \
            "iso_reader_vm_tb|ISO_READER_VM_TB: ALL TESTS PASSED"; do
    b=${spec%%|*}; m=${spec#*|}
    if grep -qF "$m" "$TMP/green.out"; then pass "$b"; else failed "$b"; grep -E "FAIL|COMPILE" "$TMP/g_$b.out" "$TMP/g_$b.log" 2>/dev/null | head -5; fi
done
for a in "\[P1\] OK" "\[P2\] OK" "\[P3\] OK" "\[P4\] OK" "S26 player parameters" "T10 remount"; do
    grep -q "$a" "$TMP/green.out" || failed "arm marker missing: $a"
done
if python3 tools/check_player_regs_wiring.py > "$TMP/c.out" 2>&1; then pass "$(cat "$TMP/c.out")"
else failed "check_player_regs_wiring.py"; cat "$TMP/c.out"; fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_player_regs: ALL GREEN" || echo "run_player_regs: FAILURES"
    exit $rc
fi

echo "== RED (each mutation must be caught by its own arm)"
# $1 label, $2 which file (pr|vm|rd), $3 sed expr, $4 expected FAIL text
mutate() {
    local src dst p=$PR v=$VM r=$RD
    case "$2" in pr) src=$PR;; vm) src=$VM;; rd) src=$RD;; esac
    dst="$TMP/$1.sv"
    sed "$3" "$src" > "$dst"
    if cmp -s "$src" "$dst"; then failed "$1: the mutation did not apply (anchor moved)"; return; fi
    case "$2" in pr) p=$dst;; vm) v=$dst;; rd) r=$dst;; esac
    run_all "$1" "$p" "$v" "$r" > "$TMP/$1.all"
    if grep -q "COMPILE-FAIL" "$TMP/$1.all"; then failed "$1: mutant did not compile"; grep -A2 COMPILE "$TMP/$1.all" | head -3; return; fi
    if grep -qF -e "$4" "$TMP/$1.all"; then pass "$1 -> caught by \"$4\""
    else failed "$1: not caught by \"$4\""; grep -E "FAIL" "$TMP/$1.all" | head -3; fi
}
# SPRM20: bit n SET = region n+1 PROHIBITED; read the sense the other way round
mutate R1-mask-sense pr 's/if (!rmask\[r\]) sprm20/if (rmask[r]) sprm20/' "FAIL [P1]"
# SPRM14: Crop and Letterbox swapped
mutate R2-crop-letterbox pr "s/2'd3:                  sprm14 = 16'h0100;/2'd2:                  sprm14 = 16'h0100;/" "FAIL [P2]"
# SPRM15: DTS claimed only when the codebooks loaded, forgetting Passthru
mutate R3-dts-no-pass pr 's/(pass_mode | dts_ok)/(dts_ok)/' "FAIL [P3]"
# the VM still answers the old constant
mutate R4-vm-constant vm "s/5'd20: in_data = cfg_sprm20;/5'd20: in_data = 16'h0001;/" "FAIL: S26"
# the reader captures the wrong byte of vmg_category
mutate R5-wrong-byte rd 's/vmg_rmask  <= rbuf\[3\];/vmg_rmask  <= rbuf[2];/' "FAIL: T1: vmg_rmask"
# a remount keeps the previous disc's mask
mutate R6-no-remount-clear rd "s|vmg_rmask  <= 8'h00;           // a new disc|;                              // a new disc|" "FAIL: T10: vmg_rmask not cleared"

echo "== RED: the emu seam"
if python3 tools/check_player_regs_wiring.py --red > "$TMP/r.out" 2>&1; then sed 's/^/  /' "$TMP/r.out"
else failed "check_player_regs_wiring.py --red"; cat "$TMP/r.out"; fi
# (A "RED on main's emu.sv" arm stood here. It went green the moment PR #154 merged --
# main then WAS the feature -- and failed every --red run after that. It was removed in
# feature/progressive-aspect: RED-on-main is shown once, by hand, in docs/status_log.md;
# the mutations above carry the same proof permanently.)

[ $rc -eq 0 ] && echo "run_player_regs: ALL GREEN" || echo "run_player_regs: FAILURES"
exit $rc
