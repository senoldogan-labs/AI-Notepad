"""Generate the promo voiceover with Chatterbox, one WAV per line, and check each take with faster-whisper.

Usage: uv run python speak.py <output-dir>

Each line is generated with increasing seeds until faster-whisper reads back the same words, so a take with a
skipped or invented word never reaches the film. Writes `<NN>.wav` per line plus `manifest.json` (line id, text,
duration in seconds) that the Remotion project imports to size its scenes.
"""

import json
import re
import sys
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from pathlib import Path

import torch
import torchaudio
from chatterbox.tts import ChatterboxTTS
from faster_whisper import WhisperModel

LINES: list[tuple[str, str]] = [
    ("hook", "Every meeting ends the same way."),
    ("question", "Who said what? And what was I supposed to do?"),
    ("meet", "Meet Gistsmith. The meeting notepad for your Mac."),
    ("listens", "It listens to Zoom, Teams, Meet, or the room you're in. No bot joins the call."),
    ("live", "Every sentence appears live. Translated, if you like."),
    ("note", "When you hang up, your note is ready. Your tasks come first."),
    ("ask", "Later, just ask. Answers come from every meeting you've had."),
    ("cta", "Gistsmith. Your meetings, written for you. Try it free at gistsmith dot com."),
]
MAX_ATTEMPTS = 6
MIN_WORD_MATCH = 0.9


@dataclass(frozen=True)
class Take:
    id: str
    text: str
    file: str
    seconds: float


class TakeMismatchError(RuntimeError):
    """Raised when no take of a line was read back with the intended words."""


def normalize_words(text: str) -> list[str]:
    spoken = text.lower().replace(".com", " dot com").replace("gistsmith", "gist smith")
    return re.sub(r"[^a-z0-9' ]", " ", spoken).split()


def words_match(expected: str, heard: str) -> bool:
    """True when the heard words are close enough (whisper may spell the brand name differently)."""
    ratio = SequenceMatcher(a=normalize_words(expected), b=normalize_words(heard)).ratio()
    return ratio >= MIN_WORD_MATCH


def transcribe(whisper: WhisperModel, path: Path) -> str:
    segments, _info = whisper.transcribe(str(path), language="en", beam_size=5)
    return " ".join(segment.text.strip() for segment in segments)


def generate_take(tts: ChatterboxTTS, whisper: WhisperModel, line_id: str, text: str, out: Path) -> Take:
    heard_attempts: list[str] = []
    for seed in range(MAX_ATTEMPTS):
        torch.manual_seed(seed)
        wav: torch.Tensor = tts.generate(text, exaggeration=0.55, cfg_weight=0.45, temperature=0.7)
        torchaudio.save(str(out), wav, tts.sr)
        heard = transcribe(whisper, out)
        heard_attempts.append(heard)
        if words_match(text, heard):
            seconds = wav.shape[1] / tts.sr
            print(json.dumps({"event": "take_ok", "id": line_id, "seed": seed, "seconds": round(seconds, 2)}))
            return Take(id=line_id, text=text, file=out.name, seconds=seconds)
        print(json.dumps({"event": "take_mismatch", "id": line_id, "seed": seed, "heard": heard}))
    raise TakeMismatchError(f"No matching take for {line_id!r} after {MAX_ATTEMPTS} seeds; heard: {heard_attempts}")


def main(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tts = ChatterboxTTS.from_pretrained(device=device)
    whisper = WhisperModel("small.en", device="cpu", compute_type="int8")
    takes = [
        generate_take(tts, whisper, line_id, text, out_dir / f"{index:02d}-{line_id}.wav")
        for index, (line_id, text) in enumerate(LINES)
    ]
    (out_dir / "manifest.json").write_text(json.dumps([asdict(take) for take in takes], indent=2) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
