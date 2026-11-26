#!/bin/sh
# run_standalone.sh <label>   (as serlk) -- the spike's standalone GLFW benchmark (GLES, vsync),
# same session and conditions as the Flutter runs, as the reference. Uses the spike's binary and
# assets in /home/serlk/mapsoly-maplibre, writes to this prototype's out/<label>/.
LABEL=${1:-ref}
SPIKE=/home/serlk/mapsoly-maplibre; ROOT=/home/serlk/mapsoly-maplibre-flutter
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export NIRI_SOCKET=$(ls /run/user/1000/niri.wayland-1.*.sock | head -1)
OUT=$ROOT/out/$LABEL; mkdir -p "$OUT"; cd "$OUT" || exit 1
rm -f bench.csv log.txt samples.txt focus.txt busy_during.txt ./*.png
busy() { cat /proc/loadavg; ps -o pid,comm | awk '$2 ~ /^(flutter|ninja|dart|dartaotruntime|clang|clang\+\+|cmake|ld\.lld|gen_snapshot|cc1|cc1plus|gcc|g\+\+|make|cargo|rustc)/'; }
busy > busy_before.txt
PREV=$(niri msg windows | awk '/^Window ID/{id=$3; sub(":","",id); f=/focused/} f&&/Title/{print id; exit}')
export MLN_BENCH=1 MLN_BENCH_VSYNC=1 MLN_BENCH_OUT=$OUT/bench.csv
"$SPIKE/bin/mbgl-glfw-gl" --offline -c "$OUT/cache.db" -s "$SPIKE/assets/styles/bright.json" \
    -y 55.752 -x 37.616 -z 14 > log.txt 2>&1 &
PID=$!
NIRI=$(echo "$NIRI_SOCKET" | sed 's/.*wayland-1\.\([0-9]*\)\.sock/\1/')
sh "$ROOT/sampler.sh" $PID "$OUT/samples.txt" $NIRI &
( while [ -d /proc/$PID ]; do
    busy | sed 1d >> busy_during.txt   # compilers etc. started by somebody else mid-run
    echo "$(cut -d' ' -f1 /proc/uptime) $(niri msg focused-window 2>/dev/null | awk -F'"' '/PID/{next} /App ID/{print $2; f=1; exit} END{if(!f) print "(none)"}')" >> focus.txt
    sleep 1
  done ) &
i=0; while [ -d /proc/$PID ] && [ $i -lt 500 ]; do usleep 200000; i=$((i+1)); done
[ -d /proc/$PID ] && { echo "TIMEOUT: killing" >> log.txt; kill $PID; sleep 1; kill -9 $PID 2>/dev/null; }
wait $PID 2>/dev/null; echo "exit=$?" >> log.txt
busy > busy_after.txt
rm -f cache.db*
[ -n "$PREV" ] && niri msg action focus-window --id "$PREV"
echo "focus app ids seen:"; cut -d' ' -f2- focus.txt | sort | uniq -c
echo "busy before/after/during:"; cat busy_before.txt busy_after.txt; sort busy_during.txt 2>/dev/null | awk '{print $2}' | uniq -c
