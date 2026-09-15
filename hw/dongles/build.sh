#!/usr/bin/env bash
# Regenerate every dongle schematic and GATE it.  Nothing here is hand-drawn, so
# this is the only way the .kicad_sch, the netlist, the BOM and the PDF stay
# consistent with each other.
#
#   ./build.sh            regenerate + check
#   ./build.sh --red      also prove the gate can fail (mutation)
set -euo pipefail
cd "$(dirname "$0")"

need() { command -v "$1" >/dev/null || { echo "missing: $1"; exit 1; }; }
need python3
need kicad-cli

fail=0

gate() {           # gate <dir> <name>
  local d=$1 n=$2
  echo "== $n"
  ( cd tools && python3 "gen_${n}.py" >/dev/null )
  ( cd "$d" && kicad-cli sch export netlist --format kicadsexpr \
        -o netlist.net "$d.kicad_sch" >/dev/null )
  # kicad-cli prints nothing when clean and exits non-zero when not, so gate
  # on the report text rather than on stdout or the exit status.
  ( cd "$d" && kicad-cli sch erc --severity-error -o erc.rpt "$d.kicad_sch" \
        >/dev/null 2>&1 || true )
  if grep -qE "Errors 0\b" "$d/erc.rpt"; then
    echo "   ERC clean"
  else
    echo "   ERC FAILED - see $d/erc.rpt"
    grep -E "^\[" "$d/erc.rpt" | head -5
    fail=1
  fi
  ( cd tools && python3 "check_${n}.py" "../$d/netlist.net" ) \
      || { echo "   NETLIST GATE FAILED"; fail=1; }
  ( cd tools && python3 gen_bom.py "../$d/netlist.net" "../$d/bom.csv" )
  ( cd "$d" && kicad-cli sch export pdf -o "$d.pdf" "$d.kicad_sch" >/dev/null )
  echo "   wrote $d/$d.pdf, $d/bom.csv"
}

gate analog-5p1 analog

if [[ "${1:-}" == "--red" ]]; then
  echo
  echo "== RED: the gate must catch a swapped centre/LFE pair"
  cp tools/gen_analog.py /tmp/gen_analog.bak
  sed -i 's/("U2", "SD1", "FC", "LFE", "J3"/("U2", "SD1", "LFE", "FC", "J3"/' \
      tools/gen_analog.py
  ( cd tools && python3 gen_analog.py >/dev/null )
  ( cd analog-5p1 && kicad-cli sch export netlist --format kicadsexpr \
        -o /tmp/red.net analog-5p1.kicad_sch >/dev/null )
  if ( cd tools && python3 check_analog.py /tmp/red.net >/dev/null 2>&1 ); then
    echo "   RED ARM PASSED - the gate is vacuous!"
    fail=1
  else
    echo "   gate correctly rejected the swap"
  fi
  cp /tmp/gen_analog.bak tools/gen_analog.py
  ( cd tools && python3 gen_analog.py >/dev/null )
  ( cd analog-5p1 && kicad-cli sch export netlist --format kicadsexpr \
        -o netlist.net analog-5p1.kicad_sch >/dev/null )
fi

echo
[[ $fail -eq 0 ]] && echo "ALL GATES PASS" || { echo "FAILURES"; exit 1; }
