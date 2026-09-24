#!/bin/sh
# Assemble the SD-card release bundle.
#   scripts/make_release.sh <engine binary> <tag>
# e.g. scripts/make_release.sh work/build/godot43rc.cortexa9 20260924
# Output: build/release/CashCowDX-MiSTer-<tag>.zip + sha256sums.txt
# Sources: dist/ (launcher, README, override.cfg), src/patches (runtime GDScript
# patches), work/build/fabric_opt/libmisterfabric.so, tools/mem_wc/prebuilt,
# the fabric core RBF and Mesa runtime (fetched from the paths below).
set -e
ENGINE=$1; TAG=$2
[ -f "$ENGINE" ] && [ -n "$TAG" ] || { echo "usage: $0 <engine> <tag>"; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RBF_SRC=${RBF_SRC:-$ROOT/../donut.dodo-mister/_Other/DonutDodo_48k_v224_20260922.rbf}
MESA_SRC=${MESA_SRC:-root@192.168.20.81:/media/fat/games/gmloader/mesa}
OUT=$ROOT/build/release/CashCowDX-MiSTer-$TAG
rm -rf "$OUT"; mkdir -p "$OUT/_Other" "$OUT/Scripts" "$OUT/games/CashCowDX/patches" "$OUT/games/CashCowDX/mesa"
cp "$ROOT/dist/README.md" "$OUT/"
cp "$ROOT/dist/Scripts/CashCowDX.sh" "$OUT/Scripts/"
cp "$ROOT/dist/games/CashCowDX/launch.sh" "$ROOT/dist/games/CashCowDX/override.cfg" "$OUT/games/CashCowDX/"
cp "$ROOT/dist/README.md" "$OUT/games/CashCowDX/README.md"
cp "$ENGINE" "$OUT/games/CashCowDX/cashcowdx"
cp "$ROOT/work/build/fabric_opt/libmisterfabric.so" "$OUT/games/CashCowDX/"
cp "$ROOT"/tools/mem_wc/prebuilt/*.ko "$OUT/games/CashCowDX/"
for f in "$ROOT"/src/patches/*.gd; do cp "$f" "$OUT/games/CashCowDX/patches/"; done
cp "$RBF_SRC" "$OUT/_Other/CashCowDX_$(basename "$RBF_SRC" .rbf | grep -oE '[0-9]{8}$').rbf"
case "$MESA_SRC" in *:*) scp -q "$MESA_SRC/*" "$OUT/games/CashCowDX/mesa/" ;; *) cp "$MESA_SRC"/* "$OUT/games/CashCowDX/mesa/" ;; esac
chmod +x "$OUT/Scripts/CashCowDX.sh" "$OUT/games/CashCowDX/launch.sh" "$OUT/games/CashCowDX/cashcowdx"
( cd "$OUT" && find . -type f ! -name sha256sums.txt | sort | xargs shasum -a 256 > sha256sums.txt )
( cd "$OUT" && rm -f "../CashCowDX-MiSTer-$TAG.zip" && zip -qr "../CashCowDX-MiSTer-$TAG.zip" . )
ls -la "$ROOT/build/release/CashCowDX-MiSTer-$TAG.zip"
