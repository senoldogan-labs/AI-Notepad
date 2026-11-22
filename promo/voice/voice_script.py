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


# The Gistsmith Keyboard film (promo/film/src/keyboardai): asking Gistsmith and voice typing without leaving the app.
KEYBOARD_LINES: tuple[ScriptLine, ...] = (
    ScriptLine("kb-hook", "Your keyboard just learned to listen."),
    ScriptLine(
        "kb-ask",
        "Ask Gistsmith about your meetings, right from the keyboard. The answer drops into your message.",
    ),
    ScriptLine("kb-voice", "Or just talk. Say comma, you get a comma. Say first and second, you get a list."),
    ScriptLine("kb-theme", "It even wears your colors."),
    ScriptLine("kb-cta", "Gistsmith Keyboard. Talk to your meetings from any app. gistsmith dot com."),
)

SCRIPTS: dict[str, tuple[ScriptLine, ...]] = {"promo": LINES, "keyboard": KEYBOARD_LINES}


def script_lines(name: str) -> tuple[ScriptLine, ...]:
    """The lines of a named script ("promo" or "keyboard"); an unknown name is an error."""
    if name not in SCRIPTS:
        raise KeyError(f"Unknown script {name!r}; expected one of {sorted(SCRIPTS)}")
    return SCRIPTS[name]


def display_text(spoken: str) -> str:
    """The on-screen spelling of a spoken line: the domain is read out as "dot com" but shown as ".com"."""
    return re.sub(r" dot com\.?$", ".com", spoken)


def spoken_tokens(text: str) -> list[str]:
    """Lower-case words as a listener hears them, for comparing the script with a transcription."""
    spoken = text.lower().replace(".com", " dot com").replace("gistsmith", "gist smith")
    return re.sub(r"[^a-z0-9' ]", " ", spoken).split()
