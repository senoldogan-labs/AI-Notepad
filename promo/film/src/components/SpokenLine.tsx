import { Easing, interpolate, useCurrentFrame } from "remotion";
import { color, fontFamily, gradientText } from "../brand";
import { type PlacedLine, wordFrame, wordsFor } from "../timeline";

const REVEAL_FRAMES = 9;

export type SpokenLineProps = {
  readonly line: PlacedLine;
  /** First word index (inclusive) of the line to show. */
  readonly fromWord: number;
  /** Last word index (exclusive) of the line to show. */
  readonly toWord: number;
  /** Words at or after this index get the brand gradient; pass `toWord` for none. */
  readonly gradientFrom: number;
  readonly fontSize: number;
  readonly fontWeight: number;
  readonly textAlign: "left" | "center";
  readonly maxWidth: number;
  readonly textColor: string;
};

/** Kinetic typography: each word rises in at the moment the voiceover says it (faster-whisper word timings). */
export const SpokenLine: React.FC<SpokenLineProps> = ({
  line,
  fromWord,
  toWord,
  gradientFrom,
  fontSize,
  fontWeight,
  textAlign,
  maxWidth,
  textColor,
}) => {
  const frame = useCurrentFrame();
  const words = wordsFor(line.take.id).slice(fromWord, toWord);
  return (
    <div
      style={{
        fontFamily,
        fontSize,
        fontWeight,
        lineHeight: 1.08,
        letterSpacing: "-0.035em",
        textAlign,
        maxWidth,
        color: textColor,
        textWrap: "balance",
      }}
    >
      {words.map((word, offset) => {
        const index = fromWord + offset;
        const start = wordFrame(line, word) - 2;
        const progress = interpolate(frame, [start, start + REVEAL_FRAMES], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.bezier(0.16, 1, 0.3, 1),
        });
        return (
          <span key={`${word.startMs}-${index}`}>
            <span
              style={{
                display: "inline-block",
                opacity: progress,
                translate: `0px ${(1 - progress) * 0.35 * fontSize}px`,
                filter: `blur(${(1 - progress) * 10}px)`,
                paddingBottom: "0.08em",
                ...(index >= gradientFrom ? gradientText : {}),
              }}
            >
              {word.text}
            </span>{" "}
          </span>
        );
      })}
    </div>
  );
};

export const headlineColor = color.ink;
