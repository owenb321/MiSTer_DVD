#!/usr/bin/env bash
#
# run_menudrain.sh -- a NATURAL MENU verdict must execute on a DELIVERED stream.
#                     bench/dvd/iso_reader_menudrain_tb.sv,
#                     docs/dvd_menu_refinements.md
#
# GREEN: the suite, plus the reader benches whose behaviour this must not move.
# --red: five targeted mutations of dvd/dvd_iso_reader.sv, each of which must be
#        caught by EXACTLY the arms it was designed to break. A mutation caught
#        by everything says nothing about which arm is load-bearing, so the
#        runner fails on an unexpected arm as loudly as on a missing one.
#
#   M1  restore the menu exemption on the JUMP latch  -> [A] (and [C])
#   M2  restore the menu exemption on the SEEK latch  -> [G] only
#   M3  drop ~cache_has_data from nat_quiet           -> [A] only
#   M4  drop the settle (nat_drained = nat_quiet)     -> [G] only
#   M5  stop streaming in S_VM_WAIT                   -> [A], [C] and [G]
#
# ⚠ M3 is only visible because arm [A] runs with vbuf_empty=1 THROUGHOUT and
# with a LONG-period sink stall: if the arm let the decoder's low-water mark
# gate as well, a reader waiting on vbuf_empty alone would pass it, and with a
# short stall "the pipe is quiet" and "there is nothing left to send" are never
# distinguishable, so dropping the cache term is invisible (measured: caught by
# nothing until the arm had both properties). That is the shape of the arm.
#
#   ./bench/dvd/run_menudrain.sh         # green arms
#   ./bench/dvd/run_menudrain.sh --red   # + the mutations
set -euo pipefail
cd "$(dirname "$0")/../.."

IV="iverilog -g2012"
SRC="dvd/dvd_vm.sv dvd/bcd_time_add.sv dvd/ps_stream_fifo.sv dvd/ps_demux.sv \
     dvd/flush_ctl.sv"
TB=bench/dvd/iso_reader_menudrain_tb.sv
rc=0

echo "== menudrain: the fixed reader =="
$IV -o bench/dvd/menudrain_sim dvd/dvd_iso_reader.sv $SRC $TB
out=$(vvp bench/dvd/menudrain_sim 2>&1) || true
echo "$out" | grep -E '^(   \[|FAIL|RESULT|menudrain:)' || true
echo "$out" | grep -q '^RESULT: PASS' || { echo "  FAIL: the suite is not green"; rc=1; }

# The Phase-B title-domain contract must be untouched: same gate, same bench.
echo "== menudrain: iso_reader_vm_tb (title-domain Phase B) must be unchanged =="
$IV -o bench/dvd/menudrain_vm_sim dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
    dvd/bcd_time_add.sv bench/dvd/iso_reader_vm_tb.sv 2>/dev/null
vout=$(vvp bench/dvd/menudrain_vm_sim 2>&1) || true
echo "$vout" | grep -E '^T[0-9]' || true
echo "$vout" | grep -qE 'FAIL|ERROR' && { echo "  FAIL: vm_tb regressed"; rc=1; } || true

if [ "${1:-}" = "--red" ]; then
  MUT=$(mktemp -d)
  # mutate <n> <label> <sed expr> <grep proof> <expected failing arms...>
  red () {
    local n="$1" label="$2" expr="$3" proof="$4"; shift 4
    local want="$*"
    sed "$expr" dvd/dvd_iso_reader.sv > "$MUT/dvd_iso_reader.sv"
    if ! grep -qF "$proof" "$MUT/dvd_iso_reader.sv"; then
      echo "  FAIL: $n did not apply -- dvd_iso_reader.sv moved"; rc=1; return
    fi
    if ! $IV -o "$MUT/sim" "$MUT/dvd_iso_reader.sv" $SRC $TB 2>/dev/null; then
      echo "  FAIL: $n did not compile"; rc=1; return
    fi
    local o got
    o=$(vvp "$MUT/sim" 2>&1) || true
    # ⚠ `|| true`: a mutation caught by NOTHING makes every grep in this chain
    # exit 1, and under `set -eo pipefail` that kills the runner before it can
    # report the most interesting result of all - "this mutation is invisible".
    got=$(echo "$o" | grep -oE '^FAIL: \[[A-G]\]' | grep -oE '\[[A-G]\]' \
          | sort -u | tr -d '[]' | tr -d '\n' || true)
    echo "   $n $label: failing arms [${got:-none}], expected [$want]"
    if [ "$got" != "$want" ]; then
      echo "  FAIL: $n was caught by the wrong arms"; rc=1
    fi
  }

  echo "== RED: each mutation must be caught by exactly its own arms =="
  red M1 "menu exemption back on the jump latch" \
      's/jnat_l   <= jump_natural;/jnat_l   <= jump_natural \&\& ~menu_dom;/' \
      'jnat_l   <= jump_natural && ~menu_dom;' AC
  red M2 "menu exemption back on the seek latch" \
      's/snat_l       <= seek_natural;/snat_l       <= seek_natural \&\& ~menu_dom;/' \
      'snat_l       <= seek_natural && ~menu_dom;' G
  red M3 "nat_quiet ignores the reader cache" \
      's/wire       nat_quiet = vbuf_empty \&\& ~cache_has_data \&\& ~blk_inflight \&\&/wire       nat_quiet = vbuf_empty \&\& ~blk_inflight \&\&/' \
      'wire       nat_quiet = vbuf_empty && ~blk_inflight &&' A
  red M4 "no settle window" \
      's/wire       nat_drained   = nat_quiet \&\& (\&nat_settle);/wire       nat_drained   = nat_quiet;/' \
      'wire       nat_drained   = nat_quiet;' G
  red M5 "S_VM_WAIT does not stream" \
      's/wire streaming = (state == S_STREAM) || (state == S_VM_WAIT);/wire streaming = (state == S_STREAM);/' \
      'wire streaming = (state == S_STREAM);' ACG
fi

[ "$rc" -eq 0 ] && echo "== menudrain: OK ==" || echo "== menudrain: FAIL =="
exit $rc
