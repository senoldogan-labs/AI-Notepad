"""The promo's voiceover script: the single source for what is spoken (speak.py) and what is shown (words.py)."""

import re
from dataclasses import dataclass


@dataclass(frozen=True)
class ScriptLine:
    id: str
    spoken: str


LINES: tuple[ScriptLine, ...] = (
    ScriptLine("hook", "Every meeting ends the same way."),
    ScriptLine("question", "Who said what? And what was I supposed to do?"),
    ScriptLine("meet", "Meet Gistsmith. The meeting notepad for your Mac."),
    ScriptLine("listens", "It listens to Zoom, Teams, Meet, or the room you're in. No bot joins the call."),
    ScriptLine("live", "Every sentence appears live. Translated, if you like."),
    ScriptLine("note", "When you hang up, your note is ready. Your tasks come first."),
    ScriptLine("ask", "Later, just ask. Answers come from every meeting you've had."),
    ScriptLine("cta", "Gistsmith. Your meetings, written for you. Try it free at gistsmith dot com."),
)


def display_text(spoken: str) -> str:
    """The on-screen spelling of a spoken line: the domain is read out as "dot com" but shown as ".com"."""
    return re.sub(r" dot com\.?$", ".com", spoken)


def spoken_tokens(text: str) -> list[str]:
    """Lower-case words as a listener hears them, for comparing the script with a transcription."""
    spoken = text.lower().replace(".com", " dot com").replace("gistsmith", "gist smith")
    return re.sub(r"[^a-z0-9' ]", " ", spoken).split()
