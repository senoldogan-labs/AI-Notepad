#!/usr/bin/env bash
# Renders the Mac + iPhone + Apple Watch still (devices.py) and writes the site's copies as WebP into
# web/src/assets/devices (Astro makes the AVIF/WebP sizes at build). The PNGs stay in <png-dir> (e.g. for launch posts).
# Screens: the Mac note and iPhone home captures the site already uses, and the Watch app's "iPhone is recording" screen
# (screens/watch-iphone-recording.png, from WatchScreensUITests with TEST_RUNNER_WATCH_SHOTS_DIR).
# Needs Blender 5.x and cwebp (`brew install webp`). Cycles on the CPU, several minutes per image; runs under nice.
# Usage: promo/blender/devices.sh <png-dir>
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: promo/blender/devices.sh <png-dir>" >&2
  exit 1
fi
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
blender="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
png_dir="$1"
mkdir -p "$png_dir"
shots="$repo/web/src/assets/screenshots"

nice -n 19 "$blender" --background --factory-startup --python-exit-code 1 --python "$here/devices.py" -- \
  "$shots/note-dark.webp" "$shots/iphone-home.webp" "$here/screens/watch-iphone-recording.png" "$png_dir" 128 100

for name in devices-wide devices-portrait; do
  cwebp -quiet -q 92 -m 6 "$png_dir/$name.png" -o "$repo/web/src/assets/devices/$name.webp"
done
echo "devices.sh: PNGs in $png_dir, WebP in web/src/assets/devices"
