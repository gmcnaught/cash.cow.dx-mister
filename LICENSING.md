# Licensing

Copyright (C) 2026 Grant McNaught.

Unless a section below says otherwise, the code in this repository is licensed under the
**GNU General Public License v3.0** (`LICENSE`), SPDX `GPL-3.0-only`. That includes `src/fabric/`, `src/vendor/` (mfgpu and the MiSTer
fabric code, copied from the author's own gmloader-next work and relicensed here), `src/godot/` (new files added to the engine),
`tools/mister-wrapper/`, `dist/` and `scripts/`.

## Exceptions

| Path | Licence |
|---|---|
| `tools/mem_wc/` | GPL-2.0, from skmp/minicast (see its SPDX header and `tools/mem_wc/README.md`). |
| `src/patches/*.gd` (shipped as binary tokens, `.gdc`) | These subclass Cash Cow DX's own scripts and reproduce parts of their logic. The game's code is © its developers and is **not** licensed by this repository; only the changes made here are GPL-3.0. The game itself is not included — you need your own copy from GOG. |
| Godot Engine | Engine files changed by `scripts/apply_godot_mister.py` stay under Godot's MIT licence (© Juan Linietsky, Ariel Manzur and Godot Engine contributors). A Godot binary built with `src/godot/` included is distributed under GPL-3.0 as a whole. |
| `MiSTer_CashCowDX` | Built from MiSTer-devel/Main_MiSTer (GPL-3.0) plus `tools/mister-wrapper/overlay/`. The source is that upstream commit (pinned in `tools/mister-wrapper/build-hps.sh`) plus this repository. |

Cash Cow DX and its assets are not part of this repository or its releases.
