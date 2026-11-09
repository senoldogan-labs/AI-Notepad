#!/usr/bin/env bash
# Gistsmith Klavye'nin mekanik seslerini ElevenLabs Sound Effects ile üretir (İSTEĞE BAĞLI; sahibin onayıyla).
#
# Şu an pakette `scripts/make-keyboard-sounds.py`'nin sentezlediği sesler var (lisans meselesi yok). Bu betik daha
# gerçekçi bir paket için hazırdır ama ÜCRETLİDİR: ElevenLabs API'sinde ses efekti dakikası $0.12 (2026-11 kamuya açık
# fiyat); 4 ses × 0,5 sn ≈ $0.004 ve her deneme ayrıca ücretlenir. Ticari kullanım yalnız ücretli planda üretilen
# seslerde var (ücretsiz planda atıf gerekir) — çalıştırmadan önce güncel Service-Specific Terms'ü doğrula.
#
# Kullanım: ELEVENLABS_API_KEY=… scripts/elevenlabs-keyboard-sounds.sh <çıktı klasörü>
# Sonra her dosyayı dinle, beğenilenleri `afconvert -f caff -d LEI16 <mp3> iOSKeyboard/Sounds/<ad>.caf` ile çevir.
set -euo pipefail

out="${1:?usage: elevenlabs-keyboard-sounds.sh <output folder>}"
: "${ELEVENLABS_API_KEY:?set ELEVENLABS_API_KEY}"
mkdir -p "$out"

generate() {
    local name="$1" prompt="$2"
    curl -sSf -X POST "https://api.elevenlabs.io/v1/sound-generation" \
        -H "xi-api-key: ${ELEVENLABS_API_KEY}" -H "Content-Type: application/json" \
        -d "$(printf '{"text":"%s","duration_seconds":0.5,"prompt_influence":0.6}' "$prompt")" \
        -o "$out/$name.mp3"
    echo "$out/$name.mp3"
}

generate key "Single keypress on a mechanical keyboard with tactile brown switches, short crisp click and soft thock, close microphone, dry, no room reverb, no background noise"
generate space "Single press of a wide mechanical keyboard spacebar, deeper thock with a slight stabilizer rattle, close microphone, dry, no background noise"
generate return "Single press of a mechanical keyboard enter key, firm medium-pitched clack, close microphone, dry, no background noise"
generate delete "Single press of a mechanical keyboard backspace key, light quick click, close microphone, dry, no background noise"
