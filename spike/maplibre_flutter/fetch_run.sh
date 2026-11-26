#!/bin/sh
# fetch_run.sh <label>...  -- copies run directories from the phone to data/maplibre-build/flutter/results/
set -eu
HOST="${TITAN2_HOST:-root@192.168.1.81}"; KEY="${TITAN2_KEY:-$HOME/.ssh/id_old}"
DEST="$(cd "$(dirname "$0")/../../data/maplibre-build/flutter" && pwd)/results"; mkdir -p "$DEST"
ssh -i "$KEY" "$HOST" "tar czf - -C /home/serlk/mapsoly-maplibre-flutter/out $*" | tar xzf - -C "$DEST"
