#!/bin/sh
# Cross-compiles the MapLibre bridge (native/maplibre -> libmapsoly_mln.so) for the phone
# (Alpine aarch64 musl) on the x86_64 PC and collects the offline map assets, both into
# linux/prebuilt/ (git-ignored), where linux/CMakeLists.txt picks them up for the bundle.
#
#   tool/build_maplibre.sh            library + assets
#   tool/build_maplibre.sh lib|assets one of them
#
# Needs: clang, lld, llvm-strip, python3, and once before it
#   spike/maplibre/build.sh           MapLibre Native static libraries + Alpine sysroot
#                                     (data/maplibre-build/, docker, ~10 min)
#   spike/maplibre/make_assets.py     fonts and sprites download (data/maplibre-assets/)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-all}"
MB="$ROOT/data/maplibre-build"; B="$MB/build-gl"; SYSROOT="$MB/sysroot"
OUT="$ROOT/linux/prebuilt"; mkdir -p "$OUT"

if [ "$WHAT" = all ] || [ "$WHAT" = lib ]; then
  [ -f "$B/libmbgl-core.a" ] || { echo "run spike/maplibre/build.sh first (needs $B/libmbgl-core.a)"; exit 1; }
  TMP="$MB/bridge"; mkdir -p "$TMP"
  # Include paths and defines exactly as mbgl-core was compiled with (from its compile database).
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
  CXX="clang++ --target=aarch64-alpine-linux-musl --sysroot=$SYSROOT"
  # shellcheck disable=SC2086
  $CXX $FLAGS -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter \
    -c "$ROOT/native/maplibre/mlnb.cpp" -o "$TMP/mlnb.o"
  # --exclude-libs/-Bsymbolic keep the vendored freetype/harfbuzz/sqlite private, so they
  # cannot clash with the system copies GTK loads into the same process.
  $CXX -shared -fuse-ld=lld -Wl,--no-undefined -Wl,--gc-sections -Wl,-Bsymbolic -Wl,--exclude-libs,ALL \
    -Wl,-soname,libmapsoly_mln.so -o "$TMP/libmapsoly_mln.unstripped.so" "$TMP/mlnb.o" \
    -Wl,--start-group "$B/libmbgl-core.a" "$B/libmbgl-vendor-parsedate.a" \
    "$B/vendor/maplibre-tile-spec/cpp/libmlt-cpp.a" "$B/vendor/maplibre-tile-spec/cpp/libfastpfor-lib.a" \
    "$B/libmbgl-vendor-csscolorparser.a" "$B/libmbgl-harfbuzz.a" "$B/libmbgl-freetype.a" \
    "$B/libmbgl-vendor-nunicode.a" "$B/libmbgl-vendor-sqlite.a" -Wl,--end-group \
    -L"$SYSROOT/usr/lib" -lEGL -lGLESv2 -lwayland-client -lwayland-egl -lcurl -ljpeg -luv -lwebp \
    -licuuc -licui18n -lpng -lz
  llvm-strip -o "$OUT/libmapsoly_mln.so" "$TMP/libmapsoly_mln.unstripped.so"
  ls -l "$OUT/libmapsoly_mln.so"
fi

if [ "$WHAT" = all ] || [ "$WHAT" = assets ]; then
  python3 "$ROOT/tool/build_maplibre_assets.py" "$ROOT/data/maplibre-assets" "$OUT/maplibre"
fi
