#!/usr/bin/env bash
# Copies the definitive AppIcon.icns. It does not redraw, resample into a new
# squircle, or add a box: the supplied icon already carries its own liquid-glass
# squircle, and wrapping it again made the artwork smaller inside a second frame.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_DIR="${1:-$ROOT_DIR/.build/generated-app-icon}"
SOURCE="$ROOT_DIR/Housekeeping/Resources/AppIcon.icns"
[[ -s "$SOURCE" ]] || { echo "Missing definitive app icon: $SOURCE" >&2; exit 1; }

mkdir -p "$OUT_DIR"
cp "$SOURCE" "$OUT_DIR/AppIcon.icns"
cmp -s "$SOURCE" "$OUT_DIR/AppIcon.icns" || { echo "The icon copy did not match the source." >&2; exit 1; }
echo "Using definitive macOS icon unchanged: $OUT_DIR/AppIcon.icns"
