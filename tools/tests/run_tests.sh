#!/usr/bin/env bash
# Host-side tests for the HIL harness. No hardware, no MiSTer, no Docker.
set -u
cd "$(dirname "$0")/../.."
fail=0
for t in tools/tests/test_*.py; do
    if python3 "$t" 2>&1 | tee /tmp/hiltest.log | grep -q "ALL GREEN"; then
        echo "PASS $(basename "$t")"
    else
        echo "FAIL $(basename "$t")"; tail -20 /tmp/hiltest.log; fail=1
    fi
done
[ $fail = 0 ] && echo "tools/tests: ALL GREEN" || echo "tools/tests: FAILURES"
exit $fail
