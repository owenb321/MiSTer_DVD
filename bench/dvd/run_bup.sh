#!/usr/bin/env bash
# run_bup.sh — the IFO header gate and .BUP fallback (audit item 8).
#
# An IFO whose sector 0 lacks "DVDVIDEO-VMG"/"DVDVIDEO-VTS" is re-read from its
# .BUP (libdvdnav's ifoOpenVMGI/ifoOpenVTSI rule); a bad BUP, or none, leaves the
# IFO parsed exactly as before. See docs/dvd_nav.md "IFO header gate and .BUP
# fallback".
#
# GREEN: iso_reader_bup_tb (arms A-I) + the reader benches that share the gated
#        reads: iso_reader_tmap_tb, iso_reader_vmgm_tb, iso_reader_ifo_tb,
#        iso_reader_vm_tb
#        + tools/check_bup_wiring.py --red (the emu.sv / Main telemetry seam)
# RED  : mutated copies of the reader. Each must fail exactly its own arms.
#   R1  no-compare     : the magic compare never fires          -> B C D E F G H I
#   R2  bup0           : the "a BUP exists" guard is dropped    -> E (reads LBA 0)
#   R3  pend-any       : a pending BUP joins any VTS's group    -> E
#   R4  gmem-slice     : gq_bup_lba sliced from the wrong field -> D I
#   R5  retry-ifo      : the retry re-reads the IFO, not the BUP-> B C D F G H I
#   R6a no-commit-vmg  : the VMGI base stays on the IFO         -> C
#   R6b no-commit-best : the Auto title base stays on the IFO   -> B G H
#   R6c no-commit-mnu  : the VTSM base stays on the IFO         -> D
#   R7  no-revert      : a bad BUP is parsed instead of the IFO -> F
#   R8  ten-bytes      : only magic bytes 0-9 compared          -> F G H
#   R9  any-kind       : a VTS IFO may carry the VMG letters    -> H
#   R10 chk-stuck      : hdr_chk not cleared at completion      -> A B C D E G H I
#                        (F's revert clears it itself. E joined with audit 10b: its
#                        menus-on mount now runs the Title-entry probe, whose VMGI
#                        read leaves the gate stuck at HC_VMG, so the probe's next
#                        read -- the PGCI_UT, no magic -- swaps to VIDEO_TS.BUP)
#   R11a no-flag-vmg   : ifo_bup_vmg never set                  -> C
#   R11b no-flag-vts   : ifo_bup_vts never set                  -> B D G H I
#   R11c no-flag-nobup : ifo_nogood not set when there is no BUP-> E
#   R11d no-flag-rev   : ifo_nogood not set on a revert         -> F
#
# Usage: bench/dvd/run_bup.sh [--red]
set -u
cd "$(dirname "$0")/../.."
RED=0; [ "${1:-}" = "--red" ] && RED=1
RD="dvd/dvd_iso_reader.sv"
TB="bench/dvd/iso_reader_bup_tb.sv"
OUT=".sim/bup"; mkdir -p "$OUT"
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
run bup   "ISO_READER_BUP_TB: ALL TESTS PASSED"  $TB $RD
grep -E 'PASS$' "$OUT/bup.log" | sed 's/^/    /'
run tmap  "ISO_READER_TMAP_TB: ALL TESTS PASSED" bench/dvd/iso_reader_tmap_tb.sv $RD
run vmgm  "ISO_READER_VMGM_TB: ALL TESTS PASSED" bench/dvd/iso_reader_vmgm_tb.sv $RD
run ifo   "ISO_READER_IFO_TB: ALL TESTS PASSED"  bench/dvd/iso_reader_ifo_tb.sv $RD
run vm    "ISO_READER_VM_TB: ALL TESTS PASSED"   bench/dvd/iso_reader_vm_tb.sv $RD
# (iso_reader_atmos_tb, a real VMGI/VTSI with BUPs, is NOT run here: it fails on
#  main too -- "PGC13 not loaded" -- so it cannot gate this. run_reader_regress.sh
#  proves this branch leaves its trace bit-identical.)
# emu.sv has no bench: the reader -> telemetry -> Main seam is read out of the files
if python3 tools/check_bup_wiring.py --red > "$OUT/wiring.log" 2>&1; then
    echo "  PASS check_bup_wiring (+ its red self-test)"
else
    echo "  FAIL check_bup_wiring"; sed 's/^/      /' "$OUT/wiring.log"; fail=1
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
        got=$(grep -oE "^FAIL [A-I]:" "$OUT/$name.log" | awk '{print $2}' | sed 's/:$//' \
              | sort -u | tr '\n' ' ' | sed 's/ $//')
        if [ "$got" = "$want" ]; then
            echo "  ok   $name -> fails [$got]"
        else
            echo "  FAIL $name: failed [$got], expected [$want]"; fail=1
        fi
    }
    mutate R1_no_compare "B C D E F G H I" \
        's/if \(hdr_byte_bad\) hdr_bad <= 1.b1;/if (1\x27b0) hdr_bad <= 1\x27b1;/'
    mutate R2_bup0 "E" \
        's/hdr_bad && !hdr_try &&\n(\s*)hdr_bup != 32.d0 && /hdr_bad \&\& !hdr_try \&\&\n$1/'
    mutate R3_pend_any "E" \
        's/grp_bup_lba <= \(pending_bup_vts == vts_num\) \? pending_bup_lba : 32.d0;/grp_bup_lba <= pending_bup_lba;/'
    mutate R4_gmem_slice "D I" \
        's/gq_bup_lba = gmem_q\[31:0\];/gq_bup_lba = gmem_q[63:32];/'
    mutate R5_retry_ifo "B C D F G H I" \
        's/sec_base     <= hdr_bup;/sec_base     <= sec_base;/'
    mutate R6a_no_commit_vmg "C" \
        's/HC_VMG: vmgi_lba    <= sec_base;/HC_VMG: ;/'
    mutate R6b_no_commit_best "B G H" \
        's/else           best_ifo_lba <= sec_base;/else           best_ifo_lba <= best_ifo_lba;/'
    mutate R6c_no_commit_mnu "D" \
        's/HC_MNU: jmp_ifo_lba <= sec_base;/HC_MNU: ;/'
    mutate R7_no_revert "F" \
        's/else if \(sd_ack_d && !sd_ack && hdr_bad && hdr_try\)/else if (1\x27b0)/'
    mutate R8_ten_bytes "F G H" \
        's/hdr_ba < 4.d12 &&/hdr_ba < 4\x27d10 \&\&/'
    mutate R9_any_kind "H" \
        's/sd_buff_dout != hdr_exp;/sd_buff_dout != hdr_exp \&\& !(hdr_ba >= 4\x27d10 \&\& (sd_buff_dout == "M" || sd_buff_dout == "G"));/'
    mutate R10_chk_stuck "A B C D E G H I" \
        's/(ifo_nogood <= 1.b1;       \/\/ header bad, no .BUP to try\n\s*)hdr_chk      <= HC_NONE;/$1/'
    mutate R11a_no_flag_vmg "C" \
        's/if \(hdr_vmg\) ifo_bup_vmg <= 1.b1;/if (hdr_vmg) ifo_bup_vmg <= 1\x27b0;/'
    mutate R11b_no_flag_vts "B D G H I" \
        's/else         ifo_bup_vts <= 1.b1;/else         ifo_bup_vts <= 1\x27b0;/'
    mutate R11c_no_flag_nobup "E" \
        's/ifo_nogood <= 1.b1;       \/\/ header bad, no .BUP to try/ifo_nogood <= 1\x27b0;/'
    mutate R11d_no_flag_rev "F" \
        's/sec_base     <= hdr_own;\n(\s*)ifo_nogood   <= 1.b1;/sec_base     <= hdr_own;\n$1ifo_nogood   <= 1\x27b0;/'
fi

if [ $fail -eq 0 ]; then
    echo "RUN_BUP: ALL PASS"
else
    echo "RUN_BUP: FAILURES"; exit 1
fi
