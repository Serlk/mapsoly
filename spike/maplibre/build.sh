#!/bin/sh
# Cross-compiles MapLibre Native's GLFW example app (+ scripted benchmark patch)
# for the phone (Alpine 3.24 aarch64 musl) on an x86_64 PC. No qemu.
#   spike/maplibre/build.sh            -> data/maplibre-build/mbgl-glfw-{gl,vk}
# Needs: docker, clang, lld, llvm-strip, cmake, ninja, pkg-config, git.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${MLN_BUILD_OUT:-$HERE/../../data/maplibre-build}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"   # MLN_BUILD_OUT: build elsewhere
COMMIT=0c62d868c0346c20bac89c306e8c6972b7dd10c1   # maplibre-native main, 2026-11-26
export MLN_SYSROOT="$OUT/sysroot"

if [ ! -e "$MLN_SYSROOT/usr/include/GLFW/glfw3.h" ]; then
  mkdir -p "$MLN_SYSROOT"
  docker run --rm -v "$MLN_SYSROOT:/sysroot" alpine:3.24 sh -c "
    apk --arch aarch64 --root /sysroot --initdb --allow-untrusted --no-scripts --no-cache \
      -X https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
      -X https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
      add musl-dev g++ curl-dev libuv-dev icu-dev libpng-dev libjpeg-turbo-dev libwebp-dev \
          sqlite-dev zlib-dev bzip2-dev glfw-dev mesa-dev wayland-dev libxkbcommon-dev \
          vulkan-loader-dev vulkan-headers linux-headers >/dev/null &&
    chown -R $(id -u):$(id -g) /sysroot"
fi

SRC="$OUT/maplibre-native"
if [ ! -d "$SRC" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/maplibre/maplibre-native.git
  git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
  # everything except Windows/WebGPU/Metal/doc-only submodules
  git -C "$SRC" submodule update --init --depth 1 --recursive --jobs 8 -- $(
    git -C "$SRC" config -f .gitmodules --get-regexp path | awk '{print $2}' |
    grep -vE 'vcpkg|wgpu-native|webgpu-cpp|doxygen|metal-cpp')
  git -C "$SRC" apply "$HERE/glfw_bench.patch"
fi
cp "$HERE/mapsoly_bench.hpp" "$SRC/platform/glfw/"

COMMON="-G Ninja -DCMAKE_TOOLCHAIN_FILE=$HERE/toolchain-alpine-aarch64.cmake -DCMAKE_BUILD_TYPE=Release
        -DMLN_WITH_WAYLAND=ON -DMLN_WITH_X11=OFF -DMLN_WITH_WERROR=OFF"
cmake -S "$SRC" -B "$OUT/build-gl" $COMMON -DMLN_WITH_OPENGL=ON -DMLN_WITH_EGL=ON
cmake -S "$SRC" -B "$OUT/build-vk" $COMMON -DMLN_WITH_VULKAN=ON -DMLN_WITH_OPENGL=OFF
for b in gl vk; do
  ninja -C "$OUT/build-$b" mbgl-glfw
  llvm-strip -o "$OUT/mbgl-glfw-$b" "$OUT/build-$b/platform/glfw/mbgl-glfw"
done
ls -l "$OUT"/mbgl-glfw-gl "$OUT"/mbgl-glfw-vk
