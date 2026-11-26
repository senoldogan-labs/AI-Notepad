import type { CSSProperties } from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import "../brand";
import "../voicetype/olive";
import { CallWindow } from "./CallWindow";
import { Chip, EndCard, Field, Headline, NoteCard, TranscriptCard } from "./parts";
import { ease, type Format, ramp, type RevealStep } from "./theme";

/**
 * "Meeting notes without a bot in the call": a plain call with four people and no notetaker, the Gistsmith live
 * transcript running beside it on the Mac, the call ends, the finished note with the tasks. Silent, reads with the
 * sound off. 1:1 and 9:16 share the parts and differ in layout (`LAYOUT`).
 */
type Rect = { readonly x: number; readonly y: number; readonly scale: number };

type Layout = {
  readonly callBig: Rect;
  readonly callSmall: Rect;
  readonly chipBigTop: number;
  readonly chipSmall: { readonly left: number; readonly top: number; readonly top2: number };
  readonly chipSize: number;
  readonly card: { readonly x: number; readonly y: number; readonly width: number; readonly srcTop: number; readonly srcHeight: number };
  readonly note: { readonly x: number; readonly y: number; readonly width: number };
};

const LAYOUT: Record<Format, Layout> = {
  square: {
    callBig: { x: 117, y: 300, scale: 0.9 },
    callSmall: { x: 40, y: 400, scale: 0.28 },
    chipBigTop: 850,
    chipSmall: { left: 40, top: 590, top2: 660 },
    chipSize: 24,
    card: { x: 330, y: 300, width: 710, srcTop: 130, srcHeight: 880 },
    note: { x: 160, y: 300, width: 760 },
  },
  portrait: {
    callBig: { x: 70, y: 560, scale: 1 },
    callSmall: { x: 70, y: 540, scale: 0.5 },
    chipBigTop: 1190,
    chipSmall: { left: 580, top: 560, top2: 660 },
    chipSize: 34,
    card: { x: 70, y: 860, width: 940, srcTop: 130, srcHeight: 820 },
    note: { x: 70, y: 520, width: 940 },
  },
};

/** Real live-panel rows (live-dark.webp, source px): header, you, Speaker 1, you, Speaker 2, you, Speaker 1. */
const STEPS: readonly RevealStep[] = [
  { at: 150, y: 100 },
  { at: 166, y: 255 },
  { at: 192, y: 385 },
  { at: 206, y: 482 },
  { at: 230, y: 580 },
  { at: 252, y: 705 },
  { at: 266, y: 800 },
  { at: 284, y: 905 },
];

const NOTE_CROP = { left: 880, top: 168, width: 1105, height: 950 };
const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;

const NoBotClip: React.FC<{ readonly format: Format }> = ({ format }) => {
  const frame = useCurrentFrame();
  const layout = LAYOUT[format];
  const move = ease(ramp(frame, 128, 36));
  const out = 1 - ramp(frame, 300, 16);
  const headA = ease(ramp(frame, 4, 20)) * (1 - ramp(frame, 288, 12));
  const headB = ease(ramp(frame, 304, 20));
  const callPresence = ease(ramp(frame, 12, 20)) * out;
  const call: Rect = {
    x: lerp(layout.callBig.x, layout.callSmall.x, move),
    y: lerp(layout.callBig.y, layout.callSmall.y, move),
    scale: lerp(layout.callBig.scale, layout.callSmall.scale, move),
  };
  const chipRow = (top: number, left: number | "center", text: string, presence: number, tone: "copper" | "plain"): React.ReactNode => {
    const wrapper: CSSProperties = { position: "absolute", top, left: left === "center" ? 0 : left, right: left === "center" ? 0 : undefined, display: "flex", justifyContent: "center" };
    return (
      <div style={wrapper}>
        <Chip text={text} presence={presence} tone={tone} size={layout.chipSize} style={{ position: "relative" }} />
      </div>
    );
  };
  const chipIn = ease(ramp(frame, 52, 18));
  return (
    <AbsoluteFill>
      <Field />
      <Headline text="Meeting notes without a bot in the call." presence={headA} format={format} />
      <Headline text="Then a finished note, with your tasks." presence={headB} format={format} />
      <AbsoluteFill style={{ opacity: out }}>
        <CallWindow frame={frame} x={call.x} y={call.y} scale={call.scale} presence={callPresence} ended={ease(ramp(frame, 290, 10))} />
        {chipRow(layout.chipBigTop, "center", "No notetaker joined", chipIn * (1 - move), "plain")}
        {chipRow(layout.chipSmall.top, layout.chipSmall.left, "No notetaker joined", chipIn * move, "plain")}
        {chipRow(layout.chipSmall.top2, layout.chipSmall.left, "Listens from your Mac", ease(ramp(frame, 176, 18)), "copper")}
        <TranscriptCard
          frame={frame}
          x={layout.card.x}
          y={layout.card.y}
          width={layout.card.width}
          srcTop={layout.card.srcTop}
          srcHeight={layout.card.srcHeight}
          steps={STEPS}
          presence={ease(ramp(frame, 150, 22))}
          highlight={null}
        />
      </AbsoluteFill>
      <NoteCard x={layout.note.x} y={layout.note.y} width={layout.note.width} crop={NOTE_CROP} presence={ease(ramp(frame, 322, 24))} tasks={ease(ramp(frame, 352, 12))} />
      <EndCard frame={frame} format={format} />
    </AbsoluteFill>
  );
};

export const NoBotSquare: React.FC = () => <NoBotClip format="square" />;
export const NoBotPortrait: React.FC = () => <NoBotClip format="portrait" />;

/** Frame of the poster still: the call and the live transcript side by side. */
export const NO_BOT_POSTER = 276;
