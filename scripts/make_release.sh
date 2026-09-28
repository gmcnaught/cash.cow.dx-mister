#!/bin/sh
# Assemble the SD-card release bundle.
#   scripts/make_release.sh <engine binary> <tag>
# e.g. scripts/make_release.sh work/build/godot43rc.cortexa9 20260924
# Output: build/release/CashCowDX-MiSTer-<tag>.zip + sha256sums.txt
# Sources: mister-port.toml rendered by external/mister-hybrid-platform (launcher,
# platform/ with its MiSTer_hybrid main= hook and hybrid.d registry entry, Scripts
# entries, MGL, mem_wc modules), dist/ (README, override.cfg), src/patches
# (runtime GDScript patches), libmisterfabric.so (FABRIC_LIB, default
# work/build/fabric_opt/libmisterfabric.so) and the
# fabric core RBF.
# The patches ship as binary tokens (.gdc): TOK_HOST (default the dev MiSTer)
# runs the release engine once in MISTER_GD_TOKENIZE mode, so the token format
# matches the shipped engine. It needs the game pck at TOK_PCK. TOK_GDC=<dir>
# instead copies .gdc files tokenized earlier by the same engine (no device).
# The zip must install only under games/, Scripts/ and _Other/: the Downloader
# rejects linux/, screenshots/, savestates/ and downloader/ for any database but
# distribution_mister (platform README, "Install paths").
set -e
ENGINE=$1; TAG=$2
[ -f "$ENGINE" ] && [ -n "$TAG" ] || { echo "usage: $0 <engine> <tag>"; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# CashCowDX-branded fabric core: maldita.castilla-mister build-rbf.yml, core_variant=cashcow
# (same RTL as DonutDodo_48k_v224; CORENAME CashCowDX, Cash Cow button labels).
RBF_SRC=${RBF_SRC:?set RBF_SRC to the CashCowDX-branded RBF (CashCowDX_YYYYMMDD.rbf)}
PLAT=$ROOT/external/mister-hybrid-platform
# MiSTer_hybrid: the platform CI artifact, or $PLAT/device/main-hook/build-hps.sh.
HOOK_BIN=${HOOK_BIN:-$PLAT/build/main-hook/MiSTer_hybrid}
# A stock Main_MiSTer under this name loads the core and never starts the game.
# v0.4.0+ hook: reads hybrid.d/ next to its own executable (not linux/hybrid.d).
grep -q 'MiSTer_hybrid registry: <binary dir>/hybrid.d' "$HOOK_BIN" 2>/dev/null \
	|| { echo "$HOOK_BIN missing or not the hooked build (run $PLAT/device/main-hook/build-hps.sh)"; exit 1; }
OUT=$ROOT/build/release/CashCowDX-MiSTer-$TAG
rm -rf "$OUT"; mkdir -p "$OUT/_Other" "$OUT/games/CashCowDX/patches"
python3 "$PLAT/tools/mister_platform.py" render "$ROOT/mister-port.toml" --out "$OUT" --hook-binary "$HOOK_BIN"
sed 's#/mister_patches\.gd"#/mister_patches.gdc"#' "$ROOT/dist/games/CashCowDX/override.cfg" > "$OUT/games/CashCowDX/override.cfg"
cp "$ROOT/dist/README.md" "$OUT/games/CashCowDX/README.md"
cp "$ENGINE" "$OUT/games/CashCowDX/cashcowdx"
cp "${FABRIC_LIB:-$ROOT/work/build/fabric_opt/libmisterfabric.so}" "$OUT/games/CashCowDX/"
if [ -n "$TOK_GDC" ]; then
	for f in "$ROOT"/src/patches/*.gd; do
		cp "$TOK_GDC/$(basename "$f" .gd).gdc" "$OUT/games/CashCowDX/patches/"
	done
else
	TOK_HOST=${TOK_HOST:-root@192.168.20.81}
	TOK_PCK=${TOK_PCK:-/media/fat/games/CashCowDX/CashCowDX.pck}
	ssh "$TOK_HOST" 'rm -rf /tmp/cc_tok && mkdir -p /tmp/cc_tok/in /tmp/cc_tok/out'
	scp -q "$ROOT"/src/patches/*.gd "$TOK_HOST:/tmp/cc_tok/in/"
	scp -q "$ENGINE" "$TOK_HOST:/tmp/cc_tok/engine"
	ssh "$TOK_HOST" "cd /tmp/cc_tok && chmod +x engine && MISTER_GD_TOKENIZE=/tmp/cc_tok/in:/tmp/cc_tok/out ./engine --headless --main-pack $TOK_PCK" | grep MISTER_GD_TOKENIZE
	scp -q "$TOK_HOST:/tmp/cc_tok/out/*.gdc" "$OUT/games/CashCowDX/patches/"
	ssh "$TOK_HOST" 'rm -rf /tmp/cc_tok'
fi
n_gd=$(ls "$ROOT"/src/patches/*.gd | wc -l); n_gdc=$(ls "$OUT"/games/CashCowDX/patches/*.gdc | wc -l)
[ "$n_gd" -eq "$n_gdc" ] || { echo "tokenized $n_gdc of $n_gd patches"; exit 1; }
cp "$RBF_SRC" "$OUT/_Other/CashCowDX_$(basename "$RBF_SRC" .rbf | grep -oE '[0-9]{8}$').rbf"
chmod +x "$OUT/games/CashCowDX/cashcowdx"
# Checksums live inside the game folder: extracting over /media/fat must not
# drop files into the SD root.
( cd "$OUT" && find . -type f ! -name sha256sums.txt | sort | xargs shasum -a 256 > games/CashCowDX/sha256sums.txt )
( cd "$OUT" && rm -f "../CashCowDX-MiSTer-$TAG.zip" && zip -qr "../CashCowDX-MiSTer-$TAG.zip" . )
ZIP=$ROOT/build/release/CashCowDX-MiSTer-$TAG.zip
members=$(unzip -Z1 "$ZIP")
bad=$(printf '%s\n' "$members" | grep -vE '^((games/CashCowDX|Scripts|_Other)/|games/$)' || true)
[ -z "$bad" ] || { echo "zip installs outside games/CashCowDX, Scripts, _Other:"; echo "$bad"; exit 1; }
for m in games/CashCowDX/platform/MiSTer_hybrid games/CashCowDX/platform/hybrid.d/CashCowDX.conf \
	Scripts/CashCowDX.sh Scripts/CashCowDX_CoresMenu.sh games/CashCowDX/launch.sh; do
	printf '%s\n' "$members" | grep -qx "$m" || { echo "zip is missing $m"; exit 1; }
done
ls -la "$ROOT/build/release/CashCowDX-MiSTer-$TAG.zip"
