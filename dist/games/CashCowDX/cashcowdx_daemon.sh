#!/bin/sh
#
# Cash Cow DX — core-load watcher.
#
# Starts the game when the CashCowDX core is loaded from the MiSTer menu
# (_Other/CashCowDX_*.rbf): watches /tmp/CORENAME and runs launch.sh while the
# core is up. launch.sh stops the engine itself when another core is loaded.
#
# If MiSTer Frontier's Master_Daemon runs, it owns the lifecycle (it runs this
# folder's _handler.sh) and this daemon stays passive, so there is never a
# double launch.
#
# Started at boot from /media/fat/linux/user-startup.sh; Scripts/CashCowDX.sh
# registers it there and starts it on first use.

GAMEDIR=/media/fat/games/CashCowDX
CORE=CashCowDX
LAUNCH="$GAMEDIR/launch.sh"
LOGDIR=/media/fat/logs/CashCowDX
MIN_RUN=10          # a run shorter than this counts as a failed start

mkdir -p "$LOGDIR"
exec >> "$LOGDIR/daemon.log" 2>&1
echo "=== $(date) cashcowdx_daemon start (pid $$)"

frontier_running() { ps -o args 2>/dev/null | grep -q '[M]aster_Daemon.sh'; }
launcher_running() { ps -o args 2>/dev/null | grep -q '[C]ashCowDX/launch.sh'; }

CHILD=""; START=0; FAILS=0; LAST=""
while :; do
	sleep 1
	core=$(tr -d '\000\r\n ' < /tmp/CORENAME 2>/dev/null)
	[ "$core" != "$LAST" ] && { FAILS=0; LAST="$core"; }
	if [ -n "$CHILD" ] && ! kill -0 "$CHILD" 2>/dev/null; then
		wait "$CHILD" 2>/dev/null
		[ $(( $(date +%s) - START )) -lt $MIN_RUN ] && FAILS=$((FAILS + 1)) || FAILS=0
		CHILD=""
	fi
	[ "$core" = "$CORE" ] || continue
	frontier_running && continue
	[ -z "$CHILD" ] || continue
	launcher_running && continue
	if [ "$FAILS" -ge 3 ]; then
		[ "$FAILS" -eq 3 ] && { echo "$(date) launch.sh failed to start 3x — not retrying until the core is reloaded"; FAILS=4; }
		continue
	fi
	echo "$(date) core $CORE loaded — starting launch.sh"
	setsid "$LAUNCH" < /dev/null > /dev/null 2>&1 &
	CHILD=$!; START=$(date +%s)
done
