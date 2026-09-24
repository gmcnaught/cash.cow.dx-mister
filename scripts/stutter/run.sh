#!/bin/bash
# Device: stutter capture on the installed release (real launcher: CPU isolation,
# pinning, mem_wc). run.sh <tag> [seconds=300] [engine binary to test]
#
# Engine: MISTER_FRAMELOG per-frame records (phases, main-thread CPU, context
# switches, faults) + state_probe.gd (game state, scene instantiations).
# System: perf trace of CPU0 (sched_switch, hard IRQs, softirqs; CLOCK_MONOTONIC),
# 1 Hz /proc/stat + /proc/interrupts + /proc/softirqs + /proc/meminfo samples.
# PROF=1 adds 1 kHz sampling of the engine main thread (prof.txt.gz; frames.py --prof).
# PERF_ON=0 skips the trace (no tmpfs perf.data; removes the tracer's own cost).
# Input: joy_drive.py (random play; restarts after game over). LIVES=<n> (default 99; 0 = the game's own)
# keeps lives topped up via state_probe.gd so a run is mostly gameplay.
# Output: /media/fat/logs/CashCowDX/stutter/<tag>/ ; analyse with scripts/stutter/frames.py.
set -u
TAG=$1; SECS=${2:-300}; ENGINE_SRC=${3:-}
G=/media/fat/games/CashCowDX
H=/media/fat/games/cashcow           # dev dir: perf, joy_inject.py
OUT=/media/fat/logs/CashCowDX/stutter/$TAG
PERF="$H/perf/perf"
mkdir -p "$OUT"; rm -f "$OUT"/*
pidof cashcowdx >/dev/null && { echo "engine already running — stop it first"; exit 1; }

cp "$G/override.cfg" /tmp/cc_override.bak
if [ -n "$ENGINE_SRC" ]; then
	[ -f "$G/cashcowdx.release" ] || cp "$G/cashcowdx" "$G/cashcowdx.release"
	cp "$ENGINE_SRC" "$G/cashcowdx"; chmod +x "$G/cashcowdx"
fi
md5sum "$G/cashcowdx" > "$OUT/engine.md5"
restore() {
	cp /tmp/cc_override.bak "$G/override.cfg"
	rm -f /tmp/cashcowdx_test.env
}
trap restore EXIT
cp "$(dirname "$0")/state_probe.gd" "$G/state_probe.gd"
printf '[autoload]\n\nMisterPatches="*%s/patches/mister_patches.gd"\nStateProbe="*%s/state_probe.gd"\n' "$G" "$G" > "$G/override.cfg"
cat > /tmp/cashcowdx_test.env <<EOF
export CASHCOW_JOY_BASE=0x3A0C0000
export MISTER_FRAMELOG=/tmp/cc_frames.bin
export MISTER_TEST_LIVES=${LIVES:-99}
export MISTER_TEST_STATE_FILE=/tmp/cc_state.txt
EOF
# EXTRA_ENV="export A=1; export B=2": more engine/launcher env for this run (A/B knobs).
[ -n "${EXTRA_ENV:-}" ] && echo "$EXTRA_ENV" >> /tmp/cashcowdx_test.env
cp /tmp/cashcowdx_test.env "$OUT/test.env"
rm -f /tmp/cc_frames.bin /tmp/cc_state.txt /media/fat/logs/CashCowDX/cashcowdx.log

/media/fat/Scripts/CashCowDX.sh > /dev/null
# Launcher isolates CPU0 after fabric bring-up and logs "cpu: ..."
w=0; until grep -q "^cpu: USB IRQ" /media/fat/logs/CashCowDX/cashcowdx.log 2>/dev/null; do
	sleep 1; w=$((w+1)); [ $w -gt 90 ] && { echo "no isolation line after 90 s"; exit 1; }
done
taskset -p 2 $$ > /dev/null      # this shell and its children stay off CPU0
sleep 12                         # attract loop; fabric gate passes
echo "engine pid $(pidof cashcowdx)" > /tmp/cc_info.txt
for t in /proc/$(pidof cashcowdx)/task/*; do echo "$(cat $t/comm) tid ${t##*/} $(taskset -p ${t##*/} | awk '{print $NF}')"; done >> /tmp/cc_info.txt

# 1 Hz system sampler
( while :; do echo "T $(awk '{print $1}' /proc/uptime)"; grep -E '^cpu[01] ' /proc/stat; grep -E "MemFree|MemAvailable|^Cached" /proc/meminfo | awk '{print "M", $1, $2}'; grep -E ':' /proc/interrupts | awk '{print "I", $1, $2, $3, $NF}'
  grep -E 'TIMER|NET_RX|TASKLET|SCHED|RCU|BLOCK|HRTIMER' /proc/softirqs | awk '{print "S", $1, $2, $3}'; sleep 1; done > /tmp/cc_sys.txt ) &
SAMP=$!
PERFPID=""
[ "${PERF_ON:-1}" = 1 ] || PERF=""
if [ -n "$PERF" ]; then LD_LIBRARY_PATH=$H/perf/lib taskset 2 "$PERF" record -q -k mono -C 0 -e sched:sched_switch -e irq:irq_handler_entry --filter "irq != 24" -e irq:irq_handler_exit --filter "irq != 24" \
	-e irq:softirq_entry -e irq:softirq_exit -o /tmp/cc_perf.data -- sleep $SECS > /dev/null 2>&1 &
PERFPID=$!
else sleep $SECS & PERFPID=$!; fi
# Input: joy_drive.py follows the game state (restarts after game over); JOY=fixed for the old fixed loop.
if [ "${JOY:-drive}" = fixed ]; then
( end=$(( $(date +%s) + SECS )); while [ $(date +%s) -lt $end ]; do
	python3 $H/joy_inject.py "start; wait 3; a; wait 3; a; wait 3; a; wait 3; a; wait 3; play 240"; done ) > /tmp/cc_joy.txt 2>&1 &
else
python3 "$(dirname "$0")/joy_drive.py" $SECS /tmp/cc_state.txt > /tmp/cc_joy.txt 2>&1 &
fi
INJ=$!
# PROF=1: sample the engine main thread (leaf IP + symbol; the binary keeps .symtab)
PROFPID=""
if [ "${PROF:-0}" = 1 ]; then
	LD_LIBRARY_PATH=$H/perf/lib taskset 2 "$H/perf/perf" record -q -k mono -e cpu-clock -F 1000 -t "$(pidof cashcowdx)" -o /tmp/cc_prof.data -- sleep $SECS > /dev/null 2>&1 &
	PROFPID=$!
fi
wait $PERFPID
[ -n "$PROFPID" ] && wait $PROFPID
kill $INJ $SAMP 2>/dev/null
for p in $(ps w | grep -E "[j]oy_(inject|drive).py" | awk '{print $1}'); do kill $p; done
python3 - <<'EOF'
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0x3A0C0000)
struct.pack_into("<I", m, 0x08, 0)
EOF
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
sleep 6
# Everything above wrote to /tmp: /media/fat is mounted sync (each append is an SD write).
cp /tmp/cc_frames.bin "$OUT/frames.bin"; mv /tmp/cc_sys.txt "$OUT/sys.txt"; mv /tmp/cc_joy.txt "$OUT/joy.txt"
mv /tmp/cc_state.txt "$OUT/state.txt"
cp /media/fat/logs/CashCowDX/cashcowdx.log "$OUT/engine.log"
[ -n "$PERF" ] && LD_LIBRARY_PATH=$H/perf/lib "$PERF" script -i /tmp/cc_perf.data -F time,cpu,comm,tid,event,trace 2>/dev/null | gzip -1 > "$OUT/cpu0.txt.gz"
[ -f /tmp/cc_prof.data ] && LD_LIBRARY_PATH=$H/perf/lib "$H/perf/perf" script -i /tmp/cc_prof.data -F time,ip,sym 2>/dev/null | gzip -1 > "$OUT/prof.txt.gz"
rm -f /tmp/cc_perf.data /tmp/cc_frames.bin /tmp/cc_prof.data
cat /tmp/cc_info.txt >> "$OUT/info.txt"; rm -f /tmp/cc_info.txt
echo "after exit: engine=$(pidof cashcowdx || echo gone) core=$(cat /tmp/CORENAME)" >> "$OUT/info.txt"
ls -la "$OUT"
