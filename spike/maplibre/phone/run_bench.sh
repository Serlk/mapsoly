#!/bin/sh
# run_bench.sh <gl|vk> <label> [vsync=1] [style=bright]
# Runs the scripted benchmark once (as the desktop user, inside the niri session),
# takes two screenshots, samples per-thread CPU / GPU freq / RSS, then refocuses Mapsoly.
B=${1:-gl}; LABEL=${2:-run}; VSYNC=${3:-1}; STYLE=${4:-bright}
ROOT=/home/serlk/mapsoly-maplibre
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export NIRI_SOCKET=$(ls /run/user/1000/niri.wayland-1.*.sock | head -1)
OUT=$ROOT/out/$LABEL; mkdir -p "$OUT"; cd "$OUT" || exit 1
rm -f bench.csv log.txt samples.txt *.png
[ "$B" = vk ] && export PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1
export MLN_BENCH=1 MLN_BENCH_VSYNC=$VSYNC MLN_BENCH_OUT=$OUT/bench.csv
dmesg 2>/dev/null | tail -200 > dmesg_before.txt
"$ROOT/bin/mbgl-glfw-$B" --offline -c "$OUT/cache.db" -s "$ROOT/assets/styles/$STYLE.json" \
    -y 55.752 -x 37.616 -z 14 > log.txt 2>&1 &
PID=$!
NIRI=$(echo "$NIRI_SOCKET" | sed 's/.*wayland-1\.\([0-9]*\)\.sock/\1/')
MAPSOLY=$(ps -o pid,comm | awk '$2=="mapsoly"{print $1; exit}')
sh "$ROOT/sampler.sh" $PID "$OUT/samples.txt" $NIRI $MAPSOLY &
waitfor() { i=0; while [ $i -lt $2 ] && [ -d /proc/$PID ] && ! grep -q "$1" log.txt; do usleep 200000; i=$((i+1)); done; }
waitfor "BENCH load load_center" 100; usleep 800000
niri msg windows > windows.txt 2>&1
grim "$OUT/shot_start.png"
waitfor "BENCH load jump_kremlin" 450; usleep 800000
grim "$OUT/shot_end.png"
i=0; while [ -d /proc/$PID ] && [ $i -lt 60 ]; do usleep 200000; i=$((i+1)); done
[ -d /proc/$PID ] && { echo "TIMEOUT: killing" >> log.txt; kill $PID; sleep 1; kill -9 $PID 2>/dev/null; }
wait $PID 2>/dev/null; echo "exit=$?" >> log.txt
rm -f cache.db*
WID=$(niri msg windows | awk '/^Window ID/{id=$3; sub(":","",id)} /Title: "Mapsoly"/{print id; exit}')
[ -n "$WID" ] && niri msg action focus-window --id "$WID"
grep -E "BENCH|rror|ERROR|WARN|arning" log.txt | head -60
