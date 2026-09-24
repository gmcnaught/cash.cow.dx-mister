#!/bin/bash
# Device soak test of the installed release: soak.sh <minutes>
# Starts the game via /media/fat/Scripts/CashCowDX.sh with scripted input
# (CASHCOW_JOY_BASE -> joy_inject.py page), plays continuously, and every 60 s
# records: engine alive, C_DONE advancing (no fabric wedge), CORENAME.
# Screenshot every 5 min. Afterwards: stops the game by loading the menu core
# and checks the launcher restored CPU placement.
MIN=${1:-30}
J=/media/fat/games/cashcow/joy_inject.py
OUT=/media/fat/logs/CashCowDX/soak.txt
mkdir -p /media/fat/logs/CashCowDX; : > $OUT
export CASHCOW_JOY_BASE=0x3A0C0000
/media/fat/Scripts/CashCowDX.sh
sleep 25
PID=$(pidof cashcowdx); echo "engine pid ${PID:-none}" >> $OUT
# Continuous play: start the game, then random play; repeat for the duration.
( end=$(( $(date +%s) + MIN * 60 )); while [ $(date +%s) -lt $end ]; do
	python3 $J "start; wait 3; a; wait 3; a; wait 3; a; wait 3; a; wait 3; play 240" > /dev/null 2>&1; done ) &
INJ=$!
d_prev=$(busybox devmem 0x3B000028 32)
for m in $(seq 1 $MIN); do
	sleep 60
	d=$(busybox devmem 0x3B000028 32); alive=no; kill -0 $PID 2>/dev/null && alive=yes
	echo "min $m: engine=$alive C_DONE $d_prev -> $d $([ "$d" != "$d_prev" ] && echo advancing || echo STALLED) core=$(cat /tmp/CORENAME)" >> $OUT
	d_prev=$d
	[ $((m % 5)) -eq 0 ] && echo screenshot > /dev/MiSTer_cmd
	[ "$alive" = yes ] || break
done
kill $INJ 2>/dev/null
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
sleep 8
echo "after exit: engine=$(pidof cashcowdx || echo gone) irq=$(cat /proc/irq/$(awk -F: '/dwc2_hsotg/{gsub(/ /,"",$1);print $1}' /proc/interrupts)/smp_affinity)" >> $OUT
for pid in $(ls /proc | grep -E '^[0-9]+$'); do readlink /proc/$pid/exe >/dev/null 2>&1 || continue; m=$(taskset -p $pid 2>/dev/null | awk '{print $NF}'); [ "$m" != 3 ] && echo "  pid $pid $(cat /proc/$pid/comm) mask $m" >> $OUT; done
tail -25 /media/fat/logs/CashCowDX/cashcowdx.log | grep -vi steam >> $OUT
echo done >> $OUT
