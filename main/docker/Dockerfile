# Pinned build image for MiSTer_DVDcss — the same ARM cross toolchain the local
# build uses (gcc-arm 10.2-2020.11, arm-none-linux-gnueabihf), baked in so the
# Docker build is self-contained and reproducible. Mirrors the Quartus 17.0.2
# pinned-image approach (see tools/docker_reexec.sh).
#
# Build:  docker build -t mister-dvd-main:gcc-arm-10.2 main/docker
# (build_main.sh builds it automatically on first USE_DOCKER=1 run.)
#
# ⚠ The BASE is bookworm, not bullseye, since 2026-09-10: bullseye went EOL and its
# security repo's InRelease EXPIRED, so `apt-get update` started failing with exit 100
# and the v0.5.0 release packaging broke on it. The base distro only supplies wget /
# make / git / python3 — the ARM cross-compiler below is a self-contained pinned
# tarball, so it is NOT the codegen pin and bumping it does not re-roll the binary.
# MEASURED at the time of the bump, because "the base cannot matter" deserved a
# number: bullseye and bookworm builds differ in exactly 2-3 bytes, all inside the
# 4-byte window at offset ~971614 -- and TWO BULLSEYE BUILDS DIFFER THE SAME WAY.
# The window is dvd_report's embedded __TIME__ ("--- dvd_report built Sep 10 2026
# 17:56:58 ---"), i.e. a build clock, not codegen. Sizes identical (1,080,108 B).
# So the base image contributes ZERO difference; the binary is simply not
# byte-reproducible. ⚠ Note bullseye can no longer be built at all for comparison:
# its security pool 404s, so the control above came from the locally cached
# pre-bump image. Re-measure the same way if the base moves again.
FROM debian:bookworm-slim

# Toolchain pin — must match the version CLAUDE.md / the local build uses. Bumping
# it changes codegen (and can change the VFP baseline), so treat like a seed re-roll.
ARG TC=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
ARG TC_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/${TC}.tar.xz

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget xz-utils git make python3 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "${TC_URL}" -O /tmp/tc.tar.xz \
    && mkdir -p /opt/toolchain \
    && tar -xJf /tmp/tc.tar.xz -C /opt/toolchain --strip-components=1 \
    && rm /tmp/tc.tar.xz

ENV PATH="/opt/toolchain/bin:${PATH}"
