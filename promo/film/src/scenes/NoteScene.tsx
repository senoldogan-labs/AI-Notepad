import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color } from "../brand";
import { AppWindow } from "../components/AppWindow";
import { Backdrop } from "../components/Backdrop";
import { SpokenLine } from "../components/SpokenLine";
import { HEIGHT, lineIn, WIDTH, wordFrame, wordsFor } from "../timeline";

/** note.webp is 2400×1560; positions below are in its 1200-wide half-size coordinates, scaled by K. */
const WINDOW_WIDTH = 1140;
const WINDOW_LEFT = (WIDTH - WINDOW_WIDTH) / 2;
const WINDOW_TOP = 290;
const K = WINDOW_WIDTH / 1200;
const TASKS = { left: 546 * K, top: 498 * K, width: 638 * K, height: 250 * K };
const TASKS_CENTER = { x: TASKS.left + TASKS.width / 2, y: TASKS.top + TASKS.height / 2 };
const FIRST_CHECK = { x: 582 * K, y: 550 * K, size: 22 * K };
/** Zoomed view: the task card fills the middle of the frame, leaving room for the callout above it. */
const ZOOM = 1.75;
const ZOOM_TARGET = { x: WIDTH / 2, y: HEIGHT / 2 + 90 };

/** After the meeting: the note is ready, then the camera moves to the tasks on top and the first one gets ticked. */
export const NoteScene: React.FC = () => {
  const frame = useCurrentFrame();
  const note = lineIn("note", "note");
  const words = wordsFor("note");
  const tasksLineWord = words[8];
  const lastWord = words[11];
  if (tasksLineWord === undefined || lastWord === undefined) {
    throw new Error('Line "note" needs 12 words ("… Your tasks come first.").');
  }
  const focusAt = wordFrame(note, tasksLineWord) - 12;
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
    x: (ZOOM_TARGET.x - (WINDOW_LEFT + TASKS_CENTER.x)) * focus,
    y: (ZOOM_TARGET.y - (WINDOW_TOP + TASKS_CENTER.y)) * focus,
  };
  const windowShift = (1 - enter) * 160;
  return (
    <AbsoluteFill>
      <Backdrop tone="cool" />
      <AbsoluteFill
        style={{
          alignItems: "center",
          paddingTop: 110,
          opacity: 1 - focus,
          translate: `0px ${-focus * 60}px`,
        }}
      >
        <SpokenLine line={note} fromWord={0} toWord={8} gradientFrom={12} fontSize={84} fontWeight={660} textAlign="center" maxWidth={1700} textColor={color.ink} />
      </AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: WINDOW_LEFT,
          top: WINDOW_TOP,
          width: WINDOW_WIDTH,
          opacity: enter * (1 - focus),
          translate: `0px ${windowShift}px`,
          scale: 1 + focus * 0.08,
          filter: `blur(${focus * 6}px)`,
        }}
      >
        <AppWindow file="shots/note.webp" width={WINDOW_WIDTH} radius={20} />
      </div>
      {/* The task card lifts out of the window and moves to the middle of the frame. */}
      <div
        style={{
          position: "absolute",
          left: WINDOW_LEFT + TASKS.left,
          top: WINDOW_TOP + TASKS.top,
          width: TASKS.width,
          height: TASKS.height,
          opacity: enter,
          translate: `${lift.x}px ${lift.y + windowShift}px`,
          scale: 1 + (ZOOM - 1) * focus,
          borderRadius: 14,
          overflow: "hidden",
          backgroundColor: color.card,
          boxShadow: `0 ${focus * 30}px ${focus * 70}px rgb(60 30 20 / ${focus * 0.16})`,
        }}
      >
        <Img
          src={staticFile("shots/note.webp")}
          style={{ position: "absolute", left: -TASKS.left, top: -TASKS.top, width: WINDOW_WIDTH, maxWidth: "none" }}
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
            left: FIRST_CHECK.x - TASKS.left - FIRST_CHECK.size / 2,
            top: FIRST_CHECK.y - TASKS.top - FIRST_CHECK.size / 2,
            width: FIRST_CHECK.size,
            height: FIRST_CHECK.size,
            borderRadius: "50%",
            backgroundColor: color.accent,
            scale: tick,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <svg width={FIRST_CHECK.size * 0.62} height={FIRST_CHECK.size * 0.62} viewBox="0 0 24 24" fill="none">
            <path d="M5 12.5l4.5 4.5L19 7.5" stroke="white" strokeWidth={3.2} strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </div>
      </div>
      <AbsoluteFill style={{ alignItems: "center", paddingTop: 120, opacity: focus }}>
        <SpokenLine line={note} fromWord={8} toWord={12} gradientFrom={8} fontSize={96} fontWeight={680} textAlign="center" maxWidth={1700} textColor={color.ink} />
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${note.take.file}`)} from={note.from} />
      <Audio src={staticFile("sfx/mouse-click.wav")} from={Math.round(tickAt)} volume={0.5} />
    </AbsoluteFill>
  );
};
