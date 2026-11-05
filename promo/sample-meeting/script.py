"""The onboarding sample meeting: the single source of who says what, in which synthetic voice."""

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Speaker:
    person: int
    name: str
    kokoro_voice: str
    speed: float


@dataclass(frozen=True)
class ScriptLine:
    person: int
    text: str


# Kokoro-82M built-in voices (Apache-2.0): a US English female and a US English male voice.
SPEAKERS: tuple[Speaker, ...] = (
    Speaker(person=1, name="Maya", kokoro_voice="af_heart", speed=0.85),
    Speaker(person=2, name="Leo", kokoro_voice="am_michael", speed=0.88),
)

LINES: tuple[ScriptLine, ...] = (
    ScriptLine(1, "Morning, Leo. Quick one today: are we still on track to ship the new sharing flow next Tuesday?"),
    ScriptLine(
        2,
        "Mostly. The flow itself is done, but link previews still break on large meetings. I need two more days for that.",
    ),
    ScriptLine(1, "Okay. Then let's not block the release on it. Can we ship without previews and turn them on later?"),
    ScriptLine(
        2,
        "Yes, they're already behind a feature flag. I'd ship on Tuesday with previews off, and enable them the week after.",
    ),
    ScriptLine(1, "Good, that's the decision then. Sharing ships on Tuesday, and previews follow a week later."),
    ScriptLine(2, "I'll finish the preview fix by Thursday and send you a test build."),
    ScriptLine(1, "Perfect. Then the release notes just say previews are coming soon."),
    ScriptLine(2, "One more thing. Since you're taking notes today, could you send the recap to the team by Friday?"),
    ScriptLine(1, "Great. Thanks, both of you. Let's talk again on Tuesday, after the release."),
)


class UnknownSpeakerError(LookupError):
    """Raised when a script line names a person without a voice in SPEAKERS."""


def speaker_for(person: int) -> Speaker:
    for speaker in SPEAKERS:
        if speaker.person == person:
            return speaker
    raise UnknownSpeakerError(f"No speaker for person {person}; known: {[s.person for s in SPEAKERS]}")


def spoken_tokens(text: str) -> list[str]:
    """Lower-case words as a listener hears them, for comparing the script with a transcription."""
    return re.sub(r"[^a-z0-9' ]", " ", text.lower()).split()
