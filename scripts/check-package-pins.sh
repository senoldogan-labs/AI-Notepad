#!/bin/bash
# Uygulamanın paket sabitleri (Config/Package.resolved) bildirimlerle tutarlı mı: project.yml'deki her uzak paket
# (Sparkle, RevenueCat) aynı adres ve exactVersion ile sabitlenmiş olmalı; çekirdek paketin sabitleri
# (Packages/AINotepadCore/Package.resolved: WhisperKit ve bağımlılıkları) aynı sürüm ve işlemeyle burada da olmalı;
# fazladan sabit ya da 40 haneli olmayan işleme kimliği olmamalı. Ağa çıkmaz. Tutarsızlıkta hepsini yazar, 1 ile çıkar.
#
# Kullanım: scripts/check-package-pins.sh
# Yayın betikleri (scripts/release-common.sh `generate_pinned_project`) projeyi üretmeden önce bunu çalıştırır.
set -euo pipefail
cd "$(dirname "$0")/.."

app_pins="Config/Package.resolved"
core_pins="Packages/AINotepadCore/Package.resolved"
project_spec="project.yml"

# Package.resolved'daki sabitler, satır başına "<adres> <sürüm> <işleme>".
pin_lines() {
    local file="$1"
    local count
    local index
    count="$(plutil -extract pins raw -o - "$file")"
    for ((index = 0; index < count; index++)); do
        printf '%s %s %s\n' \
            "$(plutil -extract "pins.$index.location" raw -o - "$file")" \
            "$(plutil -extract "pins.$index.state.version" raw -o - "$file")" \
            "$(plutil -extract "pins.$index.state.revision" raw -o - "$file")"
    done
}

# project.yml `packages:` bölümündeki uzak paketler, satır başına "<adres> <exactVersion>"; exactVersion'sız uzak
# paket "<adres> -" olarak çıkar (sürüm aralığı ya da dal sabitlenemez).
declared_remote_packages() {
    local spec="$1"
    awk '
        /^packages:/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { inside = 0 }
        !inside { next }
        /^  [^[:space:]#][^:]*:[[:space:]]*$/ { if (url != "") print url, (version == "" ? "-" : version); url = ""; version = "" }
        /^    url:/ { url = $2 }
        /^    exactVersion:/ { version = $2; gsub(/"/, "", version) }
        END { if (url != "") print url, (version == "" ? "-" : version) }
    ' "$spec"
}

errors=0
fail() {
    echo "$1" >&2
    errors=$((errors + 1))
}

app="$(pin_lines "$app_pins")"
core="$(pin_lines "$core_pins")"
declared="$(declared_remote_packages "$project_spec")"
# Bildirilen (project.yml) ve çekirdek paketin sabitlediği adresler.
known="$declared"$'\n'"$core"
[[ -n "$declared" ]] || fail "$project_spec'te uzak paket bulunamadı (packages: bölümü okunamadı)."

while read -r location version revision; do
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "$app_pins: $location işlemesi 40 haneli değil: '$revision'."
done <<< "$app"

while read -r url version; do
    [[ "$version" != "-" ]] || { fail "$project_spec: $url exactVersion ile sabitlenmemiş."; continue; }
    match="$(awk -v url="$url" '$1 == url { print $2 }' <<< "$app")"
    [[ -n "$match" ]] || { fail "$app_pins'ta $url sabiti yok ($project_spec: $version)."; continue; }
    [[ "$match" == "$version" ]] || fail "$app_pins: $url sürümü $match, $project_spec exactVersion $version."
done <<< "$declared"

while read -r line; do
    grep -qxF "$line" <<< "$app" || fail "$core_pins sabiti $app_pins'ta aynı değil: $line"
done <<< "$core"

while read -r location version revision; do
    awk -v url="$location" '$1 == url { found = 1 } END { exit !found }' <<< "$known" ||
        fail "$app_pins'taki $location sabiti ne $project_spec'te ne $core_pins'ta var."
done <<< "$app"

if ((errors > 0)); then
    echo "$errors tutarsızlık. Güncelleme adımları: AGENTS.md, \"Paket sabitleri\"." >&2
    exit 1
fi
echo "Paket sabitleri tutarlı: $(wc -l <<< "$app" | tr -d '[:space:]') paket ($app_pins)."
