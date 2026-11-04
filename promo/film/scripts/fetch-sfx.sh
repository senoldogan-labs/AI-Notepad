#!/usr/bin/env bash
# Downloads the sound effects the film uses from Remotion's public SFX library into public/sfx (not committed).
set -euo pipefail
cd "$(dirname "$0")/../public"
mkdir -p sfx
for name in whoosh mouse-click; do
  curl -sfL --retry 3 -o "sfx/$name.wav" "https://remotion.media/$name.wav"
done
