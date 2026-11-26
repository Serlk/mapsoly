#!/bin/sh
# run_demo.sh <label>   (as serlk) -- runs the API demo (MLN_DEMO=1), one screenshot per step.
LABEL=${1:-demo}
ROOT=/home/serlk/mapsoly-maplibre-flutter
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export NIRI_SOCKET=$(ls /run/user/1000/niri.wayland-1.*.sock | head -1)
OUT=$ROOT/out/$LABEL; mkdir -p "$OUT"; cd "$OUT" || exit 1
rm -f log.txt ./*.png
PREV=$(niri msg windows | awk '/^Window ID/{id=$3; sub(":","",id); f=/focused/} f&&/Title/{print id; exit}')
MLN_DEMO=1 "$ROOT/app/build/linux/arm64/release/bundle/mln_flutter_spike" > log.txt 2>&1 &
PID=$!
n=0; seen=0
while [ $n -lt 150 ] && [ -d /proc/$PID ] && ! grep -q "DEMO done" log.txt; do
  c=$(grep -c "^DEMO" log.txt)
  if [ "$c" != "$seen" ]; then seen=$c; usleep 1300000; grim "$OUT/step$c.png"; fi
  usleep 100000; n=$((n+1))
done
usleep 1500000; grim "$OUT/final.png"
kill $PID; wait $PID 2>/dev/null
[ -n "$PREV" ] && niri msg action focus-window --id "$PREV"
grep -E "DEMO|MLNB|rror" log.txt
