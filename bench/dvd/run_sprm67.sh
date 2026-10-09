#!/usr/bin/env bash
# run_sprm67.sh -- SPRM6/SPRM7 follow a title as it plays, and First Play with no First
# Play PGC: the two core differences of the 2026-10-08 library sweep
# (docs/nav_engine.md 5a).
#
#   bench/dvd/run_sprm67.sh          GREEN: the VM, the reader, the emu seam
#   bench/dvd/run_sprm67.sh --red    + one reader mutation per claim, each caught by the
#                                    arm written for it (the VM's wrapper arms are
#                                    run_vm_ab.sh --red W5-W7)
#
# Layers, because each bench is handed its inputs:
#   dvd_vm_tb [S28]           the VM: SPRM6 on a title load, SPRM7 from the reader,
#                             held through the PRE, title-only
#   iso_reader_ptt_tb         the reader publishes the GLOBAL part on every chapter move
#   iso_reader_fpnone_tb      A/B/F First Play with no FP PGC; C/D/E which title's table
#                             a PGCN-only title jump reads; G/H an indefinite still and
#                             its cell command (hold first unless the command loops)
#   check_sprm67_wiring.py    emu.sv, which has no bench
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
pass()   { echo "  ok   $*"; }
failed() { echo "  FAIL $*"; rc=1; }

# $1 out, $2 reader source, $3 bench
ivr() { iverilog -g2012 -y dvd -Y .sv -o "$1" "$2" "$3" > "$1.log" 2>&1; }
ivv() { iverilog -g2012 -Y .sv -Y .v -y dvd -I dvd -I bench/dvd -o "$1" bench/dvd/dvd_vm_tb.sv > "$1.log" 2>&1; }

echo "== GREEN"
if python3 tools/nav_isa.py --asm --check > "$TMP/asm.out" 2>&1; then pass "nav_isa --check"
else failed "nav_isa --check"; tail -2 "$TMP/asm.out"; fi
if ivv "$TMP/vm" && timeout 900 vvp "$TMP/vm" > "$TMP/vm.out" 2>&1 &&
   grep -q "S28 SPRM6/7 follow a title as it plays PASS" "$TMP/vm.out" &&
   grep -q "ALL TESTS PASS (dvd_vm_tb)" "$TMP/vm.out"; then pass "dvd_vm_tb (S28)"
else failed "dvd_vm_tb"; grep -E "^FAIL|ERRORS" "$TMP/vm.out" "$TMP/vm.log" 2>/dev/null | head -5; fi
for spec in "iso_reader_ptt_tb|ISO_READER_PTT_TB: ALL TESTS PASSED" \
            "iso_reader_fpnone_tb|ISO_READER_FPNONE_TB: ALL TESTS PASSED"; do
    b=${spec%%|*}; m=${spec#*|}
    if ivr "$TMP/$b" dvd/dvd_iso_reader.sv "bench/dvd/$b.sv" &&
       timeout 900 vvp "$TMP/$b" > "$TMP/$b.out" 2>&1 && grep -qF "$m" "$TMP/$b.out"; then pass "$b"
    else failed "$b"; grep -E "FAIL|TIMEOUT" "$TMP/$b.out" "$TMP/$b.log" 2>/dev/null | head -5; fi
done
if python3 tools/check_sprm67_wiring.py > "$TMP/w.out"; then pass "check_sprm67_wiring"
else failed "check_sprm67_wiring"; cat "$TMP/w.out"; fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED: reader mutations (a copy each; the tree is never edited)"
    if python3 tools/check_sprm67_wiring.py --red > "$TMP/wr.out"; then pass "check_sprm67_wiring --red"
    else failed "check_sprm67_wiring --red"; grep FAIL "$TMP/wr.out"; fi
    # $1 label, $2 bench, $3 the arm that must fail, $4 sed expression on the reader
    mut() {
        local src="$TMP/rd_$1.sv"
        sed "$4" dvd/dvd_iso_reader.sv > "$src"
        if cmp -s dvd/dvd_iso_reader.sv "$src"; then failed "$1: the mutation did not apply (anchor moved)"; return; fi
        if ! ivr "$TMP/m_$1" "$src" "bench/dvd/$2.sv"; then failed "$1: does not compile"; head -3 "$TMP/m_$1.log"; return; fi
        timeout 900 vvp "$TMP/m_$1" > "$TMP/m_$1.out" 2>&1
        if grep -q "^FAIL.*$3\|FAIL $3" "$TMP/m_$1.out"; then
            pass "$1 -> $(grep -m1 "FAIL" "$TMP/m_$1.out")"
        else failed "$1: arm $3 did not fail"; grep -E "FAIL|PASS" "$TMP/m_$1.out" | head -8; fi
    }
    # no reroute: First Play with no FP PGC errors (the old behaviour)
    mut R1-no-reroute iso_reader_fpnone_tb "A:" \
        "s/                if (dom == DOM_FP \&\& vts_pgcit_ptr == 32'd0) begin/                if (1'b0) begin/"
    # the reroute ignores the jump's PGCN: a First Play LinkPGCN 3 loops to PGC 1
    mut R2-reroute-pgcn1 iso_reader_fpnone_tb "B:" \
        "s/                    want_pgcn     <= (jpgcn_l != 16'd0) ? jpgcn_l : 16'd1;/                    want_pgcn     <= 16'd1;/"
    # First Play is not a menu to keep_vbuf / jump_cross
    mut R3-fp-not-menu iso_reader_fpnone_tb "B:" \
        "s/                             (jdom_l == DOM_FP \&\& fp_none));/                             1'b0);/"
    # no owner reload: a PGCN-only title jump keeps title 1's table
    mut R4-no-ttn-pick iso_reader_fpnone_tb "C:" \
        "s/                    ttn_pick    <= (jttn_l == 7'd0);    \/\/ no title named: find its owner/                    ttn_pick    <= 1'b0;/"
    # the owner reload ignores title 1's table naming the PGC
    mut R5-pick-ignores-hit iso_reader_fpnone_tb "D:" \
        "s/                             (ttn_pick \&\& !ptt_hit \&\& srp_entry_id/                             (ttn_pick \&\& srp_entry_id/"
    # SPRM7 published on a miss (as 0 + 1)
    mut R6-publish-miss iso_reader_fpnone_tb "E:" \
        "s/                    ptt_upd <= g_found;/                    ptt_upd <= 1'b1;/"
    # the part off by one (the 0-based index)
    mut R7-part-0based iso_reader_ptt_tb "T-I" \
        "s/                    ptt_cur <= {1'b0, g_best} + 11'd1;/                    ptt_cur <= {1'b0, g_best};/"
    # every cell command counts as a loop: the old command-first order everywhere
    mut R8-all-loop iso_reader_fpnone_tb "G:" \
        "s/^wire        cc_loops   = (ccls_q\[20\] \&\& ((cc_lt == 4'd1 \&\& cc_subloop) ||/wire        cc_loops   = 1'b1 || (ccls_q[20] \&\& ((cc_lt == 4'd1 \&\& cc_subloop) ||/"
    # no command counts as a loop: a motion menu would freeze
    mut R9-none-loop iso_reader_fpnone_tb "H:" \
        "s/^wire        cc_loops   = (ccls_q\[20\] \&\& ((cc_lt == 4'd1 \&\& cc_subloop) ||/wire        cc_loops   = 1'b0 \&\& (ccls_q[20] \&\& ((cc_lt == 4'd1 \&\& cc_subloop) ||/"
    # types 2/3 decoded as LinkSubIns-only (the first version's mistake)
    mut R11-type3-subins iso_reader_fpnone_tb "B2:" \
        "s/                                    cmd_b0\[7:5\] == 3'd2 || cmd_b0\[7:5\] == 3'd3,/                                    1'b0,/"
    # the class table written one entry off (cmd_nr is 1-based)
    mut R10-class-off-by-one iso_reader_fpnone_tb "[GH]:" \
        "s/                        ccls_wa <= walk_idx\[10:3\] - nr_pre16\[7:0\] - nr_post16\[7:0\] + 8'd1;/                        ccls_wa <= walk_idx[10:3] - nr_pre16[7:0] - nr_post16[7:0];/"
fi

[ $rc -eq 0 ] && echo "run_sprm67: ALL GREEN" || echo "run_sprm67: FAILURES"
exit $rc
