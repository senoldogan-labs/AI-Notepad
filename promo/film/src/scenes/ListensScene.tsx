import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color, fontFamily } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { Orb } from "../components/Orb";
import { SpokenLine } from "../components/SpokenLine";
import { useVoiceLevel } from "../components/useVoiceLevel";
import { lineIn, type PlacedLine, wordFrame, wordsFor } from "../timeline";

const ORB_SIZE = 420;

type Source = {
  readonly label: string;
  /** Word of the voiceover line that brings the chip in. */
  readonly word: number;
  readonly x: number;
  readonly y: number;
  readonly dot: string;
};

const SOURCES: readonly Source[] = [
  { label: "Zoom", word: 3, x: -470, y: -70, dot: "#5b8def" },
  { label: "Microsoft Teams", word: 4, x: 500, y: -70, dot: "#8b7fe0" },
  { label: "Google Meet", word: 5, x: -500, y: 100, dot: "#4fa77a" },
  { label: "In person", word: 8, x: 470, y: 100, dot: color.accent },
];

const Chip: React.FC<{ readonly source: Source; readonly line: PlacedLine }> = ({ source, line }) => {
  const frame = useCurrentFrame();
  const word = wordsFor(line.take.id)[source.word];
  if (word === undefined) {
    throw new Error(`Line "${line.take.id}" has no word ${source.word} for chip "${source.label}".`);
  }
  const start = wordFrame(line, word) - 3;
  const progress = interpolate(frame, [start, start + 14], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 12, mass: 0.7 }),
  });
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: "50%",
        translate: `calc(-50% + ${source.x * (0.6 + 0.4 * progress)}px) calc(-50% + ${source.y + Math.sin((frame + source.x) / 24) * 6}px)`,
        scale: Math.max(progress, 0),
        opacity: Math.min(progress * 1.5, 1),
        display: "flex",
        alignItems: "center",
        gap: 16,
        padding: "20px 32px",
        borderRadius: 999,
        backgroundColor: color.card,
        border: `1px solid ${color.line}`,
        boxShadow: "0 14px 40px rgb(60 30 20 / 0.10)",
        fontFamily,
        fontSize: 40,
        fontWeight: 600,
        letterSpacing: "-0.02em",
        color: color.ink,
        whiteSpace: "nowrap",
      }}
    >
      <span style={{ width: 16, height: 16, borderRadius: 8, backgroundColor: source.dot }} />
      {source.label}
    </div>
  );
};

/** Sound rings that leave the orb continuously. */
const Rings: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <>
      {[0, 1, 2].map((ring) => {
        const phase = ((frame + ring * 20) % 60) / 60;
        return (
          <div
            key={ring}
            style={{
              position: "absolute",
              left: "50%",
              top: "50%",
              width: 280,
              height: 280,
              translate: "-50% -50%",
              borderRadius: "50%",
              border: `2px solid ${color.accent}`,
              scale: 1 + phase * 1.1,
              opacity: (1 - phase) * 0.45,
            }}
          />
        );
      })}
    </>
  );
};

/** Where it listens: every call app or the room itself, without a bot joining. */
export const ListensScene: React.FC = () => {
  const frame = useCurrentFrame();
  const listens = lineIn("listens", "listens");
  const level = useVoiceLevel(listens);
  return (
    <AbsoluteFill>
      <Backdrop tone="cool" />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: 110 }}>
        <SpokenLine
          line={listens}
          fromWord={0}
          toWord={11}
          gradientFrom={11}
          fontSize={80}
          fontWeight={650}
          textAlign="center"
          maxWidth={1500}
          textColor={color.ink}
        />
      </AbsoluteFill>
      <AbsoluteFill style={{ top: 330 }}>
        <div style={{ position: "absolute", left: "50%", top: 300, translate: "-50% -50%", width: ORB_SIZE, height: ORB_SIZE }}>
          <Rings />
          <Orb size={ORB_SIZE} scale={0.82 + level * 0.1} spin={frame / 40} />
        </div>
        <div style={{ position: "absolute", left: 0, right: 0, top: 300 }}>
          {SOURCES.map((source) => (
            <Chip key={source.label} source={source} line={listens} />
          ))}
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "flex-end", paddingBottom: 86 }}>
        <SpokenLine
          line={listens}
          fromWord={11}
          toWord={16}
          gradientFrom={11}
          fontSize={80}
          fontWeight={650}
          textAlign="center"
          maxWidth={1500}
          textColor={color.ink}
        />
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${listens.take.file}`)} from={listens.from} />
    </AbsoluteFill>
  );
};
