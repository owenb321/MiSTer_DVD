#!/usr/bin/env bash
# Gate for show-first Audio/Subtitle (2026-10-01; docs/track_selection.md
# "Show-first Audio/Subtitle").
#
# A set-top player's Audio and Subtitle buttons SHOW the current setting on the
# first press and CHANGE it only when pressed again while it is on screen. This
# core used to change it on every press, so a user asking "which track is this?"
# had to cycle all the way round to get back.
#
# Two arms, one per place the feature lives:
#   transport_hud_tb T26        the decision: aud_step_o / sub_step_o fire only for
#                               a press made while THAT button's popup is visible
#                               (not the other button's, not an expired one, not
#                               one hidden by a menu).
#   check_track_step_wiring.py  the emu.sv seam (no bench): the track steps -- and
#                               the menu's SetSTN ownership is released -- on the
#                               step pulse, never the raw press; the popup shows
#                               the EFFECTIVE track and the step starts from it.
#
# --red applies one targeted mutation per claim and requires the assertion that
# owns it to fail:
#   M1  emu: aud_cur steps on audio_edge          -> A1  (THE OLD BEHAVIOUR)
#   M2  emu: subtitle steps on sub_edge           -> A2  (THE OLD BEHAVIOUR)
#   M3  emu: vm_owns_aud released by audio_edge   -> A3
#   M4  emu: vm_owns_sp released by sub_edge      -> A3
#   M5  emu: aud_step_w loses the hidden mask     -> A4
#   M6  emu: hud_hidden_w loses stop_full         -> A5
#   M7  emu: popup shows aud_cur                  -> A7
#   M8  emu: language readout from aud_cur        -> A7
#   M9  emu: audio step advances from aud_cur     -> A8
#   M10 emu: subtitle step advances from sub_idx  -> A8
#   H1  hud: aud_step_o ignores pop_type          -> T26f (the other button's popup)
#   H2  hud: aud_step_o uses pop_tmr, not pop_vis -> T26j (a menu-hidden popup)
#   H3  hud: aud_step_o = aud_evt (no gate)       -> T26a (the reported defect)
#   H4  hud: sub_step_o ignores pop_type          -> T26d
#
#   bench/dvd/run_track_show.sh          # GREEN arms
#   bench/dvd/run_track_show.sh --red    # GREEN + the mutation arms
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

pass()   { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; rc=1; }

# Replace exactly one occurrence of $4 with $5 in a copy, or FAIL LOUDLY: a stale
# anchor would leave an unmutated copy and the red arm would prove nothing.
mut() {  # $1 = label, $2 = src, $3 = dst, $4 = old, $5 = new
    if ! python3 -c '
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new))
' "$2" "$3" "$4" "$5"; then
        failed "$1: the mutation anchor is stale (not exactly one match) -- this arm proves NOTHING"
        return 1
    fi
    return 0
}

red_emu() {  # $1 = label, $2 = mutated file, $3 = owning assertion label
    if python3 tools/check_track_step_wiring.py "$2" > "$TMP/out" 2>&1; then
        failed "$1: the wiring check PASSED a mutated emu.sv"
        return
    fi
    if grep -q "^  $3:" "$TMP/out"; then
        pass "$1 -> caught by $3"
    else
        failed "$1: rejected, but NOT by $3"
        sed -n '2,6p' "$TMP/out"
    fi
}

run_hud() {  # $1 = transport_hud.sv to use, $2 = tag
    iverilog -g2012 -o "$TMP/hud_$2" "$1" bench/dvd/transport_hud_tb.sv > "$TMP/hud_$2.log" 2>&1 \
        || { echo "compile failed"; head -5 "$TMP/hud_$2.log"; return 2; }
    vvp "$TMP/hud_$2" > "$TMP/hud_$2.out" 2>&1
    grep -q "TRANSPORT_HUD_TB: ALL TESTS PASSED" "$TMP/hud_$2.out"
}

red_hud() {  # $1 = label, $2 = mutated file, $3 = owning arm
    if run_hud "$2" "$1"; then
        failed "$1: transport_hud_tb PASSED a mutated HUD"
        return
    fi
    if grep -q "FAIL $3" "$TMP/hud_$1.out"; then
        pass "$1 -> caught by $3"
    else
        failed "$1: rejected, but NOT by $3"
        grep FAIL "$TMP/hud_$1.out" | head -3
    fi
}

echo "== GREEN =="
if python3 tools/check_track_step_wiring.py > "$TMP/w.out" 2>&1; then
    pass "$(cat "$TMP/w.out")"
else
    failed "check_track_step_wiring.py"; cat "$TMP/w.out"
fi
if run_hud dvd/transport_hud.sv green; then
    pass "transport_hud_tb (all arms, incl. T26 show-first)"
else
    failed "transport_hud_tb"; grep FAIL "$TMP/hud_green.out" | head -5
fi
# Not vacuous: the arms that ARE the spec must have run and measured.
for arm in "T26a aud first press shows only: step=0" \
           "T26b aud press while shown steps: step=1" \
           "T26e sub press while shown steps: step=1" \
           "T26j 2nd aud in a menu still no step: step=0"; do
    grep -qF "ok   $arm" "$TMP/hud_green.out" && pass "measured: $arm" || failed "did not run: $arm"
done
# hud_frame_tb instantiates the HUD too; the new outputs must not break it.
if iverilog -g2012 -o "$TMP/hf" dvd/transport_hud.sv dvd/subpic_blend.sv bench/dvd/hud_frame_tb.sv \
       > "$TMP/hf.log" 2>&1 && vvp "$TMP/hf" > "$TMP/hf.out" 2>&1 \
   && grep -q "PASS" "$TMP/hf.out" && ! grep -q "FAIL" "$TMP/hf.out"; then
    pass "hud_frame_tb (unregressed)"
else
    failed "hud_frame_tb"; tail -5 "$TMP/hf.out" "$TMP/hf.log"
fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_track_show: PASS" || echo "run_track_show: FAIL"
    exit $rc
fi

echo "== RED (emu.sv seam) =="
E=dvd/emu.sv
mut M1 "$E" "$TMP/M1.sv" "        if (aud_step_w)
            aud_cur <=" "        if (audio_edge)
            aud_cur <=" && red_emu "M1 aud steps on the press (the old behaviour)" "$TMP/M1.sv" A1
mut M2 "$E" "$TMP/M2.sv" "        if (sub_step_w) begin" "        if (sub_edge) begin" \
    && red_emu "M2 sub steps on the press (the old behaviour)" "$TMP/M2.sv" A2
mut M3 "$E" "$TMP/M3.sv" "            if (aud_step_w)
                vm_owns_aud <= 1'b0;" "            if (audio_edge)
                vm_owns_aud <= 1'b0;" && red_emu "M3 show press releases the menu's audio" "$TMP/M3.sv" A3
mut M4 "$E" "$TMP/M4.sv" "            if (sub_step_w)
                vm_owns_sp <= 1'b0;" "            if (sub_edge)
                vm_owns_sp <= 1'b0;" && red_emu "M4 show press releases the menu's subtitle" "$TMP/M4.sv" A3
mut M5 "$E" "$TMP/M5.sv" "aud_step_w = hud_aud_step_w & ~hud_hidden_w;" "aud_step_w = hud_aud_step_w;" \
    && red_emu "M5 step under a blanked HUD" "$TMP/M5.sv" A4
mut M6 "$E" "$TMP/M6.sv" "assign hud_hidden_w = saver_on_w | stop_full;" "assign hud_hidden_w = saver_on_w;" \
    && red_emu "M6 stage-2 Stop no longer masks the step" "$TMP/M6.sv" A5
mut M7 "$E" "$TMP/M7.sv" ".aud_no       ({1'b0, aud_log} + 4'd1)," ".aud_no       ({1'b0, aud_cur} + 4'd1)," \
    && red_emu "M7 popup shows aud_cur, not the effective track" "$TMP/M7.sv" A7
mut M8 "$E" "$TMP/M8.sv" ".attr_a_sel     (aud_log)," ".attr_a_sel     (aud_cur)," \
    && red_emu "M8 language read for aud_cur" "$TMP/M8.sv" A7
mut M9 "$E" "$TMP/M9.sv" "aud_cur <= (({1'b0,aud_log} + 4'd1) >= audio_ntracks_w) ? 3'd0 : aud_log + 3'd1;" \
    "aud_cur <= (({1'b0,aud_cur} + 4'd1) >= audio_ntracks_w) ? 3'd0 : aud_cur + 3'd1;" \
    && red_emu "M9 audio steps from aud_cur" "$TMP/M9.sv" A8
mut M10 "$E" "$TMP/M10.sv" "sub_idx <= sp_sel + 5'd1;" "sub_idx <= sub_idx + 5'd1;" \
    && red_emu "M10 subtitle steps from sub_idx" "$TMP/M10.sv" A8

echo "== RED (transport_hud decision) =="
H=dvd/transport_hud.sv
mut H1 "$H" "$TMP/H1.sv" "assign aud_step_o = aud_evt && pop_vis && (pop_type == 4'd0);" \
    "assign aud_step_o = aud_evt && pop_vis;" \
    && red_hud H1 "$TMP/H1.sv" "T26f"
mut H2 "$H" "$TMP/H2.sv" "assign aud_step_o = aud_evt && pop_vis && (pop_type == 4'd0);" \
    "assign aud_step_o = aud_evt && (pop_tmr != 27'd0) && (pop_type == 4'd0);" \
    && red_hud H2 "$TMP/H2.sv" "T26j"
mut H3 "$H" "$TMP/H3.sv" "assign aud_step_o = aud_evt && pop_vis && (pop_type == 4'd0);" \
    "assign aud_step_o = aud_evt;" \
    && red_hud H3 "$TMP/H3.sv" "T26a"
mut H4 "$H" "$TMP/H4.sv" "assign sub_step_o = sub_evt && pop_vis && (pop_type == 4'd1);" \
    "assign sub_step_o = sub_evt && pop_vis;" \
    && red_hud H4 "$TMP/H4.sv" "T26d"

[ $rc -eq 0 ] && echo "run_track_show: PASS (green + red)" || echo "run_track_show: FAIL"
exit $rc
