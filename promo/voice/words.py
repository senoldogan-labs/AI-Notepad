"""Time every on-screen word of the promo voiceover with faster-whisper word timestamps.

Usage: uv run python words.py <vo-dir>

Reads `<vo-dir>/manifest.json` (written by speak.py), transcribes each take with word timestamps and aligns the heard
words to the display words of the script, so the film shows the script's spelling ("Gistsmith", "gistsmith.com")
at the moment each word is spoken. Writes `<vo-dir>/words.json`: per line, a list of {text, startMs, endMs}.
"""

import json
import re
import sys
from dataclasses import asdict, dataclass
from difflib import SequenceMatcher
from pathlib import Path

from faster_whisper import WhisperModel

# What each line shows on screen; the spoken script lives in speak.py.
DISPLAY: dict[str, str] = {
    "hook": "Every meeting ends the same way.",
    "question": "Who said what? And what was I supposed to do?",
    "meet": "Meet Gistsmith. The meeting notepad for your Mac.",
    "listens": "It listens to Zoom, Teams, Meet, or the room you're in. No bot joins the call.",
    "live": "Every sentence appears live. Translated, if you like.",
    "note": "When you hang up, your note is ready. Your tasks come first.",
    "ask": "Later, just ask. Answers come from every meeting you've had.",
    "cta": "Gistsmith. Your meetings, written for you. Try it free at gistsmith.com",
}


@dataclass(frozen=True)
class TimedWord:
    text: str
    startMs: int
    endMs: int


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


def spoken_tokens(word: str) -> list[str]:
    spoken = word.lower().replace(".com", " dot com").replace("gistsmith", "gist smith")
    return re.sub(r"[^a-z0-9' ]", " ", spoken).split()


def heard_tokens(whisper: WhisperModel, path: Path) -> list[HeardToken]:
    segments, _info = whisper.transcribe(str(path), language="en", beam_size=5, word_timestamps=True)
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
        timed.append(TimedWord(text=word, startMs=round(start * 1000), endMs=round(end * 1000)))
    return timed


def main(vo_dir: Path) -> None:
    manifest = [ManifestTake(**item) for item in json.loads((vo_dir / "manifest.json").read_text())]
    whisper = WhisperModel("small.en", device="cpu", compute_type="int8")
    result: dict[str, list[dict[str, str | int]]] = {
        take.id: [asdict(word) for word in align(DISPLAY[take.id], heard_tokens(whisper, vo_dir / take.file), take.seconds)]
        for take in manifest
    }
    (vo_dir / "words.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
