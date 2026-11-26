#!/bin/sh
# batch.sh "<label> <script> [ENV=...]" ...   (as serlk)
# Runs one benchmark per argument, e.g.
#   sh batch.sh "ref1 run_standalone.sh" "a1 run_bench.sh" "b1 run_bench.sh MLN_SUBSURFACE=1"
# Other people build software on this phone: a run waits until no compiler is running, and is
# repeated once if one showed up before, during or after it. Log: out/batch.log
ROOT=/home/serlk/mapsoly-maplibre-flutter; L=$ROOT/out/batch.log
noisy() { ps -o comm | grep -qE '^(cc1|cc1plus|gcc|g\+\+|make|ninja|cmake|clang|clang\+\+|ld\.lld|ld|as|moc|flutter|dart|dartaotruntime|gen_snapshot|cargo|rustc)$'; }
for spec in "$@"; do
  set -- $spec; label=$1; script=$2; shift 2
  try=1
  while [ $try -le 2 ]; do
    i=0; while noisy && [ $i -lt 180 ]; do sleep 5; i=$((i+1)); done
    sleep 10
    if noisy; then continue; fi
    echo "=== $label [$script $*] try $try $(date +%T) load $(cut -d' ' -f1-3 /proc/loadavg)" >> $L
    env "$@" sh $ROOT/$script "$label" >> $L 2>&1
    O=$ROOT/out/$label
    if [ -s $O/busy_during.txt ] || [ "$(wc -l < $O/busy_before.txt)" -gt 1 ] || [ "$(wc -l < $O/busy_after.txt)" -gt 1 ]; then
      echo "--- $label: other builds were running, repeating" >> $L
      try=$((try+1))
    else
      echo "--- $label: clean" >> $L; break
    fi
  done
  sleep 5
done
echo "=== batch done $(date +%T)" >> $L
