#!/bin/bash
# Device: stage 5 boss zipwire rides on the installed release (real launcher).
# [PROBE=zip|scan] [SHOTS=1] [EXTRA_ENV="export K=V"] run.sh <tag> [patches dir; default: the release's]
# Copy the probes (*.gd) and this script to /tmp first.
# Output: /media/fat/logs/CashCowDX/zipride/<tag>/zip.txt (probe lines), frames.bin (MISTER_FRAMELOG).
set -u
TAG=$1; PDIR=${2:-}
G=/media/fat/games/CashCowDX
OUT=/media/fat/logs/CashCowDX/zipride/$TAG
mkdir -p "$OUT"; rm -f "$OUT"/*
pidof cashcowdx >/dev/null && { echo "engine already running — stop it first"; exit 1; }
cp "$G/override.cfg" /tmp/cc_override.bak
restore() {
	cp /tmp/cc_override.bak "$G/override.cfg"
	rm -f /tmp/cashcowdx_test.env
}
trap restore EXIT
MP="$G/patches/mister_patches.gdc"; [ -f "$MP" ] || MP="$G/patches/mister_patches.gd"
[ -n "$PDIR" ] && { MP="$PDIR/mister_patches.gdc"; [ -f "$MP" ] || MP="$PDIR/mister_patches.gd"; }
printf '[autoload]\n\nMisterPatches="*%s"\nZipProbe="*/tmp/%s_probe.gd"\n' "$MP" "${PROBE:-zip}" > "$G/override.cfg"
{
	echo "export ZIPPROBE_OUT=/tmp/cc_zip.txt"
	echo "export MISTER_SEED=1"; echo "export MISTER_FRAMELOG=/tmp/cc_frames.bin"
	[ -n "$PDIR" ] && echo "export MISTER_PATCHES_DIR=$PDIR"
	[ -n "${EXTRA_ENV:-}" ] && echo "$EXTRA_ENV"
} > /tmp/cashcowdx_test.env
cp /tmp/cashcowdx_test.env "$OUT/test.env"
rm -f /tmp/cc_zip.txt /tmp/cc_frames.bin /tmp/cc_shots.txt
/media/fat/Scripts/CashCowDX.sh > /dev/null
# SHOTS=1: a MiSTer screenshot at each W line (the probe holds the frame 60 frames).
SHOTPID=""
if [ "${SHOTS:-0}" = 1 ]; then
	( n=0; while :; do
		c=$(grep -c '^W' /tmp/cc_zip.txt 2>/dev/null); c=${c:-0}
		if [ "$c" -gt "$n" ]; then
			n=$c; sleep 0.3; echo screenshot > /dev/MiSTer_cmd; sleep 1.5
			f=$(ls -t /media/fat/screenshots/*/*.png | head -1); echo "$(grep '^W' /tmp/cc_zip.txt | sed -n "${n}p") $f" >> /tmp/cc_shots.txt
		fi; sleep 0.2; done ) &
	SHOTPID=$!
fi
w=0; until grep -q '^DONE' /tmp/cc_zip.txt 2>/dev/null; do
	sleep 2; w=$((w+2)); [ $w -gt 400 ] && { echo "no DONE after 400 s"; break; }
done
[ -n "$SHOTPID" ] && kill $SHOTPID
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
sleep 6
cp /tmp/cc_zip.txt "$OUT/zip.txt" 2>/dev/null; cp /tmp/cc_frames.bin "$OUT/frames.bin" 2>/dev/null; rm -f /tmp/cc_frames.bin
cp /media/fat/logs/CashCowDX/cashcowdx.log "$OUT/engine.log"
[ -f /tmp/cc_shots.txt ] && while read -r _ label _ f; do cp "$f" "$OUT/$label.png"; done < /tmp/cc_shots.txt
grep '^R' "$OUT/zip.txt"
grep -iE 'error|MisterPatches' "$OUT/engine.log" | head -30
