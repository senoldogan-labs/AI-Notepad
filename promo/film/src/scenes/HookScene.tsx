import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color, fontFamily } from "../brand";
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
};

/** The loose ends every meeting leaves behind. */
const FRAGMENTS: readonly Fragment[] = [
  { text: "Wait, what did we decide?", x: -620, y: -300, z: -900, tilt: -6, kind: "message", tint: "#ffffff" },
  { text: "Who's sending the deck?", x: 560, y: -330, z: -600, tilt: 5, kind: "sticky", tint: "#fbe3d6" },
  { text: "Was that Friday or Monday?", x: -700, y: 250, z: -500, tilt: 4, kind: "sticky", tint: "#ece4fb" },
  { text: "Can someone share notes?", x: 640, y: 290, z: -1100, tilt: -4, kind: "message", tint: "#ffffff" },
  { text: "Action items??", x: -180, y: -420, z: -1500, tilt: 3, kind: "sticky", tint: "#fdf0c8" },
  { text: "Sorry, I missed that.", x: 260, y: 430, z: -1400, tilt: -3, kind: "message", tint: "#ffffff" },
  { text: "Who owns the budget?", x: -880, y: -40, z: -1700, tilt: -5, kind: "message", tint: "#ffffff" },
  { text: "Did anyone write that down?", x: 860, y: 0, z: -1300, tilt: 6, kind: "sticky", tint: "#dcefe4" },
  { text: "Next steps?", x: -320, y: 380, z: -2000, tilt: 2, kind: "sticky", tint: "#fbe3d6" },
  { text: "I'll follow up… on what?", x: 380, y: -180, z: -2200, tilt: -2, kind: "message", tint: "#ffffff" },
];

const FragmentCard: React.FC<{ readonly fragment: Fragment; readonly depth: number }> = ({ fragment, depth }) => {
  const focus = Math.abs(depth + 350);
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: "50%",
        translate: `calc(-50% + ${fragment.x}px) calc(-50% + ${fragment.y}px) ${depth}px`,
        rotate: `${fragment.tilt}deg`,
        opacity: interpolate(depth, [-2400, -1700, 250, 520], [0, 1, 1, 0], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        filter: `blur(${Math.min(focus / 160, 9)}px)`,
        fontFamily,
        fontSize: 40,
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
            <FragmentCard key={fragment.text} fragment={fragment} depth={fragment.z + travel} />
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
            gradientFrom={6}
            fontSize={104}
            fontWeight={650}
            textAlign="center"
            maxWidth={1300}
            textColor={color.ink}
          />
        </div>
        <div style={{ position: "absolute", display: "flex", flexDirection: "column", alignItems: "center" }}>
          <SpokenLine
            line={question}
            fromWord={0}
            toWord={3}
            gradientFrom={3}
            fontSize={104}
            fontWeight={650}
            textAlign="center"
            maxWidth={1500}
            textColor={color.ink}
          />
          <SpokenLine
            line={question}
            fromWord={3}
            toWord={10}
            gradientFrom={3}
            fontSize={104}
            fontWeight={650}
            textAlign="center"
            maxWidth={1500}
            textColor={color.ink}
          />
        </div>
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${hook.take.file}`)} from={hook.from} />
      <Audio src={staticFile(`vo/${question.take.file}`)} from={question.from} />
    </AbsoluteFill>
  );
};
