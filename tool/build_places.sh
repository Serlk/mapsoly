#!/bin/sh
# Builds the "places and road-safety" part of a region pack on the PC:
# offline search index (addresses, streets, localities, POIs) and speed
# cameras.
#
#   tool/build_places.sh <pack-name>
#   tool/build_places.sh moscow
#
# Input:  data/packs/<name>/region.osm.pbf (made by tool/build_region.sh)
# Output: data/packs/<name>/places.sqlite  (schema: docs/places.md)
# Needs Docker; pyosmium runs from a small local image so nothing is
# installed on the host.
set -eu
NAME="$1"
cd "$(dirname "$0")/.."
ROOT="$PWD/data"
PACK="packs/$NAME"
IMAGE="mapsoly-places:1"

if [ ! -s "$ROOT/$PACK/region.osm.pbf" ]; then
  echo "missing $ROOT/$PACK/region.osm.pbf (run tool/build_region.sh first)" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo ">> building $IMAGE"
  docker build -t "$IMAGE" tool/docker/places
fi

echo ">> extracting places and cameras"
docker run --rm -u "$(id -u):$(id -g)" \
  -v "$ROOT:/data" -v "$PWD/tool/places:/src:ro" \
  "$IMAGE" python /src/build_places.py \
  "/data/$PACK/region.osm.pbf" "/data/$PACK/places.sqlite"

ls -lh "$ROOT/$PACK/places.sqlite"
