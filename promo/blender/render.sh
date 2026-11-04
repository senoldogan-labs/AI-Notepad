#!/usr/bin/env bash
# Renders the laptop hero shot into promo/film/public/laptop as WebP frames (not committed).
# Usage: promo/blender/render.sh <frames>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/promo/film/public/laptop"
blender="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
rm -rf "$out" && mkdir -p "$out"
"$blender" --background --factory-startup --python "$here/laptop.py" -- \
  "$repo/web/src/assets/screenshots/home.webp" "$out" "$1"
