#!/bin/sh
# Inter Variable'ı site için küçültür: ağırlık ekseni sitenin kullandığı 400–700 aralığına daraltılır, optik boyut ekseni
# gövde metninin boyutuna (16) sabitlenir (sitede Inter yalnızca metin ve arayüz boyutlarında; başlıklar Newsreader; tam
# eksen aralığı dosyaya ~17 KB ekliyordu), harfler yalnızca
# Latin, Latin Genişletilmiş-A (Türkçe ve Fince harfler), noktalama ve sitede geçen birkaç simge (oklar, çeviri
# satırlarının ↳ işareti, ✓). Böylece dosya ~77 KB'tan ~38 KB'a iner (mobil ilk boyamanın önündeki en büyük istek).
# Çıktı repoya girer, derleme bunu çalıştırmaz.
# Gerekenler: fonttools ve brotli, ör. `uv run --no-project --with fonttools --with brotli sh scripts/subset-font.sh`.
# Kullanım: scripts/subset-font.sh
set -eu

web_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fonttools varLib.instancer "$web_dir/../App/Fonts/InterVariable.ttf" wght=400:700 opsz=16 -o "$work_dir/Inter-text.ttf" -q
pyftsubset "$work_dir/Inter-text.ttf" \
  --output-file="$web_dir/public/fonts/InterVariable-latin.woff2" \
  --flavor=woff2 \
  --unicodes="U+0000-00FF,U+0100-017F,U+0131,U+0152-0153,U+02C6,U+02DA,U+02DC,U+2000-206F,U+20AC,U+20BA,U+2122,U+2190-2193,U+21B3,U+2212,U+2215,U+2713" \
  --layout-features+="tnum,case,cv11,ss03" \
  --no-hinting \
  --desubroutinize

echo "Yazıldı: $web_dir/public/fonts/InterVariable-latin.woff2"
