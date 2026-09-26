# Remove what pre-platform releases installed (rendered into Scripts/CashCowDX.sh).
# The cashcowdx_daemon.sh watcher (and its user-startup.sh line) and _handler.sh:
# MiSTer Frontier's Master_Daemon would run _handler.sh as a second engine.
STARTUP=/media/fat/linux/user-startup.sh
rm -f "$GAMEDIR/_handler.sh" "$GAMEDIR/cashcowdx_daemon.sh"
if [ -f "$STARTUP" ] && grep -q "cashcowdx_daemon.sh" "$STARTUP"; then
	grep -v -e "cashcowdx_daemon.sh" -e "^# Cash Cow DX -- start the game when its core is loaded" "$STARTUP" > "$STARTUP.tmp.$$" \
		&& mv "$STARTUP.tmp.$$" "$STARTUP" && echo "launcher: removed the old watcher from $STARTUP"
fi
# shellcheck disable=SC2009  # busybox pgrep -f is not guaranteed on MiSTer
for pid in $(ps -o pid,args | awk '/[c]ashcowdx_daemon.sh/{print $1}'); do
	kill "$pid" 2>/dev/null && echo "launcher: stopped the old watcher (pid $pid)"
done
# From 20260924e: no Mesa (the engine's GL is a null implementation) and patches
# ship as binary tokens (.gdc).
[ -d "$GAMEDIR/mesa" ] && rm -rf "$GAMEDIR/mesa" && echo "launcher: removed the old Mesa runtime"
[ -f "$GAMEDIR/patches/mister_patches.gdc" ] && rm -f "$GAMEDIR"/patches/*.gd
# mem_wc modules moved to platform/mem_wc/.
rm -f "$GAMEDIR"/mem_wc-*.ko
