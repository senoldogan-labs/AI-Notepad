import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color, fontFamily } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { type Format, useFormat } from "../components/format";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, sceneDuration, wordFrame, wordsFor } from "../timeline";

const SIZES: Record<Format, { readonly name: number; readonly tagline: number; readonly pill: number; readonly terms: number; readonly width: number; readonly breakTerms: boolean }> = {
  landscape: { name: 150, tagline: 70, pill: 50, terms: 40, width: 1600, breakTerms: false },
  portrait: { name: 140, tagline: 66, pill: 42, terms: 34, width: 900, breakTerms: true },
};

/** Close: the app icon, the promise, and where to try it (terms as on gistsmith.com/pricing). */
export const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const size = SIZES[useFormat()];
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
      <AbsoluteFill
        style={{
          alignItems: "center",
          justifyContent: "center",
          perspective: 1200,
          // Slow push-in so the end card never reads as a frozen frame.
          scale: interpolate(frame, [0, sceneDuration("cta")], [1, 1.035]),
        }}
      >
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
        <SpokenLine line={cta} fromWord={0} toWord={1} emphasisFrom={1} fontSize={size.name} fontWeight={720} textAlign="center" maxWidth={size.width} textColor={color.ink} />
        <div style={{ marginTop: 6 }}>
          <SpokenLine line={cta} fromWord={1} toWord={6} emphasisFrom={3} fontSize={size.tagline} fontWeight={600} textAlign="center" maxWidth={size.width} textColor={color.ink} />
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
          <SpokenLine line={cta} fromWord={6} toWord={11} emphasisFrom={11} fontSize={size.pill} fontWeight={600} textAlign="center" maxWidth={size.width} textColor={color.bg} />
        </div>
        <div
          style={{
            marginTop: 34,
            opacity: fine,
            fontFamily,
            fontSize: size.terms,
            maxWidth: size.width,
            fontWeight: 500,
            textAlign: "center",
            color: color.muted,
            letterSpacing: "-0.01em",
          }}
        >
          3 meetings or 7 days free · <span style={{ color: color.ink, fontWeight: 600 }}>No credit card</span>
          {size.breakTerms ? <br /> : " · "}
          macOS 15 or later on Apple silicon
        </div>
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${cta.take.file}`)} from={cta.from} />
    </AbsoluteFill>
  );
};
