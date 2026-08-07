#!/bin/bash
# Render Resources/AppIcon/app-icon.svg → AppIcon.icns via qlmanage + sips + iconutil.
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$PROJ_DIR/Resources/AppIcon"
SVG="$ICON_DIR/app-icon.svg"
ICONSET="$ICON_DIR/AppIcon.iconset"
OUT_ICNS="$ICON_DIR/AppIcon.icns"
MASTER_PNG="$ICON_DIR/app-icon-1024.png"

if [[ ! -f "$SVG" ]]; then
  echo "error: missing $SVG" >&2
  exit 1
fi

echo "🎨 Generating app icon from $(basename "$SVG")..."

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Quick Look → 1024×1024 master PNG (no extra deps; NSImage cannot load SVG here).
qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null
QL_PNG="$TMP/$(basename "$SVG").png"
if [[ ! -f "$QL_PNG" ]]; then
  echo "error: qlmanage failed to produce a thumbnail for $SVG" >&2
  exit 1
fi

# Normalize to exactly 1024×1024 and keep a master for rebuilds.
sips -z 1024 1024 "$QL_PNG" --out "$MASTER_PNG" >/dev/null

# macOS .iconset pixel sizes (filename → edge length)
SIZES=(
  "icon_16x16.png:16"
  "diana.k@example.org:32"
  "icon_32x32.png:32"
  "ivan.p@example.net:64"
  "icon_128x128.png:128"
  "wendy.h@example.net:256"
  "icon_256x256.png:256"
  "wendy.h@example.net:512"
  "icon_512x512.png:512"
  "walt.e@example.net:1024"
)

for pair in "${SIZES[@]}"; do
  name="${pair%%:*}"
  size="${pair##*:}"
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET/$name" >/dev/null
  echo "  $name (${size}px)"
done

echo "📦 Compiling AppIcon.icns..."
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
rm -rf "$ICONSET"
# Drop the accidental qlmanage dump if present from earlier runs.
rm -f "$ICON_DIR/app-icon.svg.png"

echo "✅ Wrote $OUT_ICNS"
