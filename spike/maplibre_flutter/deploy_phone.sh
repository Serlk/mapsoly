#!/bin/sh
# Copies the test app (sources + the prebuilt bridge library) to the phone and builds the
# Flutter bundle there with the distro Flutter (the glibc SDK cannot target Alpine/musl).
#   native/build.sh          first, on the PC (cross-compiles linux/prebuilt/libmapsoly_mln.so)
#   ./deploy_phone.sh        copy + build   (SKIP_BUILD=1: copy only)
set -eu
HOST="${TITAN2_HOST:-root@192.168.1.81}"
KEY="${TITAN2_KEY:-$HOME/.ssh/id_old}"
ROOT=/home/serlk/mapsoly-maplibre-flutter
cd "$(dirname "$0")"
[ -f linux/prebuilt/libmapsoly_mln.so ] || { echo "run native/build.sh first"; exit 1; }
tar czf - --exclude=./build --exclude=./.dart_tool --exclude=./.idea \
  --exclude=./linux/flutter/ephemeral --exclude=./native . |
  ssh -i "$KEY" "$HOST" "mkdir -p $ROOT/app $ROOT/out && tar xzf - -C $ROOT/app &&
    cp $ROOT/app/phone/*.sh $ROOT/ && chown -R serlk:serlk $ROOT"
[ "${SKIP_BUILD:-0}" = 1 ] && exit 0
ssh -i "$KEY" "$HOST" "su serlk -c 'cd $ROOT/app && nice -n 10 flutter --suppress-analytics build linux --release'"
