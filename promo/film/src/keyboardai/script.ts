import { Easing, interpolate } from "remotion";
import { type ParticleMotion, travelTable } from "./particles";
import { DARK, EMBER_COPPER, type KeyboardAccent, LIGHT, mixAccent, mixSurfaces, OLIVE_BLUE, OLIVE_LIME, OLIVE_VIOLET, type Surfaces } from "./theme";

/**
 * "Gistsmith Keyboard": a hook on the voice field, asking Gistsmith from a chat without leaving it, voice typing with
 * spoken punctuation and a list, the keyboard taking the Appearance accent, and an end card. Frame numbers at 30 fps
 * and the pure functions that turn a frame into what the phone shows (`PhoneState`). Every string the keyboard shows is
 * the app's English localization (App/Localizable.xcstrings); the dictated text and its formatted result are what
 * KeyboardCore's `keyboardFormatDictation` returns for it.
 */
export const KB_FPS = 30;

export const HOOK_START = 0;
export const ASK_START = 96;
export const VOICE_START = 396;
export const THEME_START = 646;
export const END_START = 766;
export const KB_TOTAL = 930;
export const CROSS = 14;

/** When each voiceover line starts (frames), and the frame it must have finished by (the next part's start). */
export const VO_AT: Readonly<Record<string, { readonly start: number; readonly endBy: number }>> = {
  "kb-hook": { start: 16, endBy: ASK_START },
  "kb-ask": { start: ASK_START + 50, endBy: VOICE_START },
  "kb-voice": { start: VOICE_START + 30, endBy: THEME_START },
  "kb-theme": { start: THEME_START + 8, endBy: END_START },
  "kb-cta": { start: END_START + 12, endBy: KB_TOTAL },
};

/** Raised when the voiceover files do not match the film's script (a missing line, or a take too long for its part). */
export class VoiceoverMismatchError extends Error {}

/** The start frame of voiceover line `id`; an unknown line is an error. Pure function. */
export const voStart = (id: string): number => {
  const slot = VO_AT[id];
  if (slot === undefined) {
    throw new VoiceoverMismatchError(`No voiceover slot for line ${JSON.stringify(id)}; known: ${Object.keys(VO_AT).join(", ")}`);
  }
  return slot.start;
};

/**
 * Checks the takes against the slots: every slot has a take, every take a slot, and each take ends before its part
 * does (regenerated takes can be longer). Throws `VoiceoverMismatchError` with the offending line. Pure function.
 */
export const checkVoiceover = (takes: readonly { readonly id: string; readonly seconds: number }[], words: Readonly<Record<string, readonly unknown[]>>): void => {
  const ids: readonly string[] = takes.map((take) => take.id);
  const missing: readonly string[] = Object.keys(VO_AT).filter((id: string): boolean => !ids.includes(id) || (words[id]?.length ?? 0) === 0);
  if (missing.length > 0) {
    throw new VoiceoverMismatchError(`Voiceover lines without a take or word timings: ${missing.join(", ")} (run promo/voice speak.py and words.py)`);
  }
  takes.forEach((take) => {
    const slot = VO_AT[take.id];
    if (slot === undefined) {
      throw new VoiceoverMismatchError(`Take ${JSON.stringify(take.id)} has no slot in VO_AT`);
    }
    const end: number = slot.start + Math.ceil(take.seconds * KB_FPS);
    if (end > slot.endBy) {
      throw new VoiceoverMismatchError(`Take ${JSON.stringify(take.id)} (${take.seconds}s) ends at frame ${end}, after its part ends at ${slot.endBy}`);
    }
  });
};

/** The website loop: the voice-typing part alone (silent), ending where it starts. */
export const LOOP_TOTAL = 250;

export const QUESTION = "launch date we agreed?";
export const ANSWER = "Launch is March 12. Ella confirms pricing by Friday.";
export const INCOMING_ASK = "Quick one, what did we land on for the launch date?";
export const INCOMING_VOICE = "Perfect. What's next on your side?";
/** The conversation so far. */
const EARLIER: readonly ChatMessage[] = [
  { text: "Morning! Deck v3 is in the shared folder.", mine: false, opacity: 1 },
  { text: "Deck looks great, thanks!", mine: true, opacity: 1 },
];
/** What the recognizer writes while you speak, and what `keyboardFormatDictation` (English, default options) makes of it. */
export const RAW_DICTATION = "Sure, comma, here's the plan. First, send the deck to Ella. Second, book the review for Thursday.";
export const FORMATTED_DICTATION = "Sure, here's the plan.\n1. Send the deck to Ella\n2. Book the review for Thursday";
const RAW_WORDS: readonly string[] = RAW_DICTATION.split(" ");

const easeOut = Easing.bezier(0.22, 1, 0.36, 1);

/** 0 → 1 between `start` and `start + duration`, eased, clamped. Pure function. */
export const ramp = (frame: number, start: number, duration: number): number =>
  interpolate(frame, [start, start + duration], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOut });

/** Rises over `rise` frames from `start`, holds, falls over `fall` frames from `end`. Pure function. */
export const window01 = (frame: number, start: number, rise: number, end: number, fall: number): number =>
  ramp(frame, start, rise) * (1 - ramp(frame, end, fall));

/** A finger tap in screen points (440 × 956) and how far its short life has run (0…1). */
export type Touch = { readonly x: number; readonly y: number; readonly progress: number };

export type ChatMessage = { readonly text: string; readonly mine: boolean; readonly opacity: number };

export type TopBar =
  | { readonly kind: "suggestions"; readonly sparklePress: number; readonly voicePress: number }
  | { readonly kind: "askField"; readonly question: string; readonly askPress: number }
  | { readonly kind: "answering" }
  | { readonly kind: "answered"; readonly answer: string; readonly addPress: number };

export type Panel = {
  /** 0: keys; 1: the dictation panel in their place. */
  readonly shown: number;
  readonly stage: "listening" | "finishing";
  readonly seconds: number;
  readonly level: number;
  readonly motion: ParticleMotion;
  readonly travel: number;
  readonly donePress: number;
};

/** Everything the drawn phone needs for one frame. */
export type PhoneState = {
  readonly frame: number;
  readonly surfaces: Surfaces;
  readonly isDark: boolean;
  readonly accent: KeyboardAccent;
  readonly messages: readonly ChatMessage[];
  /** The message being written: committed text, then live (marked, underlined) text. */
  readonly draft: string;
  readonly marked: string;
  readonly caret: boolean;
  readonly topBar: TopBar;
  readonly panel: Panel;
  /** The key under the finger (letter or "space"), for its press and pop-up. */
  readonly keyDown: string | null;
  readonly sendPress: number;
  readonly touches: readonly Touch[];
};

/** Screen points of what a finger taps (dark keyboard, iOS 26 sheet). */
export const TAP = {
  sparkles: { x: 64, y: 612 },
  voice: { x: 290, y: 612 },
  ask: { x: 404, y: 612 },
  add: { x: 406, y: 612 },
  done: { x: 396, y: 783 },
  send: { x: 408, y: 538 },
  sendPanel: { x: 408, y: 666 },
} as const;

/** A tap's life: 4 frames in, 10 out. Pure function. */
const tapAt = (frame: number, at: number, point: { readonly x: number; readonly y: number }): readonly Touch[] =>
  frame >= at - 4 && frame <= at + 10 ? [{ x: point.x, y: point.y, progress: (frame - at + 4) / 14 }] : [];

/** A short press highlight around `at`. Pure function. */
const press = (frame: number, at: number): number => window01(frame, at - 3, 2, at + 2, 6);

/** Syllable-like flutter, deterministic. Pure function. */
const flutter = (frame: number): number => {
  const slow: number = 0.5 + 0.5 * Math.sin(frame * 0.53) * Math.sin(frame * 0.21 + 1.3);
  const fast: number = 0.5 + 0.5 * Math.sin(frame * 1.37 + Math.sin(frame * 0.31) * 2);
  return 0.35 * slow + 0.65 * fast;
};

/** Loudness (0…1) around moments words arrive: speech leads the text by a few frames. Pure function. */
const speakingNear = (frame: number, appear: readonly number[]): number =>
  appear.reduce((loudest: number, at: number): number => Math.max(loudest, Math.max(0, 1 - Math.abs(frame - (at - 4)) / 9)), 0);

// MARK: Ask (local frame `a`, 0 at ASK_START)

const ASK_SPARKLE = 30;
const TYPE_FROM = 40;
const TYPE_STEP = 2.5;
const ASK_SEND = 104;
const ASK_ANSWER = 156;
const ASK_ADD = 190;
const ASK_SEND_MESSAGE = 232;

const typedCount = (a: number): number => Math.max(0, Math.min(QUESTION.length, Math.floor((a - TYPE_FROM) / TYPE_STEP) + 1));

const askTopBar = (a: number): TopBar => {
  if (a < ASK_SPARKLE + 3) {
    return { kind: "suggestions", sparklePress: press(a, ASK_SPARKLE), voicePress: 0 };
  }
  if (a < ASK_SEND + 3) {
    return { kind: "askField", question: QUESTION.slice(0, typedCount(a)), askPress: press(a, ASK_SEND) };
  }
  if (a < ASK_ANSWER) {
    return { kind: "answering" };
  }
  if (a < ASK_ADD + 3) {
    return { kind: "answered", answer: ANSWER, addPress: press(a, ASK_ADD) };
  }
  return { kind: "suggestions", sparklePress: 0, voicePress: 0 };
};

const askKeyDown = (a: number): string | null => {
  if (a < TYPE_FROM - 1 || a >= TYPE_FROM + QUESTION.length * TYPE_STEP) {
    return null;
  }
  const index: number = Math.floor((a - TYPE_FROM + 1) / TYPE_STEP);
  const phase: number = (a - TYPE_FROM + 1) % TYPE_STEP;
  const character: string = QUESTION[index] ?? "";
  return phase < 1.6 ? (character === " " ? "space" : character.toUpperCase()) : null;
};

const idlePanel: Panel = { shown: 0, stage: "listening", seconds: 0, level: 0, motion: "listening", travel: 0, donePress: 0 };

export const askState = (a: number, frame: number): PhoneState => ({
  frame,
  surfaces: DARK,
  isDark: true,
  accent: OLIVE_LIME,
  messages: [
    ...EARLIER,
    { text: INCOMING_ASK, mine: false, opacity: ramp(a, 12, 8) },
    ...(a >= ASK_SEND_MESSAGE + 2 ? [{ text: ANSWER, mine: true, opacity: ramp(a, ASK_SEND_MESSAGE + 2, 6) }] : []),
  ],
  draft: a >= ASK_ADD + 3 && a < ASK_SEND_MESSAGE + 2 ? ANSWER : "",
  marked: "",
  caret: a < ASK_SPARKLE + 3 || (a >= ASK_ADD + 3 && a < ASK_SEND_MESSAGE + 2),
  topBar: askTopBar(a),
  panel: idlePanel,
  keyDown: askKeyDown(a),
  sendPress: press(a, ASK_SEND_MESSAGE),
  touches: [...tapAt(a, ASK_SPARKLE, TAP.sparkles), ...tapAt(a, ASK_SEND, TAP.ask), ...tapAt(a, ASK_ADD, TAP.add), ...tapAt(a, ASK_SEND_MESSAGE, TAP.send)],
});

// MARK: Voice (local frame `v`, 0 at VOICE_START)

const VOICE_TAP = 20;
const SPEECH_FROM = 40;
const VOICE_DONE = 142;
const VOICE_INSERT = 156;
const VOICE_SEND = 196;

/** Each raw word's appear frame: phrases with pauses, as speech arrives. */
const RAW_APPEAR: readonly number[] = (() => {
  const phrases: readonly number[] = [2, 3, 6, 6];
  const pause = 7;
  const step = 4;
  const frames: number[] = [];
  let at: number = SPEECH_FROM;
  phrases.forEach((count: number) => {
    for (let word = 0; word < count; word += 1) {
      frames.push(Math.round(at));
      at += step;
    }
    at += pause;
  });
  return frames.slice(0, RAW_WORDS.length);
})();

const rawShown = (v: number): number => RAW_APPEAR.filter((at: number): boolean => v >= at).length;

/** The voice level the keyboard sees while you dictate (0…1). Pure function. */
export const voiceLevel = (v: number): number => {
  if (v < VOICE_TAP + 8 || v >= VOICE_DONE) {
    return 0;
  }
  const voice: number = Math.min(1, speakingNear(v, RAW_APPEAR) * 1.2);
  return Math.min(1, 0.04 + voice * (0.35 + 0.65 * flutter(v)));
};

const voiceMotion = (v: number): ParticleMotion => (v >= VOICE_DONE ? "processing" : v < VOICE_TAP + 8 ? "processing" : "listening");

const VOICE_TRAVEL: readonly number[] = travelTable(LOOP_TOTAL + 1, KB_FPS, (v: number) => ({ motion: voiceMotion(v), level: voiceLevel(v) }));

export const voiceState = (v: number, frame: number): PhoneState => {
  const shown: number = rawShown(v);
  const listening: boolean = v < VOICE_DONE;
  return {
    frame,
    surfaces: DARK,
    isDark: true,
    accent: OLIVE_LIME,
    messages: [
      ...EARLIER,
      { text: INCOMING_ASK, mine: false, opacity: 1 },
      { text: ANSWER, mine: true, opacity: 1 },
      { text: INCOMING_VOICE, mine: false, opacity: ramp(v, 6, 8) },
      ...(v >= VOICE_SEND + 2 ? [{ text: FORMATTED_DICTATION, mine: true, opacity: ramp(v, VOICE_SEND + 2, 6) }] : []),
    ],
    draft: v >= VOICE_INSERT && v < VOICE_SEND + 2 ? FORMATTED_DICTATION : "",
    marked: v < VOICE_INSERT ? RAW_WORDS.slice(0, shown).join(" ") : "",
    caret: true,
    topBar: { kind: "suggestions", sparklePress: 0, voicePress: press(v, VOICE_TAP) },
    panel: {
      shown: window01(v, VOICE_TAP + 2, 10, VOICE_INSERT, 10),
      stage: listening ? "listening" : "finishing",
      seconds: Math.max(0, (v - VOICE_TAP - 4) / KB_FPS),
      level: voiceLevel(v),
      motion: voiceMotion(v),
      travel: VOICE_TRAVEL[Math.max(0, Math.min(LOOP_TOTAL, Math.floor(v)))] ?? 0,
      donePress: press(v, VOICE_DONE),
    },
    keyDown: null,
    sendPress: press(v, VOICE_SEND),
    touches: [...tapAt(v, VOICE_TAP, TAP.voice), ...tapAt(v, VOICE_DONE, TAP.done), ...tapAt(v, VOICE_SEND, TAP.send)],
  };
};

/** The website loop: the voice part, its sent reply fading out so the last frame meets the first. Pure function. */
export const loopState = (v: number): PhoneState => {
  const state: PhoneState = voiceState(v, v);
  const fade: number = 1 - ramp(v, LOOP_TOTAL - 20, 16);
  return {
    ...state,
    messages: state.messages.map((message: ChatMessage, index: number): ChatMessage => (index >= 5 ? { ...message, opacity: message.opacity * fade } : message)),
  };
};

// MARK: Theme (local frame `t`, 0 at THEME_START)

/** Accent changes while the panel listens: lime → copper → violet (light mode) → blue. */
const themeAccent = (t: number): KeyboardAccent => {
  const toCopper: number = ramp(t, 22, 12);
  const toViolet: number = ramp(t, 50, 12);
  const toBlue: number = ramp(t, 80, 12);
  return mixAccent(mixAccent(mixAccent(OLIVE_LIME, EMBER_COPPER, toCopper), OLIVE_VIOLET, toViolet), OLIVE_BLUE, toBlue);
};

const themeLight = (t: number): number => ramp(t, 50, 12);

const themeLevel = (t: number): number => Math.min(1, 0.1 + 0.75 * flutter(t * 1.1 + 40) * (0.6 + 0.4 * Math.sin(t * 0.09)));

const THEME_TRAVEL: readonly number[] = travelTable(END_START - THEME_START + 1, KB_FPS, (t: number) => ({ motion: "listening", level: themeLevel(t) }));

export const themeState = (t: number, frame: number): PhoneState => {
  const light: number = themeLight(t);
  return {
    frame,
    surfaces: mixSurfaces(DARK, LIGHT, light),
    isDark: light < 0.5,
    accent: themeAccent(t),
    messages: [
      ...EARLIER,
      { text: INCOMING_ASK, mine: false, opacity: 1 },
      { text: ANSWER, mine: true, opacity: 1 },
      { text: INCOMING_VOICE, mine: false, opacity: 1 },
      { text: FORMATTED_DICTATION, mine: true, opacity: 1 },
    ],
    draft: "",
    marked: t < 16 ? "" : (["Talk", "Talk to", "Talk to your", "Talk to your meetings"][Math.min(3, Math.floor((t - 16) / 12))] ?? ""),
    caret: true,
    topBar: { kind: "suggestions", sparklePress: 0, voicePress: press(t, 0) },
    panel: {
      shown: ramp(t, 2, 10),
      stage: "listening",
      seconds: t / KB_FPS,
      level: themeLevel(t),
      motion: "listening",
      travel: THEME_TRAVEL[Math.max(0, Math.min(END_START - THEME_START, Math.floor(t)))] ?? 0,
      donePress: 0,
    },
    keyDown: null,
    sendPress: 0,
    touches: tapAt(t, 0, TAP.voice),
  };
};

/** The accent name shown beside the phone in the theme part. Pure function. */
export const themeAccentName = (t: number): string => {
  if (ramp(t, 80, 12) > 0.5) {
    return "Blue · Light";
  }
  if (ramp(t, 50, 12) > 0.5) {
    return "Violet · Light";
  }
  return ramp(t, 22, 12) > 0.5 ? "Ember" : "Olive";
};

/** A hero voice field's level from the narrator's words of a line that starts at `startFrame`. Pure function. */
export const narratorLevel = (frame: number, startFrame: number, words: readonly { readonly startMs: number; readonly endMs: number }[]): number => {
  const ms: number = ((frame - startFrame) / KB_FPS) * 1000;
  const inWord: number = words.reduce((best: number, word: { readonly startMs: number; readonly endMs: number }): number => {
    const mid: number = (word.startMs + word.endMs) / 2;
    const half: number = Math.max(60, (word.endMs - word.startMs) / 2 + 60);
    return Math.max(best, Math.max(0, 1 - Math.abs(ms - mid) / half));
  }, 0);
  return Math.min(1, 0.12 + inWord * (0.45 + 0.55 * flutter(frame)));
};
