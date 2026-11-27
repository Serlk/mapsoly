#!/bin/sh
# Cross-compiles the offline routing server for Android on an x86_64 PC:
# Valhalla 3.6.0 (routing runtime only) plus the dependencies Android does not
# have, then lib/routing/native/valhalla_shim.cc on top of them.
#
#   tool/build_valhalla_android.sh [abi...]     (default: arm64-v8a x86_64)
#
# Output: android/app/src/main/jniLibs/<abi>/libmapsoly_valhalla.so
#
# That file is an executable, not a library. Android only lets an app exec
# files from its native library directory, and only files named lib*.so are
# installed there, hence the name. LocalValhallaBackend finds it at run time.
#
# Everything is statically linked into it (libvalhalla, protobuf-lite, lz4,
# libc++); it only needs libc, libm, libdl, liblog and libz from the system.
#
# Sources and build trees live in data/valhalla-android/ (gitignored):
#   dl/           downloaded tarballs (checked against the hashes below)
#   src/          unpacked sources
#   host/         protoc for the PC, same version as the target libprotobuf
#   <abi>/build/  per-dependency build trees
#   <abi>/prefix/ installed headers and static libraries
#   logs/         one log per step
#
# Needs: Android NDK + the SDK's CMake (which brings ninja), git, curl,
# pkg-config, make, awk, a host C++ compiler (for protoc). No root, no Docker.
#
# Environment:
#   ANDROID_HOME  SDK location (default: ~/Android/Sdk)
#   NDK_VERSION   default 28.2.13676358
#   API           minimum Android API level (default 24 = Flutter's minSdk)
#   JOBS          parallel compile jobs (default: half of the cores; Valhalla's
#                 translation units need up to ~1.5 GB of RAM each)
set -eu

VALHALLA_VERSION=3.6.0
BOOST_VERSION=1.83.0
BOOST_SHA256=6478edfe2f3305127cffe8caf73ea0176c53769f4bf1585be237eb30798c3b8e
PROTOBUF_VERSION=3.21.12 # the last release that does not need abseil
PROTOBUF_SHA256=4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460
LZ4_VERSION=1.10.0
LZ4_SHA256=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
# Vendored libraries the routing runtime includes; the other submodules
# (libosmium, pybind11, googletest, ...) are only for tools, bindings, tests.
VALHALLA_SUBMODULES="date rapidjson unordered_dense cpp-statsd-client tz"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
API="${API:-24}"
JOBS="${JOBS:-$(( ($(nproc) + 1) / 2 ))}"
NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
CMAKE_BIN="$(ls -d "$ANDROID_HOME"/cmake/*/bin | sort -V | tail -n 1)"
CMAKE="$CMAKE_BIN/cmake"
NINJA="$CMAKE_BIN/ninja"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$REPO/data/valhalla-android"
DL="$WORK/dl"
SRC="$WORK/src"
HOST="$WORK/host"
LOGS="$WORK/logs"
mkdir -p "$DL" "$SRC" "$HOST" "$LOGS"

for tool in "$CMAKE" "$NINJA" "$TOOLCHAIN/clang++"; do
  [ -x "$tool" ] || { echo "missing $tool" >&2; exit 1; }
done

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

fetch() { # url file sha256
  if [ ! -f "$DL/$2" ]; then
    curl -fL --retry 3 -o "$DL/$2.part" "$1"
    mv "$DL/$2.part" "$DL/$2"
  fi
  echo "$3  $DL/$2" | sha256sum -c - >/dev/null ||
    { echo "checksum mismatch: $DL/$2" >&2; exit 1; }
}

fetch_sources() {
  if [ ! -d "$SRC/valhalla-$VALHALLA_VERSION/.git" ]; then
    git clone -q --depth 1 --branch "$VALHALLA_VERSION" \
      https://github.com/valhalla/valhalla.git "$SRC/valhalla-$VALHALLA_VERSION"
  fi
  for module in $VALHALLA_SUBMODULES; do
    if [ ! -e "$SRC/valhalla-$VALHALLA_VERSION/third_party/$module/.git" ]; then
      git -C "$SRC/valhalla-$VALHALLA_VERSION" submodule -q update --init \
        --depth 1 "third_party/$module"
    fi
  done

  # Valhalla uses Boost headers only, so the tree is unpacked, not built.
  if [ ! -d "$SRC/boost-$BOOST_VERSION/boost" ]; then
    b="boost_$(echo "$BOOST_VERSION" | tr . _)"
    fetch "https://archives.boost.io/release/$BOOST_VERSION/source/$b.tar.bz2" \
      "$b.tar.bz2" "$BOOST_SHA256"
    mkdir -p "$SRC/boost-$BOOST_VERSION"
    tar -xjf "$DL/$b.tar.bz2" -C "$SRC/boost-$BOOST_VERSION" \
      --strip-components=1 "$b/boost"
  fi
  if [ ! -d "$SRC/protobuf-$PROTOBUF_VERSION" ]; then
    fetch "https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-$PROTOBUF_VERSION.tar.gz" \
      "protobuf-cpp-$PROTOBUF_VERSION.tar.gz" "$PROTOBUF_SHA256"
    tar -xzf "$DL/protobuf-cpp-$PROTOBUF_VERSION.tar.gz" -C "$SRC"
  fi
  if [ ! -d "$SRC/lz4-$LZ4_VERSION" ]; then
    fetch "https://github.com/lz4/lz4/releases/download/v$LZ4_VERSION/lz4-$LZ4_VERSION.tar.gz" \
      "lz4-$LZ4_VERSION.tar.gz" "$LZ4_SHA256"
    tar -xzf "$DL/lz4-$LZ4_VERSION.tar.gz" -C "$SRC"
  fi
}

# The generated *.pb.cc must match the runtime library exactly, so the PC's
# own protoc (whatever version the distro has) cannot be used.
build_host_protoc() {
  [ -x "$HOST/protoc" ] && return
  step host-protoc-configure "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -S "$SRC/protobuf-$PROTOBUF_VERSION" -B "$HOST/build-protobuf" \
    -DCMAKE_BUILD_TYPE=Release -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF
  step host-protoc-build "$CMAKE" --build "$HOST/build-protobuf" \
    --target protoc -j "$JOBS"
  cp "$(readlink -f "$HOST/build-protobuf/protoc")" "$HOST/protoc"
}

build_abi() {
  abi="$1"
  case "$abi" in
    arm64-v8a) triple=aarch64-linux-android ;;
    x86_64) triple=x86_64-linux-android ;;
    armeabi-v7a) triple=armv7a-linux-androideabi ;;
    *) echo "unknown ABI $abi" >&2; exit 2 ;;
  esac
  build="$WORK/$abi/build"
  prefix="$WORK/$abi/prefix"
  mkdir -p "$build" "$prefix/lib/pkgconfig"

  # Sections are kept separate so that the final link can drop what the shim
  # never reaches (--gc-sections); that roughly halves the binary.
  configure() {
    "$CMAKE" -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DCMAKE_MAKE_PROGRAM="$NINJA" -DANDROID_ABI="$abi" \
      -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_static \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_FIND_ROOT_PATH="$prefix" \
      -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
      -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" "$@"
  }

  if [ ! -f "$prefix/lib/liblz4.a" ]; then
    step "$abi-lz4-configure" configure \
      -S "$SRC/lz4-$LZ4_VERSION/build/cmake" -B "$build/lz4" \
      -DBUILD_STATIC_LIBS=ON -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF
    step "$abi-lz4-build" "$CMAKE" --build "$build/lz4" --target install -j "$JOBS"
  fi

  if [ ! -f "$prefix/lib/libprotobuf-lite.a" ]; then
    step "$abi-protobuf-configure" configure \
      -S "$SRC/protobuf-$PROTOBUF_VERSION" -B "$build/protobuf" \
      -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
      -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF
    step "$abi-protobuf-build" "$CMAKE" --build "$build/protobuf" --target install -j "$JOBS"
    # Valhalla prefers a protobuf CMake package over CMake's FindProtobuf, but
    # the package of a cross build has no runnable protoc. Without it
    # FindProtobuf is used, which takes Protobuf_PROTOC_EXECUTABLE.
    rm -rf "$prefix/lib/cmake/protobuf"
  fi

  # zlib is part of the NDK sysroot but has no .pc file there, and Valhalla
  # looks for it with pkg-config only.
  cat >"$prefix/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from the Android NDK sysroot
Version: 1.3
Libs: -lz
EOF

  if [ ! -f "$prefix/lib/libvalhalla.a" ]; then
    # What is switched off, and what it would have pulled in:
    #   DATA_TOOLS       mjolnir (graph building): sqlite, spatialite, luajit,
    #                    geos, openssl, libosmium
    #   SERVICES         valhalla_service & workers: prime_server, zeromq
    #   HTTP             remote tile fetching: curl
    #   GDAL             GeoTIFF isochrone output: gdal
    #   TOOLS, TESTS, PYTHON_BINDINGS: executables, googletest, pybind11
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH='' \
      step "$abi-valhalla-configure" configure \
      -S "$SRC/valhalla-$VALHALLA_VERSION" -B "$build/valhalla" \
      -DENABLE_TOOLS=OFF -DENABLE_DATA_TOOLS=OFF -DENABLE_SERVICES=OFF \
      -DENABLE_HTTP=OFF -DENABLE_PYTHON_BINDINGS=OFF -DENABLE_TESTS=OFF \
      -DENABLE_GDAL=OFF -DENABLE_CCACHE=OFF -DENABLE_SINGLE_FILES_WERROR=OFF \
      -DBoost_INCLUDE_DIR="$SRC/boost-$BOOST_VERSION" -DBoost_NO_BOOST_CMAKE=ON \
      -DProtobuf_PROTOC_EXECUTABLE="$HOST/protoc"
    step "$abi-valhalla-build" "$CMAKE" --build "$build/valhalla" --target install -j "$JOBS"
  fi

  out="$REPO/android/app/src/main/jniLibs/$abi"
  mkdir -p "$out"
  vsrc="$SRC/valhalla-$VALHALLA_VERSION"
  # 16 KiB pages are the NDK r28 default; spelled out because Android 15+
  # devices with 16 KiB pages refuse binaries aligned to 4 KiB.
  step "$abi-shim" "$TOOLCHAIN/clang++" --target="$triple$API" \
    -std=c++20 -O2 -Wall -Wextra -ffunction-sections -fdata-sections \
    -DHAS_REMOTE_API=0 -DAUTO_DOWNLOAD=0 \
    -I"$prefix/include" -I"$SRC/boost-$BOOST_VERSION" \
    -isystem "$vsrc/third_party/rapidjson/include" \
    -isystem "$vsrc/third_party/date/include" \
    -o "$out/libmapsoly_valhalla.so" \
    "$REPO/lib/routing/native/valhalla_shim.cc" \
    -L"$prefix/lib" -lvalhalla -lprotobuf-lite -llz4 -lz -llog \
    -static-libstdc++ -Wl,--gc-sections -Wl,-z,max-page-size=16384
  "$TOOLCHAIN/llvm-strip" "$out/libmapsoly_valhalla.so"
  ls -l "$out/libmapsoly_valhalla.so"
}

fetch_sources
build_host_protoc
for abi in "${@:-arm64-v8a x86_64}"; do
  for a in $abi; do
    build_abi "$a"
  done
done
