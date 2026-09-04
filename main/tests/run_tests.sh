#!/usr/bin/env bash
#
# run_tests.sh — host-side tests for the MiSTer_DVDcss overlay modules.
#
# These are ordinary native builds: no ARM toolchain, no MiSTer, no Docker. Each
# test #includes the module under test and stubs the rest of Main at link time,
# so it exercises the real logic rather than a paraphrase of it.
#
set -e
cd "$(dirname "$0")"

CXX="${CXX:-g++}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Stage the overlay where its own relative includes resolve. dvd_phys.cpp reaches
# for "../../user_io.h"; an EMPTY file there is deliberate -- the test defines the
# handful of Main functions it needs before including the module, so they are
# already in scope and there is no second copy of Main's API to drift out of date.
TREE="$OUT/tree"
mkdir -p "$TREE/support/dvd"
cp ../support/dvd/*.cpp ../support/dvd/*.h "$TREE/support/dvd/"
: > "$TREE/user_io.h"
: > "$TREE/menu.h"
: > "$TREE/video.h"
: > "$TREE/cfg.h"
: > "$TREE/hardware.h"

fail=0
for t in *_test.cpp; do
    n="${t%.cpp}"
    echo "### $n"
    "$CXX" -std=c++11 -Wall -Wno-unused-function -O0 -g \
        -I "$TREE/support/dvd" -o "$OUT/$n" "$t"
    "$OUT/$n" || fail=1
    echo
done

if [ "$fail" != 0 ]; then echo "main/tests: FAILURES"; exit 1; fi
echo "main/tests: ALL GREEN"
