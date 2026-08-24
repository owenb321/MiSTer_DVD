#!/usr/bin/env bash
# =============================================================================
# build_dvd_trace.sh -- build the libdvdnav golden-trace oracle(s)
# =============================================================================
# Phase 2 of the conformance plan (docs/conformance.md), deliverable B.
#
# libdvdnav is our layer-1 reference (a *hypothesis to verify*, not the spec --
# see docs/conformance.md). Its VM produces a verbose per-block TRACE of the
# First-Play -> menu/title boot path; that trace is the golden diff target for
# our own VM boot model (tools/dvd_vm_ref.py) and, ultimately, dvd/dvd_vm.sv.
#
# The tracer SOURCES we authored live in this repo at tools/dvd_trace/*.c
# (mirrored from the libdvdnav checkout's examples/, which is untracked). They
# are NOT wired into libdvdnav's meson build, so this script compiles them
# directly against the already-built static libs. If a source is missing from
# tools/dvd_trace/ it falls back to $DVD_REPOS/libdvdnav/examples/.
#
# Prereqs (one-time, already done in this workspace):
#   cd $DVD_REPOS/libdvdread && meson setup build && ninja -C build
#   cd $DVD_REPOS/libdvdnav  && meson setup build && ninja -C build
#
# Usage:
#   tools/build_dvd_trace.sh                 # build all tracers -> tools/bin/
#   tools/build_dvd_trace.sh <iso>           # build, then run trace_boot on <iso>
#
# Override the repo location with DVD_REPOS=/path (default below).
# =============================================================================
set -euo pipefail

DVD_REPOS="${DVD_REPOS:-$DVD_REPOS}"
NAV="$DVD_REPOS/libdvdnav"
READ="$DVD_REPOS/libdvdread"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRCDIR="$HERE/dvd_trace"                 # in-repo tracer sources (source of truth)
OUT="$HERE/bin"

NAV_LIB="$NAV/build/src/libdvdnav.a"
READ_LIB="$READ/build/src/libdvdread.a"

for lib in "$NAV_LIB" "$READ_LIB"; do
  if [[ ! -f "$lib" ]]; then
    echo "ERROR: $lib not found -- build libdvdnav/libdvdread first:" >&2
    echo "  cd ${lib%/build/*} && meson setup build && ninja -C build" >&2
    exit 1
  fi
done

DVDCSS_LIBS="$(pkg-config --libs dvdcss 2>/dev/null || echo -ldvdcss)"
mkdir -p "$OUT"

build_one() {
  local src="$SRCDIR/$1.c"
  [[ -f "$src" ]] || src="$NAV/examples/$1.c"        # fallback to the checkout
  [[ -f "$src" ]] || { echo "skip: $1.c not present"; return; }
  echo "cc  $1"
  gcc -O2 -o "$OUT/$1" "$src" \
      -I "$NAV/src" -I "$READ/src" -I "$READ/src/dvdread" \
      "$NAV_LIB" "$READ_LIB" $DVDCSS_LIBS
}

build_one trace_boot
build_one trace_menukey
build_one trace_menuearly
build_one trace_nav

echo "built -> $OUT/"

if [[ $# -ge 1 ]]; then
  echo
  echo "=== trace_boot $1 ==="
  # libdvdread spams CSS-key lines to stderr; keep only the VM/nav trace.
  "$OUT/trace_boot" "$1" 2>/dev/null
fi
