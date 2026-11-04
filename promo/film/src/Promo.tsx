import { Audio } from "@remotion/media";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { Fragment } from "react";
import { AbsoluteFill, interpolate, staticFile } from "remotion";
import { AskScene } from "./scenes/AskScene";
import { CtaScene } from "./scenes/CtaScene";
import { HookScene } from "./scenes/HookScene";
import { ListensScene } from "./scenes/ListensScene";
import { LiveScene } from "./scenes/LiveScene";
import { MeetScene } from "./scenes/MeetScene";
import { NoteScene } from "./scenes/NoteScene";
import {
  SCENE_ORDER,
  type SceneId,
  sceneDuration,
  sceneStarts,
  TRANSITION_FRAMES,
  totalDuration,
  voiceSpans,
} from "./timeline";

export const SCENE_COMPONENTS: Record<SceneId, React.FC> = {
  hook: HookScene,
  meet: MeetScene,
  listens: ListensScene,
  live: LiveScene,
  note: NoteScene,
  ask: AskScene,
  cta: CtaScene,
};

/** Music level with the voice speaking, and in the gaps between lines. */
const MUSIC_UNDER_VOICE = 0.16;
const MUSIC_IN_GAPS = 0.34;
const DUCK_FRAMES = 8;
/** Scenes whose entrance gets a whoosh; the other cuts stay quiet. */
const WHOOSH_SCENES: readonly SceneId[] = ["meet", "ask"];

/** 0 far from any voiceover line, 1 inside one, with a short ramp on both sides. */
const voicePresence = (frame: number, spans: readonly (readonly [number, number])[]): number =>
  spans.reduce((presence, [start, end]) => {
    const distance = frame < start ? start - frame : frame > end ? frame - end : 0;
    return Math.max(presence, 1 - Math.min(distance / DUCK_FRAMES, 1));
  }, 0);

/** The finished ad: seven scenes with crossfades, a CC0 music track ducked under the voice, two whooshes. */
export const Promo: React.FC = () => {
  const total = totalDuration();
  const spans = voiceSpans();
  const starts = sceneStarts();
  return (
    <AbsoluteFill>
      <TransitionSeries>
        {SCENE_ORDER.map((scene, index) => {
          const Scene = SCENE_COMPONENTS[scene];
          return (
            <Fragment key={scene}>
              {index > 0 ? (
                <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: TRANSITION_FRAMES })} />
              ) : null}
              <TransitionSeries.Sequence name={scene} durationInFrames={sceneDuration(scene)}>
                <Scene />
              </TransitionSeries.Sequence>
            </Fragment>
          );
        })}
      </TransitionSeries>
      <Audio
        src={staticFile("music/advertime.mp3")}
        volume={(f) =>
          interpolate(voicePresence(f, spans), [0, 1], [MUSIC_IN_GAPS, MUSIC_UNDER_VOICE]) *
          interpolate(f, [0, 12, total - 40, total], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
        }
      />
      {SCENE_ORDER.filter((scene) => WHOOSH_SCENES.includes(scene)).map((scene) => (
        <Audio key={scene} src={staticFile("sfx/whoosh.wav")} from={(starts[SCENE_ORDER.indexOf(scene)] ?? 0) - 6} volume={0.12} />
      ))}
    </AbsoluteFill>
  );
};
