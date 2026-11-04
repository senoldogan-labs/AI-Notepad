import { useAudioData, visualizeAudio } from "@remotion/media-utils";
import { staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import type { PlacedLine } from "../timeline";

/** Loudness (0–1) of a voiceover line at the current frame, so visuals can breathe with the voice. */
export const useVoiceLevel = (line: PlacedLine): number => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const audioData = useAudioData(staticFile(`vo/${line.take.file}`));
  const local = frame - line.from;
  if (audioData === null || local < 0 || local >= line.durationInFrames) {
    return 0;
  }
  const bins = visualizeAudio({ fps, frame: local, audioData, numberOfSamples: 32, smoothing: true });
  const average = bins.slice(0, 16).reduce((sum, value) => sum + value, 0) / 16;
  return Math.min(1, average * 6);
};
