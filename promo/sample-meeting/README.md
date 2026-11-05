# Sample meeting generator

Generates the onboarding tutorial's synthetic two-speaker meeting (`App/SampleMeeting/sample-meeting.m4a`) and its
timed transcript (`App/SampleMeeting/sample-meeting.json`) with Kokoro-82M. The lines and voices live in `script.py`.

Regenerate (macOS, needs `afconvert`; first run downloads Kokoro-82M and faster-whisper `small.en`):

```bash
cd promo/sample-meeting && uv run python generate.py out ../../App/SampleMeeting
```

Every take is read back with faster-whisper and regenerated at another speed if its words differ; the encoded mix is
checked once more before anything is written to `App/SampleMeeting/`. Intermediate WAVs stay in the git-ignored `out/`.

Checks: `uv run ruff check . && uv run ruff format --check . && uv run basedpyright`
