import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { color } from "../brand";
import { AppWindow } from "../components/AppWindow";
import { Backdrop } from "../components/Backdrop";
import { type Format, useFormat } from "../components/format";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, wordFrame, wordsFor } from "../timeline";

/** note.webp is 2400×1560; positions below are in its 1200-wide half-size coordinates, scaled by K. */
type NoteLayout = {
  readonly windowWidth: number;
  readonly windowTop: number;
  readonly zoom: number;
  readonly zoomTargetY: number;
  readonly headlineTop: number;
  readonly calloutTop: number;
  readonly headline: number;
  readonly callout: number;
  readonly textWidth: number;
};

const LAYOUT: Record<Format, NoteLayout> = {
  landscape: { windowWidth: 1140, windowTop: 290, zoom: 1.75, zoomTargetY: 630, headlineTop: 110, calloutTop: 120, headline: 84, callout: 96, textWidth: 1700 },
  portrait: { windowWidth: 1000, windowTop: 620, zoom: 1.85, zoomTargetY: 1060, headlineTop: 220, calloutTop: 420, headline: 84, callout: 96, textWidth: 940 },
};

type Rect = { readonly left: number; readonly top: number; readonly width: number; readonly height: number };
type Point = { readonly x: number; readonly y: number };
type NoteGeometry = {
  readonly left: number;
  readonly tasks: Rect;
  readonly tasksCenter: Point;
  readonly check: Point & { readonly size: number };
};

/** Positions in note.webp's 1200-wide half-size coordinates, scaled to the window width. */
const geometry = (layout: NoteLayout, frameWidth: number): NoteGeometry => {
  const k = layout.windowWidth / 1200;
  const tasks = { left: 546 * k, top: 498 * k, width: 638 * k, height: 250 * k };
  return {
    left: (frameWidth - layout.windowWidth) / 2,
    tasks,
    tasksCenter: { x: tasks.left + tasks.width / 2, y: tasks.top + tasks.height / 2 },
    check: { x: 582 * k, y: 550 * k, size: 22 * k },
  };
};

/** After the meeting: the note is ready, then the camera moves to the tasks on top and the first one gets ticked. */
export const NoteScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  const layout = LAYOUT[useFormat()];
  const { left: windowLeft, tasks, tasksCenter, check } = geometry(layout, width);
  const zoomTarget = { x: width / 2, y: layout.zoomTargetY };
  const note = lineIn("note", "note");
  const words = wordsFor("note");
  const tasksLineWord = words[8];
  const lastWord = words[11];
  if (tasksLineWord === undefined || lastWord === undefined) {
    throw new Error('Line "note" needs 12 words ("… Your tasks come first.").');
  }
  const calloutAt = wordFrame(note, tasksLineWord);
  const focusAt = calloutAt - 12;
  const tickAt = wordFrame(note, lastWord) + 14;
  const enter = interpolate(frame, [0, 26], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const focus = interpolate(frame, [focusAt, focusAt + 24], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.65, 0, 0.35, 1),
  });
  const ring = interpolate(frame, [focusAt + 16, focusAt + 30], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const tick = interpolate(frame, [tickAt, tickAt + 8], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 11 }),
  });
  const lift = {
    x: (zoomTarget.x - (windowLeft + tasksCenter.x)) * focus,
    y: (zoomTarget.y - (layout.windowTop + tasksCenter.y)) * focus,
  };
  const windowShift = (1 - enter) * 160;
  return (
    <AbsoluteFill>
      <Backdrop tone="cool" />
      <AbsoluteFill
        style={{
          alignItems: "center",
          paddingTop: layout.headlineTop,
          opacity: 1 - focus,
          translate: `0px ${-focus * 60}px`,
        }}
      >
        <SpokenLine line={note} fromWord={0} toWord={8} emphasisFrom={12} fontSize={layout.headline} fontWeight={660} textAlign="center" maxWidth={layout.textWidth} textColor={color.ink} />
      </AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: windowLeft,
          top: layout.windowTop,
          width: layout.windowWidth,
          opacity: enter * (1 - focus),
          translate: `0px ${windowShift}px`,
          scale: 1 + focus * 0.08,
          filter: `blur(${focus * 6}px)`,
        }}
      >
        <AppWindow file="shots/note.webp" width={layout.windowWidth} radius={20} />
      </div>
      {/* The task card lifts out of the window and moves to the middle of the frame. */}
      <div
        style={{
          position: "absolute",
          left: windowLeft + tasks.left,
          top: layout.windowTop + tasks.top,
          width: tasks.width,
          height: tasks.height,
          opacity: enter,
          translate: `${lift.x}px ${lift.y + windowShift}px`,
          scale: 1 + (layout.zoom - 1) * focus,
          borderRadius: 14,
          overflow: "hidden",
          backgroundColor: color.card,
          boxShadow: `0 ${focus * 30}px ${focus * 70}px rgb(60 30 20 / ${focus * 0.16})`,
        }}
      >
        <Img
          src={staticFile("shots/note.webp")}
          style={{ position: "absolute", left: -tasks.left, top: -tasks.top, width: layout.windowWidth, maxWidth: "none" }}
        />
        <div
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: 14,
            border: `2px solid ${color.accent}`,
            opacity: ring,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: check.x - tasks.left - check.size / 2,
            top: check.y - tasks.top - check.size / 2,
            width: check.size,
            height: check.size,
            borderRadius: "50%",
            backgroundColor: color.accent,
            scale: tick,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <svg width={check.size * 0.62} height={check.size * 0.62} viewBox="0 0 24 24" fill="none">
            <path d="M5 12.5l4.5 4.5L19 7.5" stroke="white" strokeWidth={3.2} strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </div>
      </div>
      <AbsoluteFill style={{ alignItems: "center", paddingTop: layout.calloutTop,
          // Hidden until its first word is spoken, so no half-faded word shows during the move.
          opacity: Math.min(focus, interpolate(frame, [calloutAt - 2, calloutAt + 4], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })), }}>
        <SpokenLine line={note} fromWord={8} toWord={12} emphasisFrom={8} fontSize={layout.callout} fontWeight={680} textAlign="center" maxWidth={layout.textWidth} textColor={color.ink} />
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${note.take.file}`)} from={note.from} />
      <Audio src={staticFile("sfx/mouse-click.wav")} from={Math.round(tickAt)} volume={0.5} />
    </AbsoluteFill>
  );
};
