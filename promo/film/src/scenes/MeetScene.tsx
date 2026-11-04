import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { Orb } from "../components/Orb";
import { SpokenLine } from "../components/SpokenLine";
import { useVoiceLevel } from "../components/useVoiceLevel";
import { lineIn } from "../timeline";

const ORB_SIZE = 560;

/** The product appears: the app's record orb rises in 3D and the name is said. */
export const MeetScene: React.FC = () => {
  const frame = useCurrentFrame();
  const meet = lineIn("meet", "meet");
  const level = useVoiceLevel(meet);
  const rise = interpolate(frame, [0, 26], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 14, mass: 0.8 }),
  });
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 10 }}>
        <div style={{ position: "relative", width: ORB_SIZE, height: ORB_SIZE, marginTop: -60, translate: `0px ${Math.sin(frame / 22) * 8}px` }}>
          <div
            style={{
              position: "absolute",
              left: "50%",
              bottom: 70,
              width: 260,
              height: 40,
              translate: "-50% 0px",
              borderRadius: "50%",
              background: "radial-gradient(closest-side, rgb(120 50 30 / 0.22), transparent)",
              opacity: rise,
            }}
          />
          <Orb size={ORB_SIZE} scale={rise * (0.9 + level * 0.08)} spin={frame / 40} />
        </div>
        <div style={{ marginTop: -70, display: "flex", flexDirection: "column", alignItems: "center", gap: 18 }}>
          <SpokenLine
            line={meet}
            fromWord={0}
            toWord={2}
            gradientFrom={1}
            fontSize={132}
            fontWeight={700}
            textAlign="center"
            maxWidth={1600}
            textColor={color.ink}
          />
          <SpokenLine
            line={meet}
            fromWord={2}
            toWord={8}
            gradientFrom={8}
            fontSize={52}
            fontWeight={500}
            textAlign="center"
            maxWidth={1600}
            textColor={color.muted}
          />
        </div>
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${meet.take.file}`)} from={meet.from} />
    </AbsoluteFill>
  );
};
