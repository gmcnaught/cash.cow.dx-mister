# Cash Cow DX for MiSTer

Cash Cow DX (Godot 4.3) running on the MiSTer DE10-Nano: the game logic runs on the ARM cores, and every frame is
drawn by an FPGA blitter core. Audio and the joystick go through the core as well.

**The game itself is not included.** You need your own copy of the **GOG** release of Cash Cow DX.

## Install

1. Extract this zip over the root of your MiSTer SD card (`/media/fat/`). It adds:
   - `_Other/CashCowDX_<date>.rbf` — the FPGA core (the shared Godot/GameMaker blitter core, branded CashCowDX)
   - `Scripts/CashCowDX.sh` — loads the core and starts the game
   - `Scripts/CashCowDX_CoresMenu.sh` — turns on starting the game from the core list (step 3)
   - `games/CashCowDX/` — the engine, its runtime, the launcher, this README and `sha256sums.txt`
     (verify the copy: FAT filesystems can silently truncate files on an interrupted copy)
2. Copy **`CashCowDX.pck`** from your GOG install to `/media/fat/games/CashCowDX/CashCowDX.pck`.
   - GOG Linux installer: `data/noarch/game/CashCowDX.pck` inside the installer (e.g. extract with `innoextract`/`unzip`),
     or the file next to the game executable in an installed copy.
   - The file this port was tested with has SHA-256 `4436b7509cab462f3efb1c56a0aba2997407ace231f6a16c35f4b1796d2d5b6c`.
3. Run **Scripts → CashCowDX_CoresMenu** once. It adds a `[CashCowDX]` section to `/media/fat/MiSTer.ini`
   (backed up first to `MiSTer.ini.bak.<time>`) with `main=/media/fat/games/CashCowDX/MiSTer_CashCowDX`.
   From then on, loading **CashCowDX** from the core list (`_Other`) starts the game. Run it again to turn this off.
   - `main=` is MiSTer's per-core setting for which MiSTer program runs while that core is loaded.
     `MiSTer_CashCowDX` is the standard MiSTer program plus one addition that starts the game once the core is up;
     every other core keeps using your normal, updated `/media/fat/MiSTer`. No background service is installed.
4. **Scripts → CashCowDX** also starts the game, with or without step 3.

Upgrading from an earlier release: run **Scripts → CashCowDX** once. It removes the old `cashcowdx_daemon.sh` watcher
(and its line in `linux/user-startup.sh`) and `_handler.sh`.

To quit, load another core from the OSD; the launcher stops the game when the core changes.

## Controls

The game reads the joystick through the core, so the MiSTer OSD button mapping for this core applies
(**OSD → Define joystick buttons**). Buttons in order: **Jump/OK, Back, Unused X, Unused Y, Start, Select, Unused L,
Unused R**. Default map on an unmapped pad: bottom face = Jump/OK, right face = Back. Start pauses.

## Notes

- The core shows the 224 lines a CRT displays (rows 7–230 of the game's 240); only the top edge of the level art and the bottom
  floor edge are outside the picture — the HUD and all gameplay are visible.
- Saves and settings go to `games/CashCowDX/data/`.
- Logs: `/media/fat/logs/CashCowDX/` (`launch.log`, `cashcowdx.log`, and `cashcowdx.prev.log` from the previous run).
- `mem_wc-<kernel>.ko` gives the blitter a faster (write-combining) DDR mapping. It is loaded only if it matches the
  running kernel (`uname -r`) and nothing else has loaded one; otherwise the game runs with the slower mapping.
  It stays loaded until reboot by design.
- While the game runs, the launcher keeps CPU core 0 for the game's main thread and moves USB interrupt handling and
  other programs to core 1; everything is put back when the game exits.
- Only one blitter-core game can run at a time; starting this one stops any other.

## Credits and licences

- Cash Cow DX © its developers; not distributed here.
- This port: GPL-3.0, source at https://github.com/gmcnaught/cash.cow.dx-mister (see `LICENSING.md` there for exceptions).
- `MiSTer_CashCowDX`: MiSTer-devel/Main_MiSTer (GPL-3.0) plus this port's hook.
- Godot Engine 4.3 (MIT) with MiSTer changes; Mesa, libdrm (MIT); libtinfo (ncurses licence).
- `mem_wc` driver: GPL-2.0, from skmp/minicast (source in the port's repository under `tools/mem_wc/`).
