#!/bin/bash
#
# Cash Cow DX on MiSTer — engine launcher (started by Scripts/CashCowDX.sh).
#
# Engine: Godot 4.3 built for the Cortex-A9 with a MiSTer display server, DDR
# audio and joystick drivers, and a canvas->FPGA-blitter bridge (the fabric
# draws every frame). Mesa (bundled) only creates GL objects.
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
CORENAME=DonutDodo
RBF_GLOB="/media/fat/_Other/CashCowDX_*.rbf"
ENGINE=cashcowdx
FABRIC_CTRL=0x3B000000      # C_SUBMIT
FABRIC_DONE=0x3B000028      # C_DONE
RETRY_MARK=/tmp/cashcowdx_fabric_retry
LOCKDIR=/tmp/cashcowdx-launch.lock
MAX_RETRIES=4

mkdir -p "$LOGDIR" "$GAMEDIR/data"
cd "$GAMEDIR" || exit 1

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
	sleep 1; waited=$((waited + 1))
done
sleep 1

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
	for pid in $(ls /proc | grep -E '^[0-9]+$'); do
		[ "$pid" = "$$" ] && continue
		readlink /proc/$pid/exe >/dev/null 2>&1 || continue      # kernel threads
		case "$(cat /proc/$pid/comm 2>/dev/null)" in MiSTer|$ENGINE) continue ;; esac
		old=$(taskset -p "$pid" 2>/dev/null | awk '{print $NF}')
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
	[ -n "$engine_pid" ] && kill "$engine_pid" 2>/dev/null
	cpu_restore
	rm -rf "$LOCKDIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- engine ---------------------------------------------------------------------
export LD_LIBRARY_PATH="$GAMEDIR/mesa"
export LIBGL_DRIVERS_PATH="$GAMEDIR/mesa"
export EGL_PLATFORM=surfaceless
export GALLIUM_DRIVER=llvmpipe
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

start_engine() {
	taskset 2 ./$ENGINE --display-driver mister --rendering-driver opengl3_es --audio-driver MiSTer \
		--max-fps 60 --main-pack CashCowDX.pck &
	engine_pid=$!
	echo "engine: started pid $engine_pid"
}

# Blitter still retiring work? (done advances, or nothing is outstanding)
fabric_ok() {
	local d0 d1 s1
	d0=$(busybox devmem $FABRIC_DONE 32 2>/dev/null); sleep 8
	d1=$(busybox devmem $FABRIC_DONE 32 2>/dev/null); s1=$(busybox devmem $FABRIC_CTRL 32 2>/dev/null)
	echo "fabric gate: done $d0 -> $d1 (submit $s1)"
	[ "$d1" != "$d0" ] || [ "$d1" = "$s1" ]
}

reload_core() {
	local rbf waited
	rbf=$(ls -t $RBF_GLOB 2>/dev/null | head -1)
	[ -n "$rbf" ] && [ -p /dev/MiSTer_cmd ] || return 1
	echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
	waited=0; while [ "$(cat /tmp/CORENAME 2>/dev/null)" != "MENU" ] && [ $waited -lt 20 ]; do sleep 1; waited=$((waited+1)); done
	echo "load_core $rbf" > /dev/MiSTer_cmd
	waited=0; while [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ] && [ $waited -lt 30 ]; do sleep 1; waited=$((waited+1)); done
	sleep 2
}

attempt=$(cat "$RETRY_MARK" 2>/dev/null); case "$attempt" in ''|*[!0-9]*) attempt=0 ;; esac
start_engine
# Give the engine time to bring the fabric up, then isolate CPU0 for it.
waited=0
while [ $waited -lt 60 ] && ! grep -q "fabric bring-up" "$LOG" 2>/dev/null; do
	kill -0 "$engine_pid" 2>/dev/null || { echo "engine exited during start-up"; exit 1; }
	sleep 1; waited=$((waited + 1))
done
cpu_isolate
if ! fabric_ok; then
	if [ "$attempt" -lt "$MAX_RETRIES" ]; then
		echo $((attempt + 1)) > "$RETRY_MARK"
		echo "fabric gate: WEDGED — reloading the core, attempt $((attempt + 1))/$MAX_RETRIES"
		kill "$engine_pid" 2>/dev/null; sleep 2; kill -9 "$engine_pid" 2>/dev/null; engine_pid=""
		cpu_restore
		rm -rf "$LOCKDIR"; trap - EXIT
		reload_core && exec "$0"
		exit 1
	fi
	echo "fabric gate: still wedged after $attempt attempts — leaving the engine running"
fi
rm -f "$RETRY_MARK"

# --- watchdog: another core loaded from the OSD -> stop the engine ---------------
while kill -0 "$engine_pid" 2>/dev/null; do
	if [ "$(cat /tmp/CORENAME 2>/dev/null)" != "$CORENAME" ]; then
		echo "watchdog: core changed to '$(cat /tmp/CORENAME 2>/dev/null)' — stopping the engine"
		kill "$engine_pid" 2>/dev/null; sleep 2; kill -9 "$engine_pid" 2>/dev/null
		break
	fi
	sleep 1
done
wait "$engine_pid" 2>/dev/null
echo "engine: exited ($?)"
