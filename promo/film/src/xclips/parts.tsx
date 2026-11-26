import type { CSSProperties } from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { fontFamily } from "../brand";
import { serifFamily } from "../voicetype/olive";
import { END_START, ease, field, type Format, ramp, type RevealStep, stepReveal } from "./theme";

/** The quiet film field: warm black, a copper light from the top, a little grain. */
export const Field: React.FC = () => (
  <AbsoluteFill style={{ backgroundColor: field.night }}>
    <AbsoluteFill style={{ backgroundImage: "radial-gradient(75% 40% at 50% 0%, rgb(227 154 114 / 0.16) 0%, transparent 70%), radial-gradient(60% 35% at 50% 100%, rgb(217 193 158 / 0.07) 0%, transparent 70%)" }} />
    <Img src={staticFile("grain.png")} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover", opacity: 0.07, mixBlendMode: "screen" }} />
  </AbsoluteFill>
);

export type HeadlineLayout = { readonly top: number; readonly size: number };

export const HEADLINE: Record<Format, HeadlineLayout> = {
  square: { top: 64, size: 78 },
  portrait: { top: 170, size: 104 },
};

/** The big serif headline that carries the message with the sound off; rises in with its presence (0…1). */
export const Headline: React.FC<{ readonly text: string; readonly presence: number; readonly format: Format }> = ({ text, presence, format }) => (
  <div
    style={{
      position: "absolute",
      left: 70,
      width: 940,
      top: HEADLINE[format].top,
      opacity: presence,
      translate: `0px ${(1 - presence) * 26}px`,
      fontFamily: serifFamily,
      fontSize: HEADLINE[format].size,
      lineHeight: 1.05,
      letterSpacing: "-0.02em",
      color: field.ink,
      textAlign: "center",
      textWrap: "balance",
    }}
  >
    {text}
  </div>
);

/** A small rounded label on the film field. */
export const Chip: React.FC<{ readonly text: string; readonly presence: number; readonly tone: "copper" | "plain"; readonly size: number; readonly style: CSSProperties }> = ({ text, presence, tone, size, style }) => (
  <div
    style={{
      position: "absolute",
      opacity: presence,
      translate: `0px ${(1 - presence) * 14}px`,
      padding: `${size * 0.32}px ${size * 0.6}px`,
      borderRadius: size * 0.5,
      fontFamily,
      fontSize: size,
      fontWeight: 600,
      letterSpacing: "-0.005em",
      whiteSpace: "nowrap",
      color: tone === "copper" ? "#141110" : field.ink,
      background: tone === "copper" ? field.copper : field.card,
      border: tone === "copper" ? `2px solid ${field.copper}` : `2px solid ${field.line}`,
      ...style,
    }}
  >
    {text}
  </div>
);

/** live-dark.webp is 840×1280 px. A progressively revealed crop of the real live panel. */
const LIVE_WIDTH = 840;

export const TranscriptCard: React.FC<{
  readonly frame: number;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly srcTop: number;
  readonly srcHeight: number;
  readonly steps: readonly RevealStep[];
  readonly presence: number;
  readonly highlight: { readonly top: number; readonly bottom: number; readonly presence: number } | null;
}> = ({ frame, x, y, width, srcTop, srcHeight, steps, presence, highlight }) => {
  const scale = width / LIVE_WIDTH;
  const height = srcHeight * scale;
  const reveal = (stepReveal(frame, steps) - srcTop) * scale;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width,
        height,
        opacity: presence,
        translate: `0px ${(1 - presence) * 40}px`,
        borderRadius: 30,
        overflow: "hidden",
        backgroundColor: "#212121",
        border: `1px solid ${field.line}`,
        boxShadow: "0 40px 100px rgb(0 0 0 / 0.5)",
        maskImage: `linear-gradient(to bottom, #000 0px, #000 ${Math.max(reveal - 44, 0)}px, transparent ${Math.max(reveal, 1)}px)`,
      }}
    >
      <Img src={staticFile("shots/live-dark.webp")} style={{ position: "absolute", left: 0, top: -srcTop * scale, width, maxWidth: "none" }} />
      {highlight === null ? null : (
        <div
          style={{
            position: "absolute",
            left: 14 * scale,
            right: 14 * scale,
            top: (highlight.top - srcTop) * scale,
            height: (highlight.bottom - highlight.top) * scale,
            borderRadius: 18 * scale,
            border: `${Math.max(3 * scale, 2)}px solid ${field.copper}`,
            backgroundColor: "rgb(227 154 114 / 0.07)",
            opacity: highlight.presence,
          }}
        />
      )}
    </div>
  );
};

/** note-dark.webp is 2400×1560 px, laid out here in 2000-unit width. A crop of the real Mac note with the tasks. */
const NOTE_WIDTH = 2000;

export const NoteCard: React.FC<{
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly crop: { readonly left: number; readonly top: number; readonly width: number; readonly height: number };
  readonly presence: number;
  readonly tasks: number;
}> = ({ x, y, width, crop, presence, tasks }) => {
  const scale = width / crop.width;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width,
        height: crop.height * scale,
        opacity: presence,
        translate: `0px ${(1 - presence) * 60}px`,
        borderRadius: 30,
        overflow: "hidden",
        backgroundColor: "#212121",
        border: `1px solid ${field.line}`,
        boxShadow: "0 40px 100px rgb(0 0 0 / 0.5)",
        maskImage: "linear-gradient(to bottom, #000 0px, #000 calc(100% - 60px), transparent 100%)",
      }}
    >
      <Img src={staticFile("shots/note-dark.webp")} style={{ position: "absolute", left: -crop.left * scale, top: -crop.top * scale, width: NOTE_WIDTH * scale, maxWidth: "none" }} />
      <div
        style={{
          position: "absolute",
          left: (890 - crop.left) * scale,
          top: (426 - crop.top) * scale,
          width: (1086) * scale,
          height: 352 * scale,
          borderRadius: 26 * scale,
          border: `${Math.max(4 * scale, 3)}px solid ${field.copper}`,
          opacity: tasks,
        }}
      />
    </div>
  );
};

/** End card: the Gistsmith mark, the name and where to get it. */
export const EndCard: React.FC<{ readonly frame: number; readonly format: Format }> = ({ frame, format }) => {
  const p = ease(ramp(frame, END_START, 22));
  const unit = format === "square" ? 1 : 1.18;
  return (
    <AbsoluteFill style={{ opacity: p }}>
      <AbsoluteFill style={{ backgroundColor: field.night }} />
      <AbsoluteFill style={{ backgroundImage: "radial-gradient(60% 40% at 50% 46%, rgb(227 154 114 / 0.2) 0%, transparent 70%)" }} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 34 * unit, translate: `0px ${(1 - p) * 24}px` }}>
        <div style={{ width: 230 * unit, height: 230 * unit, borderRadius: 52 * unit, overflow: "hidden", position: "relative" }}>
          <Img src={staticFile("icon.png")} style={{ position: "absolute", width: 230 * unit * 1.26, height: 230 * unit * 1.26, left: -230 * unit * 0.13, top: -230 * unit * 0.13, maxWidth: "none" }} />
        </div>
        <div style={{ fontFamily: serifFamily, fontSize: 112 * unit, letterSpacing: "-0.02em", color: field.ink, lineHeight: 1 }}>Gistsmith</div>
        <div style={{ fontFamily, fontSize: 42 * unit, fontWeight: 500, letterSpacing: "-0.005em", color: field.sand }}>Mac and iPhone · gistsmith.com</div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
