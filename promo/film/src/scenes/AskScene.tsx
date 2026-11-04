import { Audio } from "@remotion/media";
import { AbsoluteFill, Easing, interpolate, staticFile, useCurrentFrame } from "remotion";
import { color } from "../brand";
import { AppWindow } from "../components/AppWindow";
import { Backdrop } from "../components/Backdrop";
import { SpokenLine } from "../components/SpokenLine";
import { lineIn, wordFrame, wordsFor } from "../timeline";

/** ask.webp is 1880×1224; positions below are in its 1200-wide coordinates. */
const WINDOW_WIDTH = 1200;
const K = WINDOW_WIDTH / 1200;
const QUESTION = { left: 740 * K, top: 155 * K, width: 430 * K, height: 70 * K };
const ANSWER = { left: 320 * K, top: 225 * K, width: 860 * K, height: 340 * K };

/** Any time later: a question across all meetings, answered with sources. */
export const AskScene: React.FC = () => {
  const frame = useCurrentFrame();
  const ask = lineIn("ask", "ask");
  const words = wordsFor("ask");
  const askWord = words[2];
  const answersWord = words[3];
  if (askWord === undefined || answersWord === undefined) {
    throw new Error('Line "ask" needs at least 4 words ("Later, just ask. Answers …").');
  }
  const questionAt = wordFrame(ask, askWord) - 4;
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
  const answer = interpolate(frame, [answerAt, answerAt + 50], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.inOut(Easing.quad),
  });
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <AbsoluteFill style={{ alignItems: "center", paddingTop: 90 }}>
        <SpokenLine line={ask} fromWord={0} toWord={3} gradientFrom={10} fontSize={80} fontWeight={660} textAlign="center" maxWidth={1700} textColor={color.ink} />
        <SpokenLine line={ask} fromWord={3} toWord={10} gradientFrom={3} fontSize={80} fontWeight={660} textAlign="center" maxWidth={1700} textColor={color.ink} />
      </AbsoluteFill>
      <div
        style={{
          position: "absolute",
          left: (1920 - WINDOW_WIDTH) / 2,
          top: 345,
          width: WINDOW_WIDTH,
          opacity: enter,
          translate: `0px ${(1 - enter) * 160}px`,
        }}
      >
        <AppWindow file="shots/ask.webp" width={WINDOW_WIDTH} radius={22} />
        <div
          style={{
            position: "absolute",
            left: QUESTION.left,
            top: QUESTION.top,
            width: QUESTION.width,
            height: QUESTION.height,
            backgroundColor: color.card,
            opacity: 1 - question,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: ANSWER.left,
            width: ANSWER.width,
            top: ANSWER.top + ANSWER.height * answer,
            height: ANSWER.height * (1 - answer),
            background: `linear-gradient(to bottom, rgb(255 255 255 / 0) 0px, ${color.card} 40px)`,
          }}
        />
      </div>
      <Audio src={staticFile(`vo/${ask.take.file}`)} from={ask.from} />
    </AbsoluteFill>
  );
};
