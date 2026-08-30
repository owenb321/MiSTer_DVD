#!/usr/bin/env bash
# Optional Docker wrapper for build_main.sh. SOURCED by build_main.sh. Mirrors the
# Quartus wrapper tools/docker_reexec.sh: when USE_DOCKER=1 (and not already inside
# the container), re-exec build_main.sh inside a pinned image that carries the exact
# ARM cross toolchain (gcc-arm 10.2-2020.11, arm-none-linux-gnueabihf), so no local
# toolchain install is needed and the binary is reproducible. No-op otherwise —
# the same command works in or out of Docker:
#
#   USE_DOCKER=1 ./main/build_main.sh
#
# Env knobs:
#   MAIN_DOCKER_IMAGE   image tag (default mister-dvd-main:gcc-arm-10.2). Built from
#                       main/docker/Dockerfile on first use, cached thereafter.
#
# Design mirrors the Quartus wrapper:
#   * SAME-PATH mount (-v REPO:REPO -w REPO) so relative paths and $0 resolve
#     identically in and out of the container.
#   * -u host UID/GID + HOME=/tmp so build artifacts under main/.build stay
#     host-owned (not root), and the toolchain's scratch is writable.
#   * IN_MAIN_DOCKER=1 guards against a nested re-exec.
#   * Network stays on (default) — build_main.sh git-clones stock Main inside.
#   * MAIN_MISTER_* / CROSS_COMPILE / BUILD_DIR forwarded so the knobs still work.

maybe_reexec_in_docker() {
    [ "${USE_DOCKER:-0}" = "1" ] || return 0          # opt-in only
    [ -n "${IN_MAIN_DOCKER:-}" ] && return 0           # already inside the container

    local self self_dir repo image dockerdir
    self="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    self_dir="$(dirname "$self")"
    repo="$(git -C "$self_dir" rev-parse --show-toplevel 2>/dev/null || echo "$self_dir")"
    image="${MAIN_DOCKER_IMAGE:-mister-dvd-main:gcc-arm-10.2}"
    dockerdir="$self_dir/docker"
    shift                                              # drop the script path; keep its args

    if ! command -v docker >/dev/null 2>&1; then
        echo "USE_DOCKER=1 but 'docker' is not on PATH." >&2
        exit 1
    fi

    # Build the pinned toolchain image on first use (downloads the ARM toolchain).
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo ">> [docker] building $image (first use — downloads the ARM toolchain)" >&2
        docker build -t "$image" "$dockerdir" >&2 || { echo ">> [docker] image build failed" >&2; exit 1; }
    fi

    echo ">> [docker] re-exec in ${image}  (repo ${repo}, uid $(id -u):$(id -g))" >&2
    echo ">> [docker] cancel with: docker stop mister_dvd_main_$$" >&2
    exec docker run --rm \
        --name "mister_dvd_main_$$" \
        -u "$(id -u):$(id -g)" \
        -e IN_MAIN_DOCKER=1 -e HOME=/tmp \
        -e MAIN_MISTER_REF -e MAIN_MISTER_URL -e MAIN_MISTER_SRC -e CROSS_COMPILE -e BUILD_DIR \
        -v "$repo":"$repo" -w "$repo" \
        "$image" "$self" "$@"
}
