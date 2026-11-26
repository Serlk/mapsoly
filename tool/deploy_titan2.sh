#!/bin/sh
# Copies the sources to the Titan 2 and builds the Linux bundle there.
# The phone runs Alpine (musl), so the official x86/glibc SDK cannot
# cross-build for it; the distro Flutter on the phone does the build.
set -eu
HOST="${TITAN2_HOST:-root@192.168.1.81}"
KEY="${TITAN2_KEY:-$HOME/.ssh/id_old}"
DEST=/home/serlk/mapsoly
cd "$(dirname "$0")/.."
tar czf - --exclude=./build --exclude=./.dart_tool --exclude=./android \
  --exclude=./.git --exclude=./linux/flutter/ephemeral --exclude=./data . |
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
