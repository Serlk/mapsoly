#!/bin/sh
# Builds the MapLibre bridge (native/maplibre -> libmapsoly_mln.so) and collects the offline
# map assets into linux/prebuilt/ (git-ignored), where linux/CMakeLists.txt picks them up:
#   linux/prebuilt/aarch64/libmapsoly_mln.so   for the phone (Alpine aarch64 musl), cross-built here
#   linux/prebuilt/x86_64/libmapsoly_mln.so    for this PC (native)
#   linux/prebuilt/maplibre/                   glyphs and sprites
#
#   tool/build_maplibre.sh             whatever can be built: both libraries + assets
#   tool/build_maplibre.sh phone|pc|assets   one of them
#   tool/build_maplibre.sh pc-core     MapLibre Native itself for the PC (once, ~10-15 min):
#                                      static libraries in data/maplibre-build/build-pc
#
# Needs: clang, lld, llvm-strip, cmake, ninja, python3. Before it, once:
#   spike/maplibre/build.sh           MapLibre source, the phone's static libraries and
#                                     the Alpine sysroot (data/maplibre-build/, docker)
#   spike/maplibre/make_assets.py     fonts and sprites download (data/maplibre-assets/)
# The PC build uses the system's libuv, curl, ICU, png, jpeg, webp, Wayland and Mesa (EGL/GLES).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-all}"
MB="$ROOT/data/maplibre-build"
OUT="$ROOT/linux/prebuilt"; mkdir -p "$OUT"
LIBS="-lEGL -lGLESv2 -lwayland-client -lwayland-egl -lcurl -ljpeg -luv -lwebp -licuuc -licui18n -lpng -lz"

# bridge <build dir> <arch dir> <compiler prefix...>: compiles mlnb.cpp with the include
# paths and defines mbgl-core was compiled with (from its compile database) and links it
# with MapLibre's static libraries into one shared library.
bridge() {
  B=$1; ARCH=$2; shift 2
  TMP="$MB/bridge-$ARCH"; mkdir -p "$TMP" "$OUT/$ARCH"
  FLAGS=$(python3 - "$B/compile_commands.json" <<'PY'
import json, shlex, sys
for c in json.load(open(sys.argv[1])):
    if c["file"].endswith("src/mln/map/map.cpp"):
        a = shlex.split(c["command"]); out = []; i = 0
        while i < len(a):
            if a[i] in ("-isystem", "-I"):
                out += [a[i], a[i + 1]]; i += 2; continue
            if a[i].startswith(("-I", "-D", "-std=", "-fno-rtti")):
                out.append(a[i])
            i += 1
        print(" ".join(shlex.quote(x) for x in out)); break
PY
)
  # shellcheck disable=SC2086
  "$@" $FLAGS -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter \
    -c "$ROOT/native/maplibre/mlnb.cpp" -o "$TMP/mlnb.o"
  # --exclude-libs/-Bsymbolic keep the vendored freetype/harfbuzz/sqlite private, so they
  # cannot clash with the system copies GTK loads into the same process.
  # shellcheck disable=SC2086
  "$@" -shared -fuse-ld=lld -Wl,--no-undefined -Wl,--gc-sections -Wl,-Bsymbolic -Wl,--exclude-libs,ALL \
    -Wl,-soname,libmapsoly_mln.so -o "$TMP/libmapsoly_mln.unstripped.so" "$TMP/mlnb.o" \
    -Wl,--start-group "$B/libmbgl-core.a" "$B/libmbgl-vendor-parsedate.a" \
    "$B/vendor/maplibre-tile-spec/cpp/libmlt-cpp.a" "$B/vendor/maplibre-tile-spec/cpp/libfastpfor-lib.a" \
    "$B/libmbgl-vendor-csscolorparser.a" "$B/libmbgl-harfbuzz.a" "$B/libmbgl-freetype.a" \
    "$B/libmbgl-vendor-nunicode.a" "$B/libmbgl-vendor-sqlite.a" -Wl,--end-group $LIBS
  llvm-strip -o "$OUT/$ARCH/libmapsoly_mln.so" "$TMP/libmapsoly_mln.unstripped.so"
  ls -l "$OUT/$ARCH/libmapsoly_mln.so"
}

if [ "$WHAT" = pc-core ]; then
  [ -d "$MB/maplibre-native" ] || { echo "run spike/maplibre/build.sh first (MapLibre source)"; exit 1; }
  cmake -S "$MB/maplibre-native" -B "$MB/build-pc" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DMLN_WITH_WAYLAND=ON -DMLN_WITH_X11=OFF \
    -DMLN_WITH_WERROR=OFF -DMLN_WITH_OPENGL=ON -DMLN_WITH_EGL=ON -DMLN_WITH_GLFW=OFF
  nice -n 10 ninja -C "$MB/build-pc" mbgl-core mbgl-vendor-parsedate mbgl-vendor-csscolorparser \
    mbgl-vendor-nunicode mbgl-vendor-sqlite mbgl-harfbuzz mbgl-freetype mlt-cpp fastpfor-lib
  exit 0
fi

if [ "$WHAT" = phone ] || { [ "$WHAT" = all ] && [ -f "$MB/build-gl/libmbgl-core.a" ]; }; then
  [ -f "$MB/build-gl/libmbgl-core.a" ] || { echo "run spike/maplibre/build.sh first"; exit 1; }
  bridge "$MB/build-gl" aarch64 clang++ --target=aarch64-alpine-linux-musl "--sysroot=$MB/sysroot" "-L$MB/sysroot/usr/lib"
fi

if [ "$WHAT" = pc ] || { [ "$WHAT" = all ] && [ -f "$MB/build-pc/libmbgl-core.a" ]; }; then
  [ -f "$MB/build-pc/libmbgl-core.a" ] || { echo "run tool/build_maplibre.sh pc-core first"; exit 1; }
  bridge "$MB/build-pc" "$(uname -m)" clang++
fi

if [ "$WHAT" = all ] || [ "$WHAT" = assets ]; then
  python3 "$ROOT/tool/build_maplibre_assets.py" "$ROOT/data/maplibre-assets" "$OUT/maplibre"
fi
