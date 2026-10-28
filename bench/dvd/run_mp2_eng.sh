#!/usr/bin/env bash
# run_mp2_eng.sh -- MP2 on the shared audio engine (docs/mp2_engine.md M2): the
# sequencer running mp2.uasm (bench/dvd/dts_seq_tb.sv, +codec=2) and the whole engine
# (dvd/dts/dts_top.sv, bench/dvd/dts_top_tb.sv, +codec=2) against the emulator
# (goldens tools/mp2_golden.py <- tools/mp2_isa.py, which agrees with tools/mp2_ref.py
# pair for pair and op for op; mp2_ref is bit-exact with mp2_decode:
# bench/dvd/run_mp2_model.sh). The A/B against mp2_decode itself is run_mp2_ab.sh.
#
# GREEN, every stream of the gate set ($MP2_TEST_DIR, default ~/mp2-streams/gate), 2 frames:
#   [trace] the sequencer: every register write and store, in program order
#   [vop]   the engine: after every vector op, X, the ring and the carried sums by
#           checksum at MP2's widths;  [pcm] every pair bit-exact;  [count] the counts
#           and the rate dts_top exports;  and each frame within BUDGET (default 60 %)
#           of real time at the stream's own rate
# and the arms:
#   S1  48 kHz dual 384k (the worst frame) with input stalls and PCM back-pressure
#   S2  mono with heavy back-pressure (the duplicated emit)
#   R1  frame 1 delivered one byte short: refused (E_LEN) before any of its PCM; the
#       frames after it prove nothing of it was taken
#   L1  frame 1 followed by 37 junk bytes in its descriptor (what mp2_reframer passes
#       when no sync follows a frame): decoded, the junk drained, counted (CNT 0)
#   D1  the ring and the carried sums start as garbage (+dirty): RESET's RCLR clears them
#
# --red [MUTS="M1 M4" to run only those]: mutations on a COPY of the RTL, each caught
# by its own arm (the mut lines below).
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
SET=${MP2_TEST_DIR:-$HOME/mp2-streams/gate}
GEN=.sim/mp2/eng
CB=.sim/dts/cb
BUDGET=${BUDGET:-60}
FRAMES=${MP2_FRAMES:-2}
mkdir -p "$GEN"
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="dvd/dts/dts_seq.sv dvd/dts/dts_vec.sv dvd/dts/dts_top.sv"
TB=bench/dvd/dts_top_tb.sv
JOBS=${JOBS:-$(nproc)}

echo "== GREEN: the microcode and the ROM images are current =="
python3 tools/dts_isa.py --asm --check | sed 's/^/  /' || fail=1
python3 tools/dts_golden.py --codebooks "$CB" > /dev/null || fail=1

mapfile -t STREAMS < <(find "$SET" -name '*.mp2' | sort)
if [ ${#STREAMS[@]} -eq 0 ]; then
  echo "FAIL: no streams under $SET (set MP2_TEST_DIR; tools/mp2_scan.py, tools/gen_mp2_streams.sh)"
  exit 1
fi
SY=$SET/synth
# arm | stream | golden args | sim args | timed?
ARMS=()
for s in "${STREAMS[@]}"; do
  n=$(basename "$(dirname "$s")")_$(basename "$s" .mp2)
  ARMS+=("$n|$s|--frames $FRAMES||1")
done
ARMS+=("S1|$SY/tw_48000_d_384k.mp2|--frames 3|+stall=20 +ostall=600|0")
ARMS+=("S2|$SY/tw_48000_m_64k.mp2|--frames 2|+ostall=1500|0")
ARMS+=("R1|$SY/tw_44100_j_128k.mp2|--frames 3 --short 1||0")
ARMS+=("D1|$SY/tw_32000_s_128k.mp2|--frames 2|+dirty|0")
ARMS+=("L1|$SY/tw_48000_s_128k.mp2|--frames 3 --long 1:37||0")
declare -A STEM SIMARGS TIMED

echo "== GREEN: goldens (${#ARMS[@]} arms) =="
n=0
for a in "${ARMS[@]}"; do
  IFS='|' read -r name src gargs sargs timed <<<"$a"
  STEM[$name]=$GEN/$name; SIMARGS[$name]=$sargs; TIMED[$name]=$timed
  if [ ! -f "$src" ]; then echo "  FAIL $name: no $src"; fail=1; STEM[$name]=; continue; fi
  # shellcheck disable=SC2086
  python3 tools/mp2_golden.py "$src" --out "${STEM[$name]}" $gargs > "${STEM[$name]}.glog" 2>&1 &
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

iverilog -g2012 -o .sim/mp2/seq_sim dvd/dts/dts_seq.sv bench/dvd/dts_seq_tb.sv 2>&1 | grep -v sorry | grep . \
  && { echo "  FAIL build (sequencer)"; exit 1; }
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/mp2/top_sim $RTL $TB 2>&1 | grep -v sorry | grep . && { echo "  FAIL build"; exit 1; }

echo "== GREEN: the sequencer (codec = MP2) and the engine =="
n=0
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  # shellcheck disable=SC2086
  vvp -n .sim/mp2/seq_sim +stem="${STEM[$name]}" +codec=2 $(echo "${SIMARGS[$name]}" | grep -o '+stall=[0-9]*') \
      2>&1 | grep -v 'readmem\|Not enough' > "$GEN/$name.seq.log" &
  # shellcheck disable=SC2086
  vvp -n .sim/mp2/top_sim +stem="${STEM[$name]}" +cb="$CB" +codec=2 ${SIMARGS[$name]} 2>&1 \
      | grep -v 'readmem\|Not enough' > "$GEN/$name.log" &
  n=$((n + 2)); [ $((n % JOBS)) -lt 2 ] && wait
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if ! grep -q "^PASS: dts_seq_tb" "$GEN/$name.seq.log"; then
    echo "  FAIL $name [sequencer]: $(grep -m1 FAIL "$GEN/$name.seq.log")"; fail=1
  fi
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
    (cd "$d" && timeout 900 vvp -n sim +stem="$ROOT/${STEM[$arm]}" +cb="$ROOT/$CB" +codec=2 ${SIMARGS[$arm]} 2>&1 \
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
  ST=synth_tw_44100_s_128k
  F32=synth_tw_32000_j_128k
  # MDQ's floor by 7 is exact unless nb >= 10: (x16 + d16) is a multiple of 2^(16 - nb).
  # So M2 needs a stream with a 1,023-level class or finer in its first frames.
  HI=synth_tw_32000_s_384k
  mut M1 $ST "ma = {11'd0, a2}; mb = {10'd0, ic_q[16:0]};" "ma = 27'sd0; mb = {10'd0, ic_q[16:0]};" '\[vop\]' &
  mut M2 $HI "acc_clr = 1'b0; acc_en = 1'b1; rsh = 6'd7; trunc = 1'b1;" "acc_clr = 1'b0; acc_en = 1'b1; rsh = 6'd7; trunc = 1'b0;" '\[vop\]' &
  mut M3 $ST "ma = {{6{ss[26]}}, ss[26:0]}; mb = {5'd0, ic_q[21:0]};" "ma = {{6{ss[26]}}, ss[26:0]}; mb = {6'd0, ic_q[21:1]};" '\[vop\]' &
  mut M4 $ST "rsh = 6'd14; trunc = 1'b1;" "rsh = 6'd14; trunc = 1'b0;" '\[vop\]' &
  mut M5 $ST "wire  [9:0] mm_rg = moff + {4'd0, k_d[10:5]};" "wire  [9:0] mm_rg = moff + {5'd0, k_d[10:6]};" '\[vop\]' &
  mut M6 $ST "init = mwd_p ? {{27{b2_q[28]}}, b2_q} : 56'sd0;" "init = 56'sd0;" '\[pcm\]' &
  wait
  mut M7 $ST "wire signed [26:0] vlo27 = {11'd0, rg_q[15:0]};" "wire signed [26:0] vlo27 = {{11{rg_q[15]}}, rg_q[15:0]};" '\[vop\]' &
  mut M8 $ST "wire  [9:0] mw_rg = moff + {mw_t[3:1], mw_t[0], mw_t[0], mw_j};" "wire  [9:0] mw_rg = moff + {mw_t[3:1], mw_t[0], 1'b0, mw_j};" '\[vop\]' &
  mut M9 $ST "if (side) off1 <= off1 - 10'd64; else off0 <= off0 - 10'd64;" "if (side) off1 <= off1 - 10'd32; else off0 <= off0 - 10'd32;" '\[vop\]' &
  mut M10 S2 "pb_r = ((st == V_EMITL) || (st == V_EMITW)) && !m_mono;" "pb_r = ((st == V_EMITL) || (st == V_EMITW));" '\[pcm\]' &
  mut M11 D1 "b2_we = (k_d < 12'd64); b2_wa = k_d[5:0];" "b2_we = 1'b0; b2_wa = k_d[5:0];" '\[vop\]' &
  mut M12 $F32 "else if (vop_start && vop_op == 6'd29) mp2_fs <= vop_args[1:0];" "else if (vop_start && vop_op == 6'd29) mp2_fs <= 2'd1;" '\[count\]' &
  wait
  mut M13 $ST "ma = {{17{a1[15]}}, a1}; mb = {10'd0, ic_q[16:0]}; acc_en = 1'b1;" "ma = {17'd0, a1}; mb = {10'd0, ic_q[16:0]}; acc_en = 1'b1;" '\[vop\]' &
  mut M14 $ST "if (!mwd_p) begin rsh = 6'd16; b2_we = 1'b1;" "if (!mwd_p) begin rsh = 6'd15; b2_we = 1'b1;" '\[vop\]' &
  mut M15 $ST "rsh = 6'd1; sat24 = 1'b1; p_wi = 1'b1;" "rsh = 6'd0; sat24 = 1'b1; p_wi = 1'b1;" '\[pcm\]' &
  mut M16 $ST "xb_ra = {3'd0, a0[1:0], side, k[4:0]};" "xb_ra = {3'd0, a0[1:0], 1'b0, k[4:0]};" '\[vop\]' &
  # (Synthesising channel 1 in mono as well is NOT caught, and is not a defect on any
  #  stream that stays mono: channel 1's samples are zero, so its ring stays zero. It
  #  costs the cycles of a second channel, and it would differ from mp2_decode only on
  #  a stream that switches from stereo to mono, which leaves channel 1's ring live.)
  mut M18 D1 "direct = 1'b1; rg_we = 1'b1; rg_wa = k_d[10:0];" "direct = 1'b1; rg_we = 1'b0; rg_wa = k_d[10:0];" '\[vop\]' &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
