# Cash Cow DX on MiSTer — handoff (2026-09-24)

Read this first, then `PLAN.md` (the full record of findings and measurements; §6 covers everything since audio/input).
Repo: private `github.com/gmcnaught/cash.cow.dx-mister`. `work/`, `gamedata/`, `build/` and any `*.pck` are never committed.

## 1. State

Godot 4.3 Cash Cow DX runs on the DE10-Nano with the FPGA blitter drawing every frame, DDR audio, and the MiSTer joystick.
Real gameplay (scripted input, Godot's default 8 physics steps/frame): the main thread costs ~11 ms/frame of the 16.7 ms budget.
Frames are paced by libmisterfabric on the core's scanout frame counter (Godot V-Sync mode -> `mf_set_pacing`; `--max-fps 0`), so
every published frame is displayed; the launcher isolates CPU0 for the main thread, itself included (PLAN §6.18, §6.25).
Stutter target (≥58 displayed fps per second, ≤58 at most once per 30 s) measured with `scripts/stutter/` — PLAN §6.25.
Every canvas command type the game uses now reaches the fabric (rects, split large rects, polygons; `unhandled: none`).
A release bundle (`scripts/make_release.sh`) ships a CashCowDX-branded core (`_Other/CashCowDX_*.rbf`, CORENAME `CashCowDX`, Cash Cow
button labels). Loading it from the core list starts the game with no daemon: MiSTer.ini `[CashCowDX] main=` (set by
**Scripts → CashCowDX_CoresMenu**) makes MiSTer exec `MiSTer_CashCowDX` (upstream Main + one hook call, `tools/mister-wrapper/`)
while this core is loaded; it starts `launch.sh`. The user supplies the GOG `CashCowDX.pck` (PLAN §6.23, §6.24).
Current release: `CashCowDX-MiSTer-20260924e` (engine `godot43pn`): core load → attract 8.75 s warm / 12.0 s cold (PLAN §6.26–6.27); human hardware check passed.

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
| One frame pacer: the scanout counter (not Godot's limiter, not a wall clock); success is counted in *displayed* frames | PLAN §6.25 |
| Pass/fail stutter runs use `PERF_ON=0`; the perf trace perturbs the device (tmpfs memory, SD I/O) | PLAN §6.25 |
| Core RBF: maldita.castilla-mister `build-rbf.yml` `core_variant=cashcow` (same RTL as DonutDodo); next time prefer shared RBF + MRA | PLAN §6.23 |
| Audio load cost stays up front at boot (parallelize, never lazy); parallel loading on CPU1 was tried and gave nothing | PLAN §6.27 |
| No Mesa: null GL in fabric mode (`MISTER_NULL_GL=0` needs an external Mesa) | PLAN §6.27 |
| Pruned build: `disable_3d`, module whitelist, `text_server_fb`; **not** `disable_advanced_gui` (removes SubViewportContainer) | PLAN §6.27 |
| Patches ship as binary tokens (`.gdc`, tokenized on the device by `make_release.sh`) | PLAN §6.27 |

## 3. Layout

```
PLAN.md, HANDOFF.md
Dockerfile.godot4-build          cross image godot4-armhf-build:bullseye
scripts/apply_godot_mister.py    copies src/godot/** into the Godot tree + all anchored engine edits (idempotent)
src/godot/                        MiSTer platform (display server, audio, joypad), fabric bridge, GDScript cache
src/fabric/, src/vendor/          libmisterfabric (C ABI over the vendored mfgpu RasterBackend; deltas in src/vendor/VENDOR.md)
src/patches/                      runtime GDScript patches + loader (mister_patches.gd); loaded via override.cfg
tools/mem_wc/                     write-combining /dev/mem driver: build.sh for the device kernel, prebuilt .ko
dist/                             Scripts/{CashCowDX.sh,CashCowDX_CoresMenu.sh}, games/CashCowDX/{launch.sh,override.cfg}, README.md
tools/mister-wrapper/             build-hps.sh (upstream Main_MiSTer + overlay/ + one inserted call -> MiSTer_CashCowDX)
scripts/make_release.sh           assembles build/release/CashCowDX-MiSTer-<tag>.zip (RBF_SRC=<cashcow-variant RBF> required)
scripts/stutter/                  run.sh (device capture of the installed release), frames.py (analysis), state_probe.gd
scripts/boot/                     boot_time.sh (device: core load -> attract timing, MISTER_BOOTLOG), boot_report.py, prof_phases.py, load_self.py
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
  disable_3d=yes modules_enabled_by_default=no module_gdscript_enabled=yes module_vorbis_enabled=yes module_ogg_enabled=yes \
  module_webp_enabled=yes module_freetype_enabled=yes module_text_server_fb_enabled=yes module_svg_enabled=yes module_mbedtls_enabled=yes \
  CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ ccflags='$A' linkflags='$A'"
docker run --rm -v "$PWD/work":/w godot4-armhf-build:bullseye sh -c \
  'arm-linux-gnueabihf-objcopy --strip-debug /w/src/godot-4.3-stable/bin/godot.linuxbsd.template_release.arm32 /w/build/<name>.cortexa9'
docker run --rm -v "$PWD":/p -w /p/src/fabric godot4-armhf-build:bullseye make OUT=../../work/build/fabric_opt   # library
tools/mem_wc/build.sh                                  # kernel module for the device's running kernel
tools/mister-wrapper/build-hps.sh                     # MiSTer_CashCowDX (UPSTREAM_COMMIT=<sha> to move the pin)
RBF_SRC=work/rbf_cashcow/MalditaCastilla_<date>.rbf scripts/make_release.sh work/build/<name>.cortexa9 <tag>
```
Incremental LTO builds take ~7 min, full ~14 min. Don't run the apply script while a subagent is editing `src/godot/`.

## 5. Device (`root@192.168.20.81`)

- Release install: `/media/fat/games/CashCowDX` (+ `Scripts/CashCowDX*.sh`, `_Other/CashCowDX_*.rbf`); logs `/media/fat/logs/CashCowDX/`.
  `main=` armed in `/media/fat/MiSTer.ini`. State check: `ssh root@192.168.20.81 sh -s < scripts/mainhook_state.sh`.
- Dev/measurement dir: `/media/fat/games/cashcow` (engines `godot43*.cortexa9`, `patches/`, `patches_typed/`, probes, `run_play.sh`, `ab_play.sh`).
- Measurement: `PATCH=1 MISTER_SEED=1 MISTER_PATCHES_DIR=.../patches_typed ./ab_play.sh <engine> <tag> <steps>`; add `SPIKES=1` for
  per-frame spike logging; `./perf_stat_play.sh <engine> <tag> 1` for main-thread cycles/frame (the probe's cpu_ms is both cores).
- Scripted input: engine with `MISTER_JOY_BASE=0x3A0C0000` (release: `CASHCOW_JOY_BASE`), then `joy_inject.py "<steps>"`.
- Stutter capture: copy `scripts/stutter/` to `/media/fat/games/cashcow/stutter/`, then
  `PERF_ON=0 ./run.sh <tag> 600 [engine]` (add `PROF=1` for main-thread sampling, `EXTRA_ENV="export K=V"` for knobs); pull
  `/media/fat/logs/CashCowDX/stutter/<tag>/` and run `scripts/stutter/frames.py <dir>`. Engines need `MISTER_FRAMELOG` support (≥ godot43fl).
- `/media/fat` is mounted **sync**: every write there is a synchronous SD write — keep per-frame/per-second output in /tmp.
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
