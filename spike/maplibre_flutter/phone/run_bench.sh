#!/bin/sh
# run_bench.sh <label> [style=bright]   (run as serlk inside the niri session)
# Starts the Flutter test app with the scripted camera run, keeps a record of which window
# has focus, takes two screenshots, samples per-thread CPU / GPU freq / RSS.
# Output: /home/serlk/mapsoly-maplibre-flutter/out/<label>/
# Extra switches are passed through the environment: MLN_TICKER=1, MLNB_BIG=1, MLNB_SERIAL=1,
# MLN_SUBSURFACE=1 (route B), MLN_STATIC=1, MLNB_NOVSYNC=1 (route B only).
LABEL=${1:-run}; STYLE=${2:-bright}
ROOT=/home/serlk/mapsoly-maplibre-flutter
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
export NIRI_SOCKET=$(ls /run/user/1000/niri.wayland-1.*.sock | head -1)
OUT=$ROOT/out/$LABEL; mkdir -p "$OUT"; cd "$OUT" || exit 1
rm -f ./*.csv log.txt samples.txt focus.txt busy_during.txt ./*.png
busy() { cat /proc/loadavg; ps -o pid,comm | awk '$2 ~ /^(flutter|ninja|dart|dartaotruntime|clang|clang\+\+|cmake|ld\.lld|gen_snapshot|cc1|cc1plus|gcc|g\+\+|make|cargo|rustc)/'; }
busy > busy_before.txt
PREV=$(niri msg windows | awk '/^Window ID/{id=$3; sub(":","",id); f=/focused/} f&&/Title/{print id; exit}')
export MLN_BENCH=1 MLN_BENCH_OUT=$OUT/bench MLN_STYLE=/home/serlk/mapsoly-maplibre/assets/styles/$STYLE.json
echo "env: MLN_TICKER=${MLN_TICKER:-} MLNB_BIG=${MLNB_BIG:-} MLNB_SERIAL=${MLNB_SERIAL:-} MLN_SUBSURFACE=${MLN_SUBSURFACE:-} MLN_STATIC=${MLN_STATIC:-} MLNB_NOVSYNC=${MLNB_NOVSYNC:-} style=$STYLE" > env.txt
"$ROOT/app/build/linux/arm64/release/bundle/mln_flutter_spike" > log.txt 2>&1 &
PID=$!
NIRI=$(echo "$NIRI_SOCKET" | sed 's/.*wayland-1\.\([0-9]*\)\.sock/\1/')
sh "$ROOT/sampler.sh" $PID "$OUT/samples.txt" $NIRI &
# focus log: one line per second, "uptime focused-title"
( while [ -d /proc/$PID ]; do
    busy | sed 1d >> busy_during.txt   # compilers etc. started by somebody else mid-run
    echo "$(cut -d' ' -f1 /proc/uptime) $(niri msg focused-window 2>/dev/null | awk -F'"' '/Title/{print $2; f=1; exit} END{if(!f) print "(none)"}')" >> focus.txt
    sleep 1
  done ) &
waitfor() { i=0; while [ $i -lt $2 ] && [ -d /proc/$PID ] && ! grep -q "$1" log.txt; do usleep 200000; i=$((i+1)); done; }
waitfor "BENCH load load_center" 150; usleep 800000
niri msg windows > windows.txt 2>&1
grim "$OUT/shot_start.png"
waitfor "BENCH seg zoomin_cold" 200; usleep 3000000
grim "$OUT/shot_mid.png"
waitfor "BENCH seg nav_pitch_rot" 300; usleep 3500000
grim "$OUT/shot_nav.png"
waitfor "BENCH load jump_kremlin" 300; usleep 800000
grim "$OUT/shot_end.png"
i=0; while [ -d /proc/$PID ] && [ $i -lt 60 ]; do usleep 200000; i=$((i+1)); done
[ -d /proc/$PID ] && { echo "TIMEOUT: killing" >> log.txt; kill $PID; sleep 1; kill -9 $PID 2>/dev/null; }
wait $PID 2>/dev/null; echo "exit=$?" >> log.txt
busy > busy_after.txt
[ -n "$PREV" ] && niri msg action focus-window --id "$PREV"
grep -E "BENCH|MLNB|rror|ERROR|WARN|arning" log.txt | head -60
echo "focus titles seen:"; cut -d' ' -f2- focus.txt | sort | uniq -c
echo "busy before/after/during:"; cat busy_before.txt busy_after.txt; sort busy_during.txt 2>/dev/null | awk '{print $2}' | uniq -c
