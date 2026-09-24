#!/bin/bash
# Device: MiSTer screenshots (scaler output) at fixed times after loading the core, with a test
# engine swapped in. shot.sh <tag> <engine> <seconds...>; files: /media/fat/screenshots/<tag>_<s>s.png
TAG=$1; E=$2; shift 2
G=/media/fat/games/CashCowDX
while pidof cashcowdx >/dev/null || ps | grep -q "[r]un.sh \|[l]g_ab.sh\|[p]m_ab.sh"; do sleep 5; done
cp $G/cashcowdx /tmp/shot_engine.bak; cp "$E" $G/cashcowdx; chmod +x $G/cashcowdx
trap 'cp /tmp/shot_engine.bak $G/cashcowdx' EXIT
RBF=$(ls -t /media/fat/_Other/CashCowDX_*.rbf | head -1)
echo "load_core $RBF" > /dev/MiSTer_cmd
t=0
for s in "$@"; do
	sleep $((s - t)); t=$s
	echo "screenshot ${TAG}_${s}s.png" > /dev/MiSTer_cmd
done
sleep 2
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
sleep 8
ls -t /media/fat/screenshots/*/ 2>/dev/null | head -12
find /media/fat/screenshots -name "${TAG}_*" 
