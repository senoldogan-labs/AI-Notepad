"""Generate the promo voiceover with Chatterbox, one WAV per line, and check each take with faster-whisper.

Usage: uv run python speak.py <output-dir>

Each line is generated with increasing seeds until faster-whisper reads back the same words, so a take with a
skipped or invented word never reaches the film. Writes `<NN>-<id>.wav` per line plus `manifest.json` (line id, text,
duration in seconds) that the Remotion project imports to size its scenes. Takes are generated in a staging directory
next to `<output-dir>` and moved into place, manifest last, only once every line has a take, so a failed run leaves
the previous voiceover untouched.
"""

import json
import shutil
import sys
import tempfile
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from pathlib import Path

import torch
import torchaudio
from chatterbox.tts import ChatterboxTTS
from faster_whisper import WhisperModel

from voice_script import LINES, ScriptLine, spoken_tokens

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


def words_match(expected: str, heard: str) -> bool:
    """True when the heard words are close enough (whisper may spell the brand name differently)."""
    ratio = SequenceMatcher(a=spoken_tokens(expected), b=spoken_tokens(heard)).ratio()
    return ratio >= MIN_WORD_MATCH


def manifest_json(takes: list[Take]) -> str:
    return json.dumps([asdict(take) for take in takes], indent=2) + "\n"


def transcribe(whisper: WhisperModel, path: Path) -> str:
    # faster-whisper leaves its numpy-array and VAD-dict parameters unparameterised.
    segments, _info = whisper.transcribe(str(path), language="en", beam_size=5)  # pyright: ignore[reportUnknownMemberType]
    return " ".join(segment.text.strip() for segment in segments)


def generate_take(tts: ChatterboxTTS, whisper: WhisperModel, line: ScriptLine, out: Path) -> Take:
    heard_attempts: list[str] = []
    for seed in range(MAX_ATTEMPTS):
        # torch leaves manual_seed's parameter unannotated, chatterbox-tts the text parameter of generate, and
        # torchaudio.save has no return annotation.
        _ = torch.manual_seed(seed)  # pyright: ignore[reportUnknownMemberType]
        wav = tts.generate(line.spoken, exaggeration=0.55, cfg_weight=0.45, temperature=0.7)  # pyright: ignore[reportUnknownMemberType]
        torchaudio.save(str(out), wav, tts.sr)  # pyright: ignore[reportUnknownMemberType]
        heard = transcribe(whisper, out)
        heard_attempts.append(heard)
        if words_match(line.spoken, heard):
            seconds = wav.shape[1] / tts.sr
            print(json.dumps({"event": "take_ok", "id": line.id, "seed": seed, "seconds": round(seconds, 2)}))
            return Take(id=line.id, text=line.spoken, file=out.name, seconds=seconds)
        print(json.dumps({"event": "take_mismatch", "id": line.id, "seed": seed, "heard": heard}))
    raise TakeMismatchError(f"No matching take for {line.id!r} after {MAX_ATTEMPTS} seeds; heard: {heard_attempts}")


def publish(takes: list[Take], staging: Path, out_dir: Path) -> None:
    """Moves the staged takes into `out_dir`, then the manifest, so the manifest never describes audio it lacks."""
    for take in takes:
        _ = (staging / take.file).replace(out_dir / take.file)
    manifest = staging / "manifest.json"
    _ = manifest.write_text(manifest_json(takes))
    _ = manifest.replace(out_dir / "manifest.json")


def main(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    # chatterbox-tts leaves from_pretrained's device parameter unannotated.
    tts = ChatterboxTTS.from_pretrained(device=device)  # pyright: ignore[reportUnknownMemberType]
    whisper = WhisperModel("small.en", device="cpu", compute_type="int8")
    # Same parent as out_dir, so Path.replace is an atomic rename on one filesystem.
    staging = Path(tempfile.mkdtemp(prefix=f".{out_dir.name}-staging-", dir=out_dir.parent))
    try:
        takes = [
            generate_take(tts, whisper, line, staging / f"{index:02d}-{line.id}.wav")
            for index, line in enumerate(LINES)
        ]
        publish(takes, staging, out_dir)
    finally:
        shutil.rmtree(staging)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
