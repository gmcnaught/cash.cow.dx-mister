#!/bin/sh
# Device: hardware counters on the engine's main thread during scripted gameplay.
#   perf_stat_play.sh <binary> <tag> [patch 0|1]
# Level loads at ~t=36 with the joy_inject script below; counts t=42..62.
cd /media/fat/games/cashcow
export LD_LIBRARY_PATH=$PWD/perf/lib
P=""; [ "${3:-1}" = 1 ] && P='MisterPatches="*/media/fat/games/cashcow/patches/mister_patches.gd"\n'
printf "[autoload]\n\n${P}Tier0Probe=\"*/media/fat/games/cashcow/tier0_probe.gd\"\n\n[physics]\n\ncommon/max_physics_steps_per_frame=1\n" > override.cfg
for p in $(ps w | grep -v grep | grep "[.]/godot43" | awk '{print $1}'); do kill -9 $p; done
BIN=$1 TIER0_ENABLERS=none JOY_BASE=0x3A0C0000 ./run_play.sh > ps_$2.log 2>&1 &
python3 joy_inject.py "wait 20; start; wait 3; a; wait 3; a; wait 3; a; wait 3; a; wait 3; play 45" > /dev/null 2>&1 &
sleep 42
PID=$(pidof $1)
./perf/perf stat -t $PID -e cycles,instructions,L1-icache-load-misses,stalled-cycles-frontend,stalled-cycles-backend,branch-misses -- sleep 10 > ps_$2.a.txt 2>&1
./perf/perf stat -t $PID -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,iTLB-load-misses,branch-instructions -- sleep 10 > ps_$2.b.txt 2>&1
wait %2 2>/dev/null; kill %1 2>/dev/null; sleep 1
printf '[autoload]\n\nTier0Probe="*/media/fat/games/cashcow/tier0_probe.gd"\n' > override.cfg
echo "== $2 ($1, patch=${3:-1})"; grep -E "cycles|instructions|misses|loads|elapsed" ps_$2.a.txt ps_$2.b.txt | sed 's/^ps_[^:]*://'
grep PROBE ps_$2.log | awk '{split($2,t,"="); if (t[2]>=42 && t[2]<=62) print $2,$5,$8}' | tr '\n' '|'; echo
