#!/usr/bin/env bash
# Gate for "a sequence of authored HLI time windows must arm on the display
# schedule" (Scooby-Doo 2 whack-a-mole, 2026-09-14; docs/dvd_nav.md "A sequence
# of HLI windows is not a looping menu").
#
# nav_pci has ONE pending slot with an earliest-s_ptm-wins park policy, written
# for a LOOPING MENU that re-sends one HLI for ever. A disc that authors a
# SEQUENCE of windows breaks it: the armed set trailed the picture by up to
# ~1.5 s, so pressing the monster's own direction fired the previous window's
# miss command.
#
# Every arm presses a direction at a display time and checks WHICH COMMAND
# FIRED -- the thing the player experiences -- never a signal the fix names:
#   [A]  the reported case: the monster's direction +300 ms must HIT, three leads
#   [B]  latency: the earliest press that hits, per monster window (<= 100 ms)
#   [C]  a wrong direction must fire ITS OWN command
#   [D]  a press before a window must serve the window still on screen
#   [E]  a seek landing mid-window has only continuations to arm from
#   [E2] a LOST ss=1 while a DIFFERENT window is armed
#   [F]  hli_ss=3 ("same buttons, CHANGED commands") must take effect
#   [J]  a pending window must not be displaced by a later schedulable one
#        (the 2026-08-05 Matrix rule, which the fix must not undo)
#   [I]  CONTROL, not a gate: the same round entered with a low entry clock
#        answers a press from the start -- what makes [G]'s number readable
#   [G]  measures the known residual: a round's FIRST window is fallback-timed
#
# --red requires each mutation to fail EXACTLY the arms it should. A mutation
# caught by everything says nothing about which arm is load-bearing:
#   M1  arm_is_cont disabled (the continuation re-park is back)   -> F
#   M2  arm_is_cont ignores WHICH window is on screen             -> E2
#   M3  hli_ss=3 suppressed as well                               -> F
#   M4  sched_outranks disabled                                   -> A B
#   M5  sched_outranks without its !nxt_pre guard                 -> J
# ⚠ M1 and M3 share [F] by different routes (M1 lets continuation churn displace
# the late re-commit; M3 suppresses it outright). That is the honest result, not
# a tuned one -- the sets below were measured, then written down.
#
#   bench/dvd/run_hli_window.sh          # GREEN arms   (~30 s)
#   bench/dvd/run_hli_window.sh --red    # GREEN + the mutations (~3 min)
set -u
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

pass()   { echo "  ok   $1"; }
failed() { echo "  FAIL $1"; rc=1; }

# $1 = nav_pci.sv to use, $2 = label. Output lands in $TMP/$2.out.
run_tb() {
    iverilog -g2012 -o "$TMP/sim_$2" "$1" bench/dvd/hli_window_tb.sv > "$TMP/$2.log" 2>&1 \
        || { echo "  compile failed ($2)"; head "$TMP/$2.log"; return 2; }
    vvp "$TMP/sim_$2" > "$TMP/$2.out" 2>&1
    grep -q "HLI_WINDOW_TB: ALL TESTS PASSED" "$TMP/$2.out"
}

# the set of arm tags that reported an error, space-separated and sorted
arms_failed() {
    grep -o 'ERR \[[A-Z0-9]*' "$TMP/$1.out" 2>/dev/null \
        | sed 's/ERR \[//' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

echo "== GREEN"
if run_tb dvd/nav_pci.sv green; then
    pass "hli_window_tb over the real Scooby-Doo 2 whack-a-mole NAV packs"
    grep -E "^\[B\]|^\[G\]" "$TMP/green.out" | sed 's/^/       /'
else
    failed "hli_window_tb"
    grep -E "ERR|FAIL" "$TMP/green.out" | head
fi

# The bench must be looking at real disc data, not a silently-absent fixture.
if grep -q "MONSTER btn" "$TMP/green.out"; then
    pass "fixture present: $(grep -c 'MONSTER btn' "$TMP/green.out") monster window(s) parsed out of it"
else
    failed "fixture missing or unparsed -- the bench skipped (regen it, see the tb header)"
fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED (each mutation must fail EXACTLY its own arms)"
    # $1 label, $2 sed expression, $3 expected failing set
    red() {
        sed "$2" dvd/nav_pci.sv > "$TMP/$1.sv"
        if cmp -s dvd/nav_pci.sv "$TMP/$1.sv"; then
            failed "$1 mutation did not apply (the RTL moved under it): $2"; return
        fi
        run_tb "$TMP/$1.sv" "$1"
        if [ $? -eq 2 ]; then failed "$1 did not compile"; return; fi
        local got; got=$(arms_failed "$1")
        if [ "$got" = "$3" ]; then pass "$1 -> [$got]"
        else failed "$1 expected [$3], got [$got]"; fi
    }

    red M1 's/wire arm_is_cont = armed/wire arm_is_cont = 1'"'"'b0 \&\& armed/' "F"
    red M2 's/wire arm_is_cont = armed \&\& (f_ss == 2'"'"'d2) \&\& (f_sptm == h_sptm);/wire arm_is_cont = armed \&\& (f_ss == 2'"'"'d2);/' "E2"
    red M3 's/wire arm_is_cont = armed \&\& (f_ss == 2'"'"'d2) \&\& (f_sptm == h_sptm);/wire arm_is_cont = armed \&\& (f_ss != 2'"'"'d1) \&\& (f_sptm == h_sptm);/' "F"
    red M4 's/wire sched_outranks = nxt_v/wire sched_outranks = 1'"'"'b0 \&\& nxt_v/' "A B"
    red M5 's/wire sched_outranks = nxt_v \&\& !nxt_pre/wire sched_outranks = nxt_v/' "J"
fi

if [ $rc -eq 0 ]; then echo "run_hli_window: ALL GREEN"; else echo "run_hli_window: FAILED"; fi
exit $rc
