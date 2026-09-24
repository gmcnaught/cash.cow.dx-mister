#!/bin/bash
#
# Cash Cow DX — MiSTer Scripts-menu entry.
#
# First run: registers games/CashCowDX/cashcowdx_daemon.sh in
# /media/fat/linux/user-startup.sh and starts it. From then on, loading the
# CashCowDX core from the menu (_Other) starts the game; this entry is only
# needed once, or as a fallback.
#
# Every run: loads the CashCowDX core. The core-load daemon (ours, or MiSTer
# Frontier's Master_Daemon via _handler.sh) then starts launch.sh; if neither
# runs, this starts launch.sh itself.

GAMEDIR=/media/fat/games/CashCowDX
HANDLER="$GAMEDIR/launch.sh"
DAEMON="$GAMEDIR/cashcowdx_daemon.sh"
STARTUP=/media/fat/linux/user-startup.sh
RBF_GLOB="/media/fat/_Other/CashCowDX_*.rbf"
CORENAME="CashCowDX"
LOGDIR=/media/fat/logs/CashCowDX
CORE_WAIT_S=30

mkdir -p "$LOGDIR"
echo "Cash Cow DX: loading core and starting the engine..."
echo "log: $LOGDIR/launch.log"
exec >> "$LOGDIR/launch.log" 2>&1
echo "=== $(date) launcher start (pid $$)"

die() { echo "launcher: $*"; exit 1; }

[ -f "$HANDLER" ] || die "handler not found: $HANDLER"
[ -f "$GAMEDIR/CashCowDX.pck" ] || die "missing $GAMEDIR/CashCowDX.pck — copy it from your GOG install (see README.md)"
# update_all and zip extraction don't preserve the execute bit.
chmod +x "$HANDLER" "$DAEMON" "$GAMEDIR/_handler.sh" "$GAMEDIR/cashcowdx" 2>/dev/null

# --- core-load daemon: boot registration + start --------------------------------
if [ -f "$DAEMON" ]; then
	[ -f "$STARTUP" ] || printf '#!/bin/sh\n' > "$STARTUP"
	if ! grep -qF "$DAEMON" "$STARTUP"; then
		printf '\n# Cash Cow DX -- start the game when its core is loaded\n[ -x %s ] && %s &\n' "$DAEMON" "$DAEMON" >> "$STARTUP"
		echo "launcher: registered $DAEMON in $STARTUP"
	fi
	if ! ps -o args | grep -q '[c]ashcowdx_daemon.sh'; then
		setsid "$DAEMON" < /dev/null > /dev/null 2>&1 &
		echo "launcher: started core-load daemon (pid $!)"
	fi
fi
daemon_running() { ps -o args | grep -qE '[M]aster_Daemon.sh|[c]ashcowdx_daemon.sh'; }
launcher_running() { ps -o args | grep -q '[C]ashCowDX/launch.sh'; }

# --- core ------------------------------------------------------------------------
if [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; then
	RBF="$(ls -t $RBF_GLOB 2>/dev/null | head -1)"
	[ -n "$RBF" ] || die "no RBF matching $RBF_GLOB"
	[ -p /dev/MiSTer_cmd ] || die "/dev/MiSTer_cmd missing — is MiSTer running?"
	echo "launcher: load_core $RBF"
	echo "load_core $RBF" > /dev/MiSTer_cmd
	if daemon_running; then
		echo "launcher: core-load daemon will start the game"
		exit 0
	fi
	waited=0
	while [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; do
		sleep 1
		waited=$((waited + 1))
		[ "$waited" -ge "$CORE_WAIT_S" ] && die "core did not come up within ${CORE_WAIT_S}s (CORENAME='$(cat /tmp/CORENAME 2>/dev/null)')"
	done
	echo "launcher: core up after ${waited}s"
fi

# Core already up (or no daemon): start the game unless it is running.
launcher_running && { echo "launcher: launch.sh already running"; exit 0; }
# Detach: the Scripts console returns to the menu while the game runs.
setsid "$HANDLER" < /dev/null >> "$LOGDIR/launch.log" 2>&1 &
echo "launcher: handler started (pid $!)"
exit 0
