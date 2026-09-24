# Cash Cow DX on MiSTer — handoff (2026-09-24)

Read this first, then `PLAN.md` (the full record of findings and measurements; §6 covers everything since audio/input).
Repo: private `github.com/gmcnaught/cash.cow.dx-mister`. `work/`, `gamedata/`, `build/` and any `*.pck` are never committed.

## 1. State

Godot 4.3 Cash Cow DX runs on the DE10-Nano with the FPGA blitter drawing every frame, DDR audio, and the MiSTer joystick.
Real gameplay (scripted input, Godot's default 8 physics steps/frame) runs at a ~59–60 fps per-second mean; the main thread
costs ~11 ms/frame of the 16.7 ms budget. The remaining dips were CPU placement (USB IRQs, the audio thread and other ports'
polling daemons sharing CPU0 with the main thread); the release launcher isolates CPU0 for the main thread (PLAN §6.18).
Every canvas command type the game uses now reaches the fabric (rects, split large rects, polygons; `unhandled: none`).
A release bundle (`scripts/make_release.sh`) installs and starts from **Scripts → CashCowDX**; the user supplies the GOG
`CashCowDX.pck`.

## 2. Decisions already made (don't re-litigate)

| Decision | Record |
|---|---|
| GOG build, no Steam stub | PLAN §4 0.2b; memory `no-drm-bypass` |
| Own Godot 4.3 cross-build, `-marm` (Thumb-2 measured equal, §6.9), LTO | PLAN §4, §6.9 |
| Target Godot's default `max_physics_steps_per_frame=8` (no 1-step cap) | PLAN §6.8 |
| Behaviour-preserving changes only; game-behaviour trade-offs need sign-off (e.g. direction-only raycasts, §6.15) | — |
| `--render-thread separate` is slower on the fabric path | PLAN §6.5 |
| GDScript inline property cache: kept but OFF (`MISTER_GD_CACHE=1`); no measured gain, one spiral seen with it | PLAN §6.16 |
| mem_wc: load if absent, **never rmmod** | `tools/mem_wc/README.md` |

## 3. Layout

```
PLAN.md, HANDOFF.md
Dockerfile.godot4-build          cross image godot4-armhf-build:bullseye
scripts/apply_godot_mister.py    copies src/godot/** into the Godot tree + all anchored engine edits (idempotent)
src/godot/                        MiSTer platform (display server, audio, joypad), fabric bridge, GDScript cache
src/fabric/, src/vendor/          libmisterfabric (C ABI over the vendored mfgpu RasterBackend; deltas in src/vendor/VENDOR.md)
src/patches/                      runtime GDScript patches + loader (mister_patches.gd); loaded via override.cfg
tools/mem_wc/                     write-combining /dev/mem driver: build.sh for the device kernel, prebuilt .ko
dist/                             release launcher: Scripts/CashCowDX.sh, games/CashCowDX/{launch.sh,override.cfg}, README.md
scripts/make_release.sh           assembles build/release/CashCowDX-MiSTer-<tag>.zip
scripts/ (measurement)            ab_play.sh, perf_stat_play.sh, spike_probe.gd, cpu_isolate.sh, soak.sh, joy_inject.py,
                                  tier0_probe.gd, godot_dbg_profile.py, profile_summary.py, sfx_bench.gd, gd_access_bench.gd,
                                  named_cache_test.gd, sfx_hash.gd
work/                             NOT source: Godot tree (edits applied), builds, logs (work/tier0/aj/), decomp, tools
```

## 4. Build

```sh
python3 scripts/apply_godot_mister.py work/src/godot-4.3-stable
A="-march=armv7-a -marm -mfpu=neon -mfloat-abi=hard -mtune=cortex-a9"
docker run --rm -v "$PWD/work/src":/src godot4-armhf-build:bullseye sh -c "cd godot-4.3-stable && \
  scons -j\$(nproc) platform=linuxbsd arch=arm32 target=template_release production=yes debug_symbols=yes \
  x11=no wayland=no vulkan=no module_openxr_enabled=no \
  CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ ccflags='$A' linkflags='$A'"
docker run --rm -v "$PWD/work":/w godot4-armhf-build:bullseye sh -c \
  'arm-linux-gnueabihf-objcopy --strip-debug /w/src/godot-4.3-stable/bin/godot.linuxbsd.template_release.arm32 /w/build/<name>.cortexa9'
docker run --rm -v "$PWD":/p -w /p/src/fabric godot4-armhf-build:bullseye make OUT=../../work/build/fabric_opt   # library
tools/mem_wc/build.sh                                  # kernel module for the device's running kernel
scripts/make_release.sh work/build/<name>.cortexa9 <tag>
```
Incremental LTO builds take ~7 min, full ~14 min. Don't run the apply script while a subagent is editing `src/godot/`.

## 5. Device (`root@192.168.20.81`)

- Release install: `/media/fat/games/CashCowDX` (+ `Scripts/CashCowDX.sh`, `_Other/CashCowDX_*.rbf`); logs `/media/fat/logs/CashCowDX/`.
- Dev/measurement dir: `/media/fat/games/cashcow` (engines `godot43*.cortexa9`, `patches/`, `patches_typed/`, probes, `run_play.sh`, `ab_play.sh`).
- Measurement: `PATCH=1 MISTER_SEED=1 MISTER_PATCHES_DIR=.../patches_typed ./ab_play.sh <engine> <tag> <steps>`; add `SPIKES=1` for
  per-frame spike logging; `./perf_stat_play.sh <engine> <tag> 1` for main-thread cycles/frame (the probe's cpu_ms is both cores).
- Scripted input: engine with `MISTER_JOY_BASE=0x3A0C0000` (release: `CASHCOW_JOY_BASE`), then `joy_inject.py "<steps>"`.
- Never run two measurement loops at once (they kill each other's engines); never `rmmod mem_wc`.

## 6. Next steps

1. **Human checks:** done — user confirmed launch via Scripts → CashCowDX, audio, and controls on the release install (PLAN §6.22).
2. **Soak:** done — 30 minutes clean via the release launcher (PLAN §6.20).
3. **Scanout crop:** decided — keep the core's 224-line window; HUD and gameplay fully visible (PLAN §6.21).
4. **Level-load hitch:** ~0.5 s freeze on the scene-change frame (~1,300 nodes); not a blocker, fixing it changes the game's loading (PLAN §6.21).
5. Optional performance: PGO; direction-only enemy raycasts (needs sign-off); canvas cull (~0.9 ms).

## 7. Known risks

- Fabric wedge: the launcher's gate reloads the core and retries if C_DONE stops advancing after start; long-run behaviour is what the
  soak measures.
- mem_wc is built per kernel version; on a different MiSTer kernel the launcher falls back to the slower mapping (`tools/mem_wc/build.sh`).
- CPU isolation moves other user processes to CPU1 during play and restores them on exit (trap); a hard kill of the launcher would skip
  the restore (a reboot clears it).
