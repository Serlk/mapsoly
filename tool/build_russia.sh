#!/bin/sh
# Builds region packs for all of Russia, one per federal district.
#
#   tool/build_russia.sh            every step, skipping finished ones
#   tool/build_russia.sh routing    only the country-wide routing graph
#   tool/build_russia.sh map        only the country-wide vector tiles
#   tool/build_russia.sh packs      only cutting the district packs
#
# Needs data/osm/russia.osm.pbf (Geofabrik russia-latest) and the district
# boundaries in data/osm/poly/. The routing graph and the map are built once
# for the whole country and then cut by district, so tiles on a border are
# complete in both neighbours and routes can cross district borders.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD/data"
SRC=osm/russia.osm.pbf
OUT=russia
VALHALLA_IMAGE="${VALHALLA_IMAGE:-ghcr.io/valhalla/valhalla:3.6.0}"
DISTRICTS="central northwestern south north-caucasus volga ural siberian far-eastern crimean"
STEP="${1:-all}"
AS_ME="-u $(id -u):$(id -g)"
mkdir -p "$ROOT/$OUT"

[ -s "$ROOT/$SRC" ] || { echo "missing $ROOT/$SRC" >&2; exit 1; }

routing() {
  V="$OUT/valhalla"
  if [ -f "$ROOT/$V/done" ]; then echo ">> routing graph: already built"; return; fi
  rm -rf "${ROOT:?}/$V"; mkdir -p "$ROOT/$V"
  RUN="docker run --rm $AS_ME -e HOME=/tmp -v $ROOT:/data -w /data/$V $VALHALLA_IMAGE"
  $RUN valhalla_build_config \
    --mjolnir-tile-dir "/data/$V/tiles" \
    --mjolnir-tile-extract "/data/$V/unused.tar" \
    --mjolnir-admin "/data/$V/admin.sqlite" \
    --mjolnir-timezone "/data/$V/no-timezones.sqlite" \
    --mjolnir-concurrency "${CONCURRENCY:-$(nproc)}" > "$ROOT/$V/build.json"
  echo ">> admin areas"; $RUN valhalla_build_admins -c "/data/$V/build.json" "/data/$SRC"
  echo ">> routing tiles"; $RUN valhalla_build_tiles -c "/data/$V/build.json" "/data/$SRC"
  # Runtime config shipped inside every routing slice; paths are relative to
  # the folder it is unpacked into.
  $RUN valhalla_build_config \
    --mjolnir-tile-dir "tiles" \
    --mjolnir-tile-extract "no-extract.tar" \
    --mjolnir-traffic-extract "traffic.tar" \
    --mjolnir-admin "no-admin.sqlite" \
    --mjolnir-timezone "no-timezones.sqlite" \
    --httpd-service-listen "tcp://127.0.0.1:8002" > "$ROOT/$V/valhalla.json"
  date -u +russia-%Y%m%d-%H%M > "$ROOT/$V/build.txt"
  touch "$ROOT/$V/done"
}

map() {
  if [ -s "$ROOT/$OUT/map.pmtiles" ] && [ -f "$ROOT/$OUT/map.done" ]; then
    echo ">> map: already built"; return
  fi
  rm -rf "${ROOT:?}/$OUT/tm-store"; mkdir -p "$ROOT/$OUT/tm-store"
  echo ">> vector tiles for the whole country (on-disk store)"
  docker run --rm $AS_ME -v "$ROOT:/data" ghcr.io/systemed/tilemaker:master \
    --input "/data/$SRC" --output "/data/$OUT/map.pmtiles" \
    --store "/data/$OUT/tm-store"
  rm -rf "${ROOT:?}/$OUT/tm-store"
  # tilemaker writes tiles in build order; cutting regions out of the
  # archive needs them ordered by tile id.
  echo ">> ordering the archive for region extraction"
  docker run --rm $AS_ME -v "$ROOT:/data" protomaps/go-pmtiles:latest \
    cluster "/data/$OUT/map.pmtiles"
  touch "$ROOT/$OUT/map.done"
}

packs() {
  BUILD="$(cat "$ROOT/$OUT/valhalla/build.txt")"
  for d in $DISTRICTS; do
    P="packs/$d"; POLY="osm/poly/$d-fed-district.poly"
    mkdir -p "$ROOT/$P"
    echo "== $d"
    python3 -I tool/slice_routing.py geojson "$ROOT/$POLY" "$ROOT/$P/region.geojson"
    if [ ! -s "$ROOT/$P/region.osm.pbf" ]; then
      docker run --rm $AS_ME -v "$ROOT:/data" iboates/osmium:latest extract \
        -p "/data/$POLY" --strategy smart --overwrite \
        -o "/data/$P/region.osm.pbf" "/data/$SRC"
    fi
    [ -s "$ROOT/$P/places.sqlite" ] || tool/build_places.sh "$d"
    if [ ! -s "$ROOT/$P/map.pmtiles" ]; then
      docker run --rm $AS_ME -v "$ROOT:/data" protomaps/go-pmtiles:latest extract \
        "/data/$OUT/map.pmtiles" "/data/$P/map.pmtiles" \
        --region="/data/$P/region.geojson"
    fi
    python3 -I tool/slice_routing.py tar "$ROOT/$OUT/valhalla/tiles" "$ROOT/$POLY" \
      "$ROOT/$OUT/valhalla/valhalla.json" "$BUILD" "$ROOT/$P/routing.tar"
    ls -lh "$ROOT/$P" | awk '{print "   ", $5, $9}' | grep -E "pmtiles|sqlite|tar"
  done
}

case "$STEP" in
  routing) routing ;;
  map) map ;;
  packs) packs ;;
  all) routing; map; packs ;;
  *) echo "unknown step $STEP" >&2; exit 1 ;;
esac
