import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color, fontFamily } from "../brand";
import { type Format, useFormat } from "../components/format";
import { Backdrop } from "../components/Backdrop";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, sceneDuration } from "../timeline";

type Fragment = {
  readonly text: string;
  readonly x: number;
  readonly y: number;
  /** Starting depth in px; negative is further away. */
  readonly z: number;
  readonly tilt: number;
  readonly kind: "message" | "sticky";
  readonly tint: string;
  /** Text size relative to the other fragments. */
  readonly size: number;
};

/** The loose ends every meeting leaves behind. */
const FRAGMENTS: readonly Fragment[] = [
  // In focus at frame 0: the thumbnail and the first thing a scrolling viewer reads.
  { text: "I'll follow up… on what?", x: 0, y: -290, z: -330, tilt: -2, kind: "message", tint: "#ffffff", size: 1.3 },
  { text: "Wait, what did we decide?", x: -640, y: 190, z: -900, tilt: -6, kind: "message", tint: "#ffffff", size: 1 },
  { text: "Who's sending the deck?", x: 600, y: 300, z: -700, tilt: 5, kind: "sticky", tint: "#fbe3d6", size: 1 },
  { text: "Was that Friday or Monday?", x: -720, y: -330, z: -1700, tilt: 4, kind: "sticky", tint: "#ece4fb", size: 1 },
  { text: "Can someone share notes?", x: 660, y: -280, z: -1150, tilt: -4, kind: "message", tint: "#ffffff", size: 1 },
  { text: "Action items??", x: -200, y: 420, z: -1500, tilt: 3, kind: "sticky", tint: "#fdf0c8", size: 1 },
  { text: "Sorry, I missed that.", x: 280, y: 440, z: -1950, tilt: -3, kind: "message", tint: "#ffffff", size: 1 },
  { text: "Who owns the budget?", x: -900, y: -20, z: -2100, tilt: -5, kind: "message", tint: "#ffffff", size: 1 },
  { text: "Did anyone write that down?", x: 880, y: 20, z: -1350, tilt: 6, kind: "sticky", tint: "#dcefe4", size: 1 },
  { text: "Next steps?", x: -360, y: -470, z: -2300, tilt: 2, kind: "sticky", tint: "#fbe3d6", size: 1 },
];

/** Portrait spreads the fragments up and down instead of sideways. */
const SPREAD: Record<Format, { readonly x: number; readonly y: number; readonly text: number; readonly headline: number; readonly width: number }> = {
  landscape: { x: 1, y: 1, text: 40, headline: 104, width: 1500 },
  portrait: { x: 0.4, y: 1.8, text: 36, headline: 92, width: 960 },
};

const FragmentCard: React.FC<{ readonly fragment: Fragment; readonly depth: number; readonly format: Format }> = ({
  fragment,
  depth,
  format,
}) => {
  const focus = Math.abs(depth + 350);
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: "50%",
        translate: `calc(-50% + ${fragment.x * SPREAD[format].x}px) calc(-50% + ${fragment.y * SPREAD[format].y}px) ${depth}px`,
        rotate: `${fragment.tilt}deg`,
        opacity: interpolate(depth, [-2400, -1700, 250, 520], [0, 1, 1, 0], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        filter: `blur(${Math.min(focus / 160, 9)}px)`,
        fontFamily,
        fontSize: SPREAD[format].text * fragment.size,
        fontWeight: fragment.kind === "sticky" ? 600 : 500,
        letterSpacing: "-0.02em",
        color: color.ink,
        whiteSpace: "nowrap",
        padding: fragment.kind === "sticky" ? "34px 40px" : "24px 34px",
        borderRadius: fragment.kind === "sticky" ? 10 : 36,
        backgroundColor: fragment.tint,
        border: `1px solid ${color.line}`,
        boxShadow: "0 18px 50px rgb(60 30 20 / 0.10)",
      }}
    >
      {fragment.text}
    </div>
  );
};

/** Opening: the questions a meeting leaves behind drift past while the voiceover asks them. */
export const HookScene: React.FC = () => {
  const frame = useCurrentFrame();
  const format = useFormat();
  const layout = SPREAD[format];
  const hook = lineIn("hook", "hook");
  const question = lineIn("hook", "question");
  const end = sceneDuration("hook");
  // Fragments drift towards the camera, then rush past as the scene ends.
  const travel =
    frame * 9 +
    interpolate(frame, [end - 30, end], [0, 900], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
      easing: Easing.in(Easing.cubic),
    });
  return (
    <AbsoluteFill>
      <Backdrop tone="neutral" />
      <AbsoluteFill style={{ perspective: 1400, perspectiveOrigin: "50% 50%" }}>
        <AbsoluteFill style={{ transformStyle: "preserve-3d" }}>
          {FRAGMENTS.map((fragment) => (
            <FragmentCard key={fragment.text} fragment={fragment} depth={fragment.z + travel} format={format} />
          ))}
        </AbsoluteFill>
      </AbsoluteFill>
      <AbsoluteFill
        style={{
          justifyContent: "center",
          alignItems: "center",
          background: "radial-gradient(42% 32% at 50% 50%, rgb(253 252 252 / 0.92) 0%, rgb(253 252 252 / 0) 100%)",
        }}
      >
        <div
          style={{
            opacity: interpolate(frame, [question.from - 6, question.from + 2], [1, 0], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }),
            position: "absolute",
          }}
        >
          <SpokenLine
            line={hook}
            fromWord={0}
            toWord={6}
            emphasisFrom={6}
            fontSize={layout.headline}
            fontWeight={650}
            textAlign="center"
            maxWidth={layout.width}
            textColor={color.ink}
          />
        </div>
        <div style={{ position: "absolute", display: "flex", flexDirection: "column", alignItems: "center" }}>
          <SpokenLine
            line={question}
            fromWord={0}
            toWord={3}
            emphasisFrom={3}
            fontSize={layout.headline}
            fontWeight={650}
            textAlign="center"
            maxWidth={layout.width}
            textColor={color.ink}
          />
          <SpokenLine
            line={question}
            fromWord={3}
            toWord={10}
            emphasisFrom={3}
            fontSize={layout.headline}
            fontWeight={650}
            textAlign="center"
            maxWidth={layout.width}
            textColor={color.ink}
          />
        </div>
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${hook.take.file}`)} from={hook.from} />
      <Audio src={staticFile(`vo/${question.take.file}`)} from={question.from} />
    </AbsoluteFill>
  );
};
