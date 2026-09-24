#!/bin/bash
# Device: time a boot of the installed release from core load to the attract
# screen. boot_time.sh <tag> [cold|warm] [engine binary to test]
#   cold: drop the page cache first (first launch after power-on); warm: keep it.
# Loads the menu core, then `load_core` the CashCowDX RBF (as the OSD does; main=
# starts launch.sh), samples with boot_poll.py for SECS (default 45), then loads
# the menu core again. Engine: MISTER_BOOTLOG (startup phases, resource loads),
# MISTER_FRAMELOG; state_probe.gd for STATE/SCENE lines.
# EXTRA_ENV="export K=V" adds engine env; PERF=1 samples both CPUs (perf, 500 Hz). (Call graphs don't unwind on the LTO build: no frame pointers or unwind tables.)
# Output: /media/fat/logs/CashCowDX/boot/<tag>/ ; analyse with scripts/boot/boot_report.py.
set -u
TAG=$1; MODE=${2:-cold}; ENGINE_SRC=${3:-}; SECS=${SECS:-45}
G=/media/fat/games/CashCowDX
H=/media/fat/games/cashcow
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=/media/fat/logs/CashCowDX/boot/$TAG
RBF=$(ls -t /media/fat/_Other/CashCowDX_*.rbf | head -1)
mkdir -p "$OUT"; rm -f "$OUT"/*
pidof cashcowdx >/dev/null && { echo "engine already running — stop it first"; exit 1; }

to_menu() {
	[ "$(cat /tmp/CORENAME)" = MENU ] && return
	echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
	w=0; while [ "$(cat /tmp/CORENAME)" != MENU ] && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
	sleep 3
}
to_menu

cp "$G/override.cfg" /tmp/cc_boot_override.bak
if [ -n "$ENGINE_SRC" ]; then
	cmp -s "$ENGINE_SRC" "$G/cashcowdx" || { cp "$G/cashcowdx" /tmp/cc_boot_engine.bak; cp "$ENGINE_SRC" "$G/cashcowdx"; chmod +x "$G/cashcowdx"; }
fi
md5sum "$G/cashcowdx" > "$OUT/engine.md5"
restore() {
	cp /tmp/cc_boot_override.bak "$G/override.cfg"
	if [ -f /tmp/cc_boot_engine.bak ]; then cp /tmp/cc_boot_engine.bak "$G/cashcowdx"; rm -f /tmp/cc_boot_engine.bak; fi
	rm -f /tmp/cashcowdx_test.env
}
trap restore EXIT
cp "$H/stutter/state_probe.gd" "$G/state_probe.gd"
MP="$G/patches/mister_patches.gdc"; [ -f "$MP" ] || MP="$G/patches/mister_patches.gd"   # releases ship .gdc
printf '[autoload]\n\nMisterPatches="*%s"\nStateProbe="*%s/state_probe.gd"\n' "$MP" "$G" > "$G/override.cfg"
cat > /tmp/cashcowdx_test.env <<EOT
export MISTER_BOOTLOG=/tmp/cc_bootlog.txt
export MISTER_FRAMELOG=/tmp/cc_frames.bin
export MISTER_TEST_LIVES=0
export MISTER_TEST_STATE_FILE=/tmp/cc_state.txt
EOT
[ -n "${EXTRA_ENV:-}" ] && echo "$EXTRA_ENV" >> /tmp/cashcowdx_test.env
cp /tmp/cashcowdx_test.env "$OUT/test.env"
rm -f /tmp/cc_bootlog.txt /tmp/cc_frames.bin /tmp/cc_state.txt /tmp/cc_boot_perf.data
sync
[ "$MODE" = cold ] && echo 3 > /proc/sys/vm/drop_caches
sleep 1

taskset 2 python3 "$HERE/boot_poll.py" "$SECS" /tmp/cc_boot_poll.txt &
POLL=$!
PERFPID=""
if [ "${PERF:-0}" = 1 ]; then
	LD_LIBRARY_PATH=$H/perf/lib taskset 2 "$H/perf/perf" record -q -k mono -a -e cpu-clock -F 500 -o /tmp/cc_boot_perf.data -- sleep "$SECS" > /dev/null 2>&1 &
	PERFPID=$!
	sleep 1
fi
T0=$(awk '{print $1}' /proc/uptime)
python3 -c 'import time; print("T0 %.4f" % time.monotonic())' > "$OUT/t0.txt"
echo "load_core $RBF" > /dev/MiSTer_cmd
wait $POLL
[ -n "$PERFPID" ] && wait $PERFPID
cp /media/fat/logs/CashCowDX/cashcowdx.log "$OUT/engine.log" 2>/dev/null
to_menu
mv /tmp/cc_boot_poll.txt "$OUT/poll.txt"
for f in bootlog.txt frames.bin state.txt; do [ -f /tmp/cc_$f ] && mv /tmp/cc_$f "$OUT/$f"; done
[ -f /tmp/cc_boot_perf.data ] && LD_LIBRARY_PATH=$H/perf/lib "$H/perf/perf" script -i /tmp/cc_boot_perf.data -F time,cpu,comm,tid,ip,sym,dso 2>/dev/null | gzip -1 > "$OUT/perf.txt.gz"
rm -f /tmp/cc_boot_perf.data
echo "mode=$MODE rbf=$RBF" > "$OUT/info.txt"
ls -la "$OUT"
