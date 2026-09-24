#!/bin/sh
# Device: A/B real play. ab_play.sh <binary> <tag> [steps]
# Scripted input (fixed seed), probe on, enablers off, max_physics_steps_per_frame=<steps> (default 1).
cd /media/fat/games/cashcow

P=""; [ "${PATCH:-0}" = 1 ] && P='MisterPatches="*/media/fat/games/cashcow/patches/mister_patches.gd"\n'
[ "${SPIKES:-0}" = 1 ] && P="${P}SpikeProbe=\"*/media/fat/games/cashcow/spike_probe.gd\"\n"
printf "[autoload]\n\n${P}Tier0Probe=\"*/media/fat/games/cashcow/tier0_probe.gd\"\n\n[physics]\n\ncommon/max_physics_steps_per_frame=%s\n" "${3:-1}" > override.cfg
for p in $(ps w | grep -v grep | grep "[.]/godot43" | awk '{print $1}'); do kill -9 $p; done
BIN=$1 TIER0_ENABLERS=none JOY_BASE=0x3A0C0000 ./run_play.sh $RARGS > ab_$2.log 2>&1 &
python3 joy_inject.py "wait 20; start; wait 3; a; wait 3; a; wait 3; a; wait 3; a; wait 3; play 45" > /dev/null 2>&1
kill %1; sleep 1; printf '[autoload]\n\nTier0Probe="*/media/fat/games/cashcow/tier0_probe.gd"\n' > override.cfg
# gameplay window = probe lines with nodes > 500
awk '/^PROBE/ { split($8,n,"="); if (n[2] > 500) { split($2,t,"="); split($5,f,"="); split($6,c,"=");
  if (!t0) t0 = t[2]; t1 = t[2]; fr += f[2]; cpu += c[2] * f[2]; k++ } }
  END { printf "%s: %d probe lines, wall %ds, %.1f fps, %.2f cpu_ms/frame\n", "'$2'", k, t1 - t0 + 1, fr / (t1 - t0 + 1), cpu / fr }' ab_$2.log
