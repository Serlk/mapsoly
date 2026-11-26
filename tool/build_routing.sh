#!/bin/sh
# Builds the offline routing graph (Valhalla tiles) for a region pack on the PC.
#
#   tool/build_routing.sh <pack-name>
#   tool/build_routing.sh moscow
#
# Input:  data/packs/<name>/region.osm.pbf  (made by tool/build_region.sh)
# Output: data/packs/<name>/valhalla/tiles.tar     routing graph (indexed tar)
#         data/packs/<name>/valhalla/valhalla.json config, paths relative to
#                                                  that directory
#         data/packs/<name>/valhalla/build.json    what built it (versions)
#
# Needs Docker. The image is pinned: tiles must stay readable by the Valhalla
# on the phone, see docs/routing.md before bumping it.
#
# Environment:
#   VALHALLA_IMAGE  override the builder image
#   CONCURRENCY     build threads (default: all cores)
#   KEEP_WORK=1     keep the intermediate work/ directory (loose tiles, admins)
set -eu

VALHALLA_IMAGE="${VALHALLA_IMAGE:-ghcr.io/valhalla/valhalla:3.6.0}"

if [ $# -ne 1 ]; then
  echo "usage: $0 <pack-name>" >&2
  exit 2
fi
NAME="$1"
cd "$(dirname "$0")/.."
ROOT="$PWD/data"
PACK="packs/$NAME"
OUT="$PACK/valhalla"
WORK="$OUT/work"
CONCURRENCY="${CONCURRENCY:-$(nproc)}"

if [ ! -s "$ROOT/$PACK/region.osm.pbf" ]; then
  echo "missing $ROOT/$PACK/region.osm.pbf (run tool/build_region.sh first)" >&2
  exit 1
fi

rm -rf "${ROOT:?}/$WORK"
mkdir -p "$ROOT/$WORK"

# HOME is set because the image has no passwd entry for an arbitrary uid.
RUN="docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v $ROOT:/data -w /data/$WORK $VALHALLA_IMAGE"

echo ">> valhalla version"
VERSION="$($RUN valhalla_build_tiles --version | tail -n 1 | sed "s/.* //")"
echo "$VERSION"

# Build-time config: absolute container paths, loose tiles in work/.
# Timezones are skipped on purpose (see docs/routing.md).
$RUN valhalla_build_config \
  --mjolnir-tile-dir "/data/$WORK/tiles" \
  --mjolnir-tile-extract "/data/$OUT/tiles.tar" \
  --mjolnir-admin "/data/$WORK/admin.sqlite" \
  --mjolnir-timezone "/data/$WORK/no-timezones.sqlite" \
  --mjolnir-concurrency "$CONCURRENCY" \
  > "$ROOT/$WORK/build.json"

echo ">> building admin areas (borders, country driving rules)"
$RUN valhalla_build_admins -c "/data/$WORK/build.json" "/data/$PACK/region.osm.pbf"

echo ">> building routing tiles"
$RUN valhalla_build_tiles -c "/data/$WORK/build.json" "/data/$PACK/region.osm.pbf"

echo ">> packing tiles.tar"
rm -f "$ROOT/$OUT/tiles.tar"
$RUN valhalla_build_extract -c "/data/$WORK/build.json" --overwrite

# Runtime config shipped with the pack. Paths are relative to the directory
# the config lives in; ValhallaService (lib/routing/valhalla_service.dart)
# rewrites them to absolute ones and picks the port. To run it by hand:
#   cd data/packs/<name>/valhalla && valhalla_service valhalla.json 1
# tile_dir points at a directory that does not exist so only the tar is used.
$RUN valhalla_build_config \
  --mjolnir-tile-dir "no-tile-dir" \
  --mjolnir-tile-extract "tiles.tar" \
  --mjolnir-traffic-extract "traffic.tar" \
  --mjolnir-admin "no-admin.sqlite" \
  --mjolnir-timezone "no-timezones.sqlite" \
  --httpd-service-listen "tcp://127.0.0.1:8002" \
  > "$ROOT/$OUT/valhalla.json"

TILES="$(find "$ROOT/$WORK/tiles" -name '*.gph' | wc -l)"
cat > "$ROOT/$OUT/build.json" <<JSON
{
  "pack": "$NAME",
  "valhalla_version": "$VERSION",
  "image": "$VALHALLA_IMAGE",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tiles": $TILES,
  "admins": true,
  "timezones": false,
  "elevation": false
}
JSON

if [ "${KEEP_WORK:-0}" != 1 ]; then
  rm -rf "${ROOT:?}/$WORK"
fi

ls -lh "$ROOT/$OUT"
