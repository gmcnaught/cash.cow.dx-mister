#!/bin/bash
#
# Cash Cow DX — MiSTer Scripts-menu entry.
#
# Loads the fabric core, then hands over to games/CashCowDX/launch.sh, which
# starts the engine. Selecting the core from the Cores menu alone loads the
# bitstream and starts nothing.
#
# The core is the shared Godot/GameMaker fabric core; it reports itself as
# "DonutDodo" in /tmp/CORENAME, which is what this waits for.

GAMEDIR=/media/fat/games/CashCowDX
HANDLER="$GAMEDIR/launch.sh"
RBF_GLOB="/media/fat/_Other/CashCowDX_*.rbf"
CORENAME="DonutDodo"
LOGDIR=/media/fat/logs/CashCowDX
CORE_WAIT_S=30

mkdir -p "$LOGDIR"
echo "Cash Cow DX: loading core and starting the engine..."
echo "log: $LOGDIR/launch.log"
exec >> "$LOGDIR/launch.log" 2>&1
echo "=== $(date) launcher start (pid $$) ==="

die() { echo "launcher: $*"; exit 1; }

[ -x "$HANDLER" ] || die "handler not found or not executable: $HANDLER"
[ -f "$GAMEDIR/CashCowDX.pck" ] || die "missing $GAMEDIR/CashCowDX.pck — copy it from your GOG install (see README.md)"

if [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; then
	RBF="$(ls -t $RBF_GLOB 2>/dev/null | head -1)"
	[ -n "$RBF" ] || die "no RBF matching $RBF_GLOB"
	[ -p /dev/MiSTer_cmd ] || die "/dev/MiSTer_cmd missing — is MiSTer running?"
	echo "launcher: load_core $RBF"
	echo "load_core $RBF" > /dev/MiSTer_cmd
	waited=0
	while [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; do
		sleep 1
		waited=$((waited + 1))
		[ "$waited" -ge "$CORE_WAIT_S" ] && die "core did not come up within ${CORE_WAIT_S}s (CORENAME='$(cat /tmp/CORENAME 2>/dev/null)')"
	done
	echo "launcher: core up after ${waited}s"
fi

# Detach: the Scripts console returns to the menu while the game runs.
setsid "$HANDLER" < /dev/null >> "$LOGDIR/launch.log" 2>&1 &
echo "launcher: handler started (pid $!)"
exit 0
