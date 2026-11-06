#!/bin/sh
# Cuts Newsreader (Production Type, SIL OFL 1.1) down to the single static face the site uses for headings: weight 400,
# optical size 48 (display), Latin + Latin Extended-A (Turkish and Finnish letters), punctuation and arrows. The output
# is committed; the build does not run this.
# Source: https://github.com/google/fonts/raw/main/ofl/newsreader/Newsreader%5Bopsz,wght%5D.ttf (licence: OFL.txt in
# the same folder, copied to public/fonts/Newsreader-OFL.txt).
# Needs fonttools and brotli, e.g. `uv run --no-project --with fonttools --with brotli sh scripts/subset-serif.sh …`.
# Usage: scripts/subset-serif.sh "<path to Newsreader[opsz,wght].ttf>"
set -eu

source_ttf="$1"
web_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fonttools varLib.instancer "$source_ttf" wght=400 opsz=48 -o "$work_dir/Newsreader-display.ttf"
pyftsubset "$work_dir/Newsreader-display.ttf" \
  --output-file="$web_dir/public/fonts/Newsreader-display-latin.woff2" \
  --flavor=woff2 \
  --unicodes="U+0020-007E,U+00A0-00FF,U+0100-017F,U+0131,U+2010-2027,U+2030-203A,U+20AC,U+2122,U+2190-2193,U+2212" \
  --layout-features="kern,liga,lnum,tnum,case" \
  --no-hinting \
  --desubroutinize

echo "Wrote: $web_dir/public/fonts/Newsreader-display-latin.woff2"
