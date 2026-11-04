import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { color, fontFamily } from "../brand";
import { Orb } from "../components/Orb";
import { Backdrop } from "../components/Backdrop";
import { type Format, useFormat } from "../components/format";
import { SpokenLine } from "../components/SpokenLine";
import { useVoiceLevel } from "../components/useVoiceLevel";
import { lineIn, type PlacedLine, wordFrame, wordsFor } from "../timeline";

/** The home screen's record card in home.webp (2400×1560 px) and its orb, the app's "Start listening" button. */
const CARD_SOURCE = { left: 568, top: 300, width: 1718, height: 478 };
const ORB_SOURCE = { x: 1426, y: 444, radius: 46 };
type ListensLayout = {
  readonly cardWidth: number;
  readonly cardTop: number;
  readonly headlineTop: number;
  readonly headline: number;
  readonly textWidth: number;
  readonly chipsTop: number;
  readonly chipsWidth: number;
  readonly chipsHeight: number;
  readonly bottom: number;
};

const LAYOUT: Record<Format, ListensLayout> = {
  landscape: { cardWidth: 1040, cardTop: 330, headlineTop: 100, headline: 76, textWidth: 1500, chipsTop: 680, chipsWidth: 1800, chipsHeight: 120, bottom: 80 },
  portrait: { cardWidth: 980, cardTop: 560, headlineTop: 220, headline: 72, textWidth: 940, chipsTop: 900, chipsWidth: 900, chipsHeight: 260, bottom: 620 },
};

type CardGeometry = {
  readonly left: number;
  readonly scale: number;
  readonly orb: { readonly x: number; readonly y: number };
  /** The sphere fills 62% of the Three.js canvas height at scale 1 (fov 30°, camera at z 6). */
  readonly orbCanvas: number;
};

const cardGeometry = (layout: ListensLayout, frameWidth: number): CardGeometry => {
  const scale = layout.cardWidth / CARD_SOURCE.width;
  const left = (frameWidth - layout.cardWidth) / 2;
  return {
    left,
    scale,
    orb: { x: left + (ORB_SOURCE.x - CARD_SOURCE.left) * scale, y: layout.cardTop + (ORB_SOURCE.y - CARD_SOURCE.top) * scale },
    orbCanvas: Math.round((ORB_SOURCE.radius * 2 * scale) / 0.62),
  };
};

type Source = {
  readonly label: string;
  /** Word of the voiceover line that brings the chip in. */
  readonly word: number;
  readonly dot: string;
};

const SOURCES: readonly Source[] = [
  { label: "Zoom", word: 3, dot: "#5b8def" },
  { label: "Microsoft Teams", word: 4, dot: "#8b7fe0" },
  { label: "Google Meet", word: 5, dot: "#4fa77a" },
  { label: "In person", word: 8, dot: color.accent },
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
        scale: Math.max(progress, 0),
        opacity: Math.min(progress * 1.5, 1),
        translate: `0px ${(1 - progress) * 30}px`,
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

/** Sound rings that leave the record orb continuously. */
const Rings: React.FC<{ readonly center: { readonly x: number; readonly y: number } }> = ({ center }) => {
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
              left: center.x,
              top: center.y,
              width: 70,
              height: 70,
              translate: "-50% -50%",
              borderRadius: "50%",
              border: `2px solid ${color.card}`,
              scale: 1 + phase * 3.2,
              opacity: (1 - phase) * 0.7,
            }}
          />
        );
      })}
    </>
  );
};

/** Where it listens: the app's own record button, every call app or the room itself, and no bot joining. */
export const ListensScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  const layout = LAYOUT[useFormat()];
  const card = cardGeometry(layout, width);
  const listens = lineIn("listens", "listens");
  const level = useVoiceLevel(listens);
  const enter = interpolate(frame, [0, 22], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  return (
    <AbsoluteFill>
      <Backdrop tone="cool" />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: layout.headlineTop }}>
        <SpokenLine line={listens} fromWord={0} toWord={11} emphasisFrom={11} fontSize={layout.headline} fontWeight={650} textAlign="center" maxWidth={layout.textWidth} textColor={color.ink} />
      </AbsoluteFill>
      <AbsoluteFill style={{ opacity: enter, translate: `0px ${(1 - enter) * 60}px` }}>
        <div
          style={{
            position: "absolute",
            left: card.left,
            top: layout.cardTop,
            width: layout.cardWidth,
            height: CARD_SOURCE.height * card.scale,
            borderRadius: 30,
            overflow: "hidden",
            boxShadow: "0 30px 80px rgb(60 30 20 / 0.16)",
          }}
        >
          <Img
            src={staticFile("shots/home.webp")}
            style={{
              position: "absolute",
              left: -CARD_SOURCE.left * card.scale,
              top: -CARD_SOURCE.top * card.scale,
              width: 2400 * card.scale,
              maxWidth: "none",
            }}
          />
        </div>
        <Rings center={card.orb} />
        <div style={{ position: "absolute", left: card.orb.x - card.orbCanvas / 2, top: card.orb.y - card.orbCanvas / 2 }}>
          <Orb size={card.orbCanvas} scale={1 + level * 0.12} spin={frame / 40} />
        </div>
      </AbsoluteFill>
      <AbsoluteFill
        style={{
          top: layout.chipsTop,
          left: (width - layout.chipsWidth) / 2,
          width: layout.chipsWidth,
          height: layout.chipsHeight,
          alignContent: "center",
          flexDirection: "row",
          flexWrap: "wrap",
          justifyContent: "center",
          alignItems: "center",
          gap: 26,
        }}
      >
        {SOURCES.map((source) => (
          <Chip key={source.label} source={source} line={listens} />
        ))}
      </AbsoluteFill>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "flex-end", paddingBottom: layout.bottom }}>
        <SpokenLine line={listens} fromWord={11} toWord={16} emphasisFrom={11} fontSize={layout.headline} fontWeight={650} textAlign="center" maxWidth={layout.textWidth} textColor={color.ink} />
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${listens.take.file}`)} from={listens.from} />
    </AbsoluteFill>
  );
};
