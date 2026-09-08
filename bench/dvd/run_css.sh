#!/usr/bin/env bash
# run_css.sh -- CSS-scramble detection suite (issue #59).
#
#   (no args)   GREEN: the density verdict + the pack-framing filter
#   --red       RED:   the same scramble bench against the PRE-FIX ps_demux, which
#                      must FAIL, and the mutation check on css_detect.sv
#   --mutate    just the mutation check
#
# The RED arm rebuilds the pre-fix demux out of git rather than keeping a frozen
# copy in the tree: the filter has no runtime switch, so "run the old RTL" is the
# only honest way to show the defect, and doing it from history keeps it
# reproducible from the repo alone. That build needs -DNO_HDR_OK because the
# pre-fix module has no denominator port.
set -u
cd "$(dirname "$0")/../.."
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

build_run() { # name  expect_pass(0/1)  sources...
    local name=$1 want=$2; shift 2
    if ! iverilog -g2012 -o "$TMP/sim" "$@" 2>"$TMP/err"; then
        echo "  $name: COMPILE FAILED"; sed -n '1,5p' "$TMP/err"; rc=1; return
    fi
    local out; out=$(vvp "$TMP/sim" 2>&1)
    if echo "$out" | grep -q '^PASS'; then
        if [ "$want" = 1 ]; then echo "  $name: PASS"
        else echo "  $name: *** PASSED but should have FAILED ***"; rc=1; fi
    else
        if [ "$want" = 0 ]; then
            echo "  $name: FAILED as expected --"
            echo "$out" | grep -E 'FAIL|pulses=' | sed 's/^/      /'
        else
            echo "  $name: FAIL"; echo "$out" | tail -20 | sed 's/^/      /'; rc=1
        fi
    fi
}

mutate() {
    echo "== css_detect.sv mutation check (each must be caught) =="
    python3 - "$ROOT" <<'PY'
import os, subprocess, sys, tempfile
root = sys.argv[1]
src = open(os.path.join(root, "dvd/css_detect.sv")).read()
tmp = tempfile.mkdtemp()
MUT = [
 ("M1 leak deleted", "if (bucket != '0) bucket <= bucket - 1'b1;", ""),
 ("M2 leak on every clean header",
  "end else if (leak_cnt == LEAK_W'(LEAK_CLEAN - 1)) begin", "end else if (1'b1) begin"),
 ("M3 latch at 4, not LATCH_HITS",
  "bucket == BUCKET_W'(LATCH_HITS - 1)", "bucket == BUCKET_W'(4 - 1)"),
 ("M4 hdr_ok qualifier dropped",
  "end else if (hdr_ok) begin", "end else if (hdr_ok || scrambled) begin"),
 ("M5 verdict released when the bucket empties (not sticky)",
  """    end else if (css_scrambled) begin
        // Latched: hold everything. The verdict cannot be revisited until the media
        // changes (see the anti-flap note in the header).""",
  """    end else if (css_scrambled) begin
        if (hdr_ok && !scrambled) begin
            if (leak_cnt == LEAK_W'(LEAK_CLEAN - 1)) begin
                leak_cnt <= '0;
                if (bucket != '0) bucket <= bucket - 1'b1;
                else css_scrambled <= 1'b0;
            end else leak_cnt <= leak_cnt + 1'b1;
        end"""),
 ("M6 mount clear dropped", "end else if (mount || eject) begin", "end else if (eject) begin"),
 ("M7 latch off by one",
  "bucket == BUCKET_W'(LATCH_HITS - 1)", "bucket == BUCKET_W'(LATCH_HITS - 2)"),
 ("M8 leak_cnt reset on a clean header, not a hit",
  """            leak_cnt <= '0;
            if (bucket == BUCKET_W'(LATCH_HITS - 1)) css_scrambled <= 1'b1;""",
  """            if (bucket == BUCKET_W'(LATCH_HITS - 1)) css_scrambled <= 1'b1;"""),
]
rc = 0
for name, old, new in MUT:
    if src.count(old) != 1:
        print("  %-56s ANCHOR MOVED" % name); rc = 1; continue
    open(tmp + "/mut.sv", "w").write(src.replace(old, new, 1))
    if subprocess.run(["iverilog", "-g2012", "-o", tmp + "/sim", tmp + "/mut.sv",
                       root + "/bench/dvd/css_detect_tb.sv"], capture_output=True).returncode:
        print("  %-56s DID NOT COMPILE" % name); rc = 1; continue
    out = subprocess.run(["vvp", tmp + "/sim"], capture_output=True, text=True).stdout
    if any(l.startswith("PASS") for l in out.splitlines()):
        print("  %-56s *** SURVIVED ***" % name); rc = 1
    else:
        arms = sorted({w for l in out.splitlines() if "FAIL" in l
                         for w in l.split() if w.startswith("A") and w[1:].isdigit()})
        print("  %-56s caught by %s" % (name, " ".join(arms)))
sys.exit(rc)
PY
    [ $? -ne 0 ] && rc=1
}

case "${1:-}" in
--mutate)
    mutate
    ;;
--red)
    echo "== RED: the pre-fix demux must fail the pack-framing arms =="
    # The commit that introduced the filter; its parent is the pre-fix RTL.
    fix=$(git log --format=%H -1 -S pack_fresh -- dvd/ps_demux.sv)
    if [ -z "$fix" ]; then echo "  cannot locate the fix commit"; exit 1; fi
    git show "$fix^:dvd/ps_demux.sv" > "$TMP/ps_demux_prefix.sv"
    if ! iverilog -g2012 -DNO_HDR_OK -o "$TMP/red" "$TMP/ps_demux_prefix.sv" \
            bench/dvd/ps_demux_scram_tb.sv 2>"$TMP/err"; then
        echo "  COMPILE FAILED"; sed -n '1,5p' "$TMP/err"; exit 1
    fi
    out=$(vvp "$TMP/red" 2>&1)
    if echo "$out" | grep -q '^PASS'; then
        echo "  *** the pre-fix demux PASSED -- the bench does not prove anything ***"; rc=1
    else
        echo "  pre-fix demux FAILED as expected:"
        echo "$out" | grep -E 'FAIL T|T2 |T4 ' | sed 's/^/      /'
    fi
    echo
    mutate
    ;;
*)
    echo "== GREEN =="
    build_run "css_detect_tb   (density verdict)" 1 dvd/css_detect.sv bench/dvd/css_detect_tb.sv
    build_run "ps_demux_scram_tb (pack framing)" 1 dvd/ps_demux.sv bench/dvd/ps_demux_scram_tb.sv
    ;;
esac

[ $rc -eq 0 ] && echo "ALL GREEN" || echo "FAILURES"
exit $rc
