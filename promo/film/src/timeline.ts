// Import attributes let Node load this module too (scripts/laptop-frames.ts), not only the Remotion bundler.
import manifestJson from "../public/vo/manifest.json" with { type: "json" };
import wordsJson from "../public/vo/words.json" with { type: "json" };

/**
 * Scene timing is derived from the voiceover: each scene lasts as long as its lines plus a short lead-in and a
 * hold at the end, so re-generating the voice re-times the whole film. `public/vo/manifest.json` and
 * `public/vo/words.json` come from `promo/voice` (speak.py, words.py).
 */

export const FPS = 30;
export const WIDTH = 1920;
export const HEIGHT = 1080;
/** Overlap of two neighbouring scenes during a transition. */
export const TRANSITION_FRAMES = 14;
/** Pause between two voiceover lines in one scene. */
const LINE_GAP_FRAMES = 8;

export type LineId = "hook" | "question" | "meet" | "listens" | "live" | "note" | "ask" | "cta";
export type SceneId = "hook" | "meet" | "listens" | "live" | "note" | "ask" | "cta";

export type Take = {
  readonly id: LineId;
  readonly text: string;
  readonly file: string;
  readonly seconds: number;
};

export type TimedWord = {
  readonly text: string;
  readonly startMs: number;
  readonly endMs: number;
};

export type PlacedLine = {
  readonly take: Take;
  /** Frame inside the scene where the line starts. */
  readonly from: number;
  readonly durationInFrames: number;
};

type SceneSpec = {
  readonly lines: readonly LineId[];
  /** Frames before the first line. */
  readonly lead: number;
  /** Frames after the last line ends, before the transition. */
  readonly hold: number;
};

export const SCENE_ORDER: readonly SceneId[] = ["hook", "meet", "listens", "live", "note", "ask", "cta"];

const SCENES: Record<SceneId, SceneSpec> = {
  hook: { lines: ["hook", "question"], lead: 4, hold: 14 },
  meet: { lines: ["meet"], lead: 14, hold: 8 },
  listens: { lines: ["listens"], lead: 8, hold: 16 },
  live: { lines: ["live"], lead: 8, hold: 72 },
  note: { lines: ["note"], lead: 8, hold: 30 },
  ask: { lines: ["ask"], lead: 8, hold: 26 },
  cta: { lines: ["cta"], lead: 10, hold: 75 },
};

const takes: readonly Take[] = manifestJson as readonly Take[];
const words: Readonly<Record<LineId, readonly TimedWord[]>> = wordsJson as Readonly<Record<LineId, readonly TimedWord[]>>;

const takeFor = (id: LineId): Take => {
  const take = takes.find((item) => item.id === id);
  if (take === undefined) {
    throw new Error(`No voiceover take for line "${id}" in public/vo/manifest.json; run promo/voice/speak.py.`);
  }
  return take;
};

export const wordsFor = (id: LineId): readonly TimedWord[] => {
  const timed = words[id];
  if (timed === undefined) {
    throw new Error(`No word timings for line "${id}" in public/vo/words.json; run promo/voice/words.py.`);
  }
  return timed;
};

const framesOf = (seconds: number): number => Math.ceil(seconds * FPS);

export const placedLines = (scene: SceneId): readonly PlacedLine[] =>
  SCENES[scene].lines.reduce<readonly PlacedLine[]>((placed, id) => {
    const previous = placed[placed.length - 1];
    const from = previous === undefined ? SCENES[scene].lead : previous.from + previous.durationInFrames + LINE_GAP_FRAMES;
    const take = takeFor(id);
    return [...placed, { take, from, durationInFrames: framesOf(take.seconds) }];
  }, []);

const isLast = (scene: SceneId): boolean => SCENE_ORDER[SCENE_ORDER.length - 1] === scene;

/** Scene length including the frames the next scene overlaps during the transition. */
export const sceneDuration = (scene: SceneId): number => {
  const lines = placedLines(scene);
  const last = lines[lines.length - 1];
  if (last === undefined) {
    throw new Error(`Scene "${scene}" has no voiceover lines.`);
  }
  return last.from + last.durationInFrames + SCENES[scene].hold + (isLast(scene) ? 0 : TRANSITION_FRAMES);
};

/**
 * Frames of the Blender laptop render the "meet" scene plays, one per scene frame. promo/blender/render.sh reads this
 * through scripts/laptop-frames.ts, so a new voiceover take changes the render length too.
 */
export const laptopFrames = (): number => sceneDuration("meet");

export const totalDuration = (): number =>
  SCENE_ORDER.reduce((sum, scene) => sum + sceneDuration(scene), 0) - TRANSITION_FRAMES * (SCENE_ORDER.length - 1);

/** Frame inside the scene at which a given word of a line is spoken. */
export const wordFrame = (line: PlacedLine, word: TimedWord): number => line.from + (word.startMs / 1000) * FPS;

/** Start frame of each scene in the finished film (transitions overlap neighbours). */
export const sceneStarts = (): readonly number[] =>
  SCENE_ORDER.map(
    (_scene, index) =>
      SCENE_ORDER.slice(0, index).reduce((sum, previous) => sum + sceneDuration(previous), 0) - TRANSITION_FRAMES * index,
  );

/** Voiceover spans in the finished film, as [start, end) frames, for ducking the music under the voice. */
export const voiceSpans = (): readonly (readonly [number, number])[] => {
  const starts = sceneStarts();
  return SCENE_ORDER.flatMap((scene, index) =>
    placedLines(scene).map((line) => {
      const start = (starts[index] ?? 0) + line.from;
      return [start, start + line.durationInFrames] as const;
    }),
  );
};

export const lineIn = (scene: SceneId, id: LineId): PlacedLine => {
  const line = placedLines(scene).find((item) => item.take.id === id);
  if (line === undefined) {
    throw new Error(`Line "${id}" is not part of scene "${scene}".`);
  }
  return line;
};
