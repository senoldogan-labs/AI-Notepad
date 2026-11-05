"""Generate the onboarding sample meeting with Kokoro-82M and write its audio and timed transcript into the app.

Usage: uv run python generate.py <work-dir> <app-sample-dir>

Each line is synthesised in its speaker's voice and read back with faster-whisper; a take whose words differ from the
script is regenerated at a slightly different speed, so a skipped or invented word never reaches the app. Takes are
trimmed to their speech, loudness-matched, joined with short turn gaps and peak-limited as a whole. The mix is written
to `<work-dir>/sample-meeting.wav`, encoded to AAC with `afconvert`, and published to `<app-sample-dir>` as
`sample-meeting.m4a` plus `sample-meeting.json` (the timed transcript, written last) only after the encoded audio has
been transcribed once more as a whole; that check and each speaker's median pitch are logged.
"""

import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

import librosa
import numpy as np
import pyloudnorm
import soundfile
import torch
from faster_whisper import WhisperModel
from kokoro import KPipeline
from numpy.typing import NDArray
from scipy import ndimage

from script import LINES, ScriptLine, speaker_for, spoken_tokens

Audio = NDArray[np.float32]

SAMPLE_RATE = 24_000
# Retry speeds relative to the speaker's own speed: Kokoro's timing is deterministic, so a retry changes the pacing.
SPEED_FACTORS = (1.0, 0.96, 1.04, 0.92, 1.08)
MIN_TAKE_MATCH = 0.9
MIN_MIX_MATCH = 0.95
TRIM_TOP_DB = 40.0
LEAD_IN_SEC = 0.25
TAIL_SEC = 0.6
# One pause per turn change, varied so the exchange does not tick like a metronome.
TURN_GAPS_SEC = (0.45, 0.38, 0.55, 0.42, 0.6, 0.36, 0.5, 0.4)
# Kokoro's speech peaks sit about 21 dB above its loudness, so the mix gets a look-ahead limiter at this level.
TAKE_LUFS = -18.0
PEAK_CEILING = 0.89  # about -1 dBFS, headroom for the AAC encoder's overshoot
LIMITER_RADIUS_SEC = 0.005
AAC_BITRATE = 48_000
MAX_M4A_BYTES = 1_500_000
F0_MIN_HZ = 60.0
F0_MAX_HZ = 400.0


@dataclass(frozen=True)
class Take:
    line: ScriptLine
    audio: Audio


@dataclass(frozen=True)
class TimedLine:
    person: int
    text: str
    start_sec: float
    end_sec: float


@dataclass(frozen=True)
class Mix:
    audio: Audio
    lines: tuple[TimedLine, ...]

    @property
    def duration_sec(self) -> float:
        return len(self.audio) / SAMPLE_RATE


class TakeMismatchError(RuntimeError):
    """Raised when no take of a line was read back with the intended words."""


class MixError(RuntimeError):
    """Raised when the arranged or encoded mix breaks a limit the app relies on."""


def word_match_ratio(expected: str, heard: str) -> float:
    return SequenceMatcher(a=spoken_tokens(expected), b=spoken_tokens(heard), autojunk=False).ratio()


def synthesize(pipeline: KPipeline, voice: str, text: str, speed: float) -> Audio:
    # An empty split pattern keeps the whole line in one utterance, so its sentences share one intonation contour.
    # kokoro ships no type information for its results.
    results = list(pipeline(text, voice=voice, speed=speed, split_pattern=None))  # pyright: ignore[reportUnknownArgumentType]
    chunks: list[Audio] = []
    for result in results:
        audio = result.audio
        if audio is None:
            raise MixError(f"Kokoro returned no audio for {result.graphemes!r} (voice {voice}, speed {speed})")
        chunks.append(audio.numpy().astype(np.float32))
    if not chunks:
        raise MixError(f"Kokoro produced no chunks for {text!r} (voice {voice}, speed {speed})")
    return np.concatenate(chunks)


def trimmed(audio: Audio) -> Audio:
    """The take without its leading and trailing silence, so its span in the mix is exactly its speech."""
    # librosa leaves trim's return tuple unparameterised.
    speech, _index = librosa.effects.trim(audio, top_db=TRIM_TOP_DB)  # pyright: ignore[reportUnknownVariableType, reportUnknownMemberType]
    return np.asarray(speech, dtype=np.float32)


def loudness_normalized(audio: Audio, target_lufs: float) -> Audio:
    # pyloudnorm ships no type information.
    meter = pyloudnorm.Meter(SAMPLE_RATE)  # pyright: ignore[reportUnknownMemberType]
    loudness: float = meter.integrated_loudness(audio)  # pyright: ignore[reportUnknownMemberType]
    return (audio * np.float32(10 ** ((target_lufs - loudness) / 20))).astype(np.float32)


def transcribe(whisper: WhisperModel, path: Path) -> str:
    # faster-whisper leaves its numpy-array and VAD-dict parameters unparameterised.
    segments, _info = whisper.transcribe(str(path), language="en", beam_size=5)  # pyright: ignore[reportUnknownMemberType]
    return " ".join(segment.text.strip() for segment in segments)


def generate_take(pipeline: KPipeline, whisper: WhisperModel, line: ScriptLine, scratch: Path) -> Take:
    speaker = speaker_for(line.person)
    heard_attempts: list[str] = []
    for factor in SPEED_FACTORS:
        speed = round(speaker.speed * factor, 3)
        # Kokoro's vocoder draws noise from torch's global generator; a fixed seed makes every run identical.
        # torch leaves manual_seed's parameter unannotated.
        _ = torch.manual_seed(0)  # pyright: ignore[reportUnknownMemberType]
        audio = loudness_normalized(trimmed(synthesize(pipeline, speaker.kokoro_voice, line.text, speed)), TAKE_LUFS)
        soundfile.write(str(scratch), audio, SAMPLE_RATE)
        heard = transcribe(whisper, scratch)
        heard_attempts.append(heard)
        ratio = word_match_ratio(line.text, heard)
        event = {"speaker": speaker.name, "speed": speed, "ratio": round(ratio, 3), "heard": heard}
        if ratio >= MIN_TAKE_MATCH:
            print(json.dumps({"event": "take_ok", "seconds": round(len(audio) / SAMPLE_RATE, 2), **event}))
            return Take(line=line, audio=audio)
        print(json.dumps({"event": "take_mismatch", **event}))
    raise TakeMismatchError(
        f"No matching take for {line.text!r} at {len(SPEED_FACTORS)} speeds; heard: {heard_attempts}"
    )


def silence(seconds: float) -> Audio:
    return np.zeros(round(seconds * SAMPLE_RATE), dtype=np.float32)


def arranged(takes: tuple[Take, ...], gaps_sec: tuple[float, ...]) -> Mix:
    """Join the takes after a lead-in with one gap between consecutive lines, timing each line on the joined audio."""
    if len(gaps_sec) != len(takes) - 1:
        raise MixError(f"Need {len(takes) - 1} turn gaps for {len(takes)} lines, got {len(gaps_sec)}")
    pieces: list[Audio] = [silence(LEAD_IN_SEC)]
    timed: list[TimedLine] = []
    cursor = len(pieces[0])
    for index, take in enumerate(takes):
        if index > 0:
            gap = silence(gaps_sec[index - 1])
            pieces.append(gap)
            cursor += len(gap)
        pieces.append(take.audio)
        timed.append(
            TimedLine(
                person=take.line.person,
                text=take.line.text,
                start_sec=cursor / SAMPLE_RATE,
                end_sec=(cursor + len(take.audio)) / SAMPLE_RATE,
            )
        )
        cursor += len(take.audio)
    pieces.append(silence(TAIL_SEC))
    return Mix(audio=np.concatenate(pieces), lines=tuple(timed))


def peak_limited(audio: Audio, ceiling: float) -> Audio:
    """Duck only the samples that would pass `ceiling`, with a smooth gain that never lets one through.

    The gain each sample needs is spread over a look-ahead window by a sliding minimum of radius r and then smoothed
    by a moving average no wider than 2r + 1, so every averaged value still includes that sample's own requirement.
    """
    radius = round(LIMITER_RADIUS_SEC * SAMPLE_RATE)
    needed = np.minimum(1.0, ceiling / np.maximum(np.abs(audio), np.float32(1e-9)))
    window = 2 * radius + 1
    # scipy.ndimage leaves the filters' input and size parameters unannotated.
    spread = ndimage.minimum_filter1d(needed, size=window, mode="nearest")  # pyright: ignore[reportUnknownMemberType, reportUnknownVariableType]
    smoothed = ndimage.uniform_filter1d(spread, size=window, mode="nearest")  # pyright: ignore[reportUnknownMemberType, reportUnknownVariableType]
    gain = np.asarray(smoothed, dtype=np.float32)
    limited = (audio * gain).astype(np.float32)
    peak = float(np.max(np.abs(limited)))
    if peak > ceiling + 1e-6:
        raise MixError(f"Limiter left a peak of {peak:.4f} above the {ceiling} ceiling")
    return limited


def mastered(mix: Mix) -> Mix:
    return Mix(audio=peak_limited(mix.audio, PEAK_CEILING), lines=mix.lines)


def transcript_json(mix: Mix) -> str:
    """The app's sample-meeting.json: camelCase keys, seconds rounded to hundredths."""
    payload = {
        "durationSec": round(mix.duration_sec, 2),
        "lines": [
            {
                "person": line.person,
                "text": line.text,
                "startSec": round(line.start_sec, 2),
                "endSec": round(line.end_sec, 2),
            }
            for line in mix.lines
        ],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def encode_m4a(wav: Path, m4a: Path) -> None:
    command = ["afconvert", "-f", "m4af", "-d", "aac", "-b", str(AAC_BITRATE), "-c", "1", str(wav), str(m4a)]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        raise MixError(f"afconvert failed ({completed.returncode}): {command} stderr={completed.stderr.strip()}")
    size = m4a.stat().st_size
    if size >= MAX_M4A_BYTES:
        raise MixError(f"{m4a} is {size} bytes, over the {MAX_M4A_BYTES}-byte limit; lower AAC_BITRATE")


def median_f0_hz(audio: Audio) -> float:
    # librosa leaves pyin's return tuple unparameterised.
    f0, _voiced, _probability = librosa.pyin(audio, fmin=F0_MIN_HZ, fmax=F0_MAX_HZ, sr=SAMPLE_RATE)  # pyright: ignore[reportUnknownVariableType]
    return float(np.nanmedian(np.asarray(f0, dtype=np.float64)))


def speaker_audio(mix: Mix, person: int) -> Audio:
    return np.concatenate(
        [
            mix.audio[round(line.start_sec * SAMPLE_RATE) : round(line.end_sec * SAMPLE_RATE)]
            for line in mix.lines
            if line.person == person
        ]
    )


def verify(whisper: WhisperModel, mix: Mix, m4a: Path) -> None:
    """Read the encoded audio back as a whole and log its word match and each speaker's median pitch."""
    script_text = " ".join(line.text for line in LINES)
    ratio = word_match_ratio(script_text, transcribe(whisper, m4a))
    pitches = {
        speaker_for(person).name: round(median_f0_hz(speaker_audio(mix, person)), 1)
        for person in sorted({line.person for line in mix.lines})
    }
    # pyloudnorm ships no type information.
    loudness: float = pyloudnorm.Meter(SAMPLE_RATE).integrated_loudness(mix.audio)  # pyright: ignore[reportUnknownMemberType]
    event = {"ratio": round(ratio, 3), "median_f0_hz": pitches, "lufs": round(loudness, 1), "seconds": mix.duration_sec}
    print(json.dumps({"event": "mix_verified", **event}))
    if ratio < MIN_MIX_MATCH:
        raise MixError(f"Published audio matches the script at {ratio:.3f}, below {MIN_MIX_MATCH}")


def main(work_dir: Path, app_dir: Path) -> None:
    work_dir.mkdir(parents=True, exist_ok=True)
    app_dir.mkdir(parents=True, exist_ok=True)
    pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", device="cpu")
    whisper = WhisperModel("small.en", device="cpu", compute_type="int8")
    takes = tuple(generate_take(pipeline, whisper, line, work_dir / "take.wav") for line in LINES)
    mix = mastered(arranged(takes, TURN_GAPS_SEC))
    wav = work_dir / "sample-meeting.wav"
    soundfile.write(str(wav), mix.audio, SAMPLE_RATE, subtype="PCM_16")
    staged = work_dir / "sample-meeting.m4a"
    encode_m4a(wav, staged)
    verify(whisper, mix, staged)
    _ = shutil.copyfile(staged, app_dir / "sample-meeting.m4a")
    _ = (app_dir / "sample-meeting.json").write_text(transcript_json(mix))


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
