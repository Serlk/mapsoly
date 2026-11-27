#!/bin/sh
# Cross-compiles the MapLibre map engine for Android on an x86_64 PC: MapLibre Native's
# core (GLES 3 renderer) with the platform pieces of native/maplibre/android/, libuv and
# libpng, and the mlnb bridge (native/maplibre/mlnb.cpp) on top, as one shared library.
# Also packs the offline glyphs and sprites for the APK.
#
#   tool/build_maplibre_android.sh [abi...]     (default: arm64-v8a x86_64)
#   tool/build_maplibre_android.sh assets       only the glyphs/sprites archive
#
# Output (both gitignored):
#   android/app/src/main/jniLibs/<abi>/libmapsoly_mln.so
#   android/app/src/main/assets/maplibre.zip    from linux/prebuilt/maplibre/
#                                               (tool/build_maplibre.sh assets)
# Without them the app builds and uses the Flutter map engine.
#
# MapLibre Native's source is the tree the Linux build uses, at the commit pinned in
# spike/maplibre/build.sh (data/maplibre-build/maplibre-native; fetched here when it is
# missing). Everything else lives in data/maplibre-android/ (gitignored):
#   dl/           downloaded tarballs (checked against the hashes below)
#   src/          unpacked libuv and libpng
#   <abi>/deps/   their build trees, <abi>/prefix/ their headers and static libraries
#   <abi>/build/  MapLibre + bridge build tree
#   logs/         one log per step
#
# Needs: Android NDK, cmake >= 3.25 and ninja from the system (the SDK's CMake 3.22 is
# too old for MapLibre), git, curl, python3. No root, no Docker. A first run takes about
# ten minutes per ABI; after an edit of the bridge only that file is recompiled.
#
# Environment:
#   ANDROID_HOME  SDK location (default: ~/Android/Sdk)
#   NDK_VERSION   default 28.2.13676358
#   API           minimum Android API level (default 24 = Flutter's minSdk)
#   JOBS          parallel compile jobs (default: all cores but two)
set -eu

MLN_COMMIT=0c62d868c0346c20bac89c306e8c6972b7dd10c1 # the same as spike/maplibre/build.sh
LIBUV_VERSION=1.51.0
LIBUV_SHA256=5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb
LIBPNG_VERSION=1.6.50
LIBPNG_SHA256=708f4398f996325819936d447f982e0db90b6b8212b7507e7672ea232210949a

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
API="${API:-24}"
JOBS="${JOBS:-$(( $(nproc) > 3 ? $(nproc) - 2 : 1 ))}"
NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$REPO/data/maplibre-android"
DL="$WORK/dl"
SRC="$WORK/src"
LOGS="$WORK/logs"
MLN="$REPO/data/maplibre-build/maplibre-native"
mkdir -p "$DL" "$SRC" "$LOGS"

# Runs a step with its output in a log file; shows the tail if it fails.
step() {
  name="$1"
  shift
  echo "== $name"
  if ! "$@" >"$LOGS/$name.log" 2>&1; then
    tail -n 40 "$LOGS/$name.log" >&2
    echo "FAILED: $name (full log: $LOGS/$name.log)" >&2
    exit 1
  fi
}

# Glyphs and sprites as one stored archive: MainActivity unpacks it into the app's files
# directory, because MapLibre reads them as plain files.
assets() {
  from="$REPO/linux/prebuilt/maplibre"
  [ -d "$from/fonts" ] || { echo "no $from: run tool/build_maplibre.sh assets first" >&2; exit 1; }
  mkdir -p "$REPO/android/app/src/main/assets"
  python3 - "$from" "$REPO/android/app/src/main/assets/maplibre.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
names = sorted(os.path.relpath(os.path.join(d, f), src) for d, _, fs in os.walk(src) for f in fs)
with zipfile.ZipFile(dst + ".part", "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name in names:
        # Fixed timestamps: the same input gives the same archive.
        info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(src, name), "rb") as f:
            z.writestr(info, f.read())
os.replace(dst + ".part", dst)
print("%s: %d files, %.1f MB" % (dst, len(names), os.path.getsize(dst) / 1e6))
PY
}

if [ "${1:-}" = assets ]; then
  assets
  exit 0
fi

for tool in cmake ninja git curl python3; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
[ -x "$TOOLCHAIN/clang++" ] || { echo "missing NDK at $NDK" >&2; exit 1; }

fetch() { # url file sha256
  if [ ! -f "$DL/$2" ]; then
    curl -fL --retry 3 -o "$DL/$2.part" "$1"
    mv "$DL/$2.part" "$DL/$2"
  fi
  echo "$3  $DL/$2" | sha256sum -c - >/dev/null ||
    { echo "checksum mismatch: $DL/$2" >&2; exit 1; }
}

unpack() { # tarball directory-inside
  [ -d "$SRC/$2" ] || tar -xzf "$DL/$1" -C "$SRC"
}

fetch_maplibre() {
  git init -q "$MLN"
  git -C "$MLN" remote add origin https://github.com/maplibre/maplibre-native.git
  git -C "$MLN" fetch -q --depth 1 origin "$MLN_COMMIT"
  git -C "$MLN" checkout -q FETCH_HEAD
  # Everything except the Windows / WebGPU / Metal / documentation submodules.
  # shellcheck disable=SC2046
  git -C "$MLN" submodule update --init --depth 1 --recursive --jobs 8 -- $(
    git -C "$MLN" config -f .gitmodules --get-regexp path | awk '{print $2}' |
      grep -vE 'vcpkg|wgpu-native|webgpu-cpp|doxygen|metal-cpp')
}

if [ ! -f "$MLN/CMakeLists.txt" ]; then
  step maplibre-source fetch_maplibre
fi
[ "$(git -C "$MLN" rev-parse HEAD)" = "$MLN_COMMIT" ] ||
  { echo "$MLN is not at $MLN_COMMIT" >&2; exit 1; }

fetch "https://dist.libuv.org/dist/v$LIBUV_VERSION/libuv-v$LIBUV_VERSION.tar.gz" \
  "libuv-v$LIBUV_VERSION.tar.gz" "$LIBUV_SHA256"
fetch "https://download.sourceforge.net/libpng/libpng-$LIBPNG_VERSION.tar.gz" \
  "libpng-$LIBPNG_VERSION.tar.gz" "$LIBPNG_SHA256"
unpack "libuv-v$LIBUV_VERSION.tar.gz" "libuv-v$LIBUV_VERSION"
unpack "libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION"

# cmake_android <abi> <source> <build> <args...>: configure for the ABI.
cmake_android() {
  # (sh has no local variables: these names must differ from build_abi's.)
  c_abi="$1" c_src="$2" c_build="$3"
  shift 3
  cmake -S "$c_src" -B "$c_build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$c_abi" -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_FIND_ROOT_PATH="$WORK/$c_abi/prefix" "$@"
}

build_abi() {
  abi="$1"
  prefix="$WORK/$abi/prefix"
  deps="$WORK/$abi/deps"
  build="$WORK/$abi/build"
  mkdir -p "$prefix" "$deps"

  if [ ! -f "$prefix/lib/libuv.a" ]; then
    step "$abi-libuv-configure" cmake_android "$abi" "$SRC/libuv-v$LIBUV_VERSION" "$deps/libuv" \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DLIBUV_BUILD_SHARED=OFF -DLIBUV_BUILD_TESTS=OFF \
      -DLIBUV_BUILD_BENCH=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    step "$abi-libuv" cmake --build "$deps/libuv" --target install -j "$JOBS"
  fi
  if [ ! -f "$prefix/lib/libpng16.a" ]; then
    step "$abi-libpng-configure" cmake_android "$abi" "$SRC/libpng-$LIBPNG_VERSION" "$deps/libpng" \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
      -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    step "$abi-libpng" cmake --build "$deps/libpng" --target install -j "$JOBS"
  fi

  step "$abi-configure" cmake_android "$abi" "$REPO/native/maplibre/android" "$build" \
    -DMLN_SRC="$MLN" -DDEPS_PREFIX="$prefix"
  step "$abi-build" nice -n 10 cmake --build "$build" --target mapsoly_mln -j "$JOBS"

  out="$REPO/android/app/src/main/jniLibs/$abi"
  mkdir -p "$out"
  "$TOOLCHAIN/llvm-strip" -o "$out/libmapsoly_mln.so" "$build/libmapsoly_mln.so"
  ls -l "$out/libmapsoly_mln.so"
}

[ $# -gt 0 ] || set -- arm64-v8a x86_64
for abi in "$@"; do
  case "$abi" in
    arm64-v8a | x86_64 | armeabi-v7a) build_abi "$abi" ;;
    *) echo "unknown ABI: $abi" >&2; exit 1 ;;
  esac
done
if [ -d "$REPO/linux/prebuilt/maplibre/fonts" ]; then
  assets
else
  echo "no linux/prebuilt/maplibre: run tool/build_maplibre.sh assets, then $0 assets" >&2
fi
