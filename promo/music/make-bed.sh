#!/usr/bin/env bash
# Synthesises the promo's music bed with FFmpeg only (no samples, nothing to license):
# a warm detuned pad plus a soft plucked arpeggio over Cmaj9 – Am9 – Fmaj9 – G6/9, played twice (48 s).
# Usage: promo/music/make-bed.sh <output.wav>
set -euo pipefail

out="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

chord_seconds=6
# Five pad notes and four arpeggio notes per chord (Hz).
chords=(
  "130.81 196.00 246.94 329.63 587.33|523.25 659.26 783.99 987.77"
  "110.00 164.81 196.00 261.63 493.88|440.00 523.25 659.26 783.99"
  "87.31 130.81 164.81 220.00 392.00|349.23 440.00 523.25 659.26"
  "98.00 146.83 220.00 246.94 329.63|392.00 493.88 587.33 659.26"
)

pad_expr() {
  local terms=() f
  for f in $1; do
    terms+=("sin(2*PI*$f*t)+sin(2*PI*($f+0.7)*t+1.3)")
  done
  local IFS=+
  echo "0.022*(${terms[*]})"
}

arp_expr() {
  read -r a b c d <<<"$1"
  # Eighth notes at 100 bpm (0.3 s): a b c d c b a b …, each a sine pluck with a fast exponential decay.
  local step="mod(floor(t/0.3),8)"
  local freq="if(eq($step,0),$a,if(eq($step,1),$b,if(eq($step,2),$c,if(eq($step,3),$d,if(eq($step,4),$c,if(eq($step,5),$b,if(eq($step,6),$a,$b)))))))"
  echo "0.05*sin(2*PI*$freq*t)*exp(-7*mod(t,0.3))"
}

index=0
for round in 1 2; do
  for chord in "${chords[@]}"; do
    pad="${chord%%|*}"
    arp="${chord##*|}"
    ffmpeg -v error -y -f lavfi \
      -i "aevalsrc=exprs='$(pad_expr "$pad")+$(arp_expr "$arp")':s=48000:d=$chord_seconds" \
      -af "afade=t=in:d=0.6,afade=t=out:st=$((chord_seconds - 1)):d=1" \
      "$work/$(printf %02d $index).wav"
    index=$((index + 1))
  done
done

inputs=()
for file in "$work"/*.wav; do inputs+=(-i "$file"); done
count=${#inputs[@]}
count=$((count / 2))
filter=""
previous="[0:a]"
for ((i = 1; i < count; i++)); do
  filter+="${previous}[$i:a]acrossfade=d=0.9:c1=tri:c2=tri[x$i];"
  previous="[x$i]"
done
filter+="${previous}lowpass=f=5200,aecho=0.8:0.6:120|260:0.35|0.22,highpass=f=60,loudnorm=I=-20:TP=-2,aformat=channel_layouts=stereo[out]"

ffmpeg -v error -y "${inputs[@]}" -filter_complex "$filter" -map "[out]" -ar 48000 "$out"
