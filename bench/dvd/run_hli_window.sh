#!/usr/bin/env bash
# Gate for "a sequence of authored HLI time windows must arm on the display
# schedule" (Scooby-Doo 2 whack-a-mole, 2026-09-14; docs/dvd_nav.md "A sequence
# of HLI windows is not a looping menu").
#
# nav_pci's promotion machinery was written for a LOOPING MENU that re-sends one
# HLI for ever. A disc that authors a SEQUENCE of windows -- each making ONE
# direction a hit and the other three a miss -- breaks it four ways, so the
# armed button set trailed (or ran ahead of) the picture and a correct press
# fired the wrong window's command.
#
# Every arm presses a direction at a display time and checks WHICH COMMAND
# FIRED -- the thing the player experiences -- never a signal the fix names:
#   [A]  the reported case: the monster's direction +300 ms must HIT, three leads
#   [B]  latency: the earliest press that hits, per monster window (<= 100 ms)
#   [C]  a wrong direction must fire ITS OWN command
#   [D]  a press BEFORE a window must serve the window still on screen, swept
#        over the lead -- the long one is what catches an early promotion
#   [E]  a seek landing mid-window has only continuations to arm from
#   [E2] a LOST ss=1 while a DIFFERENT window is armed
#   [F]  hli_ss=3 ("same buttons, CHANGED commands") must take effect
#   [J]  a pending window must not be displaced by a later schedulable one
#        (the 2026-08-05 Matrix rule, which the fix must not undo)
#   [I]  CONTROL, not a gate: the same round entered with a low entry clock
#        answers a press from the start -- what makes [G]'s number readable
#   [G]  measures the known residual: a round's FIRST window is fallback-timed
#
# nav_pci_tb runs too: this change touches the promotion timer, which every disc
# MENU depends on, so the menu suite is part of the gate rather than a separate
# chore. It is also the arm that owns the future-pending HORIZON (its T7 parks a
# pending 28.7 s ahead and requires the timer to rescue it).
#
# --red requires each mutation to fail EXACTLY the arms it should. A mutation
# caught by everything says nothing about which arm is load-bearing:
#   M1  arm_is_cont disabled (the continuation re-park is back)   -> F
#   M2  arm_is_cont ignores WHICH window is on screen             -> E2
#   M3  hli_ss=3 suppressed as well                               -> F
#   M4  sched_outranks disabled                                   -> A B F
#   M5  sched_outranks without its !nxt_pre guard                 -> J
#   M6  the second pending stage never filled                     -> A
#   M7  the future-pending guard disabled (early promotion)       -> D
#   M8  a window may sit in both the head and the queue           -> F
#   M9  the future guard unbounded (waits for ever)               -> nav_pci_tb
# ⚠ Several mutations land on [F]. That is measured, not tuned: [F] presses late
# in a long window, which is where a lost or duplicated commit shows up, and the
# three routes to it are genuinely different (re-park churn, outright
# suppression, a duplicate shifting back in).
#
#   bench/dvd/run_hli_window.sh          # GREEN arms   (~40 s)
#   bench/dvd/run_hli_window.sh --red    # GREEN + the mutations (~7 min)
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

# the menu regression suite, against the same nav_pci
run_menu() {
    iverilog -g2012 -o "$TMP/menu_$2" "$1" bench/dvd/nav_pci_tb.sv > "$TMP/$2.mlog" 2>&1 \
        || { echo "  compile failed ($2, nav_pci_tb)"; head "$TMP/$2.mlog"; return 2; }
    vvp "$TMP/menu_$2" > "$TMP/$2.mout" 2>&1
    grep -q "NAV_PCI_TB: ALL TESTS PASSED" "$TMP/$2.mout"
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

if run_menu dvd/nav_pci.sv green; then
    pass "nav_pci_tb (the menu suite: this change touches the promotion timer)"
else
    failed "nav_pci_tb"
    grep -E "ERR" "$TMP/green.mout" | head
fi

# The bench must be looking at real disc data, not a silently-absent fixture.
if grep -q "MONSTER btn" "$TMP/green.out"; then
    pass "fixture present: $(grep -c 'MONSTER btn' "$TMP/green.out") monster window(s) parsed out of it"
else
    failed "fixture missing or unparsed -- the bench skipped (regen it, see the tb header)"
fi

if [ "${1:-}" = "--red" ]; then
    echo "== RED (each mutation must fail EXACTLY its own arms)"
    # $1 label, $2 sed expression, $3 expected failing set ("menu" = nav_pci_tb)
    red() {
        sed "$2" dvd/nav_pci.sv > "$TMP/$1.sv"
        if cmp -s dvd/nav_pci.sv "$TMP/$1.sv"; then
            failed "$1 mutation did not apply (the RTL moved under it): $2"; return
        fi
        if [ "$3" = "menu" ]; then
            run_menu "$TMP/$1.sv" "$1"
            case $? in
              2) failed "$1 did not compile" ;;
              1) pass "$1 -> nav_pci_tb red" ;;
              *) failed "$1 expected nav_pci_tb to go red, it passed" ;;
            esac
            return
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
    red M4 's/wire sched_outranks = nxt_v/wire sched_outranks = 1'"'"'b0 \&\& nxt_v/' "A B F"
    red M5 's/wire sched_outranks = nxt_v \&\& !nxt_pre/wire sched_outranks = nxt_v/' "J"
    red M6 's/end else if (!arm_is_cont \&\& nxt_v \&\&/end else if (1'"'"'b0 \&\& !arm_is_cont \&\& nxt_v \&\&/' "A"
    red M7 's/wire nxt_future   = stc_trusted/wire nxt_future   = 1'"'"'b0 \&\& stc_trusted/' "D"
    red M8 's/if (nx2_v \&\& f_sptm == nx2_sptm) nx2_v <= 1'"'"'b0;/\/\/ M8 dedupe removed/' "F"
    red M9 's/(nxt_ahead < FUTURE_HORIZON);/(1'"'"'b1);/' "menu"
fi

if [ $rc -eq 0 ]; then echo "run_hli_window: ALL GREEN"; else echo "run_hli_window: FAILED"; fi
exit $rc
