# Cash Cow DX on MiSTer — handoff (2026-09-23)

Read this first, then `PLAN.md` (the full record of findings and measurements, §1–§5).
This file is the short operational picture: where things are, how to build/run/measure, what is next.

## 1. State in one paragraph

Godot 4.3 Cash Cow DX runs on the DE10-Nano with **the FPGA blitter drawing every frame** (Tier 2, `PLAN.md` §5).
The engine is our own Godot 4.3-stable cross-build for Cortex-A9, with LTO and a 32-bit `fastmod` fix. It uses a MiSTer display server
(surfaceless EGL, needed only for GL resource creation) and a bridge that turns canvas RECT draws into mfgpu blitter triangles. The core is
the existing Donut Dodo 320x240 fabric core. Menus run at a locked 60 fps. The gameplay demo runs at **53 fps median (16.3 ms/frame CPU,
budget 16.7)**; it is CPU-bound on the A9 and spikes into 2-physics-tick frames. Audio (DDR ring) and input (DDR joystick words) drivers work (`PLAN.md` §6). **Real gameplay, driven by
`scripts/joy_inject.py`, collapses to 8–10 fps in stretches (physics catch-up spiral); the 53 fps figure above is the attract demo only.** No launcher yet.

## 2. Decisions already made (don't re-litigate)

| Decision | Why | Record |
|---|---|---|
| Use the **GOG build** (DRM-free). **No Steam stub.** | The user will not ship an ownership bypass. The GOG pck is byte-identical to Steam's; without GodotSteam, `steam_manager.gd` fails to parse and the game runs on, exactly like the official GOG release | PLAN §4 "0.2b results"; memory `no-drm-bypass` |
| Our own engine build, not PortMaster's `godot43.armhf` | That binary is tagged ARMv8 (SIGILL risk) and PortMaster's display path (Westonpack) has no armhf build | PLAN §4 PortMaster table |
| `-march=armv7-a -marm -mfpu=neon -mfloat-abi=hard -mtune=cortex-a9` | The A9 has NEON v1 + VFPv3-D32, no VFPv4 and no hardware divide. `-marm` avoids a GCC 10.2 ICE (`cselib.c:2614`) in `surface_tool.cpp` | PLAN §4 0.3 |
| `production=yes` (full LTO) | −24% gameplay CPU | PLAN §4 "Correction + LTO" |
| Tier 1 (llvmpipe) is not a present path | 2–4 fps; Godot 4's GLES3 canvas shader is too heavy for software GL | PLAN §4 "fastmod A/B + first rendered frames" |
| Hook **inside `RasterizerCanvasGLES3`** (not a GL-call decoder like donut.dodo) | The per-rect data is already on the CPU there, and there is less to shadow | PLAN §5 |

## 3. Layout

```
PLAN.md                         full record (findings, tables, open items)
HANDOFF.md                      this file
Dockerfile.godot4-build         cross image godot4-armhf-build:bullseye (bullseye snapshot apt, SCons wheel,
                                cross ar/ranlib + gcc-ar/gcc-ranlib links for LTO)
scripts/apply_godot_mister.py   copies src/godot/** into the Godot tree + all anchored edits (idempotent)
scripts/tier0_probe.gd          measurement autoload (via override.cfg): per-second panel/fps/CPU ms/frame
scripts/godot_dbg_profile.py    headless stand-in for the editor's remote profiler (Godot debugger protocol)
scripts/pck4_inspect.py         PCK v2 parser
src/godot/platform/linuxbsd/mister/display_server_mister.*   MiSTer display server
src/godot/drivers/gles3/mister_fabric_bridge.*               canvas → blitter bridge (engine side)
src/fabric/{mister_fabric.h,.cpp,Makefile}                   libmisterfabric.so (C ABI over vendored RasterBackend)
src/vendor/                     donut.dodo's mfgpu stack @ 7706bae (320x240 refmodel edit; see VENDOR.md)
gamedata/                       the original Steam files (static analysis only)
work/                           NOT source: Godot tree, builds, logs, decomp, tools (see below)
```

`work/` contents that matter:
- `work/src/godot-4.3-stable/`: the Godot tree **with our edits already applied**. Its objects were built with `debug_symbols=yes`, so keep that flag for incremental builds.
- `work/build/godot43fab.cortexa9`: the **current** engine (fabric bridge, LTO, fastmod; `--strip-debug`, symbol table kept for perf).
- `work/build/fabric/libmisterfabric.so`: the current library.
- `work/decomp/`: GDRE-decompiled game source (160 .gd). Read-only reference for script behaviour.
- `work/gog-extract/data/noarch/game/CashCowDX.pck`: the GOG pck (sha256 `4436b750…5d6b6c`).
- `work/tier0/`: all logs and screenshots cited in PLAN. `work/perf/pkg/`: armhf `perf` 5.10 plus its private libs.
- Tools: `work/tools/Godot 4.3.app` (editor, for the remote profiler), `work/tools/Godot RE Tools.app` (GDRE).

**There is no git repository.** `src/`, `scripts/`, `PLAN.md`, the Dockerfile and this file are the source of truth; `work/` is regenerable.
Consider `git init` (with `work/` and `gamedata/` ignored) before the next round of edits.

## 4. Build

Colima runs at 8 CPU / 8 GiB (the user raised it; ~10–14 min for a full LTO build, ~6 min incremental).

```sh
cd ~/MisterFPGA-Projects/cash.cow.dx-mister
docker build -q -t godot4-armhf-build:bullseye -f Dockerfile.godot4-build .     # only if the image is missing

# Engine: apply edits (idempotent), then build
python3 scripts/apply_godot_mister.py work/src/godot-4.3-stable
A="-march=armv7-a -marm -mfpu=neon -mfloat-abi=hard -mtune=cortex-a9"
docker run --rm -v "$PWD/work/src":/src godot4-armhf-build:bullseye sh -c "cd godot-4.3-stable && \
  scons -j\$(nproc) platform=linuxbsd arch=arm32 target=template_release production=yes debug_symbols=yes \
  x11=no wayland=no vulkan=no module_openxr_enabled=no \
  CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ ccflags='$A' linkflags='$A'"
# device copy: keep the symbol table, drop DWARF (663 MB -> 68 MB)
docker run --rm -v "$PWD/work":/w godot4-armhf-build:bullseye sh -c \
  'arm-linux-gnueabihf-objcopy --strip-debug /w/src/godot-4.3-stable/bin/godot.linuxbsd.template_release.arm32 /w/build/godot43fab.cortexa9'

# Fabric library
docker run --rm -v "$PWD":/p -w /p/src/fabric godot4-armhf-build:bullseye make
```

Build gotchas (all already handled; they matter if flags change):
- `linkflags` **must** repeat the arch flags. LTO code generation takes target flags from the link step; without them it fails with `arm_neon.h: You must enable NEON instructions`.
- `x11=no` needs `module_openxr_enabled=no` (OpenXR fails with `XrGraphicsBindingOpenGLXlibKHR`).
- Changing `debug_symbols` or `ccflags` recompiles everything (~14 min).
- The `hashfuncs.h` edit (fastmod) touches nearly every object.
- From scratch: extract `godot-4.3-stable.tar.xz` into `work/src/`, then run the apply script.

## 5. Run on the device (`root@192.168.20.81`, dir `/media/fat/games/cashcow`)

Load the fabric core first; it also works while a different core is loaded, but then nothing scans the output:
```sh
ssh root@192.168.20.81 '
for p in $(ps w | grep -v grep | grep -E "frt_3|godot43" | awk "{print \$1}"); do kill -9 $p; done
echo "load_core /media/fat/_Other/DonutDodo_48k_v224_20260922.rbf" > /dev/MiSTer_cmd; sleep 10
for p in $(ps w | grep -viE "grep|\[" | grep -E "gmloader -c|launch.sh|frt_3" | awk "{print \$1}"); do kill -9 $p; done
cat /tmp/CORENAME'          # -> DonutDodo
```
Run (fabric mode, stats every 120 frames):
```sh
cd /media/fat/games/cashcow && M=/media/fat/games/gmloader/mesa
LD_LIBRARY_PATH=$M LIBGL_DRIVERS_PATH=$M EGL_PLATFORM=surfaceless GALLIUM_DRIVER=llvmpipe \
MISTER_FABRIC=1 MISTER_FABRIC_LIB=$PWD/libmisterfabric.so GMLOADER_RASTER=mfgpu MISTER_FABRIC_STATS=120 \
GODOT_SILENCE_ROOT_WARNING=1 XDG_DATA_HOME=$PWD/data \
./godot43fab.cortexa9 --display-driver mister --rendering-driver opengl3_es --audio-driver Dummy --max-fps 60 --main-pack CashCowDX.pck
```
- **Screenshot of the real scanout:** `echo screenshot > /dev/MiSTer_cmd`, then `/media/fat/screenshots/DonutDodo/<latest>.png` (320x224 window).
- **No-FPGA oracle:** `GMLOADER_RASTER=sw MISTER_FABRIC_DUMP=<frame>` writes `/tmp/mister_fabric_frame.ppm`.
- **Tier-1 path** (llvmpipe + DDR writer, diagnostic only): drop `MISTER_FABRIC`, set `MISTER_DDR_BASE=0x3BF40000 MISTER_STATS=60`.
- **Headless logic-only measurement:** `./godot43fab.cortexa9 --headless --max-fps 60 --main-pack CashCowDX.pck`.

**Warning:** `/media/fat/games/cashcow/override.cfg` loads the measurement probe (`tier0_probe.gd`) as an autoload for **every** run in that directory.
It prints a `PROBE` line per second and force-enables `VisibleOnScreenEnabler2D` targets, which only headless needs. Remove it (or move it
out) for any non-measurement run, and before packaging.

Measurement rules learned the hard way (PLAN §4):
- Always use `--max-fps 60`. Headless otherwise shows a false ~145 fps ceiling from `low_processor_mode_sleep_usec`.
- Headless stalls the attract loop on `cast_panel` (a VisibleOnScreenEnabler2D) unless the probe emulates enablers.
- Judge CPU by `cpu_ms_per_frame` from `/proc/self/stat`. Godot's `Performance.TIME_*` monitors read >100% of wall time here.
- Don't put anything expensive in the probe. A full-tree `find_children` every 0.25 s once inflated results 4× (see the PLAN "Correction").
- Release output needs `stdbuf -oL` to show up before a `timeout` kill.

Profiling:
- `perf`: `cd perf && LD_LIBRARY_PATH=$PWD/lib ./perf record -e cpu-clock -F 999 -p <pid> -o /tmp/p.data -- sleep 8`, then `perf report --stdio --no-children --sort dso,sym`.
  The `cycles` event records nothing; DWARF call graphs stop at libc.
- Script-level: build `target=template_debug`, run with `--remote-debug tcp://<mac>:6008`, and on the Mac run
  `python3 scripts/godot_dbg_profile.py out.jsonl --port 6008 [--native]`. It auto-continues the Steam parse-error break.
  The device helper is `run_profile.sh` (`PORT=6008`). The debug binary on the device (`godot43d.cortexa9`) is from before fastmod and the display server; rebuild it if you use it.

## 6. Next steps, in order

0. **Real-play cost (PLAN §6).** Per-thread perf and a GDScript profile of scripted play (`run_play.sh` + `joy_inject.py`);
   compare with the attract demo. Consider `max_physics_steps_per_frame=1` for the shipped config (slowdown instead of 8 fps).
   Confirm audio by ear.

1. **Gameplay under 16.7 ms.** Now 16.3 ms p50, 23 ms max (`work/tier0/fab_hw2.log`). Candidates, each measured A/B with the probe on the fabric core:
   - `Control::add_theme_*_override`: early return when the value is unchanged (`scene/gui/control.cpp:2883`). The HUD re-applies a colour every
     tick (`ui/hud/info.gd:44`, `ui/hud/p1.gd:34,58`). Estimate −0.8 ms/tick.
   - Remaining software divides (fastmod got −7% of the ~11% perf showed). Re-run perf on `godot43fab`, find the `__aeabi_uidivmod` callers
     (symbol-level; no call graphs, so look at the next-hottest functions or `perf annotate`).
   - Render-side CPU (~2.6 ms/frame): `RendererCanvasCull::_cull_canvas_item`, `_draw_viewport`, and whatever GL calls remain in `canvas_begin`.
   - Physics BVH (~6% in `BVH_Tree<GodotCollisionObject2D>` with 170 gold `Area2D`s).
2. **Input:** DDR joystick words (P1 at `0x3BF40000+0x08`, bits `0=R 1=L 2=D 3=U 4=B 5=A 6=Y 7=X 8=Start`) → Godot joypad events, SDL-style
   button layout. Game actions are `p1_*_dpad/_controller` (`project.binary`). Reference: donut.dodo `patches/0005` (SDL joystick driver).
   Natural home: `DisplayServerMister::process_events()`.
3. **Audio:** Godot `AudioDriver` → DDR audio ring (48 kHz stereo S16, ring at `0x3A0D0000`, wr/rd ptr `0x3A000030/38`), from donut.dodo
   `patches/0004` (SDL `mister` audio driver, which is `gm_audio` on the core side). Check the core's `SRC_RATE` (48000 on the v224 RBF per donut.dodo PLAN §1g).
4. **Exercise real gameplay and menus** (after input): watch the `MISTER_FABRIC … unhandled:` counters for NINEPATCH/POLYGON/PRIMITIVE,
   plus `premult`, clip rects (the fabric has no scissor) and the flash shader (`flash=` count, never yet seen > 0 in attract mode).
5. **Scanout crop:** the core shows rows 7–230 (224 lines) of 240. Decide whether that's acceptable for the HUD (top rows).
6. **Tier 3:** `games/Cash Cow DX/launch.sh` with the env above, a one-engine guard (like donut.dodo's), fabric-wedge recovery (`RasterBackend_MFGPU_Shutdown`
   is already wired to atexit/signals in the library), no `override.cfg`; README stating that the user supplies the GOG `CashCowDX.pck`.

## 7. Known risks

- The fabric can wedge (donut.dodo saw C_DONE freeze after ~2 min, PLAN §1j there). Our runs were ≤110 s. Do a long soak before calling it stable.
- `--render-thread separate` is slower on the fabric path (PLAN §6.5: 19.8 vs 41.2 fps at 8 steps); don't enable it.
- Mesa from `/media/fat/games/gmloader/mesa` is a dependency: it creates GL objects, and textures still upload to llvmpipe in fabric mode.
  A GL-free rasterizer stub could remove it later, but it's not needed for correctness.
