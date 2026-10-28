#!/usr/bin/env bash
# run_dts.sh -- the whole DTS engine gate (dvd/dts/dts_top.sv = dts_seq + dts_vec,
# bench/dvd/dts_top_tb.sv; goldens tools/dts_golden.py <- the emulator tools/dts_isa.py,
# itself checked against tools/dts_fixed.py on the same frames). docs/dts_decoder.md
# sec 10. (The sequencer alone, event by event: bench/dvd/run_dts_seq.sh.)
#
# GREEN (every vector op's buffers by checksum, every PCM pair bit-exact, the counts):
#   every stream of the gate set (DTS_GATE_DIR, default ~/dts-streams/gate), 2 frames:
#     the written spec maxima, joint intensity, all ten AMODEs, sum/difference, both
#     window prototypes, the IMDCT pre-shift, Shadoan's lenient codes, CNT
#   R1 T2, frame 1's last DSYNC corrupted: refused after half its PCM; input stalls,
#      PCM back-pressure, codebook latency 1
#   R2 T2, frame 1 delivered 300 bytes short
#   R3 Shadoan with stalls and back-pressure (+stall=40 +ostall=600 +cblat=90)
#   L* T2, 3 frames, the codebook latency swept (1, 20, 60, 150): cycles reported as a
#      function of the latency ram2 will have (P2 measures it)
#   D1 T2 with the ring and the carried sums starting as garbage (+dirty: what MP2 left,
#      docs/mp2_engine.md M2): the program's RESET (RCLR) must clear them
# Every no-stall arm must also fit BUDGET (default 60 %) of real time, frame by frame.
#
# --red [MUTS="V1 V4" to run only those]: mutations on a COPY of the RTL, each caught
# by its own arm:
#   V1  the rounding shifter truncates                    (T2)          -> [vop]
#   V2  XQ never shifts step x scale down                 (A.I. 1536k)  -> [vop]
#   V3  XQ's Huffman bands skip the scale adjustment      (synth 320k adj) -> [vop]
#   V4  XVQ fetches slice 0 for every subsubframe         (museum VQ)   -> [vop]
#   V5  ADPCM's coefficients in reverse order             (T2)          -> [vop]
#   V6  an unpredicted band leaves its history            (T2)          -> [vop]
#   V7  JOINT does not write the history                  (joint)       -> [vop]
#   V8  BFLY's difference is a sum                        (sumdiff51)   -> [vop]
#   V9  the mix takes the other side's gains              (amode9)      -> [vop]
#       (the mix ignoring nmix is NOT a defect: X above a channel's mixed count is
#       zero by construction, so dts_vec does not apply the bound -- see V_MX)
#   V10 the IMDCT pre-shift is never applied              (loud 1536k)  -> [vop]
#   V11 no barrier between the IMDCT's stages             (T2)          -> [vop]
#   V12 the window ignores the perfect flag               (51 perfect)  -> [vop] / [pcm]
#   V13 the ring offset never advances                    (T2)          -> [vop]
#   V14 PCM rounds by truncation                          (T2)          -> [pcm]
#   V15 HCLR clears from band 0                           (amode9)      -> [vop]
#   V16 XCLR clears 1,024 words, not 1,280 (channel 4)    (T2)          -> [vop]
#   V17 an ignored downmix is not counted                 (Cinderella)  -> [count]
#   V18 ADPCM reads coefficient row pvq / 2               (T2)          -> [vop]
#   V19 RCLR clears nothing (the ring starts as garbage)  (D1)          -> [vop]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
GATE=${DTS_GATE_DIR:-$HOME/dts-streams/gate}
GEN=.sim/dts/top
CB=.sim/dts/cb
BUDGET=${BUDGET:-60}
mkdir -p "$GEN"
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="dvd/dts/dts_seq.sv dvd/dts/dts_vec.sv dvd/dts/dts_top.sv"
TB=bench/dvd/dts_top_tb.sv
JOBS=${JOBS:-$(nproc)}

echo "== GREEN: the microcode, the ROM images and the IMDCT program =="
python3 tools/dts_isa.py --asm --check | sed 's/^/  /' || fail=1
python3 tools/dts_vecrom.py | sed 's/^/  /' || fail=1
python3 tools/dts_golden.py --codebooks "$CB" > /dev/null || fail=1

shopt -s nullglob
STREAMS=("$GATE"/*.dts)
if [ ${#STREAMS[@]} -eq 0 ]; then
  echo "FAIL: no streams in $GATE (set DTS_GATE_DIR; tools/gen_dts_fixtures.py builds them)"
  exit 1
fi
T2=$GATE/disc_t2_sample.dts

# arm | stream | golden args | sim args | timed?
ARMS=()
for s in "${STREAMS[@]}"; do ARMS+=("$(basename "$s" .dts)|$s|--frames 2||1"); done
ARMS+=("R1|$T2|--frames 3 --refuse 1|+stall=20 +ostall=600 +cblat=1|0")
ARMS+=("R2|$T2|--frames 3 --truncate 1:300||0")
ARMS+=("R3|$GATE/disc_blockoverflow_shadoan.dts|--frames 2|+stall=40 +ostall=600 +cblat=90|0")
for L in 1 20 60 150; do ARMS+=("L$L|$T2|--frames 3|+cblat=$L|1"); done
ARMS+=("D1|$T2|--frames 2|+dirty|0")
declare -A STEM SIMARGS TIMED

echo "== GREEN: goldens (${#ARMS[@]} arms) =="
n=0
for a in "${ARMS[@]}"; do
  IFS='|' read -r name src gargs sargs timed <<<"$a"
  STEM[$name]=$GEN/$name; SIMARGS[$name]=$sargs; TIMED[$name]=$timed
  if [ ! -f "$src" ]; then echo "  FAIL $name: no $src"; fail=1; STEM[$name]=; continue; fi
  # shellcheck disable=SC2086
  python3 tools/dts_golden.py "$src" --out "${STEM[$name]}" $gargs > "${STEM[$name]}.glog" 2>&1 &
  n=$((n + 1)); [ $((n % JOBS)) -eq 0 ] && wait
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if ! grep -q "matches the model" "${STEM[$name]}.glog"; then
    echo "  FAIL $name golden: $(tail -1 "${STEM[$name]}.glog")"; fail=1; STEM[$name]=
  fi
done

# shellcheck disable=SC2086
iverilog -g2012 -o .sim/dts/top_sim $RTL $TB 2>&1 | grep -v "sorry" | grep . && { echo "  FAIL build"; exit 1; }
echo "== GREEN: the engine =="
n=0
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  # shellcheck disable=SC2086
  vvp -n .sim/dts/top_sim +stem="${STEM[$name]}" +cb="$CB" ${SIMARGS[$name]} 2>&1 \
      | grep -v 'readmem\|Not enough' > "$GEN/$name.log" &
  n=$((n + 1)); [ $((n % JOBS)) -eq 0 ] && wait
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if grep -q "^PASS: dts_top_tb" "$GEN/$name.log"; then
    line=$(grep '^dts_top_tb:' "$GEN/$name.log" | sed 's/^dts_top_tb: //')
    worst=$(echo "$line" | sed -n 's/.*worst frame \([0-9.]*\) %.*/\1/p')
    if [ "${TIMED[$name]}" = 1 ] && awk -v w="$worst" -v b="$BUDGET" 'BEGIN { exit !(w > b) }'; then
      echo "  FAIL $name: worst frame $worst % of real time, over the $BUDGET % budget"; fail=1
    else
      echo "  PASS $name: $line"
    fi
  else echo "  FAIL $name: $(grep -m1 FAIL "$GEN/$name.log")"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name arm old new arm-pattern
    local name=$1 arm=$2 old=$3 new=$4 pat=$5
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    if [ -z "${STEM[$arm]:-}" ]; then
      { echo "  $name: no golden for arm $arm"; echo MUTFAIL; } > "$RES/$name"; return
    fi
    local d; d=$(mktemp -d)
    mkdir -p "$d/dvd/dts" "$d/dvd/ac3" "$d/bench/dvd"
    cp dvd/dts/*.sv dvd/dts/*.svh dvd/dts/*.mem "$d/dvd/dts/"
    cp dvd/ac3/ac3_imdct_tables.svh "$d/dvd/ac3/"   # dts_vec includes it (the IMDCT, op 25)
    cp $TB "$d/bench/dvd/"
    python3 - "$d" "$old" "$new" <<'PYEOF'
import sys, glob
d, old, new = sys.argv[1:4]
hits = [p for p in glob.glob(d + "/dvd/dts/*.sv") if old in open(p).read()]
assert len(hits) == 1 and open(hits[0]).read().count(old) == 1, f"mutation anchor not unique/found: {old!r}"
s = open(hits[0]).read()
open(hits[0], "w").write(s.replace(old, new))
PYEOF
    # shellcheck disable=SC2086
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTL $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    (cd "$d" && timeout 900 vvp -n sim +stem="$ROOT/${STEM[$arm]}" +cb="$ROOT/$CB" ${SIMARGS[$arm]} 2>&1 \
        | grep -v 'readmem\|Not enough' > log)
    if grep -q "^PASS: dts_top_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -qE "FAIL $pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 -E "FAIL $pat" "$d/log" | sed 's/.*FAIL/FAIL/' | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  T=disc_t2_sample
  mut V1 $T "((rsrc + (x_trunc ? 56'sd0 : (56'sd1 <<< (x_rsh - 6'd1)))) >>> x_rsh)" "(rsrc >>> x_rsh)" '\[vop\]' &
  mut V2 disc_1536k_transient_ai "V_XQ5: begin shreg <= ss_gt ? ss_len : 5'd0;" "V_XQ5: begin shreg <= 5'd0;" '\[vop\]' &
  mut V3 synth_stereo_320k_adj "if (q_huff) st <= V_XQ2; else st <= V_XQ3;" "st <= V_XQ3;" '\[vop\]' &
  mut V4 disc_768k_vq_transient_museum "cb_addr <= {args[41:32], args[49:48]};" "cb_addr <= {args[41:32], 2'd0};" '\[vop\]' &
  wait
  mut V5 $T "3'd0: begin ma = hs0; mb = cs3; end" "3'd0: begin ma = hs0; mb = cs0; end" '\[vop\]' &
  mut V6 $T "if (k == 12'd4 && !dv) begin k <= 12'd0; st <= V_AD3; end" "if (k == 12'd4 && !dv) begin k <= 12'd0; st <= V_DONE; end" '\[vop\]' &
  mut V7 written_joint "hb_we = k_d[2];" "hb_we = 1'b0;" '\[vop\]' &
  mut V8 written_sumdiff51 "dsrc = {{31{bf_a[24]}}, bf_a} - {{31{bf_c[24]}}, bf_c};   // BFLY: X[p] - X[q]" "dsrc = {{31{bf_a[24]}}, bf_a} + {{31{bf_c[24]}}, bf_c};" '\[vop\]' &
  wait
  mut V9 written_amode9 "{5'd0, mb_c, 1'b0} + {8'd0, side};" "{5'd0, mb_c, 1'b0} + {8'd0, !side};" '\[vop\]' &
  mut V10 synth_stereo_1536k_loud "pshift <= (mag > 29'h400000);" "pshift <= 1'b0;" '\[vop\]' &
  mut V11 $T "wire        ip_final = ip_iv && ti_last && (o_idx == 5'd31) && (o_stage != 3'd6);" "wire        ip_final = 1'b0;" '\[vop\]' &
  mut V12 synth_51side_1536k_perfect "wn_ra = {a7[0], w_t, w_q, w_i};" "wn_ra = {1'b0, w_t, w_q, w_i};" '\[(vop|pcm)\]' &
  wait
  mut V13 $T "off0 <= off0 - 10'd32;" "off0 <= off0;" '\[(vop|pcm)\]' &
  mut V14 $T "wire  signed [24:0] p_rnd = (\$signed({p_val[23], p_val}) + 25'sd128) >>> 8;" "wire  signed [24:0] p_rnd = \$signed({p_val[23], p_val}) >>> 8;" '\[pcm\]' &
  mut V15 written_amode9 ": {3'd0, args[22:16], 2'd0};" ": 12'd0;" '\[vop\]' &
  mut V16 $T "OP_XCLR: begin lcnt <= 12'd1280; st <= V_LOOP; end" "OP_XCLR: begin lcnt <= 12'd1024; st <= V_LOOP; end" '\[vop\]' &
  wait
  mut V17 disc_dmix_cinderella3 "if (cnt_dmix && dmix_ignored != 16'hFFFF)" "if (1'b0)" '\[count\]' &
  mut V18 $T "cb_addr <= args[43:32];" "cb_addr <= {1'b0, args[43:33]};" '\[vop\]' &
  mut V19 D1 "direct = 1'b1; rg_we = 1'b1; rg_wa = k_d[10:0];" "direct = 1'b1; rg_we = 1'b0; rg_wa = k_d[10:0];" '\[vop\]' &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
