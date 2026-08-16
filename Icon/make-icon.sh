#!/bin/bash
# Regenerate AppIcon.icns from render-icon.swift. Run this if the mark changes;
# build.sh just copies the committed AppIcon.icns into the bundle.
set -euo pipefail
cd "$(dirname "$0")"

MASTER=/tmp/SpeakyIcon-1024.png
swift render-icon.swift "$MASTER"

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for px in 16 32 128 256 512; do
  sips -z "$px" "$px"       "$MASTER" --out "$SET/icon_${px}x${px}.png"      >/dev/null
  sips -z $((px*2)) $((px*2)) "$MASTER" --out "$SET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "wrote $(pwd)/AppIcon.icns"
