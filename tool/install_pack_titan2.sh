#!/bin/sh
# Copies a built region pack to the app's data folder on the Titan 2.
#   tool/install_pack_titan2.sh <pack-name>
# Files already present with the same size are skipped.
set -eu
NAME="$1"
HOST="${TITAN2_HOST:-root@192.168.1.81}"
KEY="${TITAN2_KEY:-$HOME/.ssh/id_old}"
DEST="/home/serlk/.local/share/dev.mapsoly.mapsoly/packs/$NAME"
cd "$(dirname "$0")/../data/packs/$NAME"
ssh -i "$KEY" "$HOST" "mkdir -p $DEST/valhalla"
for f in map.pmtiles places.sqlite valhalla/tiles.tar valhalla/valhalla.json; do
  [ -f "$f" ] || { echo "skip $f (not built)"; continue; }
  SIZE=$(stat -c %s "$f")
  if [ "$(ssh -i "$KEY" "$HOST" "stat -c %s $DEST/$f 2>/dev/null || echo 0")" = "$SIZE" ]; then
    echo "ok   $f"
    continue
  fi
  echo "copy $f ($SIZE bytes)"
  # The phone has no rsync/sftp: stream the file, verify its size, then rename.
  ssh -i "$KEY" "$HOST" "cat > $DEST/$f.part && [ \$(stat -c %s $DEST/$f.part) = $SIZE ] &&
    mv $DEST/$f.part $DEST/$f" < "$f"
done
ssh -i "$KEY" "$HOST" "chown -R serlk:serlk /home/serlk/.local/share/dev.mapsoly.mapsoly && ls -la $DEST $DEST/valhalla"
