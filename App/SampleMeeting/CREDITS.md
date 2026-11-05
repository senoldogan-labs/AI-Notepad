# Sample meeting audio

- `sample-meeting.m4a`: a short, fictional two-person product meeting (Maya and Leo) played in the onboarding
  tutorial. AAC, mono, 24 kHz, 48 kbps.
- `sample-meeting.json`: its timed transcript; each line's speaker, text, and start and end of speech in seconds.

## Voices

Both voices are fully synthetic text-to-speech voices. No real person's voice was recorded, sampled or cloned.

- Model: [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) by hexgrad, licensed under
  [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0). The model card states it was trained only on
  permissive or non-copyrighted audio and welcomes commercial deployment.
- Maya (person 1): Kokoro built-in voice `af_heart` (US English, female).
- Leo (person 2): Kokoro built-in voice `am_michael` (US English, male).
  Both voicepacks ship in the same Apache-2.0 repository; see its
  [VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md).

## Script

Original script written by Gistsmith for this tutorial.

## Regenerate

```bash
cd promo/sample-meeting && uv run python generate.py out ../../App/SampleMeeting
```

The generator (`promo/sample-meeting/`) checks every line with
[faster-whisper](https://github.com/SYSTRAN/faster-whisper) (MIT) before writing these files.
