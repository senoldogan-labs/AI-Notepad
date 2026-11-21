import { Easing, interpolate } from "remotion";

/**
 * The "Voice type without switching apps" film: frame numbers (30 fps) of each part and the pure functions that turn a
 * frame into what the phone shows (`PhoneState`). The words are the website's iPhone voice typing demo
 * (web/src/copy.ts `phoneVoiceDemo.dictatedLines`).
 */
export const VOICE_FPS = 30;

/** Hook, Before (the old round trip through the app), After (dictation in the keyboard), end card. */
export const HOOK_START = 0;
export const BEFORE_START = 66;
export const AFTER_START = 216;
export const END_START = 426;
export const VOICE_TOTAL = 516;
/** How long the parts cross-fade into each other. */
export const CROSS = 12;

/** The web loop: the After part alone, ending where it starts (empty field, keys up). */
export const LOOP_TOTAL = 204;

/** The dictated reply, by line in the message field (as the website's demo wraps it at 17 pt). */
export const DICTATED_LINES: readonly (readonly string[])[] = [
  ["Running", "10", "minutes", "late", "—", "start"],
  ["without", "me,", "I'll", "catch", "up", "on", "the"],
  ["notes", "in", "Gistsmith."],
];
export const DICTATED_WORDS: readonly string[] = DICTATED_LINES.flat();
const NEVER = Number.POSITIVE_INFINITY;

/** A finger tap on the screen, in screen points (440 × 956), and how far its short life has run (0…1). */
export type Touch = {
  readonly x: number;
  readonly y: number;
  readonly progress: number;
};

/** Everything the drawn phone needs for one frame. */
export type PhoneState = {
  /** Film frame, for the always-moving bits (caret blink, finish pulse). */
  readonly frame: number;
  /** 0: the messaging app; 1: the Gistsmith app has taken the screen. */
  readonly appShift: number;
  /** The Gistsmith app's "Microphone ready" card (0…1). */
  readonly handoffCard: number;
  /** The system "◀ Messages" back link in the status bar (0…1). */
  readonly backLink: number;
  /** The Dynamic Island's warm-microphone Live Activity (0…1). */
  readonly islandWarm: number;
  /** 0: keys; 1: the dictation panel in their place. */
  readonly panel: number;
  /** Opacity of each dictated word in the message field. */
  readonly words: readonly number[];
  /** The underline of live (marked) text, 0…1. */
  readonly marked: number;
  /** Fades the whole reply (for the loop's reset), 0…1. */
  readonly replyOpacity: number;
  /** The 28 waveform bar levels, oldest (left) to newest (right), 0…1. */
  readonly levels: readonly number[];
  /** Pressed highlight on the "Voice type" capsule, 0…1. */
  readonly voicePress: number;
  readonly touches: readonly Touch[];
};

const easeOut = Easing.bezier(0.22, 1, 0.36, 1);

/** 0 → 1 between `start` and `start + duration`, eased, clamped. Pure function. */
export const ramp = (frame: number, start: number, duration: number): number =>
  interpolate(frame, [start, start + duration], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOut });

/** Rises over `rise` frames from `start`, holds, falls over `fall` frames from `end`. Pure function. */
export const window01 = (frame: number, start: number, rise: number, end: number, fall: number): number =>
  ramp(frame, start, rise) * (1 - ramp(frame, end, fall));

/** Appear frames of each word: bursts of `[start, count]`, three frames apart inside a burst; later words never. */
const burstFrames = (bursts: readonly (readonly [number, number])[]): readonly number[] => {
  const frames: readonly number[] = bursts.flatMap(([start, count]: readonly [number, number]): readonly number[] =>
    Array.from({ length: count }, (_: unknown, index: number): number => start + index * 3),
  );
  return DICTATED_WORDS.map((_: string, index: number): number => frames[index] ?? NEVER);
};

const AFTER_WORDS: readonly number[] = burstFrames([
  [40, 3],
  [56, 3],
  [74, 2],
  [90, 3],
  [108, 3],
  [124, 2],
]);
/** Before: the first words only, slow to arrive after the round trip. */
const BEFORE_WORDS: readonly number[] = burstFrames([
  [124, 3],
  [138, 3],
]);

const wordOpacities = (frame: number, appear: readonly number[]): readonly number[] =>
  appear.map((at: number): number => (Number.isFinite(at) ? ramp(frame, at, 5) : 0));

/** A tap's life: 4 frames in, 10 out. Pure function. */
const tapAt = (frame: number, at: number, x: number, y: number): readonly Touch[] =>
  frame >= at - 4 && frame <= at + 10 ? [{ x, y, progress: (frame - at + 4) / 14 }] : [];

/** Loudness of the voice (0…1) around the moments words arrive: speech leads the text by a few frames. */
const speaking = (frame: number, appear: readonly number[]): number =>
  appear.reduce((loudest: number, at: number): number => {
    const distance: number = Math.abs(frame - (at - 4));
    return Math.max(loudest, Math.max(0, 1 - distance / 11));
  }, 0);

/** Syllable-like flutter, deterministic. Pure function. */
const flutter = (frame: number): number => {
  const slow: number = 0.5 + 0.5 * Math.sin(frame * 0.53) * Math.sin(frame * 0.21 + 1.3);
  const fast: number = 0.5 + 0.5 * Math.sin(frame * 1.37 + Math.sin(frame * 0.31) * 2);
  return 0.35 * slow + 0.65 * fast;
};

/** 28 bars, newest on the right, scrolling left (KeyboardWaveform with the keyboard's own levels). Pure function. */
export const waveLevels = (frame: number, appear: readonly number[]): readonly number[] =>
  Array.from({ length: 28 }, (_: unknown, index: number): number => {
    const at: number = frame - (27 - index) * 1.6;
    const voice: number = Math.min(1, speaking(at, appear) * 1.25);
    return Math.min(1, 0.03 + voice * (0.25 + 0.75 * flutter(at)) + 0.05 * flutter(at * 1.7 + 9));
  });

/** Screen points of the things a finger taps. */
export const TAP = {
  voice: { x: 262, y: 636 },
  finish: { x: 406, y: 646 },
  backLink: { x: 52, y: 32 },
} as const;

/** Before, local frame `b` (0 at BEFORE_START): tap → the app opens → back → tap again → slow dictation. Pure function. */
export const beforeState = (b: number, frame: number): PhoneState => ({
  frame,
  appShift: ramp(b, 20, 14) - ramp(b, 70, 14),
  handoffCard: window01(b, 34, 8, 70, 6),
  backLink: window01(b, 30, 6, 70, 4),
  islandWarm: ramp(b, 32, 8),
  panel: ramp(b, 108, 10),
  words: wordOpacities(b, BEFORE_WORDS),
  marked: 1,
  replyOpacity: 1,
  levels: waveLevels(b, BEFORE_WORDS),
  voicePress: window01(b, 14, 2, 19, 5) + window01(b, 102, 2, 107, 5),
  touches: [...tapAt(b, 16, TAP.voice.x, TAP.voice.y), ...tapAt(b, 66, TAP.backLink.x, TAP.backLink.y), ...tapAt(b, 104, TAP.voice.x, TAP.voice.y)],
});

/** App switches counted so far in Before (the app opens, then the way back). Pure function. */
export const beforeSwitches = (b: number): number => (b >= 26 ? 1 : 0) + (b >= 76 ? 1 : 0);

/** After, local frame `a` (0 at AFTER_START): tap → the panel replaces the keys → words stream in → ✓ → keys back. */
export const afterState = (a: number, frame: number): PhoneState => ({
  frame,
  appShift: 0,
  handoffCard: 0,
  backLink: 0,
  islandWarm: 0,
  panel: window01(a, 20, 10, 150, 12),
  words: wordOpacities(a, AFTER_WORDS),
  marked: 1 - ramp(a, 150, 8),
  replyOpacity: 1,
  levels: waveLevels(a, AFTER_WORDS),
  voicePress: window01(a, 16, 2, 21, 5),
  touches: [...tapAt(a, 18, TAP.voice.x, TAP.voice.y), ...tapAt(a, 146, TAP.finish.x, TAP.finish.y)],
});

/** The web loop: After, then the reply fades so the last frame meets the first. Pure function. */
export const loopState = (a: number): PhoneState => ({
  ...afterState(a, a),
  replyOpacity: 1 - ramp(a, LOOP_TOTAL - 18, 14),
});
