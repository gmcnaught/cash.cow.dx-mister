#!/bin/bash
#
# Cash Cow DX — MiSTer Scripts-menu entry: loads the CashCowDX core and starts
# the game.
#
# With Scripts -> CashCowDX_CoresMenu turned on (MiSTer.ini [CashCowDX]
# main=...), loading the core from the core list also starts the game, and this
# entry only loads the core. Otherwise this entry starts games/CashCowDX/launch.sh
# itself once the core is up.
#
# Also removes what older releases installed: the cashcowdx_daemon.sh watcher
# (and its user-startup.sh line) and _handler.sh, which MiSTer Frontier's
# Master_Daemon would run as a second engine on the same core load.

GAMEDIR=/media/fat/games/CashCowDX
HANDLER="$GAMEDIR/launch.sh"
WRAPPER="$GAMEDIR/MiSTer_CashCowDX"
INI=/media/fat/MiSTer.ini
STARTUP=/media/fat/linux/user-startup.sh
RBF_GLOB="/media/fat/_Other/CashCowDX_*.rbf"
CORENAME="CashCowDX"
LOGDIR=/media/fat/logs/CashCowDX
CORE_WAIT_S=30

mkdir -p "$LOGDIR"
echo "Cash Cow DX: loading core and starting the engine..."
echo "log: $LOGDIR/launch.log"
exec >> "$LOGDIR/launch.log" 2>&1
echo "=== $(date) Scripts entry (pid $$)"

die() { echo "launcher: $*"; exit 1; }

[ -f "$HANDLER" ] || die "handler not found: $HANDLER"
[ -f "$GAMEDIR/CashCowDX.pck" ] || die "missing $GAMEDIR/CashCowDX.pck — copy it from your GOG install (see README.md)"
# update_all and zip extraction don't preserve the execute bit.
chmod +x "$HANDLER" "$WRAPPER" "$GAMEDIR/cashcowdx" 2>/dev/null

# --- remove older releases' core-load watchers -----------------------------------
rm -f "$GAMEDIR/_handler.sh" "$GAMEDIR/cashcowdx_daemon.sh"
if [ -f "$STARTUP" ] && grep -q "cashcowdx_daemon.sh" "$STARTUP"; then
	grep -v -e "cashcowdx_daemon.sh" -e "^# Cash Cow DX -- start the game when its core is loaded" "$STARTUP" > "$STARTUP.tmp.$$" \
		&& mv "$STARTUP.tmp.$$" "$STARTUP" && echo "launcher: removed the old watcher from $STARTUP"
fi
for pid in $(ps -o pid,args | awk '/[c]ashcowdx_daemon.sh/{print $1}'); do
	kill "$pid" 2>/dev/null && echo "launcher: stopped the old watcher (pid $pid)"
done

main_on() { [ -x "$WRAPPER" ] && grep -q "^main=$WRAPPER" "$INI" 2>/dev/null; }
launcher_running() { ps -o args | grep -q '[C]ashCowDX/launch.sh'; }

# --- core ------------------------------------------------------------------------
if [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; then
	RBF="$(ls -t $RBF_GLOB 2>/dev/null | head -1)"
	[ -n "$RBF" ] || die "no RBF matching $RBF_GLOB"
	[ -p /dev/MiSTer_cmd ] || die "/dev/MiSTer_cmd missing — is MiSTer running?"
	echo "launcher: load_core $RBF"
	echo "load_core $RBF" > /dev/MiSTer_cmd
	if main_on; then
		echo "launcher: main= is on — MiSTer_CashCowDX starts the game"
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

# Core already up: start the game unless it is running.
launcher_running && { echo "launcher: launch.sh already running"; exit 0; }
# Detach: the Scripts console returns to the menu while the game runs.
setsid "$HANDLER" < /dev/null >> "$LOGDIR/launch.log" 2>&1 &
echo "launcher: handler started (pid $!)"
exit 0
