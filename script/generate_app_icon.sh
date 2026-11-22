#!/usr/bin/env bash
# Build the macOS AppIcon.icns directly from the definitive hardcoded AppIcon.png.
# Never procedurally redraws or substitutes another icon.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="${1:-$ROOT_DIR/.build/generated-app-icon}"
ICON_MASTER="$ROOT_DIR/Housekeeping/Resources/AppIcon.png"
[[ -f "$ICON_MASTER" ]] || { echo "Missing definitive app icon: $ICON_MASTER" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "macOS iconutil is required." >&2; exit 1; }
command -v sips >/dev/null || { echo "macOS sips is required." >&2; exit 1; }

mkdir -p "$OUT_DIR"
ICONSET="$OUT_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Normalize master to 1024x1024 PNG for iconset generation
sips -s format png -z 1024 1024 "$ICON_MASTER" --out "$OUT_DIR/AppIcon-1024.png" >/dev/null

for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$OUT_DIR/AppIcon-1024.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    twice=$((size * 2))
    sips -s format png -z "$twice" "$twice" "$OUT_DIR/AppIcon-1024.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
[[ -s "$OUT_DIR/AppIcon.icns" ]] || { echo "Icon generation failed." >&2; exit 1; }
echo "Built definitive macOS icon: $OUT_DIR/AppIcon.icns (from Housekeeping/Resources/AppIcon.png)"
