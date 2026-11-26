#!/bin/sh
# Builds an offline region pack on the PC.
#
#   tool/build_region.sh <name> <geofabrik-path> <west,south,east,north>
#   tool/build_region.sh moscow russia/central-fed-district 35.1,54.2,40.3,57.0
#
# Output: data/packs/<name>/map.pmtiles (vector tiles, OpenMapTiles schema).
# Needs Docker; the OSM tools run from containers so nothing is installed.
set -eu
NAME="$1"
GEOFABRIK="$2"
BBOX="$3"
cd "$(dirname "$0")/.."
ROOT="$PWD/data"
SRC="osm/$(basename "$GEOFABRIK").osm.pbf"
PACK="packs/$NAME"
mkdir -p "$ROOT/osm" "$ROOT/$PACK"

if [ ! -s "$ROOT/$SRC" ]; then
  echo ">> downloading $GEOFABRIK"
  curl -L --fail --retry 5 -C - -o "$ROOT/$SRC" \
    "https://download.geofabrik.de/$GEOFABRIK-latest.osm.pbf"
fi

RUN="docker run --rm -u $(id -u):$(id -g) -v $ROOT:/data"

echo ">> cropping to $BBOX"
$RUN iboates/osmium:latest extract --bbox "$BBOX" --strategy smart \
  --overwrite -o "/data/$PACK/region.osm.pbf" "/data/$SRC"

echo ">> building vector tiles"
$RUN -w /usr/src/app ghcr.io/systemed/tilemaker:master \
  --input "/data/$PACK/region.osm.pbf" --output "/data/$PACK/map.pmtiles" \
  --bbox "$BBOX"

ls -lh "$ROOT/$PACK"
