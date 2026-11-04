import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color, fontFamily } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, wordFrame, wordsFor } from "../timeline";

/** Close: the app icon, the promise, and where to try it (terms as on gistsmith.com/pricing). */
export const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const cta = lineIn("cta", "cta");
  const words = wordsFor("cta");
  const tryWord = words[6];
  const urlWord = words[10];
  if (tryWord === undefined || urlWord === undefined) {
    throw new Error('Line "cta" needs 11 words ("… Try it free at gistsmith.com").');
  }
  const pillAt = wordFrame(cta, tryWord) - 4;
  const fineAt = wordFrame(cta, urlWord) + 18;
  const icon = interpolate(frame, [0, 30], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 13, mass: 0.9 }),
  });
  const pill = interpolate(frame, [pillAt, pillAt + 14], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 14 }),
  });
  const fine = interpolate(frame, [fineAt, fineAt + 16], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", perspective: 1200 }}>
        <Img
          src={staticFile("icon.png")}
          style={{
            width: 210,
            height: 210,
            scale: 0.6 + icon * 0.4,
            opacity: Math.min(icon * 1.4, 1),
            rotate: `x ${(1 - icon) * 50}deg`,
            filter: "drop-shadow(0 26px 40px rgb(10 10 10 / 0.22))",
            marginBottom: 28,
          }}
        />
        <SpokenLine line={cta} fromWord={0} toWord={1} gradientFrom={1} fontSize={150} fontWeight={720} textAlign="center" maxWidth={1600} textColor={color.ink} />
        <div style={{ marginTop: 6 }}>
          <SpokenLine line={cta} fromWord={1} toWord={6} gradientFrom={3} fontSize={70} fontWeight={600} textAlign="center" maxWidth={1600} textColor={color.ink} />
        </div>
        <div
          style={{
            marginTop: 54,
            scale: 0.85 + pill * 0.15,
            opacity: pill,
            padding: "26px 52px 22px",
            borderRadius: 999,
            backgroundColor: color.ink,
            boxShadow: "0 20px 50px rgb(10 10 10 / 0.22)",
          }}
        >
          <SpokenLine line={cta} fromWord={6} toWord={11} gradientFrom={11} fontSize={50} fontWeight={600} textAlign="center" maxWidth={1400} textColor={color.bg} />
        </div>
        <div
          style={{
            marginTop: 34,
            opacity: fine,
            fontFamily,
            fontSize: 32,
            fontWeight: 500,
            color: color.muted,
            letterSpacing: "-0.01em",
          }}
        >
          3 meetings or 7 days free · No credit card · macOS 15 or later on Apple silicon
        </div>
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${cta.take.file}`)} from={cta.from} />
    </AbsoluteFill>
  );
};
