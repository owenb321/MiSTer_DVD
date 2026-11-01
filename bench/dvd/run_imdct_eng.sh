#!/usr/bin/env bash
# run_imdct_eng.sh -- gate for the AC-3 IMDCT on the engine (docs/imdct_engine.md I2):
# dts_vec op 25 against tools/imdct_isa.py, word for word and cycle for cycle.
#
# WHAT IS PROVEN (bench/dvd/imdct_eng_tb.sv, one continuous run from a junk ring)
#   [ring]   after every item ALL 2,048 ring words equal the emulator's (which is
#            bit-identical to imdct_512's model: tools/imdct_isa.py check)
#   [cycles] every item's go -> imdct_fin equals the emulator's cycles, which
#            tools/test_ac3_isa.py's budget charges (worst AC-3 frame 58.8 %)
#   items: one frame of 5.1, 3/0, 2/1, 3/1, 2/2, dual mono, mono and a DRC stream; random
#   and full-scale blocks (every acmod, short and long); injected-buffer ISKIP items, the
#   only way to reach 33-bit pre-sums.
#   Mutations (dvd/dts/dts_vec.sv), each must fail the arm it names:
#     M1  a product is added, never subtracted                         -> ring
#     M2  no stall on a ring word still being written                  -> ring
#     M3  every store wraps to 32 bits (the 33-bit pre-sums lose a bit) -> ring
#     M4  a delay line is read before its channel was ever transformed -> ring
#     M5  short POST's second window tap takes the long formula        -> ring
#     M6  short PRE pairs bins as a long block does                    -> ring
#     M7  R after C writes its slot instead of adding                  -> ring
#     M8  the DRC shift one too far                                    -> ring
#     M9  ISKIP starts on a stale schedule entry                       -> ring
#     M10 a term's write goes to its sample's address                  -> ring
#     M11 a stall on every write in flight (values right, slower)      -> cycles
#
# Usage: bench/dvd/run_imdct_eng.sh [--red]     (exit 0 = ALL GREEN)
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RED=0; [ "${1:-}" = "--red" ] && RED=1
rc=0

python3 - "$TMP/vec" <<'EOF' || { echo "run_imdct_eng: vector generation failed"; exit 1; }
import os, sys
sys.path.insert(0, 'tools')
import imdct_isa as I, imdct_model as IM
keys = ('noise_5p1', 'acmod3_', 'acmod4_', 'acmod5_', 'acmod6_', 'dualmono', 'bbb_mono', 'bbb_short_5p1', '10_2026')
S = [p for p in IM.gate_streams() if any(k in os.path.basename(p) for k in keys) and os.path.exists(p)]
n, wide = I.write_vectors(sys.argv[1], S, 1, 16, 8)
print(f'vectors: {n} items from {len(S)} streams + 16 random + 8 ISKIP, widest sample {wide} bits')
assert wide > 32, 'no item reached a 33-bit sample: the ISKIP items are vacuous'
EOF

run() {   # <dts_vec.sv> -> the bench's last line
    iverilog -g2012 -I . -o "$TMP/sim" "$1" bench/dvd/imdct_eng_tb.sv 2>"$TMP/log" \
        || { grep -v 'sorry: constant selects' "$TMP/log" | head -5; echo "BUILD FAILED"; return; }
    timeout 900 vvp -n "$TMP/sim" +dir="$TMP/vec" 2>&1 | grep -E 'IMDCT_ENG PASS|FAIL' | head -1
}

out=$(run dvd/dts/dts_vec.sv)
if [[ "$out" == IMDCT_ENG\ PASS* ]]; then echo "[ring] [cycles] PASS  ($out)"
else echo "FAIL  $out"; rc=1; fi

if [ $RED = 1 ]; then
    echo "mutations:"
    mut() {   # <name> <expected arm> <old> <new>
        local name=$1 want=$2 got
        python3 - "$3" "$4" dvd/dts/dts_vec.sv "$TMP/$name.sv" <<'EOF' || { echo "  $name: anchor not found"; rc=1; return; }
import sys
old, new, src, dst = sys.argv[1:]
s = open(src).read()
if s.count(old) != 1: sys.exit(1)
open(dst, 'w').write(s.replace(old, new))
EOF
        got=$(run "$TMP/$name.sv")
        if [[ "$got" == *"FAIL [$want]"* ]]; then echo "  $name: fails [$want] as expected"
        else echo "  $name: WRONG -- $got (expected [$want])"; rc=1; fi
    }
    mut M1 ring "+ (x_psub ? -pv : pv);" "+ pv;"
    mut M2 ring "im_hz = r_v && (r_srck != 2'd1) &&" "im_hz = 1'b0 && (r_srck != 2'd1) &&"
    mut M3 ring "wire  [34:0] rg_wd = x_w35 ? res[34:0] : {{3{res[31]}}, res[31:0]};" \
                "wire  [34:0] rg_wd = {{3{res[31]}}, res[31:0]};"
    mut M4 ring "(r_src >= IM_S_DL && r_src < IM_S_P && !im_vld[r_ch]) ? 2'd2 : 2'd0;" \
                "(r_src >= IM_S_DL && r_src < IM_S_P && 1'b0) ? 2'd2 : 2'd0;"
    mut M5 ring "IM_C_WA1: wn_im_ra = r_short ? 8'd127 - {r_cnt[6:0], 1'b0} : {r_cnt[6:0], 1'b1};" \
                "IM_C_WA1: wn_im_ra = {r_cnt[6:0], 1'b1};"
    mut M6 ring "f_a1 <= !f_short ? 8'd255 - fo_q : fo_nx[6] ? 8'd255 - fo_q : 8'd254 - fo_q;" \
                "f_a1 <= 8'd255 - fo_q;"
    mut M7 ring "im_cls = im_has_c ? 3'd2 : 3'd1;   // R" "im_cls = 3'd1;   // R"
    mut M8 ring "wire  [3:0] im_drc_sh = 4'd5 - {a1[7], a1[7:5]};" "wire  [3:0] im_drc_sh = 4'd6 - {a1[7], a1[7:5]};"
    mut M9 ring "if (st == V_IM) sched_ra = a0[0] ? 9'd157 : 9'd0;" "if (st == V_IM) sched_ra = 9'd1;"
    mut M10 ring "i_dst <= ra_q[1];" "i_dst <= ra_q[0];"
    mut M11 cycles "((i_v && i_dstv && i_dst == im_ra) || (x_rg_we && x_rg_wa == im_ra));" \
                   "((i_v && i_dstv && i_dst == im_ra) || x_rg_we);"
fi

[ $rc = 0 ] && echo "run_imdct_eng: ALL GREEN" || echo "run_imdct_eng: FAILURES"
exit $rc
