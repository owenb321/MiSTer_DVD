#!/usr/bin/env bash
# Gate for "a frame-step press on a playing title pauses it"
# (B18 / keyboard '.', 2026-09-16; docs/dvd_nav.md "Frame step as a pause route").
#
# B18 used to be a DEAD BUTTON during playback: its guard required
# (pause_q || stopped_w), so a press was silently swallowed unless the picture was
# already held and you knew to press B1 first. The fix adds the LAST arm of emu's
# pause_q chain -- a step press while live sets pause -- and gives both halves of
# the gesture ONE shared predicate (step_ok).
#
# Three arms, one per place the feature lives:
#   check_frame_step_wiring.py  the seam AND THE PRIORITY. emu.sv has no bench, and
#                               the new arm's position in a priority mux over one
#                               register IS its semantics: it only ever SETS pause,
#                               so hoisted above a clear-only arm it turns a
#                               coincident resume into a stuck pause. A reordering
#                               changes no term, no port and no expression, so it is
#                               invisible to every other gate including a fit.
#   pickup_hold_tb   5a-5e      the datapath: one step_req = exactly ONE pickup,
#                               still paused after, a second press steps again, and
#                               (5e) a press while LIVE buys nothing and leaves no
#                               arm behind -- the executable form of "the pausing
#                               press must not also arm a step".
#   stop_ctl_tb                 the unregression: Stop's two stages and the
#                               pause/stop screensaver are untouched. stop_ctl owns
#                               stopped_w, which the new arm reads.
#
# --red applies one targeted mutation per claim and requires the assertion that owns
# the claim to fail:
#   M1  emu: the new arm deleted            -> A3/A6   (THE SHIPPED BEHAVIOUR)
#   M2  emu: arm hoisted above the B1 toggle-> A6 ordering
#   M3  emu: `else if` -> `if`              -> A5
#   M4  emu: !stopped_w dropped             -> A4
#   M5  emu: !hold_freeze dropped from step_ok -> A1
#   M6  emu: !menu_active -> menu_active    -> A2
#   M7  emu: (pause_q||stopped_w) dropped   -> A8
#   M8  emu: pause_q <= ~pause_q            -> A7
#   M9  emu: step arm uses an inline copy   -> A9
#   M10 emu: pause_gov loses pause_q        -> A11
#   M11 emu: hud_user_evt gains step_edge   -> A13
#   M12 emu: .step_req(step_tgl) (a LEVEL)  -> A12
#   N1  emu: step_session dropped           -> A14  (THE 20-FRAME LIMIT)
#   N2  emu: step_session not inverted      -> A14
#   N3  emu: session latched from step_edge -> A14
#   R13 rtl: step_arm cleared only if paused-> pickup_hold_tb 5e
#   R14 rtl: ofv_paced loses | step_arm     -> pickup_hold_tb 5b
#   R16 rtl: step_arm cleared on bare pickup_go -> pickup_hold_tb 5b/5c/5d
#   B15 bench: 5e's one-frame supply removed-> 5e must be RED on its own mutant
#
#   bench/dvd/run_frame_step.sh          # GREEN arms
#   bench/dvd/run_frame_step.sh --red    # GREEN + the mutation arms
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

pass()   { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; rc=1; }

iv() { iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -I dvd/ac3 -o "$1" "${@:2}"; }

# Apply a mutation and FAIL LOUDLY if it did not change the file. A sed that no
# longer matches (a rename, a re-wrap) silently produces an unmutated copy, the
# checker passes, and --red reports a gate that is proving nothing.
mut() {  # $1 = label, $2 = src, $3 = dst, $4.. = sed script(s)
    local label="$1" src="$2" dst="$3"; shift 3
    cp "$src" "$dst"
    local args=()
    for e in "$@"; do args+=(-e "$e"); done
    sed -i "${args[@]}" "$dst"
    if cmp -s "$src" "$dst"; then
        failed "$label: the mutation did not apply -- pattern stale, so this arm proves NOTHING"
        return 1
    fi
    return 0
}

# A mutated emu.sv must be REJECTED, and by the named assertion that owns it.
red_emu() {  # $1 = label, $2 = mutated file, $3 = assertion substring
    if python3 tools/check_frame_step_wiring.py "$2" > "$TMP/out" 2>&1; then
        failed "$1: the wiring check PASSED a mutated emu.sv"
        return
    fi
    if grep -qe "$3" "$TMP/out"; then
        pass "$1 -> caught by: $(grep -oe "$3" "$TMP/out" | head -1)"
    else
        failed "$1: rejected, but NOT by the assertion that owns it (wanted '$3')"
        sed -n '2,6p' "$TMP/out"
    fi
}

run_ph() {  # $1 = resample_addrgen.v to use, $2 = label, $3 = bench to use
    iv "$TMP/ph_$2" "$1" rtl/mpeg2/mem_addr.v "$3" > "$TMP/ph_$2.log" 2>&1 \
        || { failed "$2: pickup_hold_tb compile failed"; head -5 "$TMP/ph_$2.log"; return 2; }
    vvp "$TMP/ph_$2" > "$TMP/ph_$2.out" 2>&1
    grep -q "^PASS: pickup_hold" "$TMP/ph_$2.out"
}

echo "== GREEN =="
if python3 tools/check_frame_step_wiring.py > "$TMP/w.out" 2>&1; then
    pass "$(cat "$TMP/w.out")"
else
    failed "check_frame_step_wiring.py"; cat "$TMP/w.out"
fi

if run_ph dvd/resample_addrgen.v green bench/dvd/pickup_hold_tb.sv; then
    pass "pickup_hold_tb (5a-5e = the frame-step datapath)"
else
    failed "pickup_hold_tb"; grep -E "^  FAIL|^FATAL" "$TMP/ph_green.out" | head
fi
# Not vacuous: 5e must have run, and 5b must have stepped exactly one picture.
grep -q "\[5b\] one step = one pickup (consumed=5)" "$TMP/ph_green.out" \
    && pass "5b measured: one step_req = exactly one pickup" \
    || failed "5b did not measure a single-picture step"
grep -q "\[5e\] live: a step press costs nothing and leaves no arm" "$TMP/ph_green.out" \
    && pass "5e measured: a live step press buys nothing" \
    || failed "5e did not run"

if iv "$TMP/stop_sim" dvd/stop_ctl.sv bench/dvd/stop_ctl_tb.sv > "$TMP/stop.log" 2>&1 \
   && vvp "$TMP/stop_sim" > "$TMP/stop.out" 2>&1 \
   && grep -q "PASS" "$TMP/stop.out" && ! grep -q "FAIL" "$TMP/stop.out"; then
    pass "stop_ctl_tb (Stop's two stages + screensaver unregressed)"
else
    failed "stop_ctl_tb"; grep -iE "fail|error" "$TMP/stop.out" | head
fi

if [ "${1:-}" != "--red" ]; then
    [ $rc -eq 0 ] && echo "run_frame_step: PASS" || echo "run_frame_step: FAIL"
    exit $rc
fi

echo "== RED (emu.sv: the seam and the priority) =="
E=dvd/emu.sv

# M1 -- the arm deleted. This IS the behaviour the change replaces: B18 dead
# during playback. The gate must not be able to drift back to it silently.
mut M1 "$E" "$TMP/M1.sv" "/else if (step_edge && !pause_q && !stopped_w && step_ok) pause_q <= 1'b1;/d" \
    && red_emu "M1 new arm deleted (the shipped behaviour)" "$TMP/M1.sv" "this IS the shipped behaviour"

# M2 -- hoisted above the B1 toggle. Same terms, same ports; only the priority
# moved, which is the one edit no other gate in the tree can see.
python3 - "$E" "$TMP/M2.sv" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
arm = "        else if (step_edge && !pause_q && !stopped_w && step_ok) pause_q <= 1'b1;\n"
tog = "        else if (pause_edge && !stopped_w) pause_q <= ~pause_q;\n"
assert s.count(arm) == 1 and s.count(tog) == 1, "M2 anchors stale"
s = s.replace(arm, "")
# re-seat it directly ABOVE the B1 toggle, so it masks every clear arm below
s = s.replace(tog, arm + tog)
open(dst, 'w').write(s)
PY
if cmp -s "$E" "$TMP/M2.sv"; then failed "M2: the mutation did not apply"; else
    red_emu "M2 arm hoisted above the B1 toggle" "$TMP/M2.sv" "comes BEFORE this arm"
fi

mut M3 "$E" "$TMP/M3.sv" "s/else if (step_edge && !pause_q && !stopped_w && step_ok) pause_q <= 1'b1;/if (step_edge \&\& !pause_q \&\& !stopped_w \&\& step_ok) pause_q <= 1'b1;/" \
    && red_emu "M3 else-if -> bare if" "$TMP/M3.sv" "expected \`else if\`"

mut M4 "$E" "$TMP/M4.sv" "s/else if (step_edge && !pause_q && !stopped_w && step_ok)/else if (step_edge \&\& !pause_q \&\& step_ok)/" \
    && red_emu "M4 !stopped_w dropped" "$TMP/M4.sv" "missing stopped_w"

mut M5 "$E" "$TMP/M5.sv" "s/^wire step_ok = cell_ready && !menu_active && !hold_freeze;/wire step_ok = cell_ready \&\& !menu_active;/" \
    && red_emu "M5 !hold_freeze dropped from step_ok" "$TMP/M5.sv" "expected exactly"

mut M6 "$E" "$TMP/M6.sv" "s/^wire step_ok = cell_ready && !menu_active && !hold_freeze;/wire step_ok = cell_ready \&\& menu_active \&\& !hold_freeze;/" \
    && red_emu "M6 !menu_active -> menu_active" "$TMP/M6.sv" "is not INVERTED"

mut M7 "$E" "$TMP/M7.sv" "s/if (step_edge && (pause_q || stopped_w) && step_ok)/if (step_edge \&\& step_ok)/" \
    && red_emu "M7 (pause_q||stopped_w) dropped from the step arm" "$TMP/M7.sv" "frame-step step arm"

mut M8 "$E" "$TMP/M8.sv" "s/&& step_ok) pause_q <= 1'b1;/\&\& step_ok) pause_q <= ~pause_q;/" \
    && red_emu "M8 pause_q <= ~pause_q" "$TMP/M8.sv" "expected exactly 1"

mut M9 "$E" "$TMP/M9.sv" "s/if (step_edge && (pause_q || stopped_w) && step_ok)/if (step_edge \&\& (pause_q || stopped_w) \&\& cell_ready \&\& !menu_active)/" \
    && red_emu "M9 step arm uses an inline copy, not step_ok" "$TMP/M9.sv" "missing step_ok"

mut M10 "$E" "$TMP/M10.sv" "s/^wire pause_gov = pause_q | hold_freeze | stopped_w;/wire pause_gov = hold_freeze | stopped_w;/" \
    && red_emu "M10 pause_gov loses pause_q" "$TMP/M10.sv" "pause_gov"

mut M11 "$E" "$TMP/M11.sv" "s/^wire hud_user_evt = pause_edge/wire hud_user_evt = pause_edge | step_edge/" \
    && red_emu "M11 hud_user_evt gains step_edge" "$TMP/M11.sv" "must NOT contain step_edge"

mut M12 "$E" "$TMP/M12.sv" "s/\.step_req          (step_dec),/.step_req          (step_tgl),/" \
    && red_emu "M12 .step_req given a LEVEL" "$TMP/M12.sv" "mpeg2video .step_req"

# N1..N3 -- the VBUF refill seam. MEASURED on the rig 2026-09-16: with the audio
# backpressure frozen ARMED under pause, stepping got 17 frames and then died with
# vbuf_fill at 0; with the audio path out of the way, 35 presses gave 35 steps and
# vbuf_fill never moved. N1 is the shipped v0.6.0 behaviour.
mut N1 "$E" "$TMP/N1.sv" "s/&& aud_bp_armed && ~step_session);/\&\& aud_bp_armed);/" \
    && red_emu "N1 step_session dropped (the reported 20-frame limit)" "$TMP/N1.sv" "MEASURED at 17 on the rig"

mut N2 "$E" "$TMP/N2.sv" "s/&& aud_bp_armed && ~step_session);/\&\& aud_bp_armed \&\& step_session);/" \
    && red_emu "N2 step_session not inverted" "$TMP/N2.sv" "is not INVERTED"

mut N3 "$E" "$TMP/N3.sv" "s/else if (step_tgl ^ step_tgl_q)       step_session <= 1'b1;/else if (step_edge) step_session <= 1'b1;/" \
    && red_emu "N3 session latched from the raw press" "$TMP/N3.sv" "must NOT contain step_edge"

echo "== RED (resample_addrgen.v: the datapath) =="
A=dvd/resample_addrgen.v

red_ph() {  # $1 = label, $2 = mutated addrgen, $3 = expected failing assertion text
    if run_ph "$2" "$(echo "$1" | cut -d' ' -f1)" bench/dvd/pickup_hold_tb.sv; then
        failed "$1: pickup_hold_tb PASSED a mutated resample_addrgen"
    elif grep -q "$3" "$TMP/ph_$(echo "$1" | cut -d' ' -f1).out"; then
        pass "$1 -> caught by pickup_hold_tb: $3"
    else
        failed "$1: failed, but not on the arm that owns it (wanted '$3')"
        grep -E "^  FAIL" "$TMP/ph_$(echo "$1" | cut -d' ' -f1).out" | head -3
    fi
}

mut R13 "$A" "$TMP/R13.v" "s/else if (clk_en && (state == STATE_INIT) && pickup_go)    step_arm <= 1'b0;/else if (clk_en \&\& (state == STATE_INIT) \&\& pickup_go \&\& pause) step_arm <= 1'b0;/" \
    && red_ph "R13 step_arm cleared only while paused" "$TMP/R13.v" "phantom frame at the next pause"

mut R14 "$A" "$TMP/R14.v" "s/output_frame_valid & (frame_due | step_arm) &/output_frame_valid \& (frame_due) \&/" \
    && red_ph "R14 ofv_paced loses | step_arm" "$TMP/R14.v" "not advance exactly one picture"

mut R16 "$A" "$TMP/R16.v" "s/else if (clk_en && (state == STATE_INIT) && pickup_go)    step_arm <= 1'b0;/else if (clk_en \&\& pickup_go)    step_arm <= 1'b0;/" \
    && red_ph "R16 step_arm cleared on bare pickup_go" "$TMP/R16.v" "not advance exactly one picture"

echo "== RED (the bench's own 5e control) =="
# 5e is only meaningful because it offers EXACTLY ONE frame after the press. Remove
# that and the arm asserts that nothing happened when nothing was ever supplied --
# true for a broken RTL too.
mut B15 bench/dvd/pickup_hold_tb.sv "$TMP/B15.sv" "s/    supplied = consumed + 1;                \/\/ offer exactly ONE/    \/\/ [B15] supply removed/" \
    && { if run_ph dvd/resample_addrgen.v b15 "$TMP/B15.sv"; then
             failed "B15: 5e PASSED with its one-frame supply removed -- the arm is vacuous"
         else
             pass "B15 5e's one-frame supply removed -> 5e itself goes RED"
         fi; }

[ $rc -eq 0 ] && echo "run_frame_step: PASS (all mutations caught by their own assertion)" \
              || echo "run_frame_step: FAIL"
exit $rc
