#!/usr/bin/env bash
# Renders the laptop hero shot into promo/film/public/laptop as WebP frames (not committed).
# The frame count is the "meet" scene length from the film's timeline (promo/film/scripts/laptop-frames.ts), so
# re-run this after regenerating the voiceover. Needs `npm ci` in promo/film and Node 22.18+ (built-in TypeScript).
# Frames are rendered into a staging directory and replace public/laptop only after Blender succeeds.
# Usage: promo/blender/render.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
film="$(cd "$here/../film" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$film/public/laptop"
blender="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

frames="$(cd "$film" && node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/laptop-frames.ts)"
if ! [[ "$frames" =~ ^[1-9][0-9]*$ ]]; then
  echo "render.sh: expected a frame count from scripts/laptop-frames.ts, got: '$frames'" >&2
  exit 1
fi

staging="$(mktemp -d "$film/.laptop-staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

"$blender" --background --factory-startup --python-exit-code 1 --python "$here/laptop.py" -- \
  "$repo/web/src/assets/screenshots/home.webp" "$staging" "$frames"

rendered="$(find "$staging" -maxdepth 1 -name '*.webp' | wc -l | tr -d ' ')"
if [[ "$rendered" != "$frames" ]]; then
  echo "render.sh: Blender wrote $rendered of $frames frames into $staging; keeping the previous $out" >&2
  exit 1
fi

rm -rf "$out"
mv "$staging" "$out"
echo "render.sh: $frames laptop frames in $out"
