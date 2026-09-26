#!/bin/sh
# Device-side state for the main= hook test: which Main binary runs, how many
# launchers/engines exist, whether the fabric retires work, old watchers.
# Usage (host): ssh root@<mister> sh -s < scripts/mainhook_state.sh
m=$(pidof MiSTer MiSTer_hybrid 2>/dev/null)
echo "CORENAME=$(cat /tmp/CORENAME)  main_pids=[$m]"
for p in $m; do echo "  pid $p exe=$(readlink /proc/$p/exe)"; done
echo "launch.sh: $(ps -o pid,args | grep -c '[C]ashCowDX/launch.sh')  engine(cashcowdx): $(pidof cashcowdx | wc -w)  other fabric engines: $(pidof gmloader frt_3.5.2 | wc -w)"
d0=$(busybox devmem 0x3B000028 32); sleep 1; d1=$(busybox devmem 0x3B000028 32)
echo "C_DONE $d0 -> $d1 (1 s)"
echo "old watchers: cashcowdx_daemon=$(ps -o args | grep -c '[c]ashcowdx_daemon') _handler.sh=$(ls /media/fat/games/CashCowDX/_handler.sh 2>/dev/null | wc -l) startup_line=$(grep -c cashcowdx_daemon /media/fat/linux/user-startup.sh)"
echo "Master_Daemon running: $(ps -o args | grep -c '[M]aster_Daemon.sh')"
