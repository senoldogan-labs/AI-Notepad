import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { color, fontFamily } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { type Format, useFormat } from "../components/format";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, sceneDuration, wordFrame, wordsFor } from "../timeline";

/** live.webp is 840×1280 px; the transcript body sits between the header and the footer. */
const PANEL_SOURCE_WIDTH = 840;
const PANEL_WIDTH = 600;
const PANEL_SCALE = PANEL_WIDTH / PANEL_SOURCE_WIDTH;
const BODY_TOP = 100 * PANEL_SCALE;
const BODY_BOTTOM = 1190 * PANEL_SCALE;
/** Source rows in live.webp: Speaker 1 in Finnish with its English line, then your reply. */
const CROP = { left: 24, top: 280, width: 792, height: 310 };
const REPLY_TOP = 505 - CROP.top;

type LiveLayout = {
  readonly headline: { readonly top: number | "center"; readonly left: number; readonly big: number; readonly small: number; readonly width: number };
  /** The panel's right edge and vertical centre. */
  readonly panel: { readonly right: number; readonly centerY: number };
  readonly zoom: number;
  readonly zoomCenterY: number;
  readonly chipFrom: { readonly right: number; readonly top: number };
  readonly chipTo: { readonly right: number; readonly top: number };
};

const LAYOUT: Record<Format, LiveLayout> = {
  landscape: {
    headline: { top: "center", left: 170, big: 100, small: 68, width: 900 },
    panel: { right: 230, centerY: 540 },
    zoom: 1.75,
    zoomCenterY: 570,
    chipFrom: { right: 790, top: 300 },
    chipTo: { right: 250, top: 150 },
  },
  portrait: {
    headline: { top: 170, left: 80, big: 96, small: 64, width: 920 },
    panel: { right: 240, centerY: 1200 },
    zoom: 1.27,
    zoomCenterY: 1060,
    chipFrom: { right: 560, top: 700 },
    chipTo: { right: 60, top: 760 },
  },
};

/** During the meeting: the panel fills in live, then the translated exchange comes up close enough to read. */
export const LiveScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  const layout = LAYOUT[useFormat()];
  const live = lineIn("live", "live");
  const translatedWord = wordsFor("live")[4];
  if (translatedWord === undefined) {
    throw new Error('Line "live" has no word 4 ("Translated").');
  }
  const translatedAt = wordFrame(live, translatedWord);
  const zoomAt = live.from + live.durationInFrames + 4;
  const end = sceneDuration("live");
  const revealed = interpolate(frame, [4, zoomAt], [0.12, 1], {
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
  const zoom = interpolate(frame, [zoomAt, zoomAt + 22], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.65, 0, 0.35, 1),
  });
  const reply = interpolate(frame, [zoomAt + 30, zoomAt + 42], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const chip = interpolate(frame, [translatedAt - 2, translatedAt + 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.spring({ damping: 13 }),
  });
  const cardWidth = CROP.width * PANEL_SCALE * (1 + (layout.zoom / PANEL_SCALE - 1) * zoom);
  const cardScale = cardWidth / CROP.width;
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <AbsoluteFill
        style={{
          justifyContent: layout.headline.top === "center" ? "center" : "flex-start",
          paddingTop: layout.headline.top === "center" ? 0 : layout.headline.top,
          paddingLeft: layout.headline.left,
          opacity: 1 - zoom,
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <SpokenLine line={live} fromWord={0} toWord={2} emphasisFrom={8} fontSize={layout.headline.big} fontWeight={680} textAlign="left" maxWidth={layout.headline.width} textColor={color.ink} />
          <SpokenLine line={live} fromWord={2} toWord={4} emphasisFrom={8} fontSize={layout.headline.big} fontWeight={680} textAlign="left" maxWidth={layout.headline.width} textColor={color.ink} />
          <div style={{ height: 30 }} />
          <SpokenLine line={live} fromWord={4} toWord={8} emphasisFrom={8} fontSize={layout.headline.small} fontWeight={620} textAlign="left" maxWidth={layout.headline.width} textColor={color.muted} />
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ perspective: 1800, opacity: 1 - zoom }}>
        <div
          style={{
            position: "absolute",
            right: layout.panel.right,
            top: layout.panel.centerY,
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
      </AbsoluteFill>
      {/* Close-up: the exchange lifts out of the panel and fills the frame. */}
      <div
        style={{
          position: "absolute",
          left: width / 2 - cardWidth / 2 + (1 - zoom) * 330,
          top: layout.zoomCenterY - (CROP.height * cardScale) / 2,
          width: cardWidth,
          height: CROP.height * cardScale,
          opacity: zoom,
          borderRadius: 28,
          overflow: "hidden",
          backgroundColor: color.card,
          boxShadow: "0 40px 100px rgb(60 30 20 / 0.18)",
        }}
      >
        <Img
          src={staticFile("shots/live.webp")}
          style={{ position: "absolute", left: -CROP.left * cardScale, top: -CROP.top * cardScale, width: PANEL_SOURCE_WIDTH * cardScale, maxWidth: "none" }}
        />
        <div
          style={{
            position: "absolute",
            left: 10 * cardScale,
            right: 10 * cardScale,
            top: REPLY_TOP * cardScale,
            bottom: 6 * cardScale,
            borderRadius: 16,
            border: `3px solid ${color.accent}`,
            backgroundColor: `${color.accent}12`,
            opacity: reply,
          }}
        />
      </div>
      <div
        style={{
          position: "absolute",
          right: interpolate(zoom, [0, 1], [layout.chipFrom.right, layout.chipTo.right]),
          top: interpolate(zoom, [0, 1], [layout.chipFrom.top, layout.chipTo.top]),
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
      <Audio src={staticFile(`vo/${live.take.file}`)} from={live.from} />
      <Audio src={staticFile("sfx/mouse-click.wav")} from={Math.min(zoomAt + 30, end - 1)} volume={0.35} />
    </AbsoluteFill>
  );
};
