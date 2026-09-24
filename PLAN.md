# Cash Cow DX on MiSTer — port plan

Status (2026-09-23): Tier 2 renders on hardware (menus 60 fps, gameplay ~53 fps); no audio/input/launcher yet. Operational summary and next steps: `HANDOFF.md`.
Sibling repos referenced: `../donut.dodo-mister` (closest precedent), `../gmloader-next`,
`../maldita.castilla-mister`, `../mister-fpga-blitter`.

---

## 1. Verified findings (Observed, from `gamedata/`)

| Fact | Evidence |
|---|---|
| Engine is **Godot 4.3.stable.official** | string in `CashCowDX.x86_64`; PCK header `GDPC` fmt 2, 4.3.0 |
| PCK **not encrypted**, not embedded; 942 entries, 24.9 MB | PCK flags `0x0`, file base `0x16630` |
| Renderer **GL Compatibility** (`rendering_method=gl_compatibility`) | `project.binary` |
| Base viewport **320x240**, `stretch/aspect=keep_height`, not resizable, 2D pixel snap on | `project.binary` |
| Pure 2D: no Light2D, no particles, no BackBufferCopy/screen_texture. Nodes seen: CanvasLayer (8 scenes), ShaderMaterial (6), Camera2D (2), SubViewport (1: `game.scn`) | byte scan of all 121 exported `.scn/.res` |
| One custom shader, `enemy_white.gdshader`: `mix(tex, white, opacity)` hit flash | extracted source |
| `game.scn` renders the game into a **SubViewport** and presents it with an optional **CRT-geom shader** (`crt_filter/crt-geom.tres`) and a **bezel** (`ui/bezel/bezel.png`); the settings panel has SCALE / SCANLINES / BEZEL toggles | `game.scn` contents; `settings_panel.gdc` strings |
| Textures: 99 `.ctex`, all `GST2` data format 2 (**WebP**, CPU-decoded, not VRAM-compressed) | ctex headers |
| Audio: 81 `oggvorbisstr` (music ≤3.2 MB each, streamed) | PCK index |
| Scripts: 160 `.gdc`, GDScript tokenized bytecode v100, zstd-compressed | `GDSC` header |
| Steam: the **GodotSteam GDExtension** (`addons/godotsteam`, x86_64-only libs) is loaded via `extension_list.cfg` | extracted `.gdextension` |
| Steam API use is confined to `managers/steam_manager.gdc`, which references the `Steam` singleton directly: `steamInit isSteamRunning isSteamRunningOnSteamDeck isSubscribed loggedOn getSteamID getPersonaName setAchievement clearAchievement storeStats findLeaderboard uploadLeaderboardScore run_callbacks` + signals `leaderboard_find_result leaderboard_score_uploaded`. Other scripts only emit `Signals.steam_*` | identifier dump of the decompressed bytecode |
| The game already has a `PLATFORM` enum including `ARM`, `EVERCADE`, `IIRCADE`, `ATARI` (the dev ships on low-end ARM platforms) | `settings_panel.gdc` / `steam_manager.gdc` identifiers |
| Input: named actions for keyboard, joypad buttons, and joypad analog (`p1_*_keyboard/_dpad/_analog/_controller`) | `project.binary`, `GameInput.gdc` |

Tooling for this: the scratch PCK v2 parser + gdc identifier dumper. `scripts/pck4_inspect.py <pck> <outdir>`
(donut.dodo's `pck_inspect.py` only reads the v1/Godot 3 layout).

## 2. What carries over from Donut Dodo, and what does not

Donut Dodo = Godot **3.5.2** + **FRT** + patched **SDL2** (offscreen EGL, `mister` audio/joystick drivers)
+ `libmisterglue` decoding **GLES2** draws into mfgpu blitter commands. 60 fps on the fabric (PLAN §1h there).

| Donut Dodo piece | Cash Cow DX | Reason |
|---|---|---|
| FRT platform | **Does not carry over** | FRT is Godot 3 only. Godot 4.3 `linuxbsd` has only X11 and Wayland display servers |
| SDL2 as the platform seam | **Does not carry over** as-is | Godot 4.3 does not use SDL for video/audio/input on Linux |
| Surfaceless EGL + Mesa llvmpipe (GLES 3.2 on device) | **Carries over** | Compatibility renderer needs GLES 3.0; device reports `OpenGL ES 3.2 Mesa 21.3.9` |
| `-march=armv7-a -mfpu=neon -mtune=cortex-a9` (no VFPv4) | **Carries over** | Same Cortex-A9; same SIGILL trap |
| bullseye armhf build container (glibc ≤ 2.31) | **Carries over** | Same device glibc |
| DDR present / audio ring / joystick words / mfgpu host lib (`src/vendor/`) | **Carries over** (C code, engine-agnostic) | Rewire into Godot driver classes instead of SDL drivers |
| FPGA core: maldita core branch `donutdodo/fb-320x240` (blitter FB 320x240) | **Carries over unchanged** | Same 320x240 geometry |
| `libmisterglue` GLES2 state shadow | **Does not carry over** | Godot 4 GLES3 canvas renderer uses instanced draws + different shaders |

Consequence: all MiSTer-specific code moves **into the Godot 4.3 source tree** as a small platform layer
(we compile the engine anyway).

## 3. Architecture

    Godot 4.3-stable (linuxbsd, arch=arm32, template_release, cortex-a9 flags)
      + module "mister" (patch series against godot-4.3-stable)
          DisplayServerMister  : surfaceless EGL (drivers/egl EGLManager) + GLES3 ctx, 320x240
                                 swap -> glReadPixels -> RGB565 -> DDR double buffer (Tier 1)
          AudioDriverMister    : 48 kHz stereo -> DDR audio ring (gm_audio from vendor)
          JoypadMister         : DDR joystick words -> Input::joy_button/joy_axis, SDL-style layout
          (no Steam stub: GodotSteam absent, as in the GOG release; see §4 0.2b)
      FPGA: donut.dodo RBF (fabric + scanout + audio + joystick)

**Steam:** no stub. Without GodotSteam, `steam_manager.gd` fails to parse and the game runs on.
This is exactly how the official GOG release behaves (verified, §4 0.2b). The supported input is the GOG build.

**Settings seed:** not needed (see §4, 0.2 results). The game disables the bezel itself below
1.5 aspect and defaults CRT off.

## 4. Tiers and gates

### Tier 0 — does Godot 4.3 fit on the A9? (decisive, cheapest)

Question answered: what does Cash Cow DX cost per frame on the Cortex-A9 with rendering removed
(`--headless` = dummy rasterizer, so script + physics + scene tree + audio decode only)?

#### PortMaster Godot 4 support (Observed 2026-09-23, from `ports.json` of PortMaster-New release `2026-09-21_0303`)

| Fact | Evidence |
|---|---|
| PortMaster's Godot 4 runtimes are **stock Godot Linux builds** (`godot43.$DEVICE_ARCH`), not FRT. FRT stops at `frt_4.0.4` / `frt_4.1.3` (aarch64 only) | `ports.json` `utils`; port launchers, e.g. `ports/orbo/orbo.sh` |
| Runtimes: 4.2.2, 4.3, 4.4, 4.4.1, 4.5, 4.6.3, 4.7.1. **armhf builds exist for 4.2.2 / 4.3 / 4.4 / 4.4.1 / 4.5**. `godot_4.3` is the most-used (14 ports) | `ports.json` |
| `godot_4.3.armhf.squashfs` (22 MB) = one file `godot43.armhf`, 58.6 MB, **`4.3.stable.official`** (same build ID as the game's x86_64 binary), display drivers `x11,wayland,headless`, NEEDED only libc/libm/libdl/libpthread/librt, max **GLIBC_2.28** | unpacked in `work/portmaster/g43/`; `readelf -d/-V` |
| That binary is tagged **`Tag_CPU_arch: v8`, `FP for ARMv8`, `NEON for ARMv8`**. It is the same kind of tagging as upstream's `frt_3.6.2 arm32`, which SIGILLed on the DE10-Nano (donut.dodo PLAN §1b) | `readelf -A` |
| Display path: `westonwrap.sh headless noop kiosk crusty_x11egl` + `--rendering-driver opengl3_es --audio-driver ALSA`. Godot uses its **X11** display server against Xwayland inside a headless Weston. "crusty_x11egl" is Westonpack's EGL-on-X11 shim, which presents through SDL2. Westonpack's own docs say "native code for non-arm64 platforms" is unsupported | Westonpack wiki "Godot-4-Example"; `orbo.sh` |
| **`weston_pkg_0.2` has no armhf build** (aarch64, plus a 12 KB x86_64 stub) | `ports.json` |
| Westonpack requires ETC2/ASTC for compressed textures and the compatibility or mobile renderer. Cash Cow DX uses WebP + compatibility, so it meets both | Westonpack wiki; §1 |

Inferred:
- The PortMaster **display** route (Weston + Xwayland + crusty) is not available on armhf. It would also
  put a compositor and an X server on the A9. The display route is not reused. §3's DisplayServerMister stays.
- The PortMaster **armhf binary** is useful only if it runs on the Cortex-A9. If it does, Tier 0 needs **no engine build**:
  `--headless` is compiled into it and needs no X11.
- The PortMaster builds do confirm that official Godot 4.3 arm32 runs a 2D compatibility game on 32-bit ARM.

Unknown: whether `godot43.armhf` actually executes ARMv8-only instructions (the tag alone does not prove it).

#### Tasks

| # | Task | Output / done when | Depends |
|---|---|---|---|
| 0.1 | **Probe the PortMaster armhf binary on the device.** Copy `work/portmaster/g43/godot43.armhf` to `/media/fat/games/cashcow/`. Run `--version`, then `--headless --quit`. Record the exit code (132 = SIGILL) and `dmesg` | PLAN note: runs / SIGILL. If it SIGILLs, capture the faulting PC and disassemble it (`objdump -d --start-address`) to name the instruction | device reachable (SSH to `192.168.20.81` timed out 2026-09-23) |
| 0.2 | **Recover the scripts that matter.** Decompile with GDRE Tools (gdsdecomp) CLI: `steam_manager`, `GlobalVariables` (`PLATFORM` constant), `settings_manager` (settings file name/format), `game.gd`/attract-mode entry | `work/decomp/` (not committed); PLAN note with the exact `Steam` call signatures used, the platform value, the `user://` settings path and keys | none |
| 0.3 | **Build container.** Base on `debian:bullseye` (glibc 2.31) with `gcc-arm-linux-gnueabihf` (GCC 10), scons, python3. Reuse `../donut.dodo-mister/Dockerfile.frt-build` conventions. Fetch `godot-4.3-stable` into `work/` | `Dockerfile.godot4-build`; `scons --version` inside it | none |
| 0.4 | **Cortex-A9 flags for Godot 4.3 arm32.** Read `platform/linuxbsd/detect.py` for `arch=arm32` defaults. Patch to `-march=armv7-a -mfpu=neon -mfloat-abi=hard -mtune=cortex-a9` (no VFPv4). Put the patch in `patches/0001-godot43-arm32-cortex-a9.patch` | patch applies cleanly | 0.3 |
| ~~0.5~~ | **Dropped** (0.2b: the GOG runtime needs no stub). Was: Steam stub module `modules/steam_stub`: registers an Engine singleton named `Steam` with the methods from §1 (signatures from 0.2), returning "not running / not owned / 0". Also declares signals `leaderboard_find_result` and `leaderboard_score_uploaded` | `patches/0002-…` or `src/modules/steam_stub/` + symlink step | 0.2 |
| 0.6 | **Build** `scons platform=linuxbsd arch=arm32 target=template_release x11=no wayland=no`. Check with `readelf -A` (`Tag_CPU_arch: v7`, VFPv3, NEON v1), `readelf -V` (max GLIBC ≤ 2.31) and `readelf -d` | `work/build/godot43.cortexa9` + readelf output in PLAN | 0.4 |
| 0.7 | **Headless run on device.** Deploy the binary and `CashCowDX.pck`. `XDG_DATA_HOME=/media/fat/games/cashcow/data ./godot --headless --main-pack CashCowDX.pck --verbose --print-fps`, 5 min, uncapped. Record startup time (`--benchmark`), steady fps (throughput = 1/engine cost), RSS from `/proc/<pid>/status`, CPU split across the 2 cores, every script/extension error | PLAN §1-style table. Use 0.1's binary as a first pass if it runs. The Steam errors from that pass show what the stub must satisfy | 0.1 or 0.6 |
| 0.8 | **Confirm the measurement covers gameplay.** Headless has no input: check (from 0.2 source + `--verbose` scene-change logs) that the game goes from title to attract/demo gameplay without input. If it doesn't, add a tiny `--script` driver or a debug-only auto-start to reach a level | log line showing a level scene loaded during the timed window | 0.2, 0.7 |
| 0.9 | **Profile only if the gate is marginal.** Build `target=template_debug` and attach the Godot 4.3 editor's remote profiler from the Mac (`--remote-debug tcp://<mac>:6007`) to split script vs physics vs idle | top script functions by ms/frame | 0.6 |
| 0.10 | **Gate decision** written into PLAN | one of: 60 fps target / 30 fps target / stop | 0.7–0.9 |

0.1 is **skipped**: assume the ARMv8-tagged PortMaster binary SIGILLs (decision 2026-09-23).

#### 0.2 results — decompile (done 2026-09-23)

GDRE Tools v2.6.4 (`work/tools/`), `--headless --recover`: 942/942 files, 160/160 scripts decompiled
into `work/decomp/` (not committed).

| Fact | Where |
|---|---|
| `settings_manager.platform` is an `@export` defaulting to `PLATFORM.STEAM`. `game.tscn` does not override it (only `version_number = "1.13"`, `leaderboards = 0`). **The retail build runs as STEAM** | `managers/settings_manager.gd:6`, `game.tscn:433` |
| With STEAM: `steam_manager` calls `Steam.steamInit()`, then **`get_tree().quit()` if `isSteamRunning()` or `isSubscribed()` is false** | `managers/steam_manager.gd` |
| With **GOG**: the same Steam calls run, then `initialize_steam()` **returns before the ownership checks** (`if platform == GOG: return`) | same |
| The other STEAM-specific behaviour: `pause_manager` accepts the extra controller PAUSE action only on STEAM. On GOG, pause still works via Start/Select. Main menu, settings and input mapping treat STEAM, ARM and GOG the same way, except for Steam Deck and GOG's keyboard-remap load | `managers/pause_manager.gd:23`, `ui/*/…gd` |

| Settings: `user://settings.dat`, `FileAccess.open_encrypted_with_pass(..., "5f6^yG6*5RLj")`, one `Dictionary` var `{scale, bezel, crt_filter, pixel_perfect, screen_shake, screen_flash, vibration, volume, inertia}`. Defaults are `scale 0` (fullscreen), `bezel true`, `crt_filter false` | `managers/settings_manager.gd` |
| **No settings seed needed:** `set_bezel_window_scale_and_ratio()` forces `bezel=false` when screen aspect < 1.5. With a 320x240 screen it sets `viewport_container.scale = 240/240 = 1`, and the CRT is off by default. DisplayServerMister only has to report `screen_get_size() = 320x240` | same |
| Headless caveat: the headless display server's `screen_get_size()` return value is not verified. If it is 0x0 the viewport scale becomes 0. That doesn't matter for CPU measurement | Inferred |
| Attract loop needs no input: `pixel_intro` → `attract_panel` cycles `main_menu → gameplay_panel → cast_panel → rules_panel → scoreboards`. `gameplay_panel` instantiates `levels/level_01/level_01_attract_mode.tscn` for **10 s** (`PANEL_DURATION`) per cycle. So task 0.8 needs no driver script; 0.7 must report fps per panel and weight the gameplay window | `ui/attract_panel/attract_panel.gd`, `ui/gameplay_panel/gameplay_panel.gd` |

#### 0.2b results — GOG build (done 2026-09-23)

Decision: the supported input is the **GOG (DRM-free) build**. Nothing bypasses the Steam build's ownership check.

| Fact | Evidence |
|---|---|
| GOG installer `cash_cow_dx_1_1_3_0_86318.sh` (Makeself 2.2.0 + zip, GOG buildId `59134599136702623`) extracts with plain `unzip`, no Docker needed | `work/gog-extract/data/noarch/game/` |
| GOG `CashCowDX.pck` and `CashCowDX.x86_64` are **byte-identical** to the Steam ones (sha256 `4436b750…5d6b6c` pck, `815e684e…80bbc` binary). GOG ships **no** `libgodotsteam` / `libsteam_api` | `shasum -a 256` |
| So the pck still has `platform = STEAM`. The GOG release gets its DRM-free behaviour from the **missing extension**: GodotSteam fails to load, `steam_manager.gd` fails to parse (`Identifier "Steam" not declared`), its node runs without a script, and `initialize_steam()` (including the quit-if-not-owned check) never runs | official x86_64 binary, `--headless`, amd64 container: log `work/gog-headless-x86.log` |
| The game keeps running after those errors: `Project FPS: 145 (6.89 mspf)` steady, no quit (x86 under emulation, not representative for speed) | same, `--print-fps` |
| `--print-fps` output only shows up with line-buffered stdout (`stdbuf -oL`). The release template doesn't flush stdout on each print, and a kill loses the buffer. Keep this in mind for 0.7 | same |

Consequence: **no Steam stub.** The MiSTer build reproduces the GOG runtime exactly: no GodotSteam library
for arm32, the same load errors, the same behaviour. Task 0.5 is dropped. Nothing is added that the official
GOG release doesn't already do.

#### 0.3 results — build container (done 2026-09-23)

`Dockerfile.godot4-build` → image `godot4-armhf-build:bullseye`.
- Verified: `arm-linux-gnueabihf-g++ 10.2.1`, glibc `2.31-13+deb11u14`, SCons 4.5.2, cross `ar/ranlib` first in PATH.
- Toolchain default is `-march=armv7-a+fp -mfpu=vfpv3-d16 -mthumb`, which is A9-safe but has no NEON.
- Two workarounds for bullseye being past EOL (both observed as 404s from `deb.debian.org/debian-security`):
  apt uses the image's own `snapshot.debian.org/.../20260824T000000Z` lines, and SCons comes from its hash-pinned PyPI wheel, not pip.
- **0.4 needs no source patch:** Godot 4.3 `linuxbsd/detect.py` adds no `-march` for arm32, and `CC`/`CXX`/`ccflags`/`linkflags`
  are SCons options. Build line:

      scons platform=linuxbsd arch=arm32 target=template_release x11=no wayland=no vulkan=no module_openxr_enabled=no \
        CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ \
        ccflags="-march=armv7-a -marm -mfpu=neon -mfloat-abi=hard -mtune=cortex-a9"

- Build fixes found on the first two runs:
  - `module_openxr_enabled=no`: with `x11=no`, `openxr_opengl_extension.h:71` fails with `XrGraphicsBindingOpenGLXlibKHR does not name a type`. The game doesn't use XR.
  - `vulkan=no`: the device has no Vulkan.
  - `-marm`: GCC 10.2.1 hits an internal compiler error (`in cselib_record_set, at cselib.c:2614`) on
    `scene/resources/surface_tool.cpp` with Thumb-2 + `-mfpu=neon`. It reproduces standalone.
    `-fno-tree-vectorize`, `-fno-schedule-insns2` and `-mno-unaligned-access` don't help.
    Dropping NEON or adding `-marm` both avoid it; `-marm` keeps NEON.
- Source: `work/src/godot-4.3-stable/` (release tarball). Stock build running as container
  `cashcow-godot-build`, log `work/src/build-template_release.log`. Colima VM raised to **8 CPUs / 8 GiB** (was 2 / 2)
  (host: 8 / 16 GB).

#### 0.6–0.8 results — on device (2026-09-23)

Engine: `work/build/godot43.cortexa9` = `4.3.stable.custom_build.77dcf97d8`, 65 MB. `readelf -A`: `Tag_CPU_arch v7`,
`Tag_ARM_ISA_use Yes`, `Tag_THUMB_ISA_use Thumb-2`, `VFPv3`, `NEONv1`. NEEDED: libc/libm/libdl/libpthread. Max `GLIBC_2.29` (device 2.31).
Build time on the 8-CPU Colima VM: 10 min. `--version` runs on the DE10-Nano: no SIGILL.

Device: `armv7l`, Features `neon vfpv3 vfpd32` (no vfpv4), 491 MB RAM (420 MB available idle).
Deployed to `/media/fat/games/cashcow/` with the GOG pck (sha256 verified).

**Headless-measurement caveats found (0.8):**
- The headless frame pacing sleeps `low_processor_mode_sleep_usec` (6900 µs) per frame, so uncapped runs show a false
  ~145 fps ceiling. Use `--max-fps 60` so the loop matches real play (60 process frames + 60 physics ticks per second).
- Headless never renders, so `VisibleOnScreenEnabler2D` never fires. `cast_panel` stays `PROCESS_MODE_DISABLED` and the attract loop
  **stalls after one cycle**; 170 gold `Area2D`s per level stay disabled and out of physics. The official x86_64 build does the same
  (`can_process=false`, `process_mode=4`).
- Harness: `scripts/tier0_probe.gd`, loaded as an autoload through `override.cfg` next to the binary (the pck is untouched).
  It applies each enabler's `enable_mode`, because the game is one 320x240 screen and everything is on screen in real play.
  `TIER0_ENABLERS=all|panels|none`. It prints the panel, physics ticks/s, frames/s and CPU ms/frame from `/proc/self/stat`.
  Godot's `Performance.TIME_PROCESS`/`TIME_PHYSICS_PROCESS` were not usable: they read >100% of wall time.

**Measurements** (`--headless --max-fps 60`; logs in `work/tier0/`):

| Panel (attract) | fps p50 / min | CPU ms per frame p50 / p95 | Notes |
|---|---|---|---|
| main_menu, rules, scoreboards, cast | 60 / 53 | 5.3–5.5 / ≤10.9 | fits a 60 fps budget |
| gameplay demo, golds out of physics (`panels`) | ~48 / 29 | 15–20 | already over 16.7 ms with no rendering |
| **gameplay demo, golds enabled (`all`, the realistic case)** | **15 / 8** | **60–80 (p95 111)** | physics holds 60–66 ticks/s. The **main thread uses one full core (982 ms/s)**; the other threads use <10 ms/s |

Memory: VmHWM 163 MB (fits in 420 MB). Startup to the first attract panel: ~16 s.

**Gate result:** gameplay logic alone saturates one A9 core at 60 physics ticks/s, leaving no main-thread time for rendering.
That is beyond the "> 25 ms → stop" line for the realistic case. Not yet known: where the time goes. The 4× jump when golds are enabled points
to one hotspot (gold pickup effects, score/UI, audio, or scripts that scan groups), not a uniform engine cost.
The golds in this harness don't move, because `is_on_screen()` stays false. Real play also moves 170 areas each tick, so the harness is
more likely to under-state cost than over-state it.

#### 0.9 results — profile (2026-09-23)

Tooling:
- `scripts/godot_dbg_profile.py` is a headless stand-in for the editor's remote profiler. Wire format: uint32 length + `encode_variant(Array[msg, thread_id, data])`.
  It must send with thread id **1** (`Thread::MAIN_ID`); messages with id 0 are ignored. It auto-continues the `steam_manager` parse-error break
  (with a debugger attached, the debug engine stops on it). Device side: `run_profile.sh` with `PORT=6008`.
- `work/build/godot43d.cortexa9` is `template_debug` (`-O2` + debug checks, about 1.55x slower than release: menus 8.5 vs 5.4 ms/tick).
- The probe's `_emulate_on_screen` (`find_children` over the whole tree) costs ~23 ms per call, so it is excluded from all numbers below.

Steady gameplay demo, debug build, per physics tick (8 ticks per rendered frame, so the frame loop is in catch-up):

| Part | ms/tick | Top items |
|---|---|---|
| GDScript self | 8.9 | gold `_physics_process` 2.2 (140 calls/tick); enemy detectors (trap/gap/wall checks) ~1.4 together; `screen_warp` 0.3; GameInput 0.3 |
| Native calls made from scripts | 4.4 | `CharacterBody2D.move_and_slide` 2.0 (~0.4 ms per call); **`Control.add_theme_color_override` 1.3 for 3 calls** |
| Outside scripts | 12.0 | not visible to the Godot profiler (node dispatch, transform/visibility notifications, AnimatedSprite2D, physics sync). The physics server step itself is ~0.5 |
| **Total** | **25.3** | release estimate ≈ 16 ms/tick. The budget for 60 fps is 16.7 ms, including rendering |

No single hotspot: the largest item is <10% of a tick. The earlier "4× jump with golds" is the catch-up spiral: once a tick costs more than 16.7 ms,
each rendered frame runs up to 8 physics ticks (`max_physics_steps_per_frame`).

Engine-side candidate (game unchanged): `Control::add_theme_*_override` (`scene/gui/control.cpp:2883`) always sends
`NOTIFICATION_THEME_CHANGED`. The HUD (`ui/hud/info.gd:44`, `ui/hud/p1.gd:34,58`) re-applies the same colour every tick, which also runs in menus
(~1.9 ms/tick there). Adding an early return when the value is unchanged saves ~1.3 ms/tick (debug).

`perf` for the "outside scripts" 12 ms: the MiSTer kernel has `CONFIG_PERF_EVENTS`/`HW_PERF_EVENTS` with the `armv7_cortex_a9` PMU.
Debian bullseye's armhf `linux-perf` 5.10 plus private libraries is at `/media/fat/games/cashcow/perf/` (run with `LD_LIBRARY_PATH=$PWD/lib`).
It bundles its own `libcrypt.so.1`, because the device's copy lacks `XCRYPT_2.0`. `perf stat -e cycles,instructions` works.
It needs an engine binary with a symbol table: release links pass `-s` (`SConstruct:737`) unless `debug_symbols=yes`.

#### Correction + LTO results (2026-09-23)

**Correction:** the earlier "gameplay 60–80 ms/frame, 15 fps" (release) was mostly measurement overhead. The probe's `_emulate_on_screen`
ran a full-tree `find_children` every 0.25 s (~23 ms each, ≈90 ms per second), which pushed the loop into physics catch-up (8 ticks per frame).
The probe now reacts to `SceneTree.node_added` instead and costs nothing measurable. The debug-profile *breakdown* above excludes the probe's own
samples and still holds proportionally. Its absolute per-tick total was inflated by the same catch-up.

Build flags: `production=yes` (full GCC LTO). Two fixes were needed:
(1) with LTO, Godot hardcodes host `gcc-ar`/`gcc-ranlib`, so the image now links those to the cross wrappers;
(2) the LTO code-generation step takes target flags from the *link*, so `linkflags` must repeat the `ccflags` arch flags. Otherwise it fails with
`arm_neon.h: You must enable NEON instructions` (mbedtls, brotli). Binary: `work/build/godot43lto.cortexa9`, 54 MB (non-LTO 65 MB),
v7/VFPv3/NEONv1, max GLIBC_2.29.

A/B, same harness, `--headless --max-fps 60`, median of the steady seconds of each attract panel (`work/tier0/ab_*.log`):

| Build | Gameplay demo ms/frame p50 (max) | Gameplay fps p50 (min) | Menus ms/frame |
|---|---|---|---|
| `-O3`, no LTO | 17.98 (90.0) | 48 (10) | 5.33 |
| **`-O3` + full LTO** | **13.65 (32.9)** | **56 (24)** | 5.08 |
| LTO, golds left disabled (`TIER0_ENABLERS=none`) | 11.46 (14.2) | 58 (45) | 4.92 |

LTO: −24% on gameplay logic. Gold emulation adds ~2.2 ms, so it takes effect.

**Revised gate reading:** game logic is ~13.7 ms of the 16.7 ms frame on **one** core. The second core is idle (<10 ms/s).
60 fps is marginal, not ruled out. It depends on:
(a) keeping rendering off the main thread (Godot 4.3 `rendering/driver/threads/thread_model` = separate render thread, experimental in 4.3; unverified here) and/or Tier-2 fabric rendering;
(b) engine micro-fixes such as the `add_theme_*_override` early return (~0.8 ms est. in release);
(c) removing the max-spike sources (scene loads, first-cycle spikes to 33 ms).
Next measurements: `perf record` on a symbolized LTO build for the "outside scripts" share, and a Tier-1 render-cost number (llvmpipe) with the render thread on core 2.

#### perf results — gameplay demo, LTO release (2026-09-23)

`perf record -e cpu-clock -F 999` for 9 s of the gameplay demo (6996 samples) on `godot43ltos.cortexa9`: the LTO build with
`debug_symbols=yes` and `objcopy --strip-debug`, so the symbol table is kept. `-g` does not change GCC codegen. The hardware `cycles` event
recorded nothing with `-p`; `cpu-clock` works. Full list: `work/tier0/perf_gameplay_top.txt`.

| Share | Where |
|---|---|
| **~11%** | **software integer divide**: `__udivsi3` 8.5, `__aeabi_uidivmod` 2.0, `____aeabi_uidivmod_from_arm` 0.5 |
| 8.1 + 1.8 + … | GDScript VM (`GDScriptFunction::call`, `GDScriptInstance::callp/get/notification`) |
| ~9.5 | 2D broadphase and narrowphase (`BVH_Tree<GodotCollisionObject2D>` 6.6, `_collision_rectangle_rectangle` 2.9, `test_body_motion` 0.6) |
| ~4 | Variant/ClassDB/dynamic_cast plumbing (`ClassDB::get/set_property`, `__dynamic_cast`, `Variant::reference`) |
| ~2.2 | malloc/free |
| ~1.4 | theme and text (`ThemeDB::get_native_type_dependencies`, `TextServerAdvanced` font hash/shape): the HUD override churn |

**Divide root cause (Observed):** the Cortex-A9 has no UDIV/SDIV (optional in ARMv7-A). `core/templates/hashfuncs.h:503` `fastmod()`
uses `__int128`, which 32-bit GCC lacks, so it falls back to `n % d`, a library call on every HashMap/HashSet probe.
Fix, in `scripts/apply_godot_mister.py`: an exact 32-bit form, `(hi*d + ((lo*d) >> 32)) >> 32` with `lowbits = hi*2^32 + lo`,
using UMULL only. Verified on the host: 84M cases (Godot prime divisors up to 2^32, including edge n), 0 mismatches
against both the `__int128` reference and `n % d`. Other `%`/`/` call sites may remain; re-run perf after the fix to see what is left.

#### fastmod A/B + first rendered frames (2026-09-23)

**fastmod fix** (`godot43ltos` → `godot43fm`, same harness, headless `--max-fps 60`, `work/tier0/fm_*.log`):
gameplay p50 13.45 → **12.46 ms/frame** (−7%), menus 5.00 → **4.59** (−8%). The gain is below the 11% the divide calls took, so other
`%`/`/` sites remain (re-run perf to list them).

**DisplayServerMister, Tier-1 path, works end to end** (`src/godot/platform/linuxbsd/mister/`, applied by `scripts/apply_godot_mister.py`):
`--display-driver mister --rendering-driver opengl3_es` → `EGL 1.5 Mesa Project, surfaceless GLES 3.0 context` →
`OpenGL ES 3.2 Mesa 21.3.9 … llvmpipe (LLVM 11.0.0, 128 bits)` → FBO 5 as `system_fbo` → readback 1.05 ms per frame.
Bring-up fixes: (1) `EGL_SURFACE_TYPE=EGL_PBUFFER_BIT`, because the default is window configs and surfaceless offers none;
(2) override `can_any_window_draw()` → true, because the headless base returns false, so `Main::iteration` never drew;
(3) the EGL teardown guard after a failed init.
Env: `LD_LIBRARY_PATH=LIBGL_DRIVERS_PATH=/media/fat/games/gmloader/mesa EGL_PLATFORM=surfaceless GALLIUM_DRIVER=llvmpipe`.
DDR scanout is implemented but not yet exercised on a loaded core (`MISTER_DDR_BASE` unset).

**llvmpipe cost (Tier 1):** **2–4 fps**, 200–300 ms of CPU per frame (menus ~200, gameplay ~300). perf: llvmpipe JIT'd shader code 47.7%,
`swrast_dri.so` 22.3% (including ongoing LLVM codegen: `SelectionDAG`, `RAGreedy`), engine 17.5%. Physics catches up at 8 ticks per frame,
so the game runs in slow motion. `--render-thread separate`: no gain (2.9–3.4 fps). The main loop syncs with the render thread every frame, and
llvmpipe's own threads use both cores. This is ~4x worse than Donut Dodo on llvmpipe (13.7 fps, GLES2): Godot 4's GLES3 canvas ubershader is
far heavier to JIT and rasterize.

**Conclusion (Inferred):** software GL is not a viable present path for Godot 4 here. Like Donut Dodo, it needs Tier 2 (fabric rendering).
Game logic after LTO + fastmod is ~12.5 ms per 60 Hz tick. Tier 2 must keep the main thread's render-submission cost within the ~4 ms left.

Order: 0.2 and 0.3 need no device, so do them first. 0.1 runs as soon as the device is up. If 0.1
runs, 0.7 can start before 0.4–0.6 finish. 0.4–0.6 are needed for Tier 1 regardless of 0.1.

**Gate:** engine cost ≤ ~10 ms/frame → continue for 60 fps. 10–25 ms → 30 fps target, or profile
GDScript first (0.9). Beyond that → stop. (Donut Dodo's Godot 3 engine cost was ~2.5 ms/frame.
Godot 4 is expected to be heavier. The amount is Unknown.)

### Tier 1 — pixels on the FPGA via llvmpipe
DisplayServerMister + DDR present + audio + joystick; rendering on llvmpipe (`--rendering-driver opengl3_es`).
Deliverable: boots to title, playable, pixel-correct screenshot. Profile like donut.dodo §1c.
Expect well under 60 fps (Donut Dodo: 13.7 fps on llvmpipe). Two render passes: SubViewport, then root.

### Tier 2 — fabric rendering (mfgpu)
Hook **inside `RasterizerCanvasGLES3`**, not at the GL call level: the engine fills per-rect
`InstanceData` (transform, dst/src rect, modulate, texture) on the CPU before upload. Emit mfgpu
TRILIST commands from there. Mirror textures from `TextureStorage` into fabric texture memory.
This replaces the GL-level decoder Donut Dodo needed.
Open items to resolve here:
- SubViewport → root composite: does mfgpu support render-to-texture? (Unknown). Fallback: patch
  the present so the 320x240 SubViewport is scanned out directly (with SCALE=FULL, the root pass is a 1:1 copy).
- `enemy_white` flash: needs a blitter lerp-to-white mode or a CPU/texture-variant fallback (Unknown what mfgpu offers).
- Text rendering (fonts via `.fontdata` glyph atlases): same rect path. Verify.

### Tier 3 — packaging
`games/Cash Cow DX/launch.sh` (one-engine guard, settings seed, env), deploy/verify script,
README noting the game is not redistributable (user supplies `CashCowDX.pck`).

## 5. Unknowns to close, in order
1. Tier 0 engine frame time on A9 (decides whether the project goes ahead).
2. Whether GDScript bytecode v100 from the 4.3 official build loads unchanged in our 4.3-stable build. Expected yes (same version). Confirm in Tier 0.
3. Whether `opengl3_es` + surfaceless EGL initialises through Godot 4.3's `EGLManager` without X11/Wayland.
4. Whether any script behaviour depends on the `PLATFORM` constant (e.g., quit button, Steam Deck paths).
5. mfgpu capabilities for render-to-texture and colour-lerp (Tier 2).

---

## 5. Tier 2 — fabric rendering: first light (2026-09-23)

**Status: the game renders through the FPGA blitter on hardware, and the picture is correct** (MiSTer scanout capture
`work/tier0/fab_hw_screen.png`, gameplay demo; SW-oracle frames `work/tier0/fab_sw_900.png` (rules panel) and `fab_sw_gp.png` (gameplay)).

Architecture (as built):
- `src/vendor/`: donut.dodo's vendored mfgpu stack @ 7706bae (RasterBackend, TRILIST=10, 320x240 refmodel edit). See `src/vendor/VENDOR.md`.
- `src/fabric/` → `libmisterfabric.so`: a plain C ABI (`mister_fabric.h`, ABI 1) over `RasterBackend_Select()` (`GMLOADER_RASTER=mfgpu|sw`),
  with the 59.92 Hz scanout pacing from donut.dodo's glue. Build: `docker run --rm -v "$PWD":/p -w /p/src/fabric godot4-armhf-build:bullseye make`.
- `src/godot/drivers/gles3/mister_fabric_bridge.*` (engine side; dlopens the library when `MISTER_FABRIC=1`):
  - **Textures:** RGBA8 copy of mip 0 captured in `TextureStorage::_texture_set_data`; invalidated in `texture_free` (non-proxy only).
  - **RECT draws:** each RECT instance is emitted from `_record_item_commands`, using the vertex math of `canvas.glsl`
    (`pixel = canvas_transform * snap(world * vertex)`, flips/transpose from `src_rect` sign and flags) and modulate × canvas modulate.
  - **Render targets:** the SubViewport → root composite is skipped, because both land on the same WORK surface; only the frame's first clear
    reaches the fabric.
  - **Flash shader:** `enemy_white` (opacity ≥ 0.5) samples a pre-whitened texture copy under key `id|0x80000000`.
  - **Skipped in fabric mode:** GL instance upload, batch replay, GL clears, and the screen blit.
- `DisplayServerMister`: `swap_buffers` → `MisterFabricBridge::present()` in fabric mode.
- All engine edits are in `scripts/apply_godot_mister.py` (idempotent, anchored on 4.3-stable text).

Observed on device (Donut Dodo core `_Other/DonutDodo_48k_v224_20260922.rbf`, loaded with `load_core`; competing engines killed):
- `backend_mfgpu: fabric bring-up ok`, and `fabric parked idle on exit`.
- Every canvas command in attract mode is TYPE_RECT: `unhandled: none`, `missing_tex=0`, 125–126 textures.
- Draw load: 95 rects/frame (menu), 66–80 (gameplay), 140 (cast panel). That is far under the ~2730 tris/frame budget.

| Panel | fps p50 (min) | CPU ms/frame p50 (max) |
|---|---|---|
| main_menu | 60 (60) | 7.21 (7.38) |
| cast / rules / scoreboards | 60 (59) | 7.8–8.8 |
| **gameplay demo** | **53 (37)** | **16.29 (22.97)** |

(`work/tier0/fab_hw2.log`; LTO + fastmod build; `--max-fps 60`, fabric-paced.) Removing the GL render-target clears
(llvmpipe `memset`/`util_fill_rect` on two threads) took menus from 12.3 to 7.2 ms/frame and gameplay from ~28 to 16.3 ms/frame.
The remaining render-side CPU is ~2.6 ms/frame (menus: 7.2 vs 4.6 headless), mostly `RendererCanvasCull`/`_draw_viewport`.

Open items:
1. Gameplay is at the edge of the budget (16.3 ms p50 vs 16.7). Spikes push physics into 2-tick frames. Candidates:
   the HUD `add_theme_color_override` early return (§4, ~0.8 ms); the remaining `%`/`/` sites; GDScript/physics hot paths from perf.
2. Scanout shows a 224-line window (rows 7–230) of the 240-line frame: the core's H40 timing, the same as donut.dodo. Check what the HUD loses at the top.
3. Not yet exercised: NINEPATCH/POLYGON/PRIMITIVE (none in attract mode), clip rects (the fabric has no scissor), and additive or
   premultiplied blends (none seen: `premult=0`). Real gameplay and menus beyond attract mode may use them; the stats line counts them.
4. Audio (DDR ring driver) and input (DDR joystick words → Godot joypad) are not written yet.
5. Launcher/packaging (Tier 3).

## 6. Audio + input, first real gameplay (2026-09-23)

Code: `src/godot/platform/linuxbsd/mister/{audio_driver_mister,joypad_mister}.*` (ports of the DDR contracts in
donut.dodo `patches/0004`/`0005` onto Godot's `AudioDriver` and `Input`; the SDL files do not apply because Godot 4.3's linuxbsd
platform has no SDL). Registered by `scripts/apply_godot_mister.py`. Engine `work/build/godot43aj.cortexa9`. Device launcher
`scripts/run_play.sh`. Scripted input: `scripts/joy_inject.py`, with the engine reading `MISTER_JOY_BASE=0x3A0C0000`, a DDR page
the core does not touch (the core uses 0x3A000030/38, 0x3A070004/08, 0x3A0D0000, 0x3A0E0000, 0x3BF40000+).

| Fact (Observed) | Evidence |
|---|---|
| Joypad path works end to end: injected Start → panel change 2 s later; A presses → level `LOONY LOOPS 1-1` loads (nodes 216 → 1342) | `work/tier0/aj/aj1.log`, `inj1.log`, `aj1_end.png` |
| Button map is Godot 4 indices from `project.godot`: A=0 jump/accept, B=1 cancel, BACK=4 select, START=6 start/pause, DPAD 11–14. The Godot 3 table in donut.dodo (Start=11) would leave Start and the d-pad dead | `work/decomp/project.godot` |
| Audio ring: 0 underruns after startup, depth ≥1026 frames, mix 0.05–0.45 ms per 512-frame period. Audible output **not yet checked by ear** | `aj1.log` `MISTER_AUDIO` lines |
| **Real gameplay collapses to 8–10 fps** for several seconds at a time (130–210 ms CPU/frame), while physics stays at 61–67 ticks/s: Godot's catch-up runs up to 8 physics steps per rendered frame | `aj2.log` … `aj4.log` |
| Not caused by the probe's enabler emulation (same with `TIER0_ENABLERS=none`) or the audio driver (same with `--audio-driver Dummy`) | `aj3.log`, `aj4.log` |
| Not DDR store cost: all `/dev/mem` writers ≈1.3% of samples (`libmisterfabric.so` 0.86%, audio thread 0.46%); engine 84%, flat (GDScript::call 8%, BVH cull 4.5%, Vorbis ≈5%, ClassDB get/set_property 4%) | perf, `/tmp/p2.data` on device |
| With `physics/common/max_physics_steps_per_frame=1` the collapse disappears: ~40 fps wall in play, 13–38 ms process CPU per frame (2 cores) | `aj5.log` |

Inferred: steady-state play is over budget, and the spiral turns each overrun into seconds at 8 fps. The attract-demo figure
(16.3 ms, §4) understated real play. Unknown: which scripts/nodes grow in real play vs the demo, and the per-thread split
(process CPU >100% during the collapse).

### 6.1 Real-play profile and first fix (2026-09-23)

Thread split (perf, release, during the 8 fps stretches): main thread 87%, audio mixer thread 11.5% (Vorbis decode), worker pool <2%.
Main thread by area: Variant/ClassDB/Object 21%, scene/canvas 14%, GDScript VM 13%, physics 9.5%, Vorbis 1.5%.

The physics solver is not a factor: `solve_constraints` is 9 µs per tick and the game has no `RigidBody2D` (bodies: Area2D, RayCast2D ×73,
ShapeCast2D ×4, CharacterBody2D ×6, StaticBody2D). Solver iterations therefore do not matter.

Script profile of real play (`work/tier0/aj/prof_native.jsonl`, debug build, `scripts/profile_summary.py`; per physics tick; debug ≈1.55× release):

| Item | ms/tick | Note |
|---|---|---|
| Gold pickups (~31 active) | 4.1 | `gold.gd::_physics_process`, `set_gold_position` moves each coin every tick (real transform + broadphase update) |
| Enemies | 3.6 | detectors (raycasts) ~2.1 |
| HUD `add_theme_color_override` | ~1.8 | same colour re-applied each tick; **fixed in the engine** (below) |
| Player `move_and_slide` | 1.2 | 3.5 calls/tick |
| `AudioStreamPlayer.play` | 0.62 at 0.1 calls/tick = **~6 ms per call** | every SFX is `oggvorbisstr`; each play builds a Vorbis decoder on the main thread. Likely spiral trigger |
| `AnimatedSprite2D.play` (bonus entrance) | 0.32 | re-plays a running animation, 5.7 calls/tick |

Fix applied (`apply_godot_mister.py`, `scene/gui/control.cpp`): `add_theme_{color,constant,font_size}_override` returns early when the value
is unchanged. A/B release, `max_physics_steps_per_frame=1`, same scripted play (`scripts/ab_play.sh`, `work/tier0/aj/ab_all.log`):

| Build | fps (run 1 / 2) | process CPU ms/frame |
|---|---|---|
| `godot43aj` (base) | 49.1 / 33.7 | 22.8 / 22.7 |
| `godot43th` (theme fix) | 52.2 / 51.7 | 17.5 / 19.7 |

With the default 8 steps/frame the fixed build still spirals to 8 fps in stretches (`ab_theme_s8.log`).

Next candidates, in order of expected value:
1. Ship `physics/common/max_physics_steps_per_frame=1` (launcher `override.cfg`): overruns become slowdown instead of 8 fps stretches.
2. Vorbis SFX start cost: cache or pre-decode short `oggvorbisstr` SFX (engine side, e.g. keep parsed setup headers per stream).
3. `AnimatedSprite2D::play` early-out when already playing the same animation (check 4.3 source first).
4. Gold/enemy per-tick cost is game logic; engine-side options are limited (transform notification / broadphase update per move).

### 6.2 Plan: cut the cost of starting a sound effect (2026-09-23)

**Measured** (`scripts/sfx_bench.gd`, release `godot43th`, headless on device):

| Fact | Value |
|---|---|
| SFX set | 45 files in `res://sounds/sfx/`, all `AudioStreamOggVorbis`, **none looping**, 0.02–1.35 s, **20.8 s total** |
| `instantiate_playback()` | **≈6.1 ms per call** (5.8–12 ms), independent of clip length, paid on **every** play |
| `start(0)` (= `seek(0)`, first-packet decode) | 18 µs |
| Where the 6 ms goes (perf, 1800 instantiations) | codebook build `vorbis_book_init_decode` 29% + its software divides/sort ~10% + header bit-reading `oggpack_read` 4%; per-decoder MDCT/window setup (`mdct_init`, `sincosf`) ~5.5% |
| Game usage | `Sounds.gd` pool of `AudioStreamPlayer`s: `player.stream = sounds[name]; player.play()`. `Music.gd` does the same for music/jingles. No script touches playback objects (`get_stream_playback` unused) |

Why every play pays: `AudioStreamPlayer::play()` → `AudioStreamOggVorbis::instantiate_playback()` → `_alloc_vorbis()` parses the three
header packets into a **fresh** `vorbis_info` and calls `vorbis_synthesis_init`, which builds the decode codebooks (`ci->fullbooks`)
once per `vorbis_info`, so once per play. Nothing is cached across playbacks of the same stream.

**Options** (all engine-side in `modules/vorbis/audio_stream_ogg_vorbis.*`; the game is unchanged):

| | Change | Per-play cost after | Other effects | Risk |
|---|---|---|---|---|
| **A. Shared setup** | Parse headers once per `AudioStreamOggVorbis` into a stream-owned `vorbis_info` (codebooks built once, on the main thread). Each playback gets only its own `vorbis_dsp_state`/`vorbis_block` over the shared, read-only info | est. ~0.5–1 ms (MDCT/window init remains) | Audio thread still decodes every SFX while it plays | Low: libvorbis treats `vi` as read-only during synthesis; the only write (`fullbooks`) happens in the first init, on the main thread. Lifetime: the stream owns the info and playbacks hold a `Ref` to the stream |
| **B. PCM cache for short clips** | For non-looping streams ≤ N s (default 3 s, env-tunable), decode once to 16-bit PCM at the mix rate (48 kHz) and have `instantiate_playback()` return a playback of an internal `AudioStreamWAV` | µs (object allocation) | Removes SFX decode from the audio thread too (the audio thread was 11.5% of CPU in play, part of it SFX). Memory ≤ 20.8 s × 48 kHz × 2 ch × 2 B ≈ **4 MB** | Medium: the playback type changes (no script depends on it). One-time decode at load. Music/jingles above the threshold stay streamed |
| C. Pool decoders per stream | Reuse finished `AudioStreamPlaybackOggVorbis` objects (`vorbis_synthesis_restart` + seek) | ≈ A | — | Higher: playbacks are ref-counted and deleted by `AudioServer` after a fade-out on the audio thread; returning them to a pool crosses that lifetime. A gets most of the gain more simply |

**Recommendation: B, with A underneath it.** A makes every Vorbis start cheap, including music and jingles, and makes B's one-time decode
cheap too. B removes the per-play cost and the audio-thread decode for the 45 SFX. They're independent, and A alone is a valid first step.

**Implementation steps**
1. A: add `vorbis_info shared_info` + `bool shared_ready` to `AudioStreamOggVorbis`, filled in `maybe_update_info()` (it already parses
   the headers, then discards them); make `_alloc_vorbis()` use `&vorbis_stream->shared_info` and skip `headerin`; clear the info in the
   stream destructor. Guard: `MISTER_OGG_SHARED=0` restores upstream behaviour.
2. Measure A with `sfx_bench.gd` (target: `inst_us` ≪ 6 ms) and the headless 40× perf capture.
3. B: in `instantiate_playback()`, if `!loop && get_length() <= MISTER_OGG_PCM_MAX_S` (default 3): on first use (or at load, see 4) decode
   through a temporary playback's `mix()` (float, already resampled to the mix rate) into an `AudioStreamWAV` (16-bit, stereo,
   48 kHz, `LOOP_DISABLED`) and return `pcm->instantiate_playback()`. `MISTER_OGG_PCM_MAX_S=0` disables it.
4. Decode timing: at load (in `set_packet_sequence`, after the `loop` property is known) or lazily on first play. At load, all 45 SFX
   decode while the `Sounds` autoload loads at boot; measure that boot delay, and move the work to a `WorkerThreadPool` task if it is over ~1 s.
5. Verify: `sfx_bench.gd` (instantiate µs, all 45 SFX), audio by ear (pitch randomisation is applied by `AudioServer`, so it is
   unaffected), then `ab_play.sh` A/B at 1 and 8 physics steps, looking at the spiral stretches and the audio thread's share in perf.

### 6.3 SFX start cost: steps 1–2 implemented (2026-09-23)

Both are in `scripts/apply_godot_mister.py` (`modules/vorbis/audio_stream_ogg_vorbis.*`).

- **Step 1, shared setup** (`OggVorbisSharedSetup`): each stream parses its headers once in `maybe_update_info()` and builds the codebooks
  with a throwaway `vorbis_synthesis_init`. Playbacks ref-count the shared `vorbis_info` and create only their own dsp state/block.
  `MISTER_OGG_SHARED=0` gives upstream behaviour. Build `godot43og`.
- **Step 2, PCM cache**: clips of ≤ `MISTER_OGG_PCM_MAX_S` s (default 3; 0 = off) are decoded at load through a normal playback's `mix()`
  (same cubic resampler, to the mix rate) into a 16-bit stereo `AudioStreamWAV`. `instantiate_playback()` returns its playback unless
  the stream loops. Build `godot43pc`.

| Measure (`sfx_bench.gd`, 45 SFX, release) | upstream | step 1 | step 2 |
|---|---|---|---|
| `instantiate_playback()` mean | 6.4 ms | 0.85 ms | **27 µs** |
| Startup to first bench line (autoload loads all SFX) | — | 5.5 s | 7.2 s (**+1.7 s** decoding 20.8 s of audio at load) |

Correctness: step 1 output is bit-identical to upstream for all 45 SFX (`scripts/sfx_hash.gd`, SHA-256 of the captured master bus with
`MISTER_OGG_SHARED=1` vs `0`). Step 2 is not bit-identical (16-bit storage); verify by ear.

Open: the +1.7 s boot cost. Option: decode in a `WorkerThreadPool` task and serve streamed playbacks until the cache is ready.

Gameplay A/B (`scripts/ab_play.sh`, serial runs, `work/tier0/aj/ab_ogg2.txt`; th = theme fix, og = + step 1, pc = + step 2):

| Steps/frame | th | og | pc |
|---|---|---|---|
| 1 (fps, run 1 / 2) | 51.6 / 52.2 | 52.8 / 53.8 | 52.4 / 53.7 |
| 1 (process CPU ms/frame) | 20.4 / 20.3 | 19.5 / 19.1 | 19.1 / 18.9 |
| 8 (fps, one run) | 29.5 | 35.3 | 35.5 |

The 8 fps stretches remain with 8 steps/frame (`pc_s8`: 8–12 fps for ~3 s). Steady play is still over budget, so the SFX spikes were one
trigger, not the whole cause. (An earlier A/B, `ab_ogg.txt`, is invalid: two runner loops were killing each other's engines.)

### 6.4 Gold coins: pixel-quantized bob (2026-09-23)

Observed in `objects/gold/gold.gd`: coins are not static. Every on-screen coin bobs 2–4 px at 3.2–4.8 px/s, writing `global_position.y`
every tick (~0.07 px). The project snaps 2D transforms to pixels (`2d/snap/snap_2d_transforms_to_pixel=true`), so the sprite moves on
screen about once per 15 ticks, while each write pays a transform notification (4 children) and an Area2D broadphase update.

Patch (`src/patches/`, deployed to `/media/fat/games/cashcow/patches/`, autoload `MisterPatches` in `override.cfg`; the pck is unmodified):
`mister_patches.gd` swaps each coin's script, on `node_added` (before `_ready`), for `gold_pixel_bob.gd`, which is
`extends "res://objects/gold/gold.gd"` overriding only `set_gold_position`: the bob runs in a float and the node is written only when
`floor(y + 0.5)` changes. On-screen motion is identical under pixel snap; the pickup shape moves < 0.5 px. `MISTER_PATCHES=0` disables it.
Verified: swap active, no script errors, coins still collected (nodes 1343 → 983 in a scripted run).

A/B `godot43pc`, without (np) vs with (gp) the patch (`work/tier0/aj/ab_gold.txt`):

| Steps/frame | np run 1 / 2 | gp run 1 / 2 |
|---|---|---|
| 1: process CPU ms/frame | 18.3 / 19.2 | 17.7 / 18.6 |
| 8: fps | 32.4 / 41.7 | 41.7 / 44.2 |
| 8: process CPU ms/frame | 30.6 / 25.5 | 24.6 / 24.2 |

About −0.6 ms/frame steady-state. Short dips into 8–13 fps remain at 8 steps/frame. Run-to-run spread is large (the scripted play takes
different paths once the game's RNG diverges), so treat single runs as ±10%.

Remaining per-coin cost: the `_physics_process` body itself (is_on_screen(), `visible = true` property write, GameManager reads,
`global_rotation` read, `set_gold_visible`): ~1.5 ms/tick in debug for ~31 coins. Removing it requires overriding `_physics_process`.

### 6.5 Separate render thread: rejected on Tier 2 (2026-09-23)

`--render-thread separate` (Godot 4.3 overlaps render of frame N with main-thread physics/process of N+1; `sync()` waits only before the next
`draw()`). It works functionally on the fabric path (no crash, normal `MISTER_FABRIC` stats, correct screenshot `work/tier0/aj/rt_try.png`), but
it is slower in every pair (`work/tier0/aj/ab_rt.txt`, godot43pc + coin patch):

| Steps/frame | single-threaded fps | separate fps |
|---|---|---|
| 1 (run 1 / 2) | 54.9 / 39.9 | 49.3 / 36.7 |
| 8 | 41.2 | 19.8 |

Process CPU per frame rises 4–17 ms. Inferred: every RenderingServer call from the scene becomes a queued command, and this game makes many
per tick; that costs more than the ~2.6 ms of render work it moves. (The earlier "no gain" note was a Tier-1 measurement and did not apply.)

### 6.6 Per-tick setters and flattened scripts (2026-09-23, measurement pending)

Engine (`apply_godot_mister.py`, build `godot43as`):
- `AnimatedSprite2D::play()` validated the name via `get_animation_names().has()` (build + sort a `Vector<String>` of all names, linear search)
  and always emitted `property_list_changed` + `queue_redraw()`. Now a hash lookup, and an early return when already playing that animation
  and nothing changes. Called every tick by mega gold, the bonus entrance and the state machine (~56 µs/call in debug).
- `ShaderMaterial::set_shader_parameter()`: early return when the cached value is equal (enemy flash sets it 5×/tick).

Game scripts (`src/patches/`, loaded by `mister_patches.gd`; `MISTER_PATCHES_SKIP=gold,input,enemy` disables individual patches):
- `gold_pixel_bob.gd`: flattened `_physics_process` (inlines set_gold_position/rotation/visible, reads `global_rotation` once) + pixel bob.
- `game_input_flat.gd`: the GameInput autoload's 42 per-tick calls inlined; `&"..."` StringName literals remove ~24 String→StringName
  conversions per tick. Evaluation order preserved (up sees last tick's down, down sees this tick's up; same for left/right).
- `enemy_detectors_flat.gd`: 7 per-tick calls inlined; `owner` and `owner.direction` read once instead of ~20 times.

Combined A/B (`work/tier0/aj/ab_flat.txt`): b0 = `godot43pc`, no patches; b1 = `godot43as` (setter fixes) + all three script patches.
The `ab_play.sh` summary fps (frames / wall span of gameplay probe lines) undercounts when a run leaves gameplay mid-window; use the
per-second medians for 8 steps.

| | b0 run 1 / 2 | b1 run 1 / 2 |
|---|---|---|
| 1 step: process CPU ms/frame | 19.1 / 18.7 | 16.9 / 17.5 |
| 8 steps: per-second fps median | 43 / 43 | 56 / 55 |
| 8 steps: minimum second | 8 / 10 | 25 / 27 |
| 8 steps: seconds < 30 fps | 7/25, 13/44 | 1/24, 1/33 |

(b1_s8_1 was perturbed by a 15 s busy-loop calibration on the same device and still led.) The 8-fps stretches are gone in these runs;
play is not yet a locked 60.

### 6.7 Hardware counters, gameplay (2026-09-23)

`scripts/perf_stat_play.sh` (`perf stat -t <main tid>`, 10 s per event group, t=42–62 of scripted play, `godot43as` + patches, 1 step/frame,
60 fps held throughout; `work/tier0/aj/perfstat.txt`). The A9 PMU works in counting mode (calibration: 0.793 GHz on a busy loop).
On this core perf maps `stalled-cycles-frontend` to the instruction-side stall event and `stalled-cycles-backend` to the dispatch stall event.

| Main thread, per 10 s | Value | Rate |
|---|---|---|
| cycles | 6.03 G | 76% of one core at 0.793 GHz |
| instructions | 2.31 G | **IPC 0.38** |
| L1-icache-load-misses | 102 M | **44 per 1000 instructions** |
| iTLB-load-misses | 12.5 M | 5.5 per 1000 instructions |
| L1-dcache-load-misses | 36 M | 4.6% of loads, 16 per 1000 instructions |
| branch-misses / branches | 51 M / 227 M | 22% |
| stalled-cycles-frontend | 0.90 G | 15% of cycles |
| stalled-cycles-backend | 4.43 G | 73% of cycles |

Inferred: the instruction side is poor (i-cache miss rate ~10× that of compact code, high iTLB misses): the hot path is spread across a
large binary. That supports code-layout work (PGO with function reordering, or Thumb-2 for ~25–30% smaller code). Most stall cycles
are dispatch stalls, whose cause this PMU does not split further (data-cache misses, dependencies, branch recovery). The 22% branch-miss
rate fits an interpreter's indirect dispatch.

### 6.8 Target: default 8 physics steps/frame; visual work once per frame (2026-09-23)

Decision (user): keep Godot's default `max_physics_steps_per_frame=8`. In catch-up frames `_physics_process` runs up to 8 times per rendered
frame while `_process` runs once, so visual work moved out of the physics tick is worth up to 8× in exactly the frames that spiral.

`mister_patches.gd` adapter (`VISUAL_TICK`): for scripts whose `_physics_process` only drives visuals, the node's physics callback is turned
off after `_ready` (Godot enables it during READY; no game script calls `set_physics_process`) and the same `_physics_process(delta)` is
called once per frame from the loader's `_process` when `n.can_process()` (pause, on-screen enablers). The loader runs with
`PROCESS_MODE_ALWAYS` and priority −1000. Checked for each script: no writes to GameManager/GlobalVariables, no signal emits or sounds in the
tick. Scripts: gold (patched subclass; the bob moves the pickup shape, so pickup timing can shift by ≤1 frame), `ui/hud/{info,p1,mooney}`,
`ui/pickup_score`, `ui/enemy_warning`, `ui/extra`, `generic/sprite_shaker`, `objects/shaft_arrows`, `objects/effect/{eye_effect,danger_warning_sign}`,
`objects/disco/disco_lights`. Left in physics: `background_color_manager.gd` (timed state machine), `TimeManager.gd` (flash timers other
scripts read), anything that moves bodies or changes collision.
`enemy_flat.gd`: the idle animation and the flash-shader update moved to `_process`.

Functional check (`work/tier0/aj/vis_try.txt`, `vis_pause.png`): 173–175 nodes ticked per frame in a level, no script errors, pause menu and
HUD correct. `MISTER_PATCHES_SKIP=visual` disables the adapter; `MISTER_PATCHES_DEBUG=1` prints the node count.

Engine fix queued (apply script, next build): `CollisionShape2D::set_disabled` early return when unchanged (diamond, bonus entrance set it
every tick; each call queued a redraw and a physics-server shape update).

### 6.9 Thumb-2 vs ARM (2026-09-23)

Thumb-2 build `godot43tt` from `work/src/godot-thumb` (a copy of the patched tree without objects), `-mthumb` instead of `-marm`;
`surface_tool.cpp` compiles as ARM via `#pragma GCC target("arm")` (the GCC 10.2 cselib ICE did not recur, including at LTO codegen).
.text 40.6 MB vs 55.6 MB (−27%). Same source as `godot43as` otherwise. All patches on, 8 steps/frame, 3 alternating runs each
(`work/tier0/aj/ab_thumb.txt`):

| | ARM (`godot43as`) | Thumb-2 (`godot43tt`) |
|---|---|---|
| per-second fps median (3 runs) | 54 / 56 / 54 | 56 / 56 / 56 |
| minimum second | 44 / 43 / 39 | 38 / 37 / 38 |
| seconds < 55 fps | 14/26, 10/24, 14/25 | 11/24, 11/24, 11/24 |
| process CPU ms/frame | 19.9 / 19.9 / 20.3 | 20.3 / 20.2 / 20.2 |
| L1-icache misses per 1000 instructions | 43.1 | **33.9** |
| stalled-cycles-frontend | 14.7% | 12.1% |
| stalled-cycles-backend | 72.6% | 71.9% |
| iTLB misses per 1000 instructions | 5.3 | 5.3 |

Result: Thumb-2 cuts i-cache misses by ~21% but frame time does not measurably change. The instruction side was only ~15% of cycles; dispatch
stalls (~72%) dominate, and this PMU does not attribute them further. Inferred: code-layout work (Thumb-2, and PGO's function reordering)
has a ceiling of a few percent here; PGO's other effects (inlining and branch layout from profiles) are untested.

Also visible across these runs (all patches, incl. the visual-tick adapter): no second below 37 fps at 8 steps/frame, versus minimums of
25–27 fps in §6.6's b1 runs and 8–10 fps before the patches.

### 6.10 GDScript access costs: static types help calls, not properties (2026-09-23)

Godot 4.3 compiler (`modules/gdscript/gdscript_compiler.cpp:781-833`, `gdscript_byte_codegen.cpp:818-849`): `obj.prop` on any Object —
native or script, typed or untyped, including implicit `self` native properties like `visible` — compiles to `OPCODE_GET_NAMED`/`SET_NAMED`
(by-name lookup: script members first, then `ClassDB::get_property` up the class chain). Only builtin value types (`Vector2.x`) and a
script's own members get direct access. Method calls on a typed native base (incl. `self`) compile to `CALL_METHOD_BIND_VALIDATED`
(direct ptrcall) only when the argument count is exact (no defaulted parameters) and every argument type matches exactly (`:234-252`).

Measured (`scripts/gd_access_bench.gd`, release `godot43as`, ns per op, empty-loop cost subtracted):

| Form | ns/op |
|---|---|
| `node.global_position` read | 2560 |
| `node.get_global_position()` | 413 |
| `node.visible = true` | 1550 |
| `node.set_visible(true)` | 308 |
| `node.visible` read | 1535 |
| `node.is_visible()` | ≈0 (below loop noise) |
| `spr.play(ACTIVE)` (String const, defaulted args) | 772 |
| `spr.play(&"active", 1.0, false)` (validated) | 518 |
| other script's member (`GameManager.x`-like) | 475 |
| call to a script function | 1075 |

So in hot scripts: native property access costs 4–6× a typed getter/setter call; a script function call costs ~1 µs (why flattening
works); and calls with defaulted parameters or String-for-StringName arguments miss the validated path (e.g. `Input.is_action_pressed(&"a")`
needs the explicit `false` for `exact_match`).

A/B `CollisionShape2D::set_disabled` early return + `player_detectors_flat` + `screen_warp_flat` (`work/tier0/aj/ab_cs.txt`; c0 = `godot43as`
with `MISTER_PATCHES_SKIP=playerdet,warp`, c1 = `godot43cs` with all patches; 8 steps, 3 alternating runs): per-second medians 54/56/56 vs
55/56/54, minimums 40/39/38 vs 43/40/40, CPU/frame within noise. No measurable change — expected from their profile share (≤0.4 ms/tick debug
each). The A/B resolves about ±2 fps on medians; the scripted play diverges between runs once the game's RNG differs.

Typed-call patches A/B (`work/tier0/aj/ab_typed.txt`; `godot43cs`, 8 steps, `MISTER_SEED=1`; u = `patches/`, t = `patches_typed/`):
per-second means 54.5/55.4/53.4 vs 55.7/54.5/55.2; seconds < 55 fps 44%/36%/38% vs 35%/36%/25%; minimums 38/39/40 vs 44/44/38.
Small and within run-to-run spread, but consistently no worse; `patches_typed/` becomes the default set.

### 6.11 Visual bug: half-brightness level art below a shallow diagonal (2026-09-23, fixed)

Observed (user, from the shared screenshots; confirmed by per-pixel classification, `work/tier0/aj/brightness_map.png`): the level art
renders at ~52% brightness ((255,0,165) -> (132,0,82), (0,0,249) -> (0,0,132)) below a line of slope ~0.15; sprites and HUD are unaffected.
The level art is one `Sprite2D` (`background_sprite`, `levels/level_generic/level_background.gd`) whose texture is **1472x240**
(`level_01.png`); the camera scrolls across it. Its diagonal has slope 240/1472 = 0.163: the half-bright region is the rect's FIRST
triangle (`q0,q1,q2`, `mister_fabric_bridge.cpp:295`); the second triangle is correct. Which part of the 320 px window falls on each side
depends on the camera x, hence "split" in some frames and "all dim" in others.
Not the guard-band clipper (vertices stay within ±2000 px -> pass-through). The triangle's area x2 in 12.4 units is 9.04e7, ~5x the
`blt_tri_setup.sv` validated envelope (~1.7e7); the per-pixel W*area_recip multiply is full-width (2x 48x24 -> 96 bit), so the exact RTL
mechanism is not yet identified.
Next: (1) decisive check — the same frame through the SW oracle (`GMLOADER_RASTER=sw MISTER_FABRIC_DUMP`) to confirm it is FPGA-specific;
(2) fix in the bridge regardless: subdivide large rects (local-space grid, e.g. <=256 px cells, matching UVs) and drop cells fully
off-screen — keeps every triangle inside the validated envelope and cuts off-screen setup work.

Fix (`mister_fabric_bridge.cpp` `emit_rect`, build `godot43sp`): a rect whose screen bbox exceeds 224 px on either axis is split in its
[0,1]^2 parameter space into <=224 px cells (uv/position are linear in the parameter, so flips/transpose/rotation carry over); cells wholly
off-screen are dropped; the rest go out as one triangle batch. Small rects take the unchanged path. Stats line gains `split=`/`split_culled=`.
Verified: screenshot `work/tier0/aj/split/20260923_212721-screen.png` (level art, attract demo) has 74520 full-bright and 0 half-bright
pixels, vs. level art mostly half-bright in every pre-fix capture; user confirmed visually. The exact RTL mechanism for >1.7e7-area
triangles remains unidentified (worth a note to the core's owner: `blt_tri_setup.sv` envelope). The SW-oracle PPM dump
(`MISTER_FABRIC_DUMP`) did not fire in two attempts; cause not investigated. No performance effect expected: the blitter already clamps
its walk to the screen, so the split only adds a few triangle setups.

### 6.12 Current-code profile, loader fixes, node pooling (2026-09-23)

Profile of the current code (`work/tier0/aj/prof_cur.jsonl`; debug build `godot43dsp` with all engine fixes, typed patches, 8 steps,
`--native`; steady gameplay frames only, excluding level-load frames): script time **8.35 ms per physics tick** (was 18.45 before §6.3–6.10).
Largest remaining: `move_and_slide` 1.34 ms/tick (2.06 in spike frames; engine physics), the loader's per-frame VISUAL_TICK loop 1.03
(profiler-inflated: it makes ~130 native calls per frame), enemy detectors 0.64, gold 0.47, screen warp 0.38, popup spawns 0.15 (0.57 in
spike frames). Level-load frames also showed the loader's `get_property_list()` per swapped node (8.9 ms per load frame).

Loader fixes (`mister_patches.gd`): script-variable names cached per script via `Script.get_script_property_list()`; VISUAL_TICK nodes
leave the list on `tree_exiting`, so the per-frame loop is one `can_process()` + the call per node.

Node pooling (written by a subagent, reviewed): `pickup_score_pool.gd`, `pickup_score_manager_pool.gd`, `effect_pool.gd`,
`effect_delete_pool.gd`, `effect_manager_pool.gd`; skip keys `pool_score`, `pool_score_mgr`, `pool_fx`, `pool_fx_mgr`. The 13 one-shot
effects and the "+N" popups are reused (hidden + PROCESS_MODE_DISABLED while parked; per-scene pools grow on demand, keep ≤12 effects /
≤16 popups; 15 effects pre-warmed per level load). Left on the original path: danger sign, eye effect, enemy death effects (own lifetimes).
Popups are not pre-warmed (their `_ready` draws from the global RNG). Known differences: a reused node may start its animation one frame
earlier/later; the popup's yellow override is applied once instead of every tick.

Pooling A/B (`work/tier0/aj/ab_pool.txt`; `godot43sp`, typed patches, new loader on both sides, 8 steps, `MISTER_SEED=1`; np = pools skipped,
pl = pools on; 3 alternating runs): seconds < 55 fps 41%/42%/43% -> 34%/27%/31%; minimum second 41/38/38 -> 45/44/43; per-second means
55.9/55.6/55.1 -> 56.2/56.8/55.7. Functional: all 10 swaps active, no script errors (only the expected steam_manager parse error), popups
and effects render correctly (`work/tier0/aj/pool_shot_big.png`), coins collected (nodes 1358 -> 1030). CPU/frame on both sides
(15.6–17.8 ms) is below the ~19–20 ms of §6.9–6.10 runs; the loader fixes and the rect split are common to both sides here, so that drop is
not attributable to pooling.

### 6.13 Engine hot spots in real play: canvas cull, process-list sort, BVH segment test (2026-09-23)

Release perf of real play (`godot43sp` + all patches, 20 s, main thread; `work/tier0/aj/perf_sp_syms.txt`): physics in total ~13%
(raycasts/BVH segment cull 5.8%, narrowphase 2.3%, broadphase other 2.3%, `move_and_slide`/`test_body_motion` ~1.2%); canvas/scene 24%
(top symbol `RendererCanvasCull::_cull_canvas_item` 8.8%, `_draw_viewport` 2.85%); `Node::is_greater_than` 2.85%; GDScript VM 12%;
Variant/ClassDB/Object 16%. The debug script profiler's 1.34 ms/tick for `move_and_slide` was mostly native-call instrumentation;
jump frames cost +8% script time vs neighbours (15 jumps), not a spike source.

1. `RendererCanvasCull::_cull_canvas_item`: early return for empty leaf items (no commands, no children, no visibility notifier / viewport
   render / back-buffer copy / canvas group / y-sort / clip), keeping the `repeat_size/_times` write. Covers every RayCast2D (15 per enemy),
   CollisionShape2D and marker node. Build `godot43cc`. A/B vs `godot43sp` (`ab_cc.txt`, 3 runs): per-second means 55.2/56.1/57.6 ->
   57.0/57.2/57.0, CPU/frame −0.35 ms, seconds < 55 fps 41/29/34% -> 38/29/20%; rendering correct (`cc_shot_big.png`). Small, within spread.
2. `SceneTree::_process_group` re-sort: every node that starts processing is appended and the whole list was re-sorted with a comparator
   that walks ancestor chains. Fast path: find the sorted prefix, sort the short tail, binary-insert; full sort otherwise. The comparator is
   a strict total order, so the result equals the full sort.
3. `BVH_ABB::intersects_segment` (hot in `_cull_segment_iterative`, 4.5%): LTO had already inlined `Rect2::intersects_segment` (8 `vdiv`
   in the hot function), so the cost is the math. Pre-test with the per-axis range rejects the slab test itself starts with (same float
   expression for the box end: `min + (-neg_max - min)`), and return true for segments moving along at most one axis once they pass —
   provably what the slab test returns there. Axis-aligned detector rays then never divide.
2+3 built together as `godot43bs`. A/B vs `godot43cc` (`ab_bs.txt`, 3 alternating runs, 8 steps): process CPU/frame 16.92/16.86/17.13 ->
16.57/16.28/16.39 ms (−0.56 ms average, lower in every pair); per-second means 57.4/56.4/56.8 -> 57.7/58.2/57.5; seconds < 55 fps mixed
(22/34/28% -> 28/27/24%). Functional check clean (no script errors, coins collected).

Division audit (`work/tier0/aj/divscan.py` over `perf_sp_symoff.txt`: perf samples mapped to instructions via `perf script -F sym,symoff`
+ `nm`/`objdump`; a sample on a `vdiv`/`vsqrt` or the 2 instructions after it counts as divide cost): float divide/sqrt = **0.10%** of
main-thread samples (largest `Vector2::normalized` 0.05%); integer-divide helpers (`__udivsi3`, `__aeabi_uidivmod`, `__udivmoddi4`, ...)
≈ **1.1%** in total, callers not identifiable without frame-pointer call graphs. Not worth a shift/reciprocal pass. Correction to item 3
above: the 8 `vdiv` in `_cull_segment_iterative` carry 0.03% of samples against 4.54% for the function — its cost is traversal (loads,
box conversion, mispredicted branches), not division; the pre-test still removes the conversion and most branches for axis-aligned rays.

### 6.14 `_draw_viewport` hot spot: the 8192-slot z scan, not ordered writes (2026-09-23)

The two hottest instructions in `RendererViewport::_draw_viewport` (+0xba0/+0xbcc, ~2% of all samples) are the inlined body of
`RendererCanvasCull::_render_canvas_item_tree`'s link loop: `for (i = 0; i < z_range; i++)` over all 8192 z slots (CANVAS_ITEM_Z_MIN..MAX),
loads and compares only — no device-memory stores or barriers. With it, every tree render memsets two 8192-entry pointer arrays (64 KB;
`memset` 0.81%), once per canvas layer per viewport per frame. The fabric's DDR command writes are in `libmisterfabric.so` (~1%).
Fix (build `godot43zr`): `_attach_canvas_item_for_draw` (the only writer) records the lowest/highest z slot used; the link loop scans that
range; the arrays are kept all-null between renders by clearing only that range after linking (the list chains through `Item::next`);
the arrays are zeroed once at allocation. Output identical.
A/B `godot43zr` vs `godot43bs` (`ab_zr.txt`, 3 runs, 8 steps): per-second means 57.4/57.0/57.2 -> 58.2/59.2/57.6; seconds < 55 fps
16/33/21% -> 11/11/11%; process CPU/frame noisy (13.9–16.9 both). Perf (`perf_zr_syms.txt` vs `perf_sp_syms.txt`): `_draw_viewport`
2.85% -> 0.29%, `Node::is_greater_than` 2.85% -> 0.50% (§6.13 item 2), `memset` 0.81% -> 0.19%, `_cull_canvas_item` 8.80% -> 7.93%
(§6.13 item 1), BVH `_cull_segment_iterative` 4.54% -> 4.39% (§6.13 item 3: no real effect, as the division audit predicted).

**Main thread, steady gameplay (`godot43zr`, all patches, 1 step/frame, `perf stat -t`, 2x10 s): 11.1 ms per frame (69% of one core).**
The probe's `cpu_ms_per_frame` (~15–17 ms) is process CPU across both cores (main + audio mixer + workers + kernel); the 16.7 ms budget
applies to the main thread. A 9 ms target needs ~2.1 ms (~19%) more.

### 6.15 Enemy/player detectors: where the time goes; dead raycasts (2026-09-23)

The detector *script* is cheap in release: per enemy per tick ~13 typed `is_colliding()` calls (~0.3 µs each), one `owner`, one
`direction` read and ~9 by-name writes into the enemy script (~0.5 µs each) — estimated 10–15 µs/enemy/tick. (The debug profile's
0.64 ms/tick self time is inflated by `--native` call instrumentation.) The cost is the casting itself: every enabled RayCast2D/ShapeCast2D
casts every tick in its own INTERNAL_PHYSICS_PROCESS whether or not anything reads it — ~5.8% of the main thread (~0.65 ms/frame).
Dead casts (declared, never read anywhere in the game, incl. attract-mode variants): `slide_detector_left`/`_right` on every enemy
(2 of its 15 rays) and the player's `rainbow_detector` (a circle ShapeCast2D). The detector patches now disable them in `_ready`
(`set_enabled(false)`): ~12% of the cast work, no behaviour change.
Further option (behaviour trade-off, needs sign-off): cast direction-dependent rays (trap/wall/ground left vs right) only for the side
the enemy faces, force-updating the other side on the tick it turns; ~30–40% of the remaining enemy rays.

### 6.16 GDScript inline cache for by-name property access (2026-09-23)

Main-thread breakdown of `godot43zr` (11.1 ms/frame; `perf_zr_syms.txt`): script execution 3.5 ms (Variant/Object/ClassDB dynamic dispatch
18.8% = 2.1 ms, GDScript VM 12.9% = 1.4 ms), rendering 2.0 ms (cull 1.0, FPGA submit 1.0), physics 1.5 ms, scene tree 0.7, kernel+locking
0.8 (incl. `v7_dma_inv_range` 0.8%), libc 0.5, unattributed 1.4.

Engine change (build `godot43nc`; `src/godot/modules/gdscript/gdscript_mister_named_cache.cpp` + apply-script edits to
`gdscript_function.{h,cpp}` and `gdscript_vm.cpp`): OPCODE_GET_NAMED / SET_NAMED on an object first try a per-instruction cache entry
keyed by (object class, GDScript). Filled only where the full lookup provably ends in the same place — MEMBER (script member without
getter/setter; set only when the value already has the member's type) or NATIVE (no script level resolves the name: no member,
constant, static, signal, method, subclass, `_get`/`_set`; first native class level with the name has a plain getter/setter
MethodBind, called exactly as ClassDB does); anything else UNCACHEABLE for that key. Side array per function allocated on first use,
main thread only; scripts held by Ref; GDExtension classes excluded (ClassInfo::gdextension). Debug-build difference only: a failing
native setter call no longer raises the "invalid assignment" break.
Semantic check (`scripts/named_cache_test.gd`, headless on device): output identical between `godot43zr` and `godot43nc` (26 lines:
untyped/typed members incl. float->int conversion, setget, `_get` shadowing `visible`, `_set` redirecting `position`, constant/static/
method/signal via instance, inherited members, one site across 5 class/script combinations).
A/B `godot43nc` vs `godot43zr` (`ab_nc.txt`): no steady-state gain (main thread 12.48/11.25 ms vs 11.1), and run 2 collapsed into a 12 s
catch-up spiral (14–38 fps, t=58–69) not seen without the cache. Correction: the 0.5–1 ms estimate took the whole "dispatch" bucket; the
lookups the cache removes are `ClassDB::get_property` 0.85% + `set_property` 0.67% + `GDScriptInstance::get` 1.45% ≈ 3% (≤0.3 ms). Now
gated behind `MISTER_GD_CACHE=1` (off by default), with a megamorphic limit (a site stops refilling after 5 key changes).

### 6.17 FPGA submit path (subagent) and write-combining DDR (2026-09-23)

Library/bridge optimizations (subagent; details and exhaustive/replay equivalence tests in `work/fabric_eq/`, deltas in
`src/vendor/VENDOR.md`): `emit()` builds each 32-byte command on the stack and stores 8 aligned words instead of 32 bytes (the ring is
strongly-ordered without mem_wc: one bus transaction per store); texture-cache lookup hint before the 256-slot scan per quad; exact inline
`lroundf` + one-entry packed-colour cache; inline floor/ceil in `mf_crop_rect`; bridge `SNAME("opacity")` and inline exact floor for vertex
snapping. Whole-library replay: identical command ring, heap and framebuffer over 897 frames / 170,065 commands. `v7_dma_inv_range`
(0.78%) attributed to the rtw88 USB Wi-Fi RX path (interrupt context), not the fabric.

`mem_wc` for kernel 6.18.38-MiSTer (`tools/mem_wc/`, `build.sh` + prebuilt): the SD card's copies were all built for 5.15.1. Built in a
Docker volume against `MiSTer-devel/Linux-Kernel_MiSTer` branch `MiSTer-v6.18` (SUBLEVEL 38) with the device's `/proc/config.gz`,
`LOCALVERSION=-MiSTer`, `KBUILD_MODPOST_WARN=1` (MODVERSIONS off); vermagic `6.18.38-MiSTer SMP mod_unload ARMv7 p2v8`. Loaded with
`phys_base=0x3B000000 phys_size=0x01000000`; the library logs `rings+heap write-combined (/dev/mem_wc)`; `GMLOADER_NO_WC=1` reverts.
Never rmmod (see tools/mem_wc/README.md).

Main thread per frame (`work/tier0/aj/wc_matrix.txt`; `godot43zr`, 1 step/frame, 60 fps, 4 windows each):
| | windows (ms) | mean |
|---|---|---|
| A strongly-ordered, old lib | 11.76 12.47 11.43 12.79 | 12.11 |
| B write-combined, old lib | 11.43 12.12 12.64 11.44 | 11.91 |
| C write-combined, optimized lib | 11.13 11.22 11.25 12.28 | 11.47 |
| D strongly-ordered, optimized lib | 11.41 11.33 11.35 11.18 | 11.32 |
Inferred: the optimized library is worth ~0.5–0.8 ms/frame (C, D below A, B in 7 of 8 windows). Write-combining is not resolvable in
steady state once `emit` writes words (window spread ±0.6 ms); its measured 10x bandwidth matters for texture-heap refills (level loads,
new textures). Rendering correct with both (`wc_opt_shot_big.png`, 0 half-bright pixels). The green "58" in that capture is the core's
OSD "FPS Overlay" option (C_STATUS bit1), not a library change.

### 6.18 Dip diagnosis: frame spikes vs. CPU placement (2026-09-24)

`scripts/spike_probe.gd` (autoload via `ab_play.sh SPIKES=1`): one `SPIKE` line per frame whose wall period exceeds 20 ms or that ran
2+ physics ticks, with nodes added/removed, scene files instantiated, game/player state. 3 scripted runs on the current best config
(`godot43br`, optimized libmisterfabric, write-combining, typed patches, 8 steps; `work/tier0/aj/spikes_all.txt`):
- Level loads: 445–562 ms frames instantiating ~1,200–1,300 nodes (level, 170 gold, ...) — one-off.
- In level: ~450 spike frames per ~45 s run (~8/s, ~14% of frames), mostly 20–34 ms; 452 of 1,149 are 2-tick catch-up frames; 80% had
  no node added or removed. With an 11.3 ms average main thread, that points to preemption/blocking rather than extra work.
CPU placement during play: `Main_MiSTer` (pid of `/media/fat/MiSTer`) uses ~46% of total CPU and is pinned to CPU1 (affinity mask 2);
the engine's main thread and most of its threads run on CPU0; the USB controller interrupt (IRQ 34, dwc2_hsotg: Wi-Fi 0bda:c820, Xbox 360
pad, USB-serial, SATA bridge, hubs) fires **8,213/s, all delivered to CPU0** (mask 3, the GIC picks CPU0); 26% system time.
Experiment running: IRQ 34 affinity CPU0 (1) vs CPU1 (2), 2 alternating spike runs each, restored to 3 afterwards.
IRQ 34 on CPU0 vs CPU1 (`work/tier0/aj/irq_ab.txt`, 2 runs each, `godot43br`): spikes 10.9, 11.2 /s -> 7.7, 7.9 /s; seconds < 55 fps
30%, 28% -> 8%, 10%; mean 57.5, 54.5 -> 59.0, 58.0 fps.
Scheduler trace, CPU0, 8 s of level play with IRQ 34 on CPU1 (`perf record -e sched:sched_switch -C 0`; `work/tier0/aj/sched.txt`):
the main thread was preempted 5,480 times (~685/s) for 992 ms total (12%): 505 ms by another engine thread on CPU0 (most likely the audio
mixer decoding music) and ~350 ms by short-lived shell processes (`bash`, `pidof`, `ps`, `tr`, `sleep`, `cat`, `grep`) spawned by polling
daemons of other installed ports (`/media/fat/MiSTer_Frontier/Master_Daemon.sh`, `/media/fat/games/Solarus/solarus_daemon.sh`); 61
preemptions > 2 ms, longest 117 ms. Blocked/sleeping: 658 episodes, 2.4 s, almost all frame pacing (idle ran meanwhile).
Inferred: the remaining dips are CPU placement, not game work. Test running: `scripts/cpu_isolate.sh` (USB IRQ, the engine's non-main
threads and all other user processes except Main_MiSTer -> CPU1; engine main thread -> CPU0; `off` restores mask 3).
CPU isolation A/B (`work/tier0/aj/iso_ab.txt`, `godot43br`, 2 runs each; isolation applied 15 s after launch, restored after):
| | spikes per level-second | mean fps | seconds < 55 fps |
|---|---|---|---|
| USB IRQ -> CPU1 only | 8.2, 7.9 | 58.1, 59.5 | 2/44, 1/25 |
| full isolation (`cpu_isolate.sh on`) | **2.4, 2.4** | **59.7, 60.5** | 2/35, 1/41 |
~70% fewer spike frames on top of the IRQ move. All affinities verified restored (IRQ 34 mask 3; every user process mask 3 except
Main_MiSTer, which pins itself to CPU1 and is never touched).
For packaging: pin threads inside the engine (main thread -> CPU0 at display-server init; the MiSTer audio thread -> CPU1) and have the
launcher move IRQ 34 and other user processes to CPU1 on start, restoring on exit (trap), instead of the shell-side per-tid juggling.

### 6.19 Release work: POLYGON draws, thread pinning, launcher (2026-09-24)

POLYGON commands (`unhandled: t2` in the fabric stats) were dropped: the HUD's two ProgressBars (`ui/hud/hud.tscn`: `combo_bar` under
"COMBO xN", `time_bonus_bar` in the bonus level) fill via StyleBoxFlat, which records TYPE_POLYGON. GLES3 keeps polygon vertices only in GL
buffers, so the bridge now keeps a CPU copy (`polygon_created`/`polygon_freed`, hooked in `request_polygon`/`free_polygon`) and
`emit_polygon` draws it as triangles (world transform, snap, canvas transform; per-vertex / single / white colour x modulate; per-vertex
UV). Texture/flash/blend resolution is shared with rects (`resolve_source`). Build `godot43pl`: poly=231–600 per 300 frames,
missing_poly=0, **no unhandled command types in a full run**; the combo bar renders (`work/tier0/aj/pl_hud_crop.png`).

Engine thread pinning (`MISTER_PIN_MAIN=<cpu>` at the end of DisplayServerMister init, after Mesa's threads exist;
`MISTER_PIN_AUDIO=<cpu>` in the mixer thread), for the launcher's CPU placement (§6.18).

Release packaging (`dist/`, `scripts/make_release.sh <engine> <tag>` -> `build/release/CashCowDX-MiSTer-<tag>.zip`):
`Scripts/CashCowDX.sh` (loads `_Other/CashCowDX_*.rbf`, waits for CORENAME `DonutDodo`, detaches `launch.sh` with setsid);
`games/CashCowDX/launch.sh` (lock + reap any fabric engine; FPGA-ready wait; mem_wc load-if-absent/never-unload; engine under
`taskset 2` with main->CPU0/audio->CPU1; after fabric bring-up: USB IRQ + other user processes -> CPU1, restored on exit via trap;
fabric gate: C_DONE must advance within 8 s, else reload core via menu.rbf and retry up to 4x; watchdog: stop the engine when another core
is loaded); `override.cfg` loads the patch loader only (no measurement probe); README with install/pck/controls/licences. The user supplies
`CashCowDX.pck` from the GOG release.

### 6.20 Release candidate: install, smoke test, 30-minute soak (2026-09-24)

Bundle `CashCowDX-MiSTer-20260924.zip` (engine `godot43rc`: all engine changes + thread pinning; optimized libmisterfabric; typed
patches incl. pools; mem_wc 6.18.38; Mesa runtime; 40 MB) extracted over `/media/fat` on the device: 0 checksum failures; GOG pck
`4436b750…` copied in. Zip root holds only `_Other/`, `Scripts/`, `games/`.
Smoke test via `Scripts/CashCowDX.sh` (scripted input through `CASHCOW_JOY_BASE`): entry returns immediately (launcher detached);
mem_wc reused; fabric bring-up ok, write-combined; main thread mask 1 (CPU0), USB IRQ on CPU1, 26 processes moved; gameplay renders
correctly at 60 fps (`work/tier0/aj/release_smoke_big.png`); loading the menu core -> watchdog stops the engine, CPU placement and IRQ
restored. The submit timeouts logged between the core change and the watchdog are the engine submitting to an unloaded core (poll now 1 s).
Fix after the smoke test: engine threads created after the main thread pinned itself (inherited CPU0) are moved to CPU1 by `cpu_isolate`.
**Soak** (`scripts/soak.sh 30`, `work/tier0/aj/soak30.txt`): 30/30 minutes engine alive and C_DONE advancing (~3,550 frames/min, ~59 fps
against the 60 fps pacing cap), no wedge, clean exit on core change, all affinities restored (only Main_MiSTer at its own mask 2).

### 6.21 Release checks that don't need a human (2026-09-24)

**Scanout crop — keep the core's 224-line window.** The core deliberately scans framebuffer rows 7–230 (Genesis V28 active height, the
area a consumer CRT shows; commit 82870b8 in maldita.castilla-mister; 240->224 scaling was tried and reverted, aa90ce2/3d853ad: text looked
squashed). Cash Cow check (full 320x240 frame read from the fabric's DDR scanout buffer at 0x3BF40040 during level play, aligned to the
screenshot at shift 7 — `work/tier0/aj/fbdump.bin`, `crop_rows.png`): the HUD text occupies rows 9–23 (fully visible); rows 0–6 hold only
the top edge of the level art; rows 231–239 hold the floor edge (the lower 2 rows of the floor spikes, the lower half of the bottom
platform). Nothing gameplay-critical is cropped.
**Controller.** The press path is proven in two halves: donut.dodo measured the core's joystick word at 0x3BF40008 changing under real
presses on this device (its patch 0005, 2026-08-24), and our engine's read of a DDR joystick word -> Godot input is the exact code path
every scripted run exercised (only the base address differs). Feel and preferred OSD mapping remain a human check.
**Audio.** During level play (release install, `godot43rc`): engine writes 47,920 frames/s, the FPGA consumes 47,923 frames/s (48 kHz within
0.2%) — sound is being played. Content: RMS 11,211 (~-9 dBFS), 1.8% of samples at full scale. Godot clamps the float mix to +/-1.0 and
scales to 31 bits (`audio_server.cpp:302-310`), and the driver's `>> 16` maps that to exactly +32767/-32768, so the path is unity gain;
the full-scale samples are the game's own mix hitting Godot's standard clamp, as on PC. Listening remains a human check.
**Level-load hitch — not a release blocker.** `work/tier0/aj/spikes_all.txt`: the 445–562 ms frames are the single frame in which the
game's scene change instantiates the level (`level_01.tscn` + 1,291 nodes incl. 171 gold, `title_panel`), i.e. at a screen transition
the game itself performs synchronously (no threaded loading in the game's code); the picture holds the previous frame for ~0.5 s, no
gameplay frame is affected and no input is lost (the next frame runs 1 physics tick). Reducing it would mean changing how the game
loads levels (threaded `ResourceLoader`, deferred gold spawning) — a game-behaviour change, left out.

### 6.22 Human release check (2026-09-24)

User-verified on the device with the release install: the game loads via **Scripts → CashCowDX**; audio plays correctly; game
controls work as expected. This closes the human checks left open in §6.21 (controller feel/mapping, listening). Release candidate
`CashCowDX-MiSTer-20260924.zip` (§6.20) has no open blockers.

### 6.23 Own core identity and start-on-core-load (2026-09-24)

Gap reported by the user: the shipped RBF identified as `DonutDodo` (Donut Dodo's CONF_STR name and button labels) and selecting it
from the core list started nothing. Fix, in two parts:
**Branded RBF.** maldita.castilla-mister (branch `donutdodo/fb-320x240`, where the shared fabric core is built) `44af13a`: a
`CASHCOW_CORE` macro switches the CONF_STR name to `CashCowDX` and J1 to `Jump/OK,Back,Unused X,Unused Y,Start,Select,Unused L,Unused R`
(jn unchanged: bottom = Jump/OK, right = Back); RTL identical. `build-rbf.yml` input `core_variant=cashcow` defines it. The build moved
the known `pll_hdmi` (`yc_out`) setup path to -0.168 ns; the gate now accepts that domain under the same -0.20 ns baseline (`632b83d`).
Seed 2 regressed `emu|pll` to -0.493 (rejected). Shipped: run 36003890841 (seed 1), `CashCowDX_20260924.rbf`, sha1 `5504e08f…`.
Device: `/tmp/CORENAME` and `/tmp/RBFNAME` read `CashCowDX`; screenshots file under `CashCowDX/`.
**Start on core load.** `games/CashCowDX/_handler.sh` (MiSTer Frontier's Master_Daemon runs it when CORENAME=CashCowDX) and
`cashcowdx_daemon.sh` (our own watcher for devices without Frontier; passive while Master_Daemon runs; registered in
`linux/user-startup.sh` by `Scripts/CashCowDX.sh` on first run). `launch.sh` changes: CORENAME `CashCowDX`; interruptible sleeps so the
TERM trap runs inside Frontier's 1 s SIGTERM->SIGKILL window; engine kill + CPU restore run in the background so a SIGKILL can't skip
them; the core-reload retry is a detached helper (a daemon kills the launcher when the core changes); exits at once unless the loaded
core is CashCowDX (Master_Daemon sees the RBF path change ~1 s before CORENAME and spawns the handler once for the outgoing core).
Device tests (all pass): core load with Frontier -> handler -> engine, fabric gate advancing, title screen
(`work/tier0/aj/branded_core_boot.png`); core change -> engine stopped, `cpu: restored`, USB IRQ mask 3; Frontier stopped ->
Scripts entry registers + starts our daemon -> game; menu -> watchdog stop; core load -> our daemon starts the game; both daemons
running -> exactly 1 launcher, 1 engine. Frontier's Master_Daemon was restarted after the test; device left at MENU.
Bundle `CashCowDX-MiSTer-20260924b.zip`. Future direction (user): one shared RBF + a per-game MRA (`setname` becomes `/tmp/CORENAME`,
`user_io.cpp:431`), instead of per-game CONF_STR builds.

### 6.24 Start on core load without a daemon: per-core `main=` wrapper (2026-09-24)

Replaces §6.23's `_handler.sh` + `cashcowdx_daemon.sh`. Mechanism (same as maldita.castilla-mister's `MiSTer_Maldita`): upstream
Main_MiSTer's per-core ini key `main=` (`cfg.cpp` "MAIN", `user_io.cpp` "core requires exec") makes stock MiSTer exec another Main
binary while that core is loaded; any other core's section has the default `main=MiSTer`, so loading it execs stock MiSTer again.
`[CashCowDX] main=/media/fat/games/CashCowDX/MiSTer_CashCowDX`, set/cleared by `Scripts/CashCowDX_CoresMenu.sh` (backs up MiSTer.ini;
refuses a binary without the hook string). `MiSTer_CashCowDX` = upstream Main_MiSTer + `tools/mister-wrapper/overlay/cashcow_{hook,child}`
+ one call `cashcow_hook_poll()` after `scheduler_wait_fpga_ready()` in `scheduler_co_poll()` (Maldita measured spawning before that
wait: 3/5 frame-1 wedges; after: 0/5). The hook spawns `launch.sh` once per exec (setsid, log `launch.log`), `NOENGINE` flag to skip.
**No vendored upstream file:** `build-hps.sh` inserts the call at build time on an anchor and uses upstream's Makefile with `PRJ`
renamed; either anchor missing fails the build. Pin `3380931` (Maldita's). Current upstream master `aa271e4`: the insert applies, but
the build fails in upstream's own `scaler.cpp` (`mister_scaler_read` default argument redeclared) with the Debian bullseye gcc — not
caused by the hook; pin kept.
`Scripts/CashCowDX.sh` now removes the old watcher (process, `user-startup.sh` line, `_handler.sh`, which Master_Daemon would run as a
second engine); with `main=` on it only loads the core. `launch.sh` reload helper starts the next launcher itself only when `main=` is off.
Release: `make_release.sh` ships the wrapper + toggle, requires the hook string in the wrapper; bundle `CashCowDX-MiSTer-20260924c.zip`.
Device tests on .81 (Master_Daemon + Solarus daemon running throughout), `work/tier0/mainhook/{switch,disarm}_test.txt`, all pass:
armed load -> `/proc/<MiSTer>/exe` = MiSTer_CashCowDX, 1 launch.sh, 1 engine, C_DONE +~63/s, attract screen
(`work/tier0/mainhook/armed_load.png`); game -> menu, game -> NES: stock `/media/fat/MiSTer`, 0 engines, USB IRQ mask 3, CPU masks
restored; menu -> game, NES -> game, repeat: 1/1 each time; same core reloaded over itself: the new launcher stands down on the lock and
the running engine continues (C_DONE advancing); disarmed load: stock Main, 0 engines; disarmed Scripts entry: 1/1; re-arm re-enables
the commented line (one `[CashCowDX]` section). Not tested: OSD and a real controller under MiSTer_CashCowDX (needs a person);
MGL `setname` on the shared RBF selecting the `[CashCowDX]` section. Device left armed, game running.
