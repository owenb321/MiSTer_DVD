#!/usr/bin/env bash
# run_vm_snap.sh -- the VM state snapshot (dvd/vm_snap.sv + dvd_vm's E_SNAP;
# docs/nav_engine.md "State snapshot"). Save states, step 2.
#
#   GREEN  bench/dvd/vm_snap_tb.sv: arms [absent] [empty] [req] [words] [nochange]
#          [pos] [reread] [busy] and the restore's [refuse] [load] [pending] all PASS --
#          the real microcode and vm_snap together
#          tools/check_vm_snap_wiring.py: the emu.sv / dvd_vm / nav_dsi / qsf /
#          dvd_ctl.cpp seams (emu.sv has no bench)
#   RED    (--red) every mutation of dvd/vm_snap.sv must fail EXACTLY the arms listed
#          beside it, and the wiring check must catch each wiring mutation.
#
# The microcode's own side -- a snapshot changes nothing the VM does, its words equal
# the Python model's, and its ;MUT / wrapper arms -- is bench/dvd/run_vm_ab.sh. The
# Main's side is main/tests/run_tests.sh (dvd_ctl_test [6]..[11], ctl-vs-* arms).
#
# vvp exits 0 on a bench that only prints FAIL, so the verdict is the bench's own
# PASS/FAIL lines plus its RESULT marker, never the exit code alone.
set -u
cd "$(dirname "$0")/../.."
fail=0
TB=bench/dvd/vm_snap_tb.sv
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# sim <vm_snap.sv> -> prints the sorted FAIL arm list ("-" when none), or BUILD/NOVERDICT
sim() {
    local dut=$1 log="$tmp/log"
    if ! iverilog -g2012 -I dvd -o "$tmp/sim" dvd/dvd_vm.sv "$dut" "$TB" > "$tmp/build" 2>&1; then
        echo BUILD; return; fi
    vvp "$tmp/sim" > "$log" 2>&1
    if ! grep -q "^RESULT: " "$log"; then echo NOVERDICT; return; fi
    local arms; arms=$(grep -oE '^FAIL \[[a-z]+\]' "$log" | sed 's/FAIL \[\(.*\)\]/\1/' | sort -u | tr '\n' ' ')
    echo "${arms:--}"
}

echo "== GREEN"
iverilog -g2012 -I dvd -o "$tmp/g" dvd/dvd_vm.sv dvd/vm_snap.sv "$TB" && vvp "$tmp/g" > "$tmp/glog" 2>&1
if grep -q "^RESULT: PASS" "$tmp/glog" && ! grep -q "^FAIL" "$tmp/glog"; then
    echo "  PASS vm_snap_tb"; grep "^PASS \[" "$tmp/glog" | sed 's/^/      /'
else
    echo "  FAIL vm_snap_tb"; tail -20 "$tmp/glog" | sed 's/^/      /'; fail=1
fi
if python3 tools/check_vm_snap_wiring.py > "$tmp/wlog" 2>&1; then
    echo "  PASS check_vm_snap_wiring"
else
    echo "  FAIL check_vm_snap_wiring"; grep FAIL "$tmp/wlog" | sed 's/^/      /'; fail=1
fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED (RTL: each must fail exactly its arms)"
    # mut <name> <expected arms, space separated> <old> <new> [<old2> <new2>]
    mut() {
        local name=$1 want=$2; shift 2
        python3 - "$tmp/m.sv" "$@" <<'PYEOF'
import sys
dst, *pairs = sys.argv[1:]
s = open('dvd/vm_snap.sv').read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if s.count(old) != 1:
        sys.exit(f'anchor count {s.count(old)} != 1: {old!r}')
    s = s.replace(old, new)
open(dst, 'w').write(s)
PYEOF
        if [ $? != 0 ]; then echo "  FAIL $name: mutation did not apply -- its arm is VOID"; fail=1; return; fi
        local got; got=$(sim "$tmp/m.sv"); got=$(echo "$got" | xargs)
        if [ "$got" = "$want" ]; then echo "  ok   $name -> [$got]"
        else echo "  FAIL $name: failed [$got], must fail exactly [$want]"; fail=1; fi
    }
    mut "S1 command decoded on its low byte"     "absent" \
        "active <= (io_din == CMD);" "active <= (io_din[7:0] == CMD[7:0]);"
    # S2 re-fires every cycle the request bit is held, so it also restarts the stream
    # over and over: the words, the re-read and the VM's rest are disturbed with it
    mut "S2 request fires mid-transaction"       "nochange req reread words" \
        "if (!io_enable && req_l && !rbusy) begin" "if (req_l && !rbusy) begin"
    mut "S3 len one short"                       "busy req words" \
        "len  <= {1'b0, wa};" "len  <= {1'b0, wa} - 8'd1;"
    mut "S4 seq never moves"                     "busy req" \
        "busy <= 1'b0; seq <= seq + 16'd1;" "busy <= 1'b0; seq <= seq;"
    mut "S5 has_video stuck at 1"                "pos" \
        "p_video <= |first_ref_ea;" "p_video <= 1'b1;"
    mut "S6 freshness survives a flush"          "pos" \
        "if (pos_clr)         fresh <= 1'b0;" "if (1'b0)            fresh <= 1'b0;"
    # S7 also corrupts the reference blob the restore arms read back
    mut "S7 no read-ahead restart"               "load refuse reread" \
        "begin dout_r <= {8'd0, p_cid}; raddr <= 7'd0; end" "begin dout_r <= {8'd0, p_cid}; end"
    mut "S8 a busy buffer streamed"              "busy" \
        "left   <= busy ? 8'd0 : len;" "left   <= len;"
    mut "S9 position latched live, not at done"  "pos" \
        "p_lbn <= nv_pck_lbn; p_prev <= prev_video;" "p_prev <= prev_video;" \
        "4'd5: dout_r <= p_lbn[31:16];" "4'd5: dout_r <= nv_pck_lbn[31:16] ^ 16'h0001;"
    mut "S10 words past len not zero"            "busy empty words" \
        "end else dout_r <= 16'd0;
                endcase" "end else dout_r <= q;
                endcase"
    # ---- the restore (save states step 3) ----
    # The restore arms share one VM in sequence: a blob wrongly ACCEPTED in [refuse] is
    # really applied, so the restore count [load] checks (and the state [pending] needs)
    # moves with it. Those extra arms are this mutation's own consequence.
    mut "S11 the checksum is never checked"      "load refuse" \
        "else if (h_acc != h_sum)        verdict <= 3'd5;" "else if (1'b0)                  verdict <= 3'd5;"
    mut "S12 a refused format still restores"    "load pending refuse" \
        "else if (h_fmt != snap_fmt)     verdict <= 3'd3;" "else if (h_fmt != snap_fmt)     begin verdict <= 3'd3; rbusy <= 1'b1; restore_req <= 1'b1; end"
    mut "S13 a load overwrites a pending blob"   "pending" \
        "if (bcnt >= 8'd5 && h_cnt < WORDS && !rbusy && !busy) begin" "if (bcnt >= 8'd5 && h_cnt < WORDS && !busy) begin"
    mut "S14 the VM reads the host's address"    "load" \
        "q <= buf_m[rbusy ? rst_ra : raddr];" "q <= buf_m[raddr];"
    mut "S15 applied restores not counted"       "load" \
        "rbusy <= 1'b0; verdict <= 3'd2; rcount <= rcount + 5'd1;" "rbusy <= 1'b0; verdict <= 3'd2; rcount <= rcount;"

    echo "== RED (wiring: the checker must catch each)"
    python3 tools/check_vm_snap_wiring.py --red || fail=1
fi

[ $fail = 0 ] && echo "run_vm_snap: ALL PASS" || { echo "run_vm_snap: FAILURES"; exit 1; }
