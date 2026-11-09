#!/usr/bin/env python3
"""Gistsmith Klavye'nin mekanik klavye seslerini sentezler (lisans meselesi yok: sesler burada üretilir).

Her ses kısa bir tıklama (yüksek frekanslı gürültü patlaması, "click") ve gövdenin rezonansından (sönümlenen alçak
tonlar, "thock") oluşur. Rastgelelik sabit tohumludur: dosyalar her çalıştırmada aynı çıkar.

Kullanım: python3 -I scripts/make-keyboard-sounds.py iOSKeyboard/Sounds
Çıktı: key.caf, space.caf, return.caf, delete.caf (16-bit, 44.1 kHz, tek kanal; `afconvert` ile CAF).
"""

import math
import random
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

SAMPLE_RATE: int = 44_100


def synthesize(seed: int, duration: float, click_level: float, body_hz: tuple[float, ...], body_decay: float, gain: float) -> list[float]:
    """Tıklama + rezonans; değerler -1…1."""
    rng: random.Random = random.Random(seed)
    count: int = int(SAMPLE_RATE * duration)
    samples: list[float] = []
    previous: float = 0.0
    for index in range(count):
        t: float = index / SAMPLE_RATE
        # Tıklama: ilk ~4 ms'de hızla sönen, yüksek geçirgen (fark) gürültü.
        noise: float = rng.uniform(-1.0, 1.0)
        high: float = noise - previous
        previous = noise
        click: float = click_level * high * math.exp(-t / 0.0012)
        # Gövde: birkaç alçak tonun sönümlenen toplamı; hafif saldırı yumuşatması.
        attack: float = min(1.0, t / 0.0008)
        body: float = sum(math.sin(2 * math.pi * hz * t + k) for k, hz in enumerate(body_hz)) / len(body_hz)
        samples.append(gain * (click + attack * 0.6 * body * math.exp(-t / body_decay)))
    peak: float = max(abs(value) for value in samples) or 1.0
    return [value / peak * gain for value in samples]


SOUNDS: dict[str, dict[str, object]] = {
    "key": {"seed": 1, "duration": 0.07, "click_level": 1.0, "body_hz": (310.0, 520.0, 1180.0), "body_decay": 0.012, "gain": 0.55},
    "space": {"seed": 2, "duration": 0.11, "click_level": 0.7, "body_hz": (180.0, 260.0, 640.0), "body_decay": 0.022, "gain": 0.6},
    "return": {"seed": 3, "duration": 0.10, "click_level": 0.8, "body_hz": (220.0, 330.0, 900.0), "body_decay": 0.018, "gain": 0.6},
    "delete": {"seed": 4, "duration": 0.08, "click_level": 0.9, "body_hz": (260.0, 420.0, 980.0), "body_decay": 0.014, "gain": 0.5},
}


def write_wav(path: Path, samples: list[float]) -> None:
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value)) * 32_000)) for value in samples))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make-keyboard-sounds.py <output folder>")
    out: Path = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        for name, settings in SOUNDS.items():
            wav: Path = Path(temporary) / f"{name}.wav"
            write_wav(
                wav,
                synthesize(
                    seed=int(settings["seed"]),  # type: ignore[arg-type]  # tablo değerleri karışık türde
                    duration=float(settings["duration"]),  # type: ignore[arg-type]
                    click_level=float(settings["click_level"]),  # type: ignore[arg-type]
                    body_hz=tuple(settings["body_hz"]),  # type: ignore[arg-type]
                    body_decay=float(settings["body_decay"]),  # type: ignore[arg-type]
                    gain=float(settings["gain"]),  # type: ignore[arg-type]
                ),
            )
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", str(wav), str(out / f"{name}.caf")], check=True)
            print(f"{name}.caf")


if __name__ == "__main__":
    main()
