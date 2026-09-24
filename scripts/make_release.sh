#!/bin/sh
# Assemble the SD-card release bundle.
#   scripts/make_release.sh <engine binary> <tag>
# e.g. scripts/make_release.sh work/build/godot43rc.cortexa9 20260924
# Output: build/release/CashCowDX-MiSTer-<tag>.zip + sha256sums.txt
# Sources: dist/ (launcher, README, override.cfg), src/patches (runtime GDScript
# patches), work/build/fabric_opt/libmisterfabric.so, tools/mem_wc/prebuilt,
# the fabric core RBF and the
# MiSTer_CashCowDX main= wrapper (tools/mister-wrapper/build-hps.sh).
# The patches ship as binary tokens (.gdc): TOK_HOST (default the dev MiSTer)
# runs the release engine once in MISTER_GD_TOKENIZE mode, so the token format
# matches the shipped engine. It needs the game pck at TOK_PCK.
set -e
ENGINE=$1; TAG=$2
[ -f "$ENGINE" ] && [ -n "$TAG" ] || { echo "usage: $0 <engine> <tag>"; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# CashCowDX-branded fabric core: maldita.castilla-mister build-rbf.yml, core_variant=cashcow
# (same RTL as DonutDodo_48k_v224; CORENAME CashCowDX, Cash Cow button labels).
RBF_SRC=${RBF_SRC:?set RBF_SRC to the CashCowDX-branded RBF (CashCowDX_YYYYMMDD.rbf)}
WRAPPER=${WRAPPER:-$ROOT/build/mister-wrapper/MiSTer_CashCowDX}
# A stock Main_MiSTer under this name loads the core and never starts the game.
grep -q /media/fat/games/CashCowDX/launch.sh "$WRAPPER" 2>/dev/null \
	|| { echo "$WRAPPER missing or not the hooked build (run tools/mister-wrapper/build-hps.sh)"; exit 1; }
OUT=$ROOT/build/release/CashCowDX-MiSTer-$TAG
rm -rf "$OUT"; mkdir -p "$OUT/_Other" "$OUT/Scripts" "$OUT/games/CashCowDX/patches"
cp "$ROOT/dist/Scripts/CashCowDX.sh" "$ROOT/dist/Scripts/CashCowDX_CoresMenu.sh" "$OUT/Scripts/"
cp "$ROOT/dist/games/CashCowDX/launch.sh" "$OUT/games/CashCowDX/"
sed 's#/mister_patches\.gd"#/mister_patches.gdc"#' "$ROOT/dist/games/CashCowDX/override.cfg" > "$OUT/games/CashCowDX/override.cfg"
cp "$WRAPPER" "$OUT/games/CashCowDX/MiSTer_CashCowDX"
cp "$ROOT/dist/README.md" "$OUT/games/CashCowDX/README.md"
cp "$ENGINE" "$OUT/games/CashCowDX/cashcowdx"
cp "$ROOT/work/build/fabric_opt/libmisterfabric.so" "$OUT/games/CashCowDX/"
cp "$ROOT"/tools/mem_wc/prebuilt/*.ko "$OUT/games/CashCowDX/"
TOK_HOST=${TOK_HOST:-root@192.168.20.81}
TOK_PCK=${TOK_PCK:-/media/fat/games/CashCowDX/CashCowDX.pck}
ssh "$TOK_HOST" 'rm -rf /tmp/cc_tok && mkdir -p /tmp/cc_tok/in /tmp/cc_tok/out'
scp -q "$ROOT"/src/patches/*.gd "$TOK_HOST:/tmp/cc_tok/in/"
scp -q "$ENGINE" "$TOK_HOST:/tmp/cc_tok/engine"
ssh "$TOK_HOST" "cd /tmp/cc_tok && chmod +x engine && MISTER_GD_TOKENIZE=/tmp/cc_tok/in:/tmp/cc_tok/out ./engine --headless --main-pack $TOK_PCK" | grep MISTER_GD_TOKENIZE
scp -q "$TOK_HOST:/tmp/cc_tok/out/*.gdc" "$OUT/games/CashCowDX/patches/"
ssh "$TOK_HOST" 'rm -rf /tmp/cc_tok'
n_gd=$(ls "$ROOT"/src/patches/*.gd | wc -l); n_gdc=$(ls "$OUT"/games/CashCowDX/patches/*.gdc | wc -l)
[ "$n_gd" -eq "$n_gdc" ] || { echo "tokenized $n_gdc of $n_gd patches"; exit 1; }
cp "$RBF_SRC" "$OUT/_Other/CashCowDX_$(basename "$RBF_SRC" .rbf | grep -oE '[0-9]{8}$').rbf"
chmod +x "$OUT/Scripts/CashCowDX.sh" "$OUT/Scripts/CashCowDX_CoresMenu.sh" "$OUT/games/CashCowDX/launch.sh" \
	"$OUT/games/CashCowDX/MiSTer_CashCowDX" "$OUT/games/CashCowDX/cashcowdx"
# Checksums live inside the game folder: extracting over /media/fat must not
# drop files into the SD root.
( cd "$OUT" && find . -type f ! -name sha256sums.txt | sort | xargs shasum -a 256 > games/CashCowDX/sha256sums.txt )
( cd "$OUT" && rm -f "../CashCowDX-MiSTer-$TAG.zip" && zip -qr "../CashCowDX-MiSTer-$TAG.zip" . )
ls -la "$ROOT/build/release/CashCowDX-MiSTer-$TAG.zip"
