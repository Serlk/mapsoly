#!/bin/sh
# Cross-compiles mapsoly_valhalla (valhalla_shim.cc) for the phone
# (Alpine 3.24, aarch64, musl) on an x86_64 PC. No qemu needed: an Alpine
# container installs the aarch64 headers/libs into a sysroot and the host
# clang + lld link against it.
#
#   lib/routing/native/build_shim.sh [out-dir]     (default: data/routing-native)
#
# Needs: docker, clang, lld, llvm-strip. The Alpine release must match the
# phone, because the binary links against that release's libvalhalla.so.3.
set -eu
ALPINE="${ALPINE:-3.24}"
ARCH="${ARCH:-aarch64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mkdir -p "${1:-$HERE/../../../data/routing-native}" && cd "${1:-$HERE/../../../data/routing-native}" && pwd)"
SYSROOT="$OUT/sysroot-alpine-$ALPINE-$ARCH"

if [ ! -e "$SYSROOT/usr/include/valhalla/tyr/actor.h" ]; then
  mkdir -p "$SYSROOT"
  docker run --rm -v "$SYSROOT:/sysroot" "alpine:$ALPINE" sh -c "
    apk --arch $ARCH --root /sysroot --initdb --allow-untrusted --no-scripts \
      --no-cache \
      -X https://dl-cdn.alpinelinux.org/alpine/v$ALPINE/main \
      -X https://dl-cdn.alpinelinux.org/alpine/v$ALPINE/community \
      add musl-dev g++ valhalla-dev >/dev/null &&
    chown -R $(id -u):$(id -g) /sysroot"
fi

clang++ --target="$ARCH-alpine-linux-musl" --sysroot="$SYSROOT" -fuse-ld=lld \
  -std=c++20 -O2 -Wall -Wextra \
  -o "$OUT/mapsoly_valhalla" "$HERE/valhalla_shim.cc" \
  -lvalhalla -lprotobuf-lite -pthread -Wl,--allow-shlib-undefined
llvm-strip "$OUT/mapsoly_valhalla"
ls -l "$OUT/mapsoly_valhalla"
