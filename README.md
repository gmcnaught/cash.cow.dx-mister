# Cash Cow DX for MiSTer

A port of **Cash Cow DX** (Godot 4.3) to the MiSTer DE10-Nano. The game's logic runs in a Godot 4.3 engine built for the
board's Cortex-A9 ARM cores. Every frame is drawn by an FPGA blitter core, and audio and the joystick also go through the core.
There is no GPU and no software rasterizer in the loop.

**The game is not included.** You need your own copy of the **GOG** release. This repository and its releases contain
only the engine, the launcher, the FPGA core and the port's runtime patches.

| | |
|---|---|
| Gameplay | 60 fps, paced on the core's scanout (every frame shown once) |
| Start-up (core load → attract screen) | 8.75 s warm, 12.0 s first start after power-on |
| Memory | ~160 MB peak |

## Install

Download the latest `CashCowDX-MiSTer-<tag>.zip` from [Releases](https://github.com/gmcnaught/cash.cow.dx-mister/releases), then:

1. Extract it over the root of the SD card (`/media/fat/`).
2. Copy `CashCowDX.pck` from your GOG install to `/media/fat/games/CashCowDX/CashCowDX.pck`.
3. Run **Scripts → CashCowDX_CoresMenu** once. After that, loading **CashCowDX** from the core list (`_Other`) starts the game.
   **Scripts → CashCowDX** also starts it.

The full user guide (controls, where to find the `.pck`, logs, upgrading) is
[`dist/README.md`](dist/README.md), which ships in the zip as `games/CashCowDX/README.md`.

## How it works

```
 MiSTer core list ──load──▶ CashCowDX core (FPGA: blitter, scanout, audio, joystick words in DDR)
        │                                ▲
        ▼ MiSTer.ini [CashCowDX] main=   │ command ring + texture heap in DDR (0x3B000000)
 MiSTer_hybrid ──starts──▶ launch.sh ──▶ cashcowdx (Godot 4.3, Cortex-A9)
 (upstream Main_MiSTer + one hook;       canvas commands ─▶ libmisterfabric ─▶ blitter
  reads linux/hybrid.d/CashCowDX.conf)
```

- **Engine** (`scripts/apply_godot_mister.py`, `src/godot/`). Stock Godot 4.3 plus:
  - a MiSTer display server, DDR audio driver and joystick driver;
  - a bridge that sends Godot's 2D canvas commands (rects, polygons, textures) straight to the blitter;
  - a null GL, so no Mesa is loaded;
  - CPU-cost fixes found by profiling the game on the A9.

  The apply script copies `src/godot/` into a Godot source tree and applies anchored edits to upstream files. It is idempotent.
- **`libmisterfabric`** (`src/fabric/`, `src/vendor/`): a C API over the mfgpu blitter backend. It handles textures,
  draws and presenting, and paces frames on the core's own scanout counter.
- **Runtime patches** (`src/patches/`): GDScript subclasses of a few of the game's scripts. They make its hottest per-tick
  code cheaper and pool frequently spawned effects. The game's `.pck` is not modified. The patches are loaded from
  `override.cfg` and ship as binary tokens (`.gdc`).
- **Launcher and device files** (`mister-port.toml`, rendered by the
  [mister-hybrid-platform](https://github.com/gmcnaught/mister-hybrid-platform) submodule in `external/`):
  - refuses to start unless the loaded core is CashCowDX with the `gm-fabric` DDR map;
  - keeps one engine at a time and loads the write-combining DDR driver (`mem_wc`);
  - reserves CPU0 for the engine's main thread;
  - reloads the core if the blitter stalls at start-up;
  - stops the game when another core is loaded.
- **Start on core load**: MiSTer's per-core `main=` setting runs the platform's shared `MiSTer_hybrid` while this
  core is loaded. It is upstream Main_MiSTer plus one call that starts the launcher named in
  `linux/hybrid.d/CashCowDX.conf`. There is no background daemon.

[`PLAN.md`](PLAN.md) is the engineering record: findings, measurements and decisions, with the data behind each change.
[`HANDOFF.md`](HANDOFF.md) is the short version: current state, decisions, layout and build.

## Building from source

Requirements: Docker (any host; the image carries an armhf cross toolchain), the Godot 4.3-stable source, and a MiSTer
on the network for packaging (patch tokenizing) and testing.

```sh
# 1. Cross-build image (Debian bullseye: glibc 2.31 matches the MiSTer, GCC 10)
docker build -t godot4-armhf-build:bullseye -f Dockerfile.godot4-build .

# 2. Godot 4.3-stable source
mkdir -p work/src && curl -L https://github.com/godotengine/godot/releases/download/4.3-stable/godot-4.3-stable.tar.xz \
  | tar -xJ -C work/src

# 3. Apply the MiSTer changes, then build the engine (LTO; ~15 min full, ~7 min incremental)
python3 scripts/apply_godot_mister.py work/src/godot-4.3-stable
A="-march=armv7-a -marm -mfpu=neon -mfloat-abi=hard -mtune=cortex-a9"
docker run --rm -v "$PWD/work/src":/src godot4-armhf-build:bullseye sh -c "cd godot-4.3-stable && \
  scons -j\$(nproc) platform=linuxbsd arch=arm32 target=template_release production=yes debug_symbols=yes \
  x11=no wayland=no vulkan=no module_openxr_enabled=no \
  disable_3d=yes modules_enabled_by_default=no module_gdscript_enabled=yes module_vorbis_enabled=yes module_ogg_enabled=yes \
  module_webp_enabled=yes module_freetype_enabled=yes module_text_server_fb_enabled=yes module_svg_enabled=yes module_mbedtls_enabled=yes \
  CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ ccflags='$A' linkflags='$A'"
mkdir -p work/build
docker run --rm -v "$PWD/work":/w godot4-armhf-build:bullseye sh -c \
  'arm-linux-gnueabihf-objcopy --strip-debug /w/src/godot-4.3-stable/bin/godot.linuxbsd.template_release.arm32 /w/build/cashcowdx.cortexa9'

# 4. Blitter library, write-combining driver (for the device's kernel), start-on-core-load wrapper
docker run --rm -v "$PWD":/p -w /p/src/fabric godot4-armhf-build:bullseye make OUT=../../work/build/fabric_opt
external/mister-hybrid-platform/device/main-hook/build-hps.sh   # MiSTer_hybrid (or take it from the platform CI artifact)

# 5. Release zip -> build/release/CashCowDX-MiSTer-<tag>.zip
#    RBF_SRC: the CashCowDX-branded fabric core (maldita.castilla-mister build-rbf.yml, core_variant=cashcow).
#    TOK_HOST: a MiSTer with the game's .pck installed; the release engine tokenizes the patches there.
RBF_SRC=<path to the core .rbf> TOK_HOST=root@<mister> scripts/make_release.sh work/build/cashcowdx.cortexa9 <tag>
```

Build notes:
- Keep `disable_advanced_gui` off. It removes `SubViewportContainer`, which the game needs.
- The game is English-only, so `text_server_fb` replaces `text_server_adv` (the text renders identically).

## Measuring on the device

The engine has opt-in instrumentation. Each switch below is an environment variable; unset, it costs one cached check.

| Switch | What it records |
|---|---|
| `MISTER_FRAMELOG=<file>` | One 64-byte record per frame: phases, fabric wait, CPU time, scanout counter |
| `MISTER_BOOTLOG=<file>` | Start-up phases, every resource load, and main-thread time per load primitive |

The harnesses run the installed release through its real launcher:
- `scripts/stutter/`: frame-pacing captures during scripted play (`run.sh`, analysed by `frames.py`).
- `scripts/boot/`: timing from core load to the attract screen (`boot_time.sh` → `boot_report.py`, `prof_phases.py`), plus
  scanout screenshots (`shot.sh`).

Engine feature switches for A/B runs (all on by default):

| Switch | Feature |
|---|---|
| `MISTER_NULL_GL=0` | Null GL (setting 0 needs a Mesa build in `LD_LIBRARY_PATH`) |
| `MISTER_GD_KEEP_PARSERS=0` | GDScript parse reuse |
| `MISTER_OGG_SHARED=0` | Shared Vorbis setup |
| `MISTER_OGG_PCM_MAX_S=0` | SFX PCM cache |
| `MISTER_OGG_PCM_ASYNC=0` | Background SFX decode |
| `MISTER_PATCHES=0` | Runtime patches |

## Repository layout

| Path | Contents |
|---|---|
| `scripts/apply_godot_mister.py` | Every engine edit, anchored and idempotent |
| `src/godot/` | New engine files: MiSTer platform, fabric bridge, null GL, frame and boot logs |
| `src/fabric/`, `src/vendor/` | `libmisterfabric` and the vendored mfgpu backend (local changes recorded in `src/vendor/VENDOR.md`) |
| `src/patches/` | Runtime GDScript patches and their loader |
| `mister-port.toml` | Launcher and device-file manifest, rendered by the platform (`scripts/make_release.sh`) |
| `dist/` | `override.cfg`, user README, `scripts-extra.sh` (upgrade clean-up rendered into the Scripts entry) |
| `external/mister-hybrid-platform/` | Submodule: launcher library, `MiSTer_hybrid` hook, `mem_wc` driver, DDR-map spec |
| `scripts/` | Release packaging and measurement harnesses |
| `work/`, `build/`, `gamedata/` | Local build trees, captures and game files. Git-ignored and never committed |

## Licence

GPL-3.0, with per-path exceptions. See [`LICENSING.md`](LICENSING.md) and [`LICENSE`](LICENSE):
- Godot engine files keep their MIT licence.
- `mem_wc` (in the platform submodule) is GPL-2.0.
- The runtime patches subclass the game's own scripts, and the game's code is not licensed by this repository.

Cash Cow DX and its assets are © their developers and are not part of this repository or its releases.
