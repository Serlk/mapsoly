#!/bin/sh
# Copies the sources to the Titan 2 and builds the Linux bundle there.
# The phone runs Alpine (musl), so the official x86/glibc SDK cannot
# cross-build for it; the distro Flutter on the phone does the build.
set -eu
HOST="${TITAN2_HOST:-root@192.168.1.81}"
KEY="${TITAN2_KEY:-$HOME/.ssh/id_old}"
DEST=/home/serlk/mapsoly
cd "$(dirname "$0")/.."
# MapLibre map engine: bridge library (cross-built here) and offline map assets go
# into linux/prebuilt/, which the phone's CMake build puts into the bundle. Without
# them the app still works, with the Flutter map engine.
if [ -f data/maplibre-build/build-gl/libmbgl-core.a ] && [ -d data/maplibre-assets/fonts ]; then
  tool/build_maplibre.sh phone
  tool/build_maplibre.sh assets
else
  echo "warning: MapLibre not built (see docs/map-engine.md); the app will use the Flutter map engine"
fi
tar czf - --exclude=./build --exclude=./.dart_tool --exclude=./android \
  --exclude=./.git --exclude=./linux/flutter/ephemeral --exclude=./data --exclude=./spike \
  --exclude=./linux/prebuilt/x86_64 . |
  ssh -i "$KEY" "$HOST" "mkdir -p $DEST && tar xzf - -C $DEST && chown -R serlk:serlk $DEST &&
    su serlk -c 'cd $DEST && flutter --suppress-analytics build linux --release'"
# The routing backend is a separate small binary (see lib/routing/native/).
SHIM=data/routing-native/mapsoly_valhalla
if [ -x "$SHIM" ]; then
  ssh -i "$KEY" "$HOST" "cat > $DEST/build/linux/arm64/release/bundle/mapsoly_valhalla &&
    chmod 755 $DEST/build/linux/arm64/release/bundle/mapsoly_valhalla &&
    chown serlk:serlk $DEST/build/linux/arm64/release/bundle/mapsoly_valhalla" < "$SHIM"
else
  echo "warning: $SHIM missing, routing will not work (run lib/routing/native/build_shim.sh)"
fi
# The app icon for the launcher: the scalable picture and a few sizes, and the
# launcher entry pointed at it (the entry itself is created once by hand).
ICONS=/home/serlk/.local/share/icons/hicolor
tar cf - -C assets/icon . | ssh -i "$KEY" "$HOST" "
  mkdir -p $ICONS/scalable/apps /tmp/mapsoly-icon && tar xf - -C /tmp/mapsoly-icon &&
  cp /tmp/mapsoly-icon/mapsoly.svg $ICONS/scalable/apps/dev.mapsoly.mapsoly.svg &&
  for s in 48 64 128 256 512; do
    mkdir -p $ICONS/\${s}x\${s}/apps &&
    cp /tmp/mapsoly-icon/mapsoly-\$s.png $ICONS/\${s}x\${s}/apps/dev.mapsoly.mapsoly.png
  done
  rm -rf /tmp/mapsoly-icon
  chown -R serlk:serlk /home/serlk/.local/share/icons
  D=/home/serlk/.local/share/applications/dev.mapsoly.mapsoly.desktop
  [ -f \$D ] && sed -i 's/^Icon=.*/Icon=dev.mapsoly.mapsoly/' \$D
  true"
