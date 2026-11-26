import { AbsoluteFill, useCurrentFrame } from "remotion";
import "../brand";
import "../voicetype/olive";
import { Chip, EndCard, Field, Headline, TranscriptCard } from "./parts";
import { ease, type Format, ramp, type RevealStep } from "./theme";

/**
 * "Understand the meeting while they talk": the real live panel, the speaker's own language in grey and the
 * translation under it in white, line by line as they speak. Silent, 1:1 and 9:16.
 */
type Layout = {
  readonly card: { readonly x: number; readonly y: number; readonly width: number; readonly srcHeight: number };
  readonly legendTop: number;
  readonly chipSize: number;
};

const LAYOUT: Record<Format, Layout> = {
  square: { card: { x: 172, y: 332, width: 736, srcHeight: 800 }, legendTop: 262, chipSize: 26 },
  portrait: { card: { x: 70, y: 610, width: 940, srcHeight: 1000 }, legendTop: 520, chipSize: 34 },
};

/** Real live-panel rows (live-dark.webp, source px): header, you, Speaker 1 in Finnish, its English line, you, Speaker 2. */
const STEPS: readonly RevealStep[] = [
  { at: 30, y: 100 },
  { at: 56, y: 255 },
  { at: 100, y: 385 },
  { at: 134, y: 482 },
  { at: 182, y: 580 },
  { at: 222, y: 705 },
  { at: 252, y: 800 },
  { at: 284, y: 905 },
  { at: 312, y: 1000 },
];

const LiveClip: React.FC<{ readonly format: Format }> = ({ format }) => {
  const frame = useCurrentFrame();
  const layout = LAYOUT[format];
  const head = ease(ramp(frame, 4, 20));
  const pair = ease(ramp(frame, 138, 10)) * (1 - ramp(frame, 250, 12));
  return (
    <AbsoluteFill>
      <Field />
      <Headline text="Understand the meeting while they talk." presence={head} format={format} />
      <div style={{ position: "absolute", top: layout.legendTop, left: 0, right: 0, display: "flex", justifyContent: "center", gap: 16 }}>
        <Chip text="What they said" presence={ease(ramp(frame, 98, 16))} tone="plain" size={layout.chipSize} style={{ position: "relative" }} />
        <Chip text="What you read" presence={ease(ramp(frame, 134, 16))} tone="copper" size={layout.chipSize} style={{ position: "relative" }} />
      </div>
      <TranscriptCard
        frame={frame}
        x={layout.card.x}
        y={layout.card.y}
        width={layout.card.width}
        srcTop={0}
        srcHeight={layout.card.srcHeight}
        steps={STEPS}
        presence={ease(ramp(frame, 14, 22))}
        highlight={{ top: 276, bottom: 484, presence: pair }}
      />
      <EndCard frame={frame} format={format} />
    </AbsoluteFill>
  );
};

export const LiveTranslationSquare: React.FC = () => <LiveClip format="square" />;
export const LiveTranslationPortrait: React.FC = () => <LiveClip format="portrait" />;

/** Frame of the poster still: both lines of the translated exchange are up. */
export const LIVE_POSTER = 270;
