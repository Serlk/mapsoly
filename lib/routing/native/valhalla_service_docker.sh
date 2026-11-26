#!/bin/sh
# Drop-in "valhalla_service" for the PC: runs the real one from the pinned
# Docker image. Same command line, so LocalValhallaBackend can spawn it:
#
#   MAPSOLY_VALHALLA_BIN=$PWD/lib/routing/native/valhalla_service_docker.sh
#
# The working directory (a pack's valhalla/ dir) and the directory of the
# config file are mounted at the same paths inside the container, so the
# absolute paths in the runtime config keep working.
set -eu
VALHALLA_IMAGE="${VALHALLA_IMAGE:-ghcr.io/valhalla/valhalla:3.6.0}"
CONFIG="$(realpath "$1")"
THREADS="${2:-1}"
DATA="$(pwd -P)"
RUNTIME="$(dirname "$CONFIG")"
NAME="mapsoly-valhalla-$$"

# `docker run` only forwards signals while it is alive, and Valhalla drains
# for a while on SIGTERM; kill the container outright when we are told to
# stop. (After a SIGKILL of this script the container keeps running until
# `docker kill`: nothing can be done about that from here.)
stop() {
  docker kill "$NAME" >/dev/null 2>&1 || true
  exit 0
}
trap stop TERM INT HUP

docker run --rm --init --name "$NAME" --network host -u "$(id -u):$(id -g)" \
  -v "$DATA:$DATA:ro" -v "$RUNTIME:$RUNTIME" -w "$DATA" \
  "$VALHALLA_IMAGE" valhalla_service "$CONFIG" "$THREADS" &
wait $!
