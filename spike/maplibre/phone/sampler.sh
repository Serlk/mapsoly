#!/bin/sh
# sampler.sh PID OUTFILE [EXTRA_PID...]  -- samples every ~0.5 s until PID exits:
#   "T <uptime_s> <gpu_freq_hz> <VmRSS_kB>" then raw /proc/PID/task/*/stat lines,
#   then "X <pid> <raw stat>" for each extra process (compositor etc.).
PID=$1; OUT=$2; shift 2
: > "$OUT"
while [ -d /proc/$PID ]; do
  {
    echo "T $(cut -d' ' -f1 /proc/uptime) $(cat /sys/class/devfreq/13000000.gpu/cur_freq) $(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null)"
    cat /proc/$PID/task/*/stat 2>/dev/null
    for x in "$@"; do echo "X $x $(cat /proc/$x/stat 2>/dev/null)"; done
  } >> "$OUT"
  usleep 450000
done
