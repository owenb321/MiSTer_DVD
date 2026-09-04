#!/usr/bin/env bash
# Optional Docker wrapper for the Quartus build scripts. SOURCED by build_release.sh
# and tools/seed_sweep.sh. When USE_DOCKER=1 (and we're not already inside the
# container), re-exec the CALLING script inside the pinned Quartus 17.0.2 image with
# the repo bind-mounted at its real host path and the host UID/GID. No-op otherwise,
# so the same commands work in or out of the container:
#
#   USE_DOCKER=1 ./build_release.sh --compile
#   USE_DOCKER=1 SEEDS="7 11" ./tools/seed_sweep.sh DVD_foo
#
# Env knobs:
#   QUARTUS_DOCKER_IMAGE   image to use (default raetro/quartus:mister — Quartus
#                          17.0.2 Build 602, the version CLAUDE.md pins).
#
# Why it's built this way:
#   * SAME-PATH mount (-v REPO:REPO -w REPO): the scripts use relative paths AND
#     seed_sweep.sh has a hardcoded `cd <repo>`; mounting at the identical absolute
#     path makes both resolve in-container, and $0 in log lines stays meaningful.
#   * -u host UID/GID + HOME=/tmp: Quartus writes output_files/ db/ incremental_db/
#     into the repo — as root that leaves root-owned files that break the host
#     git/editor workflow. Run as the caller so artifacts stay host-owned. HOME=/tmp
#     is writable for Quartus's per-user scratch.
#   * IN_QUARTUS_DOCKER=1 exported into the container so a NESTED call
#     (seed_sweep.sh -> build_release.sh) runs natively instead of spawning a second
#     container.
#   * Memory is left UNBOUNDED — the fitter peaks ~6 GB; a low --memory OOM-kills it.
#   * SEEDS/FMAX_MIN/SWEEP_ALL/NOTIFY_* are forwarded so seed_sweep's env knobs and
#     notifications still work; positional args (--compile, NAME, ...) pass via "$@".
#   * GIT_* are resolved on the HOST and forwarded: the image may have no git, and
#     build_release.sh's provenance manifest needs branch/sha/dirty. QUARTUS_DOCKER_IMAGE
#     rides along so the manifest can record which image actually built the .rbf.

maybe_reexec_in_docker() {
    [ "${USE_DOCKER:-0}" = "1" ] || return 0        # opt-in only
    [ -n "${IN_QUARTUS_DOCKER:-}" ] && return 0      # already inside the container

    local self self_dir repo image
    self="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"   # absolutise the script path
    self_dir="$(dirname "$self")"
    repo="$(git -C "$self_dir" rev-parse --show-toplevel 2>/dev/null || echo "$self_dir")"
    image="${QUARTUS_DOCKER_IMAGE:-raetro/quartus:mister}"
    shift                                             # drop the script path; keep its args

    if ! command -v docker >/dev/null 2>&1; then
        echo "USE_DOCKER=1 but 'docker' is not on PATH." >&2
        exit 1
    fi

    # Git facts for the build provenance manifest (build_release.sh writes
    # <rbf>.json). Resolved HERE, on the host, because the Quartus image is not
    # guaranteed to carry a git binary and build_release.sh runs INSIDE it. Any
    # value already exported by the caller wins, so CI can inject its own.
    export GIT_BRANCH="${GIT_BRANCH:-$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
    export GIT_SHA="${GIT_SHA:-$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)}"
    export GIT_DIRTY="${GIT_DIRTY:-$([ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && echo true || echo false)}"

    echo ">> [docker] re-exec in ${image}  (repo ${repo}, uid $(id -u):$(id -g))" >&2
    echo ">> [docker] cancel with: docker stop quartus_$(basename "$self" .sh)_$$" >&2
    exec docker run --rm \
        --name "quartus_$(basename "$self" .sh)_$$" \
        -u "$(id -u):$(id -g)" \
        -e IN_QUARTUS_DOCKER=1 -e HOME=/tmp \
        -e SEEDS -e FMAX_MIN -e SWEEP_ALL -e FIT_TIMEOUT -e NOTIFY_URL -e NOTIFY_SILENT \
        -e GIT_BRANCH -e GIT_SHA -e GIT_DIRTY -e QUARTUS_DOCKER_IMAGE \
        -v "$repo":"$repo" -w "$repo" \
        "$image" "$self" "$@"
}
