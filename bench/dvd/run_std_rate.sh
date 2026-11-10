#!/usr/bin/env bash
# run_std_rate.sh -- the STC tick and audio NCO trim for standard conversion
# (dvd/std_rate.sv, docs/standard_convert.md).
#
#   GREEN  bench/dvd/std_rate_tb.sv: unity is cycle-identical to clk/300; slow and fast are
#          exact over whole periods and evenly spaced; a mode change never bursts; every NCO
#          trim achieves its ratio.
#   RED    (--red) one mutation per claim, each failing exactly its own arm.
set -u
cd "$(dirname "$0")/../.."
fail=0

run() {  # name dut expect(pass|fail) [arm...]
    local name=$1 dut=$2 want=$3; shift 3
    local d; d=$(mktemp -d)
    iverilog -g2012 -o "$d/sim" "$dut" bench/dvd/std_rate_tb.sv > "$d/build" 2>&1
    if [ ! -f "$d/sim" ]; then
        echo "  FAIL $name: did not build"; tail -15 "$d/build" | sed 's/^/      /'; fail=1; rm -rf "$d"; return
    fi
    vvp "$d/sim" > "$d/log" 2>&1
    if [ ! -s "$d/log" ]; then
        echo "  FAIL $name: no output -- not a verdict"; fail=1
    elif [ "$want" = pass ]; then
        if grep -q "^PASS" "$d/log" && ! grep -q "^FAIL" "$d/log"; then
            echo "  PASS $name"; grep -E '^\s+\[' "$d/log" | sed 's/^/      /'
        else
            echo "  FAIL $name"; tail -15 "$d/log" | sed 's/^/      /'; fail=1
        fi
    else
        # Exactly its own arm(s): every named arm fails, and no other arm does.
        local ok=1 a seen
        grep -q "^PASS" "$d/log" && ok=0
        for a in "$@"; do grep -q "^FAIL \[$a\]" "$d/log" || ok=0; done
        seen=$(grep -oE '^FAIL \[[a-z0-9]+\]' "$d/log" | sed -E 's/^FAIL \[(.*)\]/\1/' | sort -u)
        for a in $seen; do case " $* " in *" $a "*) ;; *) ok=0 ;; esac; done
        if [ $ok = 1 ]; then
            echo "  PASS $name (failed as it must: $(echo $seen))"
        else
            echo "  FAIL $name: wanted only [$*], saw [$(echo $seen)]"; tail -8 "$d/log" | sed 's/^/      /'; fail=1
        fi
    fi
    rm -rf "$d"
}

mutant() {  # name old new arm...
    local name=$1 old=$2 new=$3; shift 3
    local d; d=$(mktemp -d)
    if python3 - "$d/std_rate.sv" "$old" "$new" <<'PYEOF'
import sys
s = open('dvd/std_rate.sv').read()
if s.count(sys.argv[2]) != 1:
    sys.exit("RED anchor moved: " + sys.argv[2])
open(sys.argv[1], 'w').write(s.replace(sys.argv[2], sys.argv[3]))
PYEOF
    then run "$name" "$d/std_rate.sv" fail "$@"
    else echo "  FAIL $name: mutation did not apply"; fail=1; fi
    rm -rf "$d"
}

echo "== GREEN"
run "std_rate_tb" dvd/std_rate.sv pass

if [ "${1:-}" = "--red" ]; then
    echo "== RED"
    mutant "R1 unity period 301"          "fast ? 19'd288000 : 19'd300;" "fast ? 19'd288000 : 19'd301;" unity switch mode3
    mutant "R2 slow numerator 961"        "slow ? 19'd960 " "slow ? 19'd961 " slow
    mutant "R3 fast denominator off by 1" "fast ? 19'd288000" "fast ? 19'd288001" fast
    mutant "R4 no restart on a mode edge" "acc    <= mode_edge ? 19'd0 : tick" "acc    <= tick" switch
    mutant "R5 slow trim sign flipped"    "nco_trim = -22'sd312742;" "nco_trim =  22'sd312742;" trim
    mutant "R6 fast 96k digit wrong"      "22'sd652200" "22'sd652300" trim
    mutant "R7 mode 3 stops the clock"    "wire        fast = (mode == 2'd2);" "wire        fast = (mode >= 2'd2);" mode3 trim
fi

# dvd/emu.sv has no bench: tools/check_std_convert_wiring.py reads the seams out of the file.
echo "== WIRING"
if python3 tools/check_std_convert_wiring.py > /dev/null; then echo "  PASS wiring"
else python3 tools/check_std_convert_wiring.py | sed 's/^/      /'; echo "  FAIL wiring"; fail=1; fi

wmutant() {  # name old new arm
    local name=$1 old=$2 new=$3 arm=$4
    local d; d=$(mktemp -d)
    if python3 - "$d/emu.sv" "$old" "$new" <<'PYEOF'
import sys
s = open('dvd/emu.sv').read()
if s.count(sys.argv[2]) != 1:
    sys.exit("RED anchor moved: " + sys.argv[2])
open(sys.argv[1], 'w').write(s.replace(sys.argv[2], sys.argv[3]))
PYEOF
    then
        python3 tools/check_std_convert_wiring.py --emu "$d/emu.sv" > "$d/log" 2>&1
        if grep -q "FAIL $arm:" "$d/log" && [ "$(grep -c '^  FAIL ' "$d/log")" = 1 ]; then
            echo "  PASS $name (failed as it must: $arm)"
        else
            echo "  FAIL $name: wanted only [$arm]"; sed 's/^/      /' "$d/log" | head -8; fail=1
        fi
    else echo "  FAIL $name: mutation did not apply"; fail=1; fi
    rm -rf "$d"
}

if [ "${1:-}" = "--red" ]; then
    echo "== WIRING RED"
    wmutant "W1 STC on the true tick"   "if (stc_rate_tick) stc_tog <= ~stc_tog;" "if (stc_div == 9'd299) stc_tog <= ~stc_tog;" stc_tog
    wmutant "W2 nav_trace scaled"       ".tick        (stc_div == 9'd299)," ".tick        (stc_rate_tick)," trace_tick
    wmutant "W3 trim tied to 0"         ".nco_trim (dec_nco_trim)" ".nco_trim ()" trim_out
    wmutant "W4 raster not inverted"    "wire pal_out = pal_eff ^ std_conv_active;" "wire pal_out = pal_eff;" raster
    wmutant "W5 passthrough unguarded"  "status[6] & ~cdda_mode_w & ~std_conv_active & ~std_conv_wait;" "status[6] & ~cdda_mode_w & ~std_conv_wait;" pass
    wmutant "W11 passthrough in the gap" "status[6] & ~cdda_mode_w & ~std_conv_active & ~std_conv_wait;" "status[6] & ~cdda_mode_w & ~std_conv_active;" pass
    wmutant "W12 wait never asserts"     "assign std_conv_wait = (std_conv_sel != 2'd0) & ~pal_val_s2;" "assign std_conv_wait = 1'b0;" pass_wait
    wmutant "W6 acts on a stale verdict" "wire   std_conv_req  = pal_val_s2 & " "wire   std_conv_req  = " active
    wmutant "W7 both directions swapped" "? 2'd1 : 2'd2),   // PAL disc" "? 2'd2 : 2'd1),   // PAL disc" rate_mode
    wmutant "W8 walk ignores conversion" "|| (conv_s2 != conv_prev)" "" walk_kick
    wmutant "W9 NTSC vsync on 576 lines" "wr_data = conv_prev ? {4'b0, 12'd581, 4'b0, 12'd586}" "wr_data = conv_prev ? {4'b0, 12'd488, 4'b0, 12'd494}" walk_vsync
    wmutant "W10 HUD on the source"     ".pal_mode     (ov_pal)," ".pal_mode     (pal_eff)," overlay
    wmutant "W13 analog NTSC->PAL"      "assign std_conv_an   = std_conv_req & pal_det_s2 & " "assign std_conv_an   = std_conv_req & " analog
    wmutant "W14 analog takes film raster" "| std_conv_film;" "| std_conv_active;" filmp
    wmutant "W15 cross modes on analog" "conv_s1 <= std_conv_film; " "conv_s1 <= std_conv_active; " walk_sync
    wmutant "W16 ratios swapped"        "analog_letterbox ? 2'd2 : 2'd1;" "analog_letterbox ? 2'd1 : 2'd2;" ratio
    wmutant "W17 analog never scales"   "= analog_letterbox | std_conv_an; " "= analog_letterbox; " vscale_en
    wmutant "W18 inverse only for LB"   ".letterbox_en (disp_vscale_en & sp_map_en)," ".letterbox_en (analog_letterbox & sp_map_en)," map_en
    wmutant "W19 csync on the source"   ".pal    (ov_pal)," ".pal    (pal_eff)," csync
    wmutant "W20 half_scan PAL value"   "wire [15:0] half_scan_dec = conv_an_dec ? 16'd720" "wire [15:0] half_scan_dec = conv_an_dec ? 16'd900" half_scan
    wmutant "W21 63 per second"         ".disp_fps       (std_conv_an ? 6'd62 :" ".disp_fps       (std_conv_an ? 6'd63 :" disp_fps
    wmutant "W22 menus moved too"       ".ratio ((std_conv_an & ~sp_map_en) ? disp_vscale_ratio : 2'd0)," ".ratio (std_conv_an ? disp_vscale_ratio : 2'd0)," sub_ratio
    wmutant "W24 no synthetic 3:2"      ".std_cad           (conv_an_dec)," ".std_cad           (1'b0)," cadence
    wmutant "W23 5/8 bar is PAL's"      "(disp_vscale_ratio == 2'd2) ? 12'd60  : pal_eff ? 12'd72" "(disp_vscale_ratio == 2'd2) ? 12'd72  : pal_eff ? 12'd72" map_bar
fi

if [ $fail = 0 ]; then echo "PASS run_std_rate"; else echo "FAIL run_std_rate"; exit 1; fi
