import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color, fontFamily } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, sceneDuration, wordFrame, wordsFor } from "../timeline";

/** live.webp is 840×1280; the transcript body sits between the header and the footer. */
const PANEL_WIDTH = 600;
const PANEL_SCALE = PANEL_WIDTH / 840;
const BODY_TOP = 100 * PANEL_SCALE;
const BODY_BOTTOM = 1110 * PANEL_SCALE;

/** During the meeting: the live panel fills in sentence by sentence, with the translation under each line. */
export const LiveScene: React.FC = () => {
  const frame = useCurrentFrame();
  const live = lineIn("live", "live");
  const translatedWord = wordsFor("live")[4];
  if (translatedWord === undefined) {
    throw new Error('Line "live" has no word 4 ("Translated").');
  }
  const translatedAt = wordFrame(live, translatedWord);
  const end = sceneDuration("live");
  const revealed = interpolate(frame, [4, end - 20], [0.12, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.inOut(Easing.quad),
  });
  const coverTop = BODY_TOP + (BODY_BOTTOM - BODY_TOP) * revealed;
  const enter = interpolate(frame, [0, 24], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const chip = interpolate(frame, [translatedAt - 2, translatedAt + 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 13 }),
  });
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <AbsoluteFill style={{ justifyContent: "center", paddingLeft: 170 }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <SpokenLine line={live} fromWord={0} toWord={2} gradientFrom={8} fontSize={100} fontWeight={680} textAlign="left" maxWidth={900} textColor={color.ink} />
          <SpokenLine line={live} fromWord={2} toWord={4} gradientFrom={8} fontSize={100} fontWeight={680} textAlign="left" maxWidth={900} textColor={color.ink} />
          <div style={{ height: 30 }} />
          <SpokenLine line={live} fromWord={4} toWord={8} gradientFrom={4} fontSize={68} fontWeight={620} textAlign="left" maxWidth={900} textColor={color.ink} />
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ perspective: 1800 }}>
        <div
          style={{
            position: "absolute",
            right: 230,
            top: 540,
            translate: `0px calc(-50% + ${(1 - enter) * 120}px)`,
            opacity: enter,
            rotate: `y ${-14 + enter * 6 - frame * 0.03}deg`,
            width: PANEL_WIDTH,
            borderRadius: 26,
            overflow: "hidden",
            backgroundColor: color.card,
            border: `1px solid ${color.line}`,
            boxShadow: "0 2px 4px rgb(10 10 10 / 0.04), 0 40px 90px rgb(60 30 20 / 0.16)",
          }}
        >
          <Img src={staticFile("shots/live.webp")} style={{ display: "block", width: "100%" }} />
          <div
            style={{
              position: "absolute",
              left: 0,
              right: 0,
              top: coverTop,
              height: Math.max(BODY_BOTTOM - coverTop, 0),
              background: "linear-gradient(to bottom, rgb(252 252 252 / 0) 0px, #fcfcfc 36px)",
            }}
          />
        </div>
        <div
          style={{
            position: "absolute",
            right: 790,
            top: 300,
            scale: chip,
            opacity: chip,
            display: "flex",
            alignItems: "center",
            gap: 14,
            padding: "18px 28px",
            borderRadius: 999,
            backgroundColor: color.ink,
            color: color.bg,
            fontFamily,
            fontSize: 34,
            fontWeight: 600,
            letterSpacing: "-0.01em",
            boxShadow: "0 16px 40px rgb(10 10 10 / 0.18)",
          }}
        >
          Finnish <span style={{ color: color.peach }}>→</span> English
        </div>
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${live.take.file}`)} from={live.from} />
    </AbsoluteFill>
  );
};
