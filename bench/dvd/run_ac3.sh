#!/usr/bin/env bash
# run_ac3.sh -- the whole engine running AC-3 (dvd/dts/dts_top.sv with codec = 1,
# bench/dvd/ac3_top_tb.sv): every block imdct_512 is handed, against tools/ac3_golden.py's
# blocks -- the emulator's, checked there against tools/ac3_model.py and, for every
# unmodified stream, against dvd/ac3/'s own dump (bench/ac3/golden_main.cpp via
# tools/test_ac3_model.py goldens()). docs/ac3_engine.md A2c.
#
# GREEN: every coefficient of every channel, the LFE slot, and the block's side
# information, identical, at every IMDCT handshake; blocks / frames / refusals / overrun
# bits / bytes counted:
#   every stream of tools/test_ac3_model.py's set, 4 frames (a *refuse* window 5), with
#     X filled with junk first (+xjunk: what a DTS track leaves; every coefficient must
#     be written every block)
#   S1 noise 5.1 with input stalls        S2 the E_GROUP window (refused mid-AQ) with stalls
#   R1 E_EXP (--badexp)                   T1 truncation
#   B1 the gate's worst frame within BUDGET % of real time, imdct_512 in series
#
# --red [MUTS="V1 V2"]: mutations on a COPY of the RTL, each caught by its own arm.
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
GATE=${AC3_TEST_DIR:-$HOME/ac3-streams/gate}
GEN=.sim/ac3/top
mkdir -p "$GEN"
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTLS="dvd/dts/dts_seq.sv dvd/dts/dts_vec.sv dvd/dts/dts_top.sv"
TB=bench/dvd/ac3_top_tb.sv
JOBS=${JOBS:-$(nproc)}
BUDGET=${BUDGET:-60}

echo "== GREEN: the microcode and its tables are current =="
python3 tools/dts_isa.py --asm --check | sed 's/^/  /' || fail=1

shopt -s nullglob globstar
STREAMS=(tools/streams/*.ac3 bench/ac3/vectors/*.ac3 "$GATE"/**/*.ac3)
[ ${#STREAMS[@]} -eq 0 ] && { echo "FAIL: no AC-3 streams"; exit 1; }
TONE=tools/streams/tone_5p1_48k_192k.ac3
NOISE=tools/streams/noise_5p1_48k_640k.ac3
GROUP=$(ls "$GATE"/*refuse_unmodelled*.ac3 2>/dev/null | head -1)

echo "== GREEN: dvd/ac3's own dumps of every stream (the RTL golden) =="
python3 -c "
import sys; sys.path.insert(0, 'tools')
from test_ac3_model import goldens
goldens(sys.argv[1:], 12)" "${STREAMS[@]}" || { echo "  FAIL the RTL golden tap"; exit 1; }

# arm | stream | golden args | sim args
ARMS=()
for s in "${STREAMS[@]}"; do
  case "$s" in *refuse*) g="--frames 5";; *) g="--frames 4";; esac
  ARMS+=("$(basename "$s" .ac3)|$s|$g --rtl-gold .sim/ac3/gold|+xjunk")
done
ARMS+=("S1|$NOISE|--frames 3|+stall=20")
ARMS+=("S2|$GROUP|--frames 5|+stall=10 +xjunk")
ARMS+=("R1|$TONE|--frames 4 --badexp 1|")
ARMS+=("T1|$TONE|--frames 4 --truncate 1:200|")
ARMS+=("B1|$NOISE|--frames 6|+budget=$BUDGET")
declare -A STEM SIMARGS

echo "== GREEN: goldens (${#ARMS[@]} arms) =="
n=0
for a in "${ARMS[@]}"; do
  IFS='|' read -r name src gargs sargs <<<"$a"
  STEM[$name]=$GEN/$name; SIMARGS[$name]=$sargs
  if [ ! -f "$src" ]; then echo "  FAIL $name: no $src"; fail=1; STEM[$name]=; continue; fi
  # shellcheck disable=SC2086
  python3 tools/ac3_golden.py "$src" --out "${STEM[$name]}" $gargs > "${STEM[$name]}.glog" 2>&1 &
  n=$((n + 1)); [ $((n % JOBS)) -eq 0 ] && wait
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if ! grep -q "match the model" "${STEM[$name]}.glog"; then
    echo "  FAIL $name golden: $(tail -1 "${STEM[$name]}.glog")"; fail=1; STEM[$name]=
  fi
done

iverilog -g2012 -o .sim/dts/ac3_top_sim $RTLS $TB 2>&1 | grep -v "sorry" | grep . && { echo "  FAIL build"; exit 1; }
echo "== GREEN: the engine (codec = AC-3) =="
n=0
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  # shellcheck disable=SC2086
  vvp -n .sim/dts/ac3_top_sim +stem="${STEM[$name]}" ${SIMARGS[$name]} 2>&1 \
      | grep -v 'readmem\|Not enough' > "$GEN/$name.log" &
  n=$((n + 1)); [ $((n % JOBS)) -eq 0 ] && wait
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if grep -q "^PASS: ac3_top_tb" "$GEN/$name.log"; then
    echo "  PASS $name: $(grep '^ac3_top_tb:' "$GEN/$name.log" | sed 's/^ac3_top_tb: //')"
  else echo "  FAIL $name: $(grep -m1 FAIL "$GEN/$name.log")"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name arm file old new arm-pattern
    local name=$1 arm=$2 file=$3 old=$4 new=$5 pat=$6
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    if [ -z "${STEM[$arm]:-}" ]; then
      { echo "  $name: no golden for arm $arm"; echo MUTFAIL; } > "$RES/$name"; return
    fi
    local d; d=$(mktemp -d)
    mkdir -p "$d/dvd/dts" "$d/dvd/ac3" "$d/bench/dvd"
    cp dvd/dts/*.sv dvd/dts/*.svh dvd/dts/*.mem "$d/dvd/dts/"
    cp dvd/ac3/ac3_imdct_tables.svh "$d/dvd/ac3/"   # dts_vec includes it (the IMDCT, op 25)
    cp $TB "$d/bench/dvd/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTLS $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    (cd "$d" && timeout 900 vvp -n sim +stem="$ROOT/${STEM[$arm]}" ${SIMARGS[$arm]} 2>&1 \
        | grep -v 'readmem\|Not enough' > log)
    if grep -q "^PASS: ac3_top_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -qE "FAIL $pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 -E "FAIL $pat" "$d/log" | sed 's/.*FAIL/FAIL/' | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  V=dvd/dts/dts_vec.sv; Q=dvd/dts/dts_seq.sv; P=dvd/dts/dts_top.sv
  T=tone_5p1_48k_192k
  PH=$(basename "$(ls "$GATE"/*phsflg*.ac3 | head -1)" .ac3)
  DY=$(basename "$(ls "$GATE"/*dynrnge*.ac3 | head -1)" .ac3)
  # REMAT's stream: the first whose first 4 frames rematrix (the model's counter)
  RM=$(basename "$(python3 - "${STREAMS[@]}" <<'PYEOF'
import sys
sys.path.insert(0, 'tools')
import ac3_model as M
for p in sys.argv[1:]:
    d = M.Decoder()
    try:
        for k, (_, fr) in enumerate(M.frames(open(p, 'rb').read())):
            if k >= 4:
                break
            d.frame(fr)
    except M.Ac3Error:
        pass
    if d.stats.get('remat'):
        print(p)
        break
PYEOF
)" .ac3)
  # AQ
  mut V1 $T $V "rsh = i_b0 ? 6'd0 : {1'b0, i_e}; trunc = 1'b1;" "rsh = i_b0 ? 6'd0 : {1'b0, i_e}; trunc = 1'b0;" "\[coef\]" &
  mut V2 $T $V "ma = lf27; mb = 27'sd23170; rsh = 6'd7 + {1'b0, c_e};" "ma = lf27; mb = 27'sd23170; rsh = 6'd7 + {1'b0, c_e}; trunc = 1'b1;" "\[coef\]" &
  mut V3 $T $V "ip_q[15:0] ^ {lfsr[7:0], 8'd0};" "ip_q[15:0] ^ {lfsr[15:8], 8'd0};" "\[coef\]" &
  # (the "0 past exponent 23" rule's own mutation, > 23 -> > 24, is EQUIVALENT: |ns x
  # 23170| < 2^30, so rounding at a shift of 31 gives 0 anyway. The rule is kept to match
  # the model's statement of it.)
  mut V4 $T $V "ma = lf27; mb = 27'sd23170; rsh = 6'd7 + {1'b0, c_e};" "ma = lf27; mb = 27'sd23170; rsh = 6'd6 + {1'b0, c_e};" "\[coef\]" &
  wait
  # AQC
  mut V5 $T $V "ma = creg27; mb = xb27; rsh = 6'd18;" "ma = creg27; mb = xb27; rsh = 6'd17;" "\[coef\]" &
  mut V6 $T $V "c_dm <= xq_code[4:0];" "c_dm <= 5'd0;" "\[coef\]" &
  mut V7 "$PH" $V "direct = 1'b1; dsrc = {{32{xq_code[23]}}, xq_code}; xb_we = 1'b1;" \
                  "direct = 1'b1; dsrc = {32'd0, xq_code}; xb_we = 1'b1;" "\[coef\]" &
  mut V8 $T $V "            V_CSC: begin creg <= res[23:0]; st <= V_CCH; end" \
               "            V_CSC: begin creg <= 24'd0; st <= V_CCH; end" "\[coef\]" &
  wait
  # CZERO, REMAT, IMDCT
  mut V9 $T $V "V_CZ: begin direct = 1'b1; xb_we = 1'b1;" "V_CZ: begin direct = 1'b1; xb_we = 1'b0;" "\[coef\]" &
  mut V10 $RM $V "dsrc = {{31{bf_a[24]}}, bf_a} - {{31{bf_c[24]}}, bf_c};
                        xb_we = 1'b1; xb_wa = {3'd1, rb};" "dsrc = {{31{bf_c[24]}}, bf_c} - {{31{bf_a[24]}}, bf_a};
                        xb_we = 1'b1; xb_wa = {3'd1, rb};" "\[coef\]" &
  # V11's stream: a block whose rematrix flags differ across the band edge at bin 25,
  # with a live coefficient there (else the edge's mutation is equivalent on it)
  RE=$(basename "$(python3 - "${STREAMS[@]}" <<'PYEOF'
import sys
sys.path.insert(0, 'tools')
import ac3_model as M
hit = []
orig = M.rematrix_coeffs
def hook(st, coeff, end, flags):
    if end > 25 and ((flags ^ (flags >> 1)) & 1) and (coeff[0][25] or coeff[1][25]):
        hit.append(1)
    return orig(st, coeff, end, flags)
M.rematrix_coeffs = hook
for p in sys.argv[1:]:
    if 'refuse' in p:
        continue
    d = M.Decoder()
    try:
        for k, (_, fr) in enumerate(M.frames(open(p, 'rb').read())):
            if k >= 4:
                break
            d.frame(fr)
    except M.Ac3Error:
        pass
    if hit:
        print(p)
        break
PYEOF
)" .ac3)
  mut V11 "$RE" $V "wire  [1:0] r_band = (rb < 8'd25) ? 2'd0" "wire  [1:0] r_band = (rb < 8'd26) ? 2'd0" "\[coef\]" &
  mut V12 "$DY" $P "blk_dynrng <= vop_args[23:16];" "blk_dynrng <= vop_args[31:24];" "\[side\]" &
  wait
  # (GAP: "the item pending at a refusal is processed" -- V_AW ignoring it -- survives
  # S2, because with today's timing the engine has always finished bin k before the
  # sequencer refuses bin k + 1: a fresh grouped code alone takes >= 15 cycles. The
  # contract is for a slower engine; its sequencer half, keeping xq_valid, is scored by
  # run_ac3_seq.sh X21.)
  mut V14 $T $V "OP_AQC: begin ab <= 1'b0; lcnt <= args[47:32] - args[31:16];" \
                "OP_AQC: begin ab <= 1'b0; lcnt <= args[47:32] - args[31:16] - 12'd1;" "\[(coef|count|hang)\]" &
  wait
  for f in "$RES"/*; do grep -v MUTFAIL "$f"; grep -q MUTFAIL "$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail = 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
