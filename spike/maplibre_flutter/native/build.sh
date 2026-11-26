#!/bin/sh
# Cross-compiles libmapsoly_mln.so (the mlnb bridge + MapLibre Native, statically linked)
# for the phone (Alpine 3.24 aarch64 musl) on the x86_64 PC, reusing the static libraries
# and the sysroot produced by spike/maplibre/build.sh.
#   spike/maplibre_flutter/native/build.sh
#     -> data/maplibre-build/flutter/libmapsoly_mln.so
#     -> spike/maplibre_flutter/linux/prebuilt/libmapsoly_mln.so (+ mlnb.h), used by the runner's CMake
# --exclude-libs/-Bsymbolic keep the vendored freetype/harfbuzz/sqlite private, so they cannot
# clash with the system copies GTK loads into the same process.
# Needs: clang, lld, llvm-strip, and a finished data/maplibre-build/build-gl.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
MB="$(cd "$HERE/../../../data/maplibre-build" && pwd)"
SRC="$MB/maplibre-native"; B="$MB/build-gl"; SYSROOT="$MB/sysroot"
OUT="$MB/flutter"; mkdir -p "$OUT"
[ -f "$B/libmbgl-core.a" ] || { echo "run spike/maplibre/build.sh first (needs $B/libmbgl-core.a)"; exit 1; }

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
  -c "$HERE/mlnb.cpp" -o "$OUT/mlnb.o"
$CXX -shared -fuse-ld=lld -Wl,--no-undefined -Wl,--gc-sections -Wl,-Bsymbolic -Wl,--exclude-libs,ALL -Wl,-soname,libmapsoly_mln.so \
  -o "$OUT/libmapsoly_mln.unstripped.so" "$OUT/mlnb.o" \
  -Wl,--start-group "$B/libmbgl-core.a" "$B/libmbgl-vendor-parsedate.a" \
  "$B/vendor/maplibre-tile-spec/cpp/libmlt-cpp.a" "$B/vendor/maplibre-tile-spec/cpp/libfastpfor-lib.a" \
  "$B/libmbgl-vendor-csscolorparser.a" "$B/libmbgl-harfbuzz.a" "$B/libmbgl-freetype.a" \
  "$B/libmbgl-vendor-nunicode.a" "$B/libmbgl-vendor-sqlite.a" -Wl,--end-group \
  -L"$SYSROOT/usr/lib" -lEGL -lGLESv2 -lwayland-client -lwayland-egl -lcurl -ljpeg -luv -lwebp -licuuc -licui18n -lpng -lz
llvm-strip -o "$OUT/libmapsoly_mln.so" "$OUT/libmapsoly_mln.unstripped.so"
mkdir -p "$HERE/../linux/prebuilt"
cp "$OUT/libmapsoly_mln.so" "$HERE/mlnb.h" "$HERE/../linux/prebuilt/"
ls -l "$OUT/libmapsoly_mln.so"
llvm-readelf -d "$OUT/libmapsoly_mln.so" | grep NEEDED
