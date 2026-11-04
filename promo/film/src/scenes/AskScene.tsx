import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { color } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { type Format, useFormat } from "../components/format";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, wordFrame, wordsFor } from "../timeline";

/** ask.webp is 1880×1224 px. Only the conversation pane is shown, without the sidebar, at a readable size. */
const SOURCE_WIDTH = 1880;
const PANE = { left: 500, top: 232, width: 1342, height: 650 };
type AskLayout = {
  readonly cardWidth: number;
  readonly cardTop: number;
  readonly headlineTop: number;
  readonly headline: number;
  readonly textWidth: number;
};

const LAYOUT: Record<Format, AskLayout> = {
  landscape: { cardWidth: 1480, cardTop: 338, headlineTop: 80, headline: 78, textWidth: 1700 },
  portrait: { cardWidth: 1020, cardTop: 700, headlineTop: 220, headline: 80, textWidth: 960 },
};
/** In pane coordinates (source px minus the pane origin). */
const QUESTION = { left: 1160 - PANE.left, top: 250 - PANE.top, width: 650, height: 110 };
const ANSWER = { top: 360 - PANE.top, height: 520 };

/** Any time later: a question across all meetings, answered with sources. */
export const AskScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { width } = useVideoConfig();
  const layout = LAYOUT[useFormat()];
  const K = layout.cardWidth / PANE.width;
  const ask = lineIn("ask", "ask");
  const words = wordsFor("ask");
  const laterWord = words[0];
  const answersWord = words[3];
  if (laterWord === undefined || answersWord === undefined) {
    throw new Error('Line "ask" needs at least 4 words ("Later, just ask. Answers …").');
  }
  const questionAt = wordFrame(ask, laterWord) + 6;
  const answerAt = wordFrame(ask, answersWord);
  const enter = interpolate(frame, [0, 26], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const question = interpolate(frame, [questionAt, questionAt + 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const answer = interpolate(frame, [answerAt, answerAt + 54], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.inOut(Easing.quad),
  });
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: layout.headlineTop }}>
        <SpokenLine line={ask} fromWord={0} toWord={3} emphasisFrom={10} fontSize={layout.headline} fontWeight={660} textAlign="center" maxWidth={layout.textWidth} textColor={color.ink} />
        <SpokenLine line={ask} fromWord={3} toWord={10} emphasisFrom={10} fontSize={layout.headline} fontWeight={660} textAlign="center" maxWidth={layout.textWidth} textColor={color.ink} />
      </AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: (width - layout.cardWidth) / 2,
          top: layout.cardTop,
          width: layout.cardWidth,
          height: PANE.height * K,
          opacity: enter,
          translate: `0px ${(1 - enter) * 140}px`,
          scale: 1 + answer * 0.03,
          borderRadius: 30,
          overflow: "hidden",
          backgroundColor: color.card,
          border: `1px solid ${color.line}`,
          boxShadow: "0 30px 90px rgb(60 30 20 / 0.16)",
        }}
      >
        <Img
          src={staticFile("shots/ask.webp")}
          style={{ position: "absolute", left: -PANE.left * K, top: -PANE.top * K, width: SOURCE_WIDTH * K, maxWidth: "none" }}
        />
        <div
          style={{
            position: "absolute",
            left: QUESTION.left * K,
            top: QUESTION.top * K,
            width: QUESTION.width * K,
            height: QUESTION.height * K,
            backgroundColor: color.card,
            opacity: 1 - question,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: 0,
            right: 0,
            top: (ANSWER.top + ANSWER.height * answer) * K - 40,
            height: ANSWER.height * (1 - answer) * K + 60,
            background: `linear-gradient(to bottom, rgb(255 255 255 / 0) 0px, ${color.card} 40px)`,
          }}
        />
      </div>
      <Audio src={staticFile(`vo/${ask.take.file}`)} from={ask.from} />
    </AbsoluteFill>
  );
};
