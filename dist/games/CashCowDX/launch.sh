#!/bin/bash
#
# Cash Cow DX on MiSTer — engine launcher. Started by MiSTer_CashCowDX when the
# CashCowDX core loads (MiSTer.ini [CashCowDX] main=, turned on by
# Scripts/CashCowDX_CoresMenu.sh), or by Scripts/CashCowDX.sh.
#
# Engine: Godot 4.3 built for the Cortex-A9 with a MiSTer display server, DDR
# audio and joystick drivers, and a canvas->FPGA-blitter bridge (the fabric
# draws every frame). GL is a null implementation in the engine: no Mesa.
#
# What this script adds around the engine:
#   - one engine at a time (lock + reap), FPGA-ready wait
#   - mem_wc: write-combining DDR mapping, loaded if absent, NEVER unloaded
#   - CPU placement: CPU0 for the engine's main thread; USB IRQ, the engine's
#     other threads and other user processes on CPU1; restored on exit
#   - fabric gate: if the blitter stops retiring work after start, reload the
#     core and retry (up to 4 times)
#   - watchdog: stop the engine if another core is loaded from the OSD
set -u

GAMEDIR=/media/fat/games/CashCowDX
LOGDIR=/media/fat/logs/CashCowDX
LOG="$LOGDIR/cashcowdx.log"
CORENAME=CashCowDX
RBF_GLOB="/media/fat/_Other/CashCowDX_*.rbf"
ENGINE=cashcowdx
FABRIC_CTRL=0x3B000000      # C_SUBMIT
FABRIC_DONE=0x3B000028      # C_DONE
RETRY_MARK=/tmp/cashcowdx_fabric_retry
LOCKDIR=/tmp/cashcowdx-launch.lock
MAX_RETRIES=4

# Interruptible sleep, so a SIGTERM runs the cleanup trap without waiting for a
# foreground sleep.
nap() { sleep "$1" & wait $!; }

mkdir -p "$LOGDIR" "$GAMEDIR/data"
# Measurement hook (scripts/stutter/): extra env for the engine, e.g. MISTER_FRAMELOG.
# In /tmp, so it never survives a reboot.
[ -f /tmp/cashcowdx_test.env ] && . /tmp/cashcowdx_test.env
cd "$GAMEDIR" || exit 1

# Only on our core (e.g. a Scripts run racing a core change).
if [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; then
	echo "$(date) launch.sh: core is '$(cat /tmp/CORENAME 2>/dev/null)', not $CORENAME — not starting" >> "$LOGDIR/launch.log"
	exit 0
fi

# --- one launcher / one engine -------------------------------------------------
if ! mkdir "$LOCKDIR" 2>/dev/null; then
	owner=$(cat "$LOCKDIR/pid" 2>/dev/null)
	if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
		echo "launch.sh: another launcher (pid $owner) is running — standing down"
		exit 0
	fi
fi
echo $$ > "$LOCKDIR/pid"
# Any fabric engine (ours or another port's) on the same control block corrupts it.
for name in $ENGINE gmloader frt_3.5.2; do
	for pid in $(pidof "$name" 2>/dev/null); do
		echo "launch.sh: stopping a running fabric engine ($name pid $pid)"
		kill "$pid" 2>/dev/null
		sleep 2
		kill -9 "$pid" 2>/dev/null
	done
done

mv -f "$LOG" "$LOGDIR/cashcowdx.prev.log" 2>/dev/null
exec >> "$LOG" 2>&1
echo "=== $(date) launch.sh (pid $$) CORENAME='$(cat /tmp/CORENAME 2>/dev/null)' kernel=$(uname -r)"

# --- FPGA ready (bit 31 of the HPS GPI is low once the core is configured) ----
waited=0
while v=$(busybox devmem 0xFF706014 32 2>/dev/null) && [ -n "$v" ] && [ $((v & 0x80000000)) -ne 0 ]; do
	[ "$waited" -ge 20 ] && { echo "FPGA still not ready after 20s — starting anyway"; break; }
	nap 1; waited=$((waited + 1))
done
# Settle only after a wait: when the core was already configured (the usual
# case — main= starts us after the load) the engine's own start-up (~2.5 s
# before the fabric bring-up) is margin enough (PLAN §6.26).
[ "$waited" -gt 0 ] && nap 1

# --- mem_wc (optional; the fabric library falls back to /dev/mem) -------------
# Load only if nothing has: never rmmod a mem_wc — a process can keep a live
# mapping after closing the fd, and unloading under it once hung a device.
KO="$GAMEDIR/mem_wc-$(uname -r).ko"
if [ ! -e /dev/mem_wc ]; then
	if [ -f "$KO" ]; then
		insmod "$KO" phys_base=0x3B000000 phys_size=0x01000000 2>/dev/null \
			&& echo "mem_wc: loaded ($KO)" || echo "mem_wc: insmod failed — strongly-ordered DDR mapping"
	else
		echo "mem_wc: no module for kernel $(uname -r) — strongly-ordered DDR mapping"
	fi
else
	echo "mem_wc: already present"
fi

# --- CPU placement --------------------------------------------------------------
USB_IRQ=$(awk -F: '/dwc2_hsotg/{gsub(/ /,"",$1); print $1; exit}' /proc/interrupts)
USB_IRQ_MASK=""
[ -n "$USB_IRQ" ] && USB_IRQ_MASK=$(cat /proc/irq/$USB_IRQ/smp_affinity 2>/dev/null)
MOVED=""
cpu_isolate() {
	[ -n "$USB_IRQ" ] && echo 2 > /proc/irq/$USB_IRQ/smp_affinity 2>/dev/null
	# This launcher too: its watchdog loop forks every second, and each fork on
	# CPU0 preempted the main thread (stutter capture base1, PLAN §6.25).
	taskset -p 2 $$ >/dev/null 2>&1
	# Builtins only per /proc entry: the readlink/cat/taskset forks for ~110
	# entries ran on CPU1 while the engine boots (PLAN §6.27). taskset forks
	# only for a process that moves.
	local d pid cmd comm key old
	for d in /proc/[0-9]*; do
		pid=${d#/proc/}
		[ "$pid" = "$$" ] && continue
		cmd=""; read -r -d '' cmd 2>/dev/null < "$d/cmdline"
		[ -n "$cmd" ] || continue                                 # kernel threads (and exited)
		comm=""; read -r comm 2>/dev/null < "$d/comm"
		case "$comm" in MiSTer|$ENGINE) continue ;; esac
		old=""
		while read -r key old; do [ "$key" = "Cpus_allowed:" ] && break; old=""; done 2>/dev/null < "$d/status"
		old=${old##*,}; old=${old#"${old%%[!0]*}"}               # "00000003" -> "3"
		[ -n "$old" ] && [ "$old" != "2" ] || continue
		taskset -a -p 2 "$pid" >/dev/null 2>&1 && MOVED="$MOVED $pid:$old"
	done
	# Engine threads created after the main thread pinned itself inherited CPU0.
	if [ -n "$engine_pid" ]; then
		for t in /proc/$engine_pid/task/*; do
			tid=${t##*/}
			[ "$tid" = "$engine_pid" ] || taskset -p 2 "$tid" >/dev/null 2>&1
		done
	fi
	echo "cpu: USB IRQ ${USB_IRQ:-none} -> CPU1; moved $(echo "$MOVED" | wc -w) processes and the engine's worker threads to CPU1"
}
cpu_restore() {
	[ -n "$USB_IRQ" ] && [ -n "$USB_IRQ_MASK" ] && echo "$USB_IRQ_MASK" > /proc/irq/$USB_IRQ/smp_affinity 2>/dev/null
	for e in $MOVED; do
		taskset -a -p "${e#*:}" "${e%%:*}" >/dev/null 2>&1
	done
	MOVED=""
	echo "cpu: restored"
}

engine_pid=""
cleanup() {
	# Background: a SIGKILL of this script must not skip the engine kill or the restore.
	[ -n "$engine_pid" ] && { kill "$engine_pid" 2>/dev/null; ( sleep 2; kill -9 "$engine_pid" 2>/dev/null ) & }
	cpu_restore &
	rm -rf "$LOCKDIR"
	wait
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- engine ---------------------------------------------------------------------
export MISTER_FABRIC=1
export MISTER_FABRIC_LIB="$GAMEDIR/libmisterfabric.so"
export GMLOADER_RASTER=mfgpu
export MISTER_JOY=1
# This core's joystick words (Maldita.sv FB_QW_BASE). CASHCOW_JOY_BASE is a test hook
# (scripted input via scripts/joy_inject.py writing an unused DDR page).
export MISTER_JOY_BASE=${CASHCOW_JOY_BASE:-0x3BF40000}
export MISTER_PATCHES_DIR="$GAMEDIR/patches"
export MISTER_PIN_MAIN=0                 # the engine starts on CPU1 (taskset 2); main moves to CPU0
export MISTER_PIN_AUDIO=1
export GODOT_SILENCE_ROOT_WARNING=1
export XDG_DATA_HOME="$GAMEDIR/data"
export XDG_CONFIG_HOME="$GAMEDIR/data"

# Frame pacing: libmisterfabric paces on the core's scanout frame counter
# (MISTER_FABRIC_PACE=scanout), so Godot's own limiter is off (--max-fps 0);
# two pacers at 60.00 and ~59.92 Hz drifted against the scanout (PLAN §6.25).
start_engine() {
	# Engine output goes through a pipe to a logger process (moved to CPU1 with the
	# rest): /media/fat is mounted sync, so a print written straight to the log
	# would block the main thread on an SD write (PLAN §6.25).
	taskset 2 ./$ENGINE --display-driver mister --rendering-driver opengl3_es --audio-driver MiSTer \
		--max-fps "${CASHCOW_MAX_FPS:-0}" --main-pack CashCowDX.pck > >(exec cat) 2>&1 &
	engine_pid=$!
	echo "engine: started pid $engine_pid"
}

# Blitter still retiring work? (done advances, or nothing is outstanding)
fabric_ok() {
	local d0 d1 s1
	d0=$(busybox devmem $FABRIC_DONE 32 2>/dev/null); nap 8
	d1=$(busybox devmem $FABRIC_DONE 32 2>/dev/null); s1=$(busybox devmem $FABRIC_CTRL 32 2>/dev/null)
	echo "fabric gate: done $d0 -> $d1 (submit $s1)"
	[ "$d1" != "$d0" ] || [ "$d1" = "$s1" ]
}

# Reload the core via the menu core, from a detached helper. After the reload
# MiSTer_CashCowDX starts a new launch.sh when main= is on; otherwise the helper
# starts it.
reload_core() {
	local rbf
	rbf=$(ls -t $RBF_GLOB 2>/dev/null | head -1)
	[ -n "$rbf" ] && [ -p /dev/MiSTer_cmd ] || return 1
	setsid sh -c '
		echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
		w=0; while [ "$(cat /tmp/CORENAME 2>/dev/null)" != MENU ] && [ $w -lt 20 ]; do sleep 1; w=$((w+1)); done
		echo "load_core $1" > /dev/MiSTer_cmd
		w=0; while [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$2" ] && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
		sleep 2
		[ -x "$4" ] && grep -q "^main=$4" /media/fat/MiSTer.ini 2>/dev/null || exec "$3"
	' reload "$rbf" "$CORENAME" "$0" "$GAMEDIR/MiSTer_CashCowDX" < /dev/null >> "$LOG" 2>&1 &
	# Hold until the core is gone, so this launcher exits before the reloaded core starts the next one.
	local waited=0
	while [ "$(cat /tmp/CORENAME 2>/dev/null)" = "$CORENAME" ] && [ $waited -lt 20 ]; do nap 1; waited=$((waited+1)); done
}

attempt=$(cat "$RETRY_MARK" 2>/dev/null); case "$attempt" in ''|*[!0-9]*) attempt=0 ;; esac
start_engine
# Give the engine time to bring the fabric up, then isolate CPU0 for it.
waited=0
while [ $waited -lt 60 ] && ! grep -q "fabric bring-up" "$LOG" 2>/dev/null; do
	kill -0 "$engine_pid" 2>/dev/null || { echo "engine exited during start-up"; exit 1; }
	nap 1; waited=$((waited + 1))
done
cpu_isolate
if ! fabric_ok; then
	if [ "$attempt" -lt "$MAX_RETRIES" ]; then
		echo $((attempt + 1)) > "$RETRY_MARK"
		echo "fabric gate: WEDGED — reloading the core, attempt $((attempt + 1))/$MAX_RETRIES"
		kill "$engine_pid" 2>/dev/null; nap 2; kill -9 "$engine_pid" 2>/dev/null; engine_pid=""
		cpu_restore
		rm -rf "$LOCKDIR"
		reload_core
		exit 1
	fi
	echo "fabric gate: still wedged after $attempt attempts — leaving the engine running"
fi
rm -f "$RETRY_MARK"

# --- watchdog: another core loaded from the OSD -> stop the engine ---------------
while kill -0 "$engine_pid" 2>/dev/null; do
	cur=""; read -r cur < /tmp/CORENAME 2>/dev/null
	if [ "$cur" != "$CORENAME" ]; then
		echo "watchdog: core changed to '$cur' — stopping the engine"
		kill "$engine_pid" 2>/dev/null; nap 2; kill -9 "$engine_pid" 2>/dev/null
		break
	fi
	nap 1
done
wait "$engine_pid" 2>/dev/null
echo "engine: exited ($?)"
