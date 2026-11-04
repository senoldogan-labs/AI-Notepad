import { Audio } from "@remotion/media";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { slide } from "@remotion/transitions/slide";
import { Fragment } from "react";
import { AbsoluteFill, interpolate, staticFile } from "remotion";
import { AskScene } from "./scenes/AskScene";
import { CtaScene } from "./scenes/CtaScene";
import { HookScene } from "./scenes/HookScene";
import { ListensScene } from "./scenes/ListensScene";
import { LiveScene } from "./scenes/LiveScene";
import { MeetScene } from "./scenes/MeetScene";
import { NoteScene } from "./scenes/NoteScene";
import { SCENE_ORDER, type SceneId, sceneDuration, TRANSITION_FRAMES, totalDuration } from "./timeline";

export const SCENE_COMPONENTS: Record<SceneId, React.FC> = {
  hook: HookScene,
  meet: MeetScene,
  listens: ListensScene,
  live: LiveScene,
  note: NoteScene,
  ask: AskScene,
  cta: CtaScene,
};

/** Start frame of each scene in the finished film (transitions overlap neighbours). */
const sceneStarts = (): readonly number[] =>
  SCENE_ORDER.reduce<readonly number[]>(
    (starts, scene, index) => (index === 0 ? [0] : [...starts, (starts[index - 1] ?? 0) + sceneDuration(SCENE_ORDER[index - 1] ?? scene) - TRANSITION_FRAMES]),
    [],
  );

/** The finished ad: seven scenes, crossfades and slides between them, a soft music bed and transition whooshes. */
export const Promo: React.FC = () => {
  const total = totalDuration();
  return (
    <AbsoluteFill>
      <TransitionSeries>
        {SCENE_ORDER.map((scene, index) => {
          const Scene = SCENE_COMPONENTS[scene];
          return (
            <Fragment key={scene}>
              {index > 0 ? (
                <TransitionSeries.Transition
                  presentation={index % 2 === 0 ? fade() : slide({ direction: "from-right" })}
                  timing={linearTiming({ durationInFrames: TRANSITION_FRAMES })}
                />
              ) : null}
              <TransitionSeries.Sequence name={scene} durationInFrames={sceneDuration(scene)}>
                <Scene />
              </TransitionSeries.Sequence>
            </Fragment>
          );
        })}
      </TransitionSeries>
      <Audio
        src={staticFile("music/bed.wav")}
        volume={(f) => interpolate(f, [0, 20, total - 45, total], [0, 0.32, 0.32, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
      />
      {sceneStarts()
        .slice(1)
        .map((start) => (
          <Audio key={start} src={staticFile("sfx/whoosh.wav")} from={start - 6} volume={0.18} />
        ))}
    </AbsoluteFill>
  );
};
