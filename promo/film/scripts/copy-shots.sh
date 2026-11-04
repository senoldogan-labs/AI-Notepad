#!/usr/bin/env bash
# Copies the app screenshots the film shows from the website's assets into public/shots (not committed), so the film
# and gistsmith.com always show the same screens.
set -euo pipefail
cd "$(dirname "$0")/../public"
mkdir -p shots
for name in home live note ask; do
  cp "../../../web/src/assets/screenshots/$name.webp" "shots/$name.webp"
done
