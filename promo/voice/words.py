"""Time every on-screen word of the promo voiceover with faster-whisper word timestamps.

Usage: uv run python words.py <vo-dir>

Reads `<vo-dir>/manifest.json` (written by speak.py), transcribes each take with word timestamps and aligns the heard
words to the display form of the take's spoken text (`voice_script.display_text`), so the film shows the script's
spelling ("Gistsmith", "gistsmith.com") at the moment each word is spoken. Writes `<vo-dir>/words.json`: per line, a
list of {text, startMs, endMs}.
"""

import json
import sys
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

from faster_whisper import WhisperModel

from voice_script import display_text, spoken_tokens


@dataclass(frozen=True)
class TimedWord:
    text: str
    start_ms: int
    end_ms: int


@dataclass(frozen=True)
class HeardToken:
    token: str
    start: float
    end: float


@dataclass(frozen=True)
class ManifestTake:
    id: str
    text: str
    file: str
    seconds: float


class AlignmentError(RuntimeError):
    """Raised when too few script words were heard to place the rest between them."""


class ManifestError(ValueError):
    """Raised when manifest.json does not have the shape speak.py writes."""


def parse_take(item: dict[str, object]) -> ManifestTake:
    take_id, text, file, seconds = (item.get(key) for key in ("id", "text", "file", "seconds"))
    if not (isinstance(take_id, str) and isinstance(text, str) and isinstance(file, str)):
        raise ManifestError(f"Manifest entry needs string id, text and file: {item!r}")
    if not isinstance(seconds, int | float):
        raise ManifestError(f"Manifest entry needs numeric seconds: {item!r}")
    return ManifestTake(id=take_id, text=text, file=file, seconds=float(seconds))


def parse_manifest(raw: str) -> list[ManifestTake]:
    # speak.py writes a JSON array of objects; each field is checked in parse_take.
    items: list[dict[str, object]] = json.loads(raw)
    return [parse_take(item) for item in items]


def heard_tokens(whisper: WhisperModel, path: Path) -> list[HeardToken]:
    # faster-whisper leaves its numpy-array and VAD-dict parameters unparameterised.
    segments, _info = whisper.transcribe(str(path), language="en", beam_size=5, word_timestamps=True)  # pyright: ignore[reportUnknownMemberType]
    return [
        HeardToken(token=token, start=word.start, end=word.end)
        for segment in segments
        for word in segment.words or []
        for token in spoken_tokens(word.word)
    ]


def align(display: str, heard: list[HeardToken], seconds: float) -> list[TimedWord]:
    """Give each display word the span of its matched heard tokens; unmatched words share the gap around them."""
    words = display.split()
    owners = [index for index, word in enumerate(words) for _token in spoken_tokens(word)]
    script = [token for word in words for token in spoken_tokens(word)]
    matcher = SequenceMatcher(a=script, b=[item.token for item in heard], autojunk=False)
    spans: dict[int, tuple[float, float]] = {}
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            owner = owners[block.a + offset]
            item = heard[block.b + offset]
            start, end = spans.get(owner, (item.start, item.end))
            spans[owner] = (min(start, item.start), max(end, item.end))
    if len(spans) < len(words) * 0.6:
        raise AlignmentError(f"Only {len(spans)}/{len(words)} words heard in {display!r}: {heard}")
    timed: list[TimedWord] = []
    for index, word in enumerate(words):
        if index in spans:
            start, end = spans[index]
        else:
            before = max((spans[i][1] for i in spans if i < index), default=0.0)
            after = min((spans[i][0] for i in spans if i > index), default=seconds)
            start, end = before, after
        timed.append(TimedWord(text=word, start_ms=round(start * 1000), end_ms=round(end * 1000)))
    return timed


def words_json(timings: dict[str, list[TimedWord]]) -> str:
    """The film's words.json, with the camelCase keys `TimedWord` in promo/film/src/timeline.ts reads."""
    payload = {
        line_id: [{"text": word.text, "startMs": word.start_ms, "endMs": word.end_ms} for word in words]
        for line_id, words in timings.items()
    }
    return json.dumps(payload, indent=2) + "\n"


def main(vo_dir: Path) -> None:
    manifest = parse_manifest((vo_dir / "manifest.json").read_text())
    whisper = WhisperModel("small.en", device="cpu", compute_type="int8")
    timings = {
        take.id: align(display_text(take.text), heard_tokens(whisper, vo_dir / take.file), take.seconds)
        for take in manifest
    }
    _ = (vo_dir / "words.json").write_text(words_json(timings))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
