#!/usr/bin/env bash
# Downloads the music track into promo/film/public/music (not committed).
# "Advertime" from FreePD (freepd.com, now offline; mirrored at a.ocv.me), licensed CC0 1.0 Universal:
# free for commercial use, no attribution required.
# Usage: promo/music/fetch-music.sh
set -euo pipefail
out="$(cd "$(dirname "$0")/../film/public" && pwd)/music"
mkdir -p "$out"
curl -sfL --retry 3 -o "$out/advertime.mp3" "https://a.ocv.me/pub/stuff/music/freepd/upbeat/Advertime.mp3"
