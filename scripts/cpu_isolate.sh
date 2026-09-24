#!/bin/sh
# Measurement helper: give the engine's main thread CPU0 to itself while a run
# is in progress. Usage: cpu_isolate.sh on <engine-binary-name> | off
# on : USB IRQ -> CPU1; engine main thread -> CPU0, its other threads -> CPU1;
#      every other user process (and what it later spawns) -> CPU1, except
#      Main_MiSTer, which manages its own affinity and is never touched.
# off: everything back to both CPUs (mask 3). Kernel threads are not touched.
IRQ=$(awk -F: '/dwc2_hsotg/{gsub(/ /,"",$1); print $1}' /proc/interrupts)
case "$1" in
on)
	B=$2
	[ -n "$IRQ" ] && echo 2 > /proc/irq/$IRQ/smp_affinity
	P=$(pidof "$B")
	for pid in $(ls /proc | grep -E '^[0-9]+$'); do
		[ "$pid" = "$P" ] && continue
		readlink /proc/$pid/exe >/dev/null 2>&1 || continue   # skip kernel threads
		[ "$(cat /proc/$pid/comm)" = "MiSTer" ] && continue   # Main_MiSTer manages its own affinity
		taskset -a -p 2 $pid >/dev/null 2>&1
	done
	for t in /proc/$P/task/*; do
		tid=$(basename $t)
		if [ "$tid" = "$P" ]; then taskset -p 1 $tid >/dev/null; else taskset -p 2 $tid >/dev/null; fi
	done ;;
off)
	[ -n "$IRQ" ] && echo 3 > /proc/irq/$IRQ/smp_affinity
	for pid in $(ls /proc | grep -E '^[0-9]+$'); do
		readlink /proc/$pid/exe >/dev/null 2>&1 || continue
		[ "$(cat /proc/$pid/comm)" = "MiSTer" ] && continue   # never touched by "on"
		taskset -a -p 3 $pid >/dev/null 2>&1
	done ;;
esac
