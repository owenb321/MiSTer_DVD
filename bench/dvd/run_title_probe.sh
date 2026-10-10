#!/usr/bin/env bash
# run_title_probe.sh — the Title key on a disc with no Title menu (audit 10b).
#
# With Disc Menus on, the mount probes the VMGM for an entry-2 (Title) PGC before
# nav_ready rises; emu.sv drops the Title key without one (libdvdnav vm_jump_menu,
# DVD Demystified 3rd ed. p. 9-26). See docs/dvd_vm.md "Title key on a disc with no
# Title menu".
#
# GREEN: iso_reader_titleprobe_tb (arms A-H) + the reader benches that mount with a
#        VMGI and Disc Menus on (iso_reader_bup_tb, iso_reader_vm_tb,
#        iso_reader_fpnone_tb, iso_reader_vmgm_tb, iso_reader_lu_tb)
#        + tools/check_title_key_wiring.py --red (the emu.sv / Main seam)
# RED  : mutated copies of the reader. Each must fail exactly its own arms.
#   T1  no-ok-latch     : a found entry never sets title_ok     -> A D2 F H
#   T2  miss-is-ok      : an exhausted scan sets title_ok       -> B D
#   T3a err-noput       : no PGCI_UT raises pgc_error            -> C
#   T3b err-badut       : a bad PGCI_UT raises pgc_error         -> C2
#   T3c err-nr0         : an empty PGCIT raises pgc_error        -> C3
#   T3d nr0-final2      : an empty PGCIT takes the linear-title
#                         fallback (dom is TT during the probe)  -> C3
#   T4  vatr-in-probe   : the probe writes the menu aspect       -> A B C2 C3 D D2 F H
#   T5  nav-early       : nav_ready rises at S_FINALIZE          -> A B C C2 C3 D D2 F H
#   T6  no-lu-walk      : the probe takes LU[0], not the en unit -> D D2
#   T7  probe-always    : the probe runs with Disc Menus off     -> E
#   T8  malformed-not-ok: a malformed start hides the entry      -> H
#   T9  dom-vmgm        : the probe sets dom = VMGM              -> A B C C2 C3 D D2 F H
#   T10 bup-skip        : the probe's VMGI read is not gated     -> F
#   T11 no-finish       : S_DONE never raises nav_ready          -> A B C C2 C3 D D2 F G H
#   T12 probed-never    : vmgm_probed never set                  -> A B C C2 C3 D D2 F H
#   T13 jump-fallback   : a command jump's miss takes SRP[1]     -> G
#
# Usage: bench/dvd/run_title_probe.sh [--red]
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
RD="dvd/dvd_iso_reader.sv"
TB="bench/dvd/iso_reader_titleprobe_tb.sv"
OUT=".sim/title_probe"; mkdir -p "$OUT"
fail=0

# run <name> <pass-string> <tb> <rtl...>
run() {
    local name=$1 pass=$2 tb=$3; shift 3
    if iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$@" "$tb" 2>"$OUT/$name.build"; then
        if timeout 900 vvp -n "$OUT/$name" > "$OUT/$name.log" 2>&1 && grep -q "$pass" "$OUT/$name.log"; then
            echo "  PASS $name"
        else
            echo "  FAIL $name"; grep -E "FAIL|TIMEOUT|FATAL" "$OUT/$name.log" | head -20; fail=1
        fi
    else
        echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build" | head -20; fail=1
    fi
}

echo "== GREEN =="
run probe  "ISO_READER_TITLEPROBE_TB: ALL TESTS PASSED" $TB $RD
grep -E 'PASS$' "$OUT/probe.log" | sed 's/^/    /'
run bup    "ISO_READER_BUP_TB: ALL TESTS PASSED"    bench/dvd/iso_reader_bup_tb.sv $RD
run vm     "ISO_READER_VM_TB: ALL TESTS PASSED"     bench/dvd/iso_reader_vm_tb.sv $RD
run fpnone "ISO_READER_FPNONE_TB: ALL TESTS PASSED" bench/dvd/iso_reader_fpnone_tb.sv $RD
run vmgm   "ISO_READER_VMGM_TB: ALL TESTS PASSED"   bench/dvd/iso_reader_vmgm_tb.sv $RD
run lu     "ISO_READER_LU_TB: ALL TESTS PASSED"     bench/dvd/iso_reader_lu_tb.sv $RD
# emu.sv has no bench: the reader -> key gate -> telemetry -> Main seam is read out
# of the files
if python3 tools/check_title_key_wiring.py --red > "$OUT/wiring.log" 2>&1; then
    echo "  PASS check_title_key_wiring (+ its red self-test)"
else
    echo "  FAIL check_title_key_wiring"; sed 's/^/      /' "$OUT/wiring.log"; fail=1
fi

if [ $RED -eq 1 ]; then
    echo "== RED (each mutation must fail exactly its arms) =="
    # mutate <name> <expected arms> <perl -0 substitution>
    mutate() {
        local name=$1 want=$2 expr=$3
        local src="$OUT/$name.sv"
        perl -0pe "$expr" "$RD" > "$src"
        if cmp -s "$RD" "$src"; then
            echo "  FAIL $name: the substitution matched nothing (mutation is stale)"; fail=1; return
        fi
        if ! iverilog -g2012 -y dvd -Y .sv -o "$OUT/$name" "$src" "$TB" 2>"$OUT/$name.build"; then
            echo "  FAIL $name (build)"; sed 's/^/      /' "$OUT/$name.build" | head; fail=1; return
        fi
        timeout 900 vvp -n "$OUT/$name" > "$OUT/$name.log" 2>&1
        local got
        got=$(grep -oE "^FAIL [A-H][23]?[: ]" "$OUT/$name.log" | awk '{print $2}' | sed 's/:$//' \
              | sort -u | tr '\n' ' ' | sed 's/ $//')
        if [ "$got" = "$want" ]; then
            echo "  ok   $name -> fails [$got]"
        else
            echo "  FAIL $name: failed [$got], expected [$want]"; fail=1
        fi
    }
    ALLVM="A B C C2 C3 D D2 F H"
    mutate T1_no_ok_latch "A D2 F H" \
        's/vmgm_title_ok <= 1.b1;\n(\s*)state         <= S_DONE;/vmgm_title_ok <= 1\x27b0;\n$1state         <= S_DONE;/'
    mutate T2_miss_is_ok "B D" \
        's/state <= S_DONE;               \/\/ no Title entry/begin vmgm_title_ok <= 1\x27b1; state <= S_DONE; end/'
    mutate T3a_err_noput "C" \
        's/if \(!probe\) pgc_error <= 1.b1;     \/\/ probe: no PGCI_UT/pgc_error <= 1\x27b1;     \/\//'
    mutate T3b_err_badut "C2" \
        's/if \(!probe\) pgc_error <= 1.b1;     \/\/ probe: bad UT/pgc_error <= 1\x27b1;     \/\//'
    mutate T3c_err_nr0 "C3" \
        's/(if \(dom != DOM_TT \|\| probe\) begin[^\n]*\n\s*)if \(!probe\) pgc_error <= 1.b1;/${1}pgc_error <= 1\x27b1;/'
    mutate T3d_nr0_final2 "C3" \
        's/if \(dom != DOM_TT \|\| probe\) begin/if (dom != DOM_TT) begin/'
    mutate T4_vatr_in_probe "A B C2 C3 D D2 F H" \
        's/end else if \(probe\) begin(\n\s*\/\/ Title-entry probe: straight to the PGCI_UT)/end else if (1\x27b0) begin$1/'
    mutate T5_nav_early "$ALLVM" \
        's/nav_ready <= !\(vm_mode && vmgi_found\);/nav_ready <= 1\x27b1;/'
    mutate T6_no_lu_walk "D D2" \
        's/end else if \(ut_nr_lus == 16.d1\) begin/end else if (ut_nr_lus == 16\x27d1 || probe) begin/'
    mutate T7_probe_always "E" \
        's/if \(vm_mode && vmgi_found\) begin(\n\s*probe)/if (vmgi_found) begin$1/'
    mutate T8_malformed_not_ok "H" \
        's/if \(srp_entry_id\[7\] && srp_entry_id\[3:0\] == want_entry\) begin(\n\s*vmgm_title_ok)/if (srp_entry_id[7] \&\& srp_entry_id[3:0] == want_entry \&\& srp_pgc_start[31:21] == 11\x27d0) begin$1/'
    mutate T9_dom_vmgm "$ALLVM" \
        's/(\n(\s*)probe       <= 1.b1;)/$1\n$2dom         <= DOM_VMGM;/'
    mutate T10_bup_skip "F" \
        's/hdr_chk     <= HC_VMG;         \/\/ VMGI sector 0: header gate/hdr_chk     <= HC_NONE;/'
    mutate T11_no_finish "A B C C2 C3 D D2 F G H" \
        's/(vmgm_probed <= 1.b1;\n)\s*nav_ready   <= 1.b1;\n/$1/'
    mutate T12_probed_never "$ALLVM" \
        's/vmgm_probed <= 1.b1;/vmgm_probed <= 1\x27b0;/'
    mutate T13_jump_fallback "G" \
        's/(scan_mode  <= 1.b0;            \/\/ no entry match -> SRP\[0\]\n\s*scan_title <= 1.b0;\n\s*)srp_i      <= 16.d0;/${1}srp_i      <= 16\x27d1;/'
fi

if [ $fail -eq 0 ]; then
    echo "RUN_TITLE_PROBE: ALL PASS"
else
    echo "RUN_TITLE_PROBE: FAILURES"; exit 1
fi
