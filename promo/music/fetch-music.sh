#!/usr/bin/env bash
# Fetches the music track with yt-dlp into promo/film/public/music (not committed).
# "Advertime" from FreePD (freepd.com, now offline; mirrored at a.ocv.me), licensed CC0 1.0 Universal:
# free for commercial use, no attribution required.
# Usage: promo/music/fetch-music.sh
set -euo pipefail
out="$(cd "$(dirname "$0")/../film/public" && pwd)/music"
mkdir -p "$out"
uvx yt-dlp --quiet --no-warnings --retries 3 --force-overwrites -o "$out/advertime.%(ext)s" \
  "https://a.ocv.me/pub/stuff/music/freepd/upbeat/Advertime.mp3"
