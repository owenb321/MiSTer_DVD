#!/usr/bin/env bash
# run_es_stuff.sh -- dvd/es_stuff.sv: zero_byte stuffing at a keep_vbuf menu hop
#                    (docs/quant_matrix.md 13q)
#
#   (no args)   GREEN: bench/dvd/es_stuff_tb.sv + the emu wiring check
#   --red       GREEN, then the mutation check: each mutated copy of the module
#               must FAIL the bench (a level/count bench is exactly the shape that
#               passes without proving anything -- the mutations are the proof)
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
            echo "  $name: FAILED as expected -- $(echo "$out" | grep -E 'FAIL' | head -1)"
        else
            echo "  $name: FAIL"; echo "$out" | grep -E 'FAIL|ok' | sed 's/^/      /'; rc=1
        fi
    fi
}

echo "== es_stuff_tb (GREEN) =="
build_run "es_stuff_tb" 1 dvd/es_stuff.sv bench/dvd/es_stuff_tb.sv
echo "== emu wiring (the seam has no bench) =="
python3 tools/check_es_stuff_wiring.py || rc=1

if [ "${1:-}" = "--red" ]; then
    echo "== es_stuff.sv mutation check (each must be caught) =="
    python3 - "$ROOT" "$TMP" <<'PY'
import os, subprocess, sys
root, tmp = sys.argv[1], sys.argv[2]
src = open(os.path.join(root, "dvd/es_stuff.sv")).read()
MUT = [
 ("M1 spend without waiting for the pipe reset (rst_seen dropped)",
  "wire start = armed && rst_seen && pipe_rst_n && in_valid && ~run;",
  "wire start = armed && pipe_rst_n && in_valid && ~run;"),
 ("M2 the start cycle does not count (N+1 zeros)",
  "cnt      <= out_ready ? N[CW-1:0] - 1'b1 : N[CW-1:0];",
  "cnt      <= N[CW-1:0];"),
 ("M3 input not held during the run (landing byte leaks/lost)",
  "assign in_ready  = out_ready & ~stuff;",
  "assign in_ready  = out_ready;"),
 ("M4 the landing byte passes before the run (start not in the mux)",
  "wire stuff = run || start;",
  "wire stuff = run;"),
 ("M5 zeros not paced by the sink (dropped under backpressure)",
  "end else if (run && out_ready) begin",
  "end else if (run) begin"),
 ("M6 the run carries the input instead of zeros",
  "assign out_data  = stuff ? 9'h000 : {in_mark, in_byte};",
  "assign out_data  = {in_mark, in_byte};"),
 ("M7 a second arm during a run is lost",
  """            if (arm) begin
                armed    <= 1'b1;
                rst_seen <= 1'b0;
            end""",
  """            if (arm && !run) begin
                armed    <= 1'b1;
                rst_seen <= 1'b0;
            end"""),
]
bad = 0
for name, old, new in MUT:
    if src.count(old) != 1:
        print(f"  {name}: MUTATION ANCHOR NOT FOUND (count={src.count(old)}) -- fix the runner"); bad += 1; continue
    path = os.path.join(tmp, "mut.sv")
    open(path, "w").write(src.replace(old, new))
    r = subprocess.run(["iverilog", "-g2012", "-o", os.path.join(tmp, "msim"),
                        path, os.path.join(root, "bench/dvd/es_stuff_tb.sv")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  {name}: DOES NOT COMPILE -- not a valid mutation"); bad += 1; continue
    out = subprocess.run(["vvp", os.path.join(tmp, "msim")], capture_output=True, text=True).stdout
    if "PASS: es_stuff_tb" in out:
        print(f"  {name}: *** SURVIVED ***"); bad += 1
    else:
        first = next((l for l in out.splitlines() if "FAIL" in l), "(no FAIL line)")
        print(f"  {name}: caught -- {first.strip()}")
sys.exit(1 if bad else 0)
PY
    [ $? -eq 0 ] || rc=1
fi

[ "$rc" -eq 0 ] && echo "== es_stuff: OK ==" || echo "== es_stuff: FAIL =="
exit $rc
