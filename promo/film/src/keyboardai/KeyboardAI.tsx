import { Audio } from "@remotion/media";
import type { CSSProperties } from "react";
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { fontFamily } from "../brand";
import { serifFamily } from "../voicetype/olive";
import manifest from "../../public/vo-keyboard/manifest.json";
import words from "../../public/vo-keyboard/words.json";
import { ParticleField } from "./ParticleField";
import { travelTable } from "./particles";
import { Phone, PHONE_HEIGHT, PHONE_WIDTH } from "./Phone";
import {
  ASK_START,
  askState,
  CROSS,
  END_START,
  narratorLevel,
  KB_FPS,
  KB_TOTAL,
  LOOP_TOTAL,
  loopState,
  type PhoneState,
  ramp,
  THEME_START,
  themeAccentName,
  themeState,
  checkVoiceover,
  VoiceoverMismatchError,
  voStart,
  VOICE_START,
  voiceState,
  window01,
} from "./script";
import { field, OLIVE_LIME } from "./theme";

/**
 * "Gistsmith Keyboard": ask your meetings and voice type from any app's keyboard. Narrated (promo/voice, script
 * "keyboard") over a quiet music bed; the headlines carry it with the sound off. One timeline, four layouts:
 * 9:16 (primary), 1:1, 16:9, and the silent 4:5 website loop of the voice-typing part.
 */
type Take = { readonly id: string; readonly file: string; readonly seconds: number };
type TimedWord = { readonly text: string; readonly startMs: number; readonly endMs: number };

const TAKES: readonly Take[] = manifest as readonly Take[];
const WORDS: Readonly<Record<string, readonly TimedWord[]>> = words as Readonly<Record<string, readonly TimedWord[]>>;
checkVoiceover(TAKES, WORDS);

/** The word timings of a voiceover line (`checkVoiceover` has made sure every line has them). */
const wordsOf = (id: string): readonly TimedWord[] => {
  const timed: readonly TimedWord[] | undefined = WORDS[id];
  if (timed === undefined) {
    throw new VoiceoverMismatchError(`No word timings for ${JSON.stringify(id)}`);
  }
  return timed;
};

type Layout = {
  readonly width: number;
  readonly height: number;
  /** Copy block. */
  readonly textLeft: number;
  readonly textTop: number;
  readonly textWidth: number;
  readonly textAlign: "left" | "center";
  readonly headSize: number;
  readonly subSize: number;
  /** Phone camera: pixel centre x, where the phone's bottom edge sits (it may bleed off the frame), and its scale. */
  readonly phoneX: number;
  readonly phoneBottom: number;
  readonly phoneScale: number;
  /** The phone fades in from `maskFrom` to `maskTo` (px from the top) so it never runs into the copy; 0 = no fade. */
  readonly maskFrom: number;
  readonly maskTo: number;
  /** The voice field of the hook and end card. */
  readonly heroWidth: number;
  readonly heroTop: number;
  readonly hookTop: number;
};

const PORTRAIT: Layout = {
  width: 1080,
  height: 1920,
  textLeft: 70,
  textTop: 140,
  textWidth: 940,
  textAlign: "center",
  headSize: 92,
  subSize: 38,
  phoneX: 540,
  phoneBottom: 1960,
  phoneScale: 1.72,
  maskFrom: 520,
  maskTo: 700,
  heroWidth: 920,
  heroTop: 1060,
  hookTop: 600,
};

const SQUARE: Layout = {
  width: 1080,
  height: 1080,
  textLeft: 72,
  textTop: 150,
  textWidth: 400,
  textAlign: "left",
  headSize: 64,
  subSize: 28,
  phoneX: 782,
  phoneBottom: 1150,
  phoneScale: 1.2,
  maskFrom: 0,
  maskTo: 140,
  heroWidth: 860,
  heroTop: 640,
  hookTop: 300,
};

const LANDSCAPE: Layout = {
  width: 1920,
  height: 1080,
  textLeft: 150,
  textTop: 300,
  textWidth: 780,
  textAlign: "left",
  headSize: 96,
  subSize: 38,
  phoneX: 1380,
  phoneBottom: 1180,
  phoneScale: 1.36,
  maskFrom: 0,
  maskTo: 150,
  heroWidth: 1200,
  heroTop: 640,
  hookTop: 290,
};

type Copy = { readonly tag: string; readonly head: string; readonly sub: string };

const COPY: Readonly<Record<"hook" | "ask" | "voice" | "theme", Copy>> = {
  hook: { tag: "Gistsmith Keyboard · iPhone", head: "Your keyboard just\nlearned to listen.", sub: "" },
  ask: { tag: "Ask Gistsmith", head: "Ask your meetings,\nfrom any app.", sub: "The answer drops into your message." },
  voice: { tag: "Voice type", head: "Just talk.\nIt types.", sub: "Say “comma”, get a comma.\nSay “first… second…”, get a list." },
  theme: { tag: "Appearance", head: "It wears\nyour colors.", sub: "" },
};

/** Each part's presence (0…1). Pure function. */
const parts = (frame: number) => ({
  hook: 1 - ramp(frame, ASK_START - CROSS, CROSS),
  ask: window01(frame, ASK_START - 4, CROSS, VOICE_START - CROSS, CROSS / 2),
  voice: window01(frame, VOICE_START - 4, CROSS, THEME_START - CROSS, CROSS / 2),
  theme: window01(frame, THEME_START - 4, CROSS, END_START - CROSS, CROSS / 2),
  end: ramp(frame, END_START - 4, 20),
});

/** The phone's state at a film frame. Pure function. */
const phoneAt = (frame: number): PhoneState => {
  if (frame >= THEME_START) {
    return themeState(Math.min(frame, END_START + 20) - THEME_START, frame);
  }
  if (frame >= VOICE_START) {
    return voiceState(frame - VOICE_START, frame);
  }
  return askState(Math.max(0, frame - ASK_START), frame);
};

const hookLevel = (frame: number): number => narratorLevel(frame, voStart("kb-hook"), wordsOf("kb-hook"));
const endLevel = (frame: number): number => narratorLevel(frame, voStart("kb-cta"), wordsOf("kb-cta"));
const HOOK_TRAVEL: readonly number[] = travelTable(ASK_START + 1, KB_FPS, (frame: number) => ({ motion: "listening", level: hookLevel(frame) }));
const END_TRAVEL: readonly number[] = travelTable(KB_TOTAL - END_START + 1, KB_FPS, (local: number) => ({ motion: "listening", level: endLevel(END_START + local) }));

/** Warm Ember night, copper light from the top, sand from below, a little grain; the light drifts slowly. */
const Field: React.FC<{ readonly frame: number }> = ({ frame }) => {
  const drift: number = Math.sin(frame / 90) * 6;
  return (
    <AbsoluteFill style={{ backgroundColor: field.night }}>
      <AbsoluteFill
        style={{
          backgroundImage: `radial-gradient(80% 50% at ${50 + drift}% -8%, rgb(227 154 114 / 0.26) 0%, transparent 70%), radial-gradient(70% 45% at ${45 - drift}% 112%, rgb(217 193 158 / 0.14) 0%, transparent 70%)`,
        }}
      />
      <Img src={staticFile("grain.png")} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover", opacity: 0.08, mixBlendMode: "screen" }} />
    </AbsoluteFill>
  );
};

const CopyBlock: React.FC<{ readonly copy: Copy; readonly presence: number; readonly layout: Layout; readonly extra: React.ReactNode }> = ({ copy, presence, layout, extra }) => {
  if (presence <= 0.001) {
    return null;
  }
  const rise: number = (1 - presence) * 26;
  return (
    <div style={{ position: "absolute", left: layout.textLeft, top: layout.textTop, width: layout.textWidth, textAlign: layout.textAlign, opacity: presence, translate: `0px ${rise}px` }}>
      <div style={{ fontFamily, fontSize: layout.subSize * 0.72, fontWeight: 600, letterSpacing: "0.02em", color: field.copper }}>{copy.tag}</div>
      <div style={{ marginTop: 18, fontFamily: serifFamily, fontSize: layout.headSize, lineHeight: 1.04, letterSpacing: "-0.02em", color: field.ink, whiteSpace: "pre-line" }}>{copy.head}</div>
      {copy.sub.length > 0 ? (
        <div style={{ marginTop: 22, fontFamily, fontSize: layout.subSize, fontWeight: 500, lineHeight: 1.28, letterSpacing: "-0.01em", color: field.muted, whiteSpace: "pre-line" }}>{copy.sub}</div>
      ) : null}
      {extra}
    </div>
  );
};

const AccentChip: React.FC<{ readonly frame: number; readonly layout: Layout }> = ({ frame, layout }) => {
  const t: number = frame - THEME_START;
  const state: PhoneState = themeState(Math.max(0, t), frame);
  const color: string = state.isDark ? state.accent.fillDark : state.accent.fillLight;
  return (
    <div style={{ marginTop: 30, display: "flex", justifyContent: layout.textAlign === "center" ? "center" : "flex-start" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "12px 22px", borderRadius: 999, background: "rgb(255 255 255 / 0.06)", border: "1px solid rgb(255 255 255 / 0.1)", fontFamily, fontSize: layout.subSize * 0.8, fontWeight: 600, color: field.ink }}>
        <div style={{ width: layout.subSize * 0.62, height: layout.subSize * 0.62, borderRadius: 999, background: color, boxShadow: `0 0 24px ${color}` }} />
        {themeAccentName(t)}
      </div>
    </div>
  );
};

/** A large voice field moving with the narrator (the hook, the end card). */
const Hero: React.FC<{ readonly frame: number; readonly width: number; readonly left: number; readonly top: number; readonly presence: number; readonly level: number; readonly travel: number }> = ({
  frame,
  width,
  left,
  top,
  presence,
  level,
  travel,
}) => {
  if (presence <= 0.001) {
    return null;
  }
  const height: number = width * 0.15;
  return (
    <div style={{ position: "absolute", left, top, width, height, opacity: presence, scale: 0.94 + 0.06 * presence, filter: `drop-shadow(0 0 ${40 + 60 * level}px rgb(181 196 71 / ${0.16 + 0.2 * level}))` }}>
      <ParticleField width={width} height={height} accent={OLIVE_LIME} isDark level={level} mode="listening" travel={travel} time={frame / KB_FPS} />
    </div>
  );
};

const PhoneStage: React.FC<{ readonly frame: number; readonly layout: Layout; readonly presence: number }> = ({ frame, layout, presence }) => {
  if (presence <= 0.001) {
    return null;
  }
  const enter: number = ramp(frame, ASK_START - 10, 26);
  const scale: number = layout.phoneScale;
  const left: number = layout.phoneX - (PHONE_WIDTH * scale) / 2;
  const top: number = layout.phoneBottom - PHONE_HEIGHT * scale + (1 - enter) * 260;
  const mask: string | undefined =
    layout.maskTo > 0 ? `linear-gradient(180deg, transparent 0px, transparent ${layout.maskFrom}px, #000 ${layout.maskTo}px, #000 100%)` : undefined;
  return (
    <AbsoluteFill style={{ opacity: presence * enter, maskImage: mask, WebkitMaskImage: mask }}>
      <div style={{ position: "absolute", left, top }}>
        <Phone state={phoneAt(frame)} scale={scale} />
      </div>
    </AbsoluteFill>
  );
};

const EndCard: React.FC<{ readonly presence: number; readonly layout: Layout }> = ({ presence, layout }) => {
  if (presence <= 0.001) {
    return null;
  }
  const unit: number = Math.min(layout.width, layout.height) / 1080;
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", textAlign: "center", opacity: presence, scale: 0.97 + 0.03 * presence }}>
      <Img src={staticFile("icon.png")} style={{ width: 210 * unit, height: 210 * unit, filter: "drop-shadow(0 24px 40px rgb(0 0 0 / 0.5))" }} />
      <div style={{ marginTop: 34 * unit, fontFamily: serifFamily, fontSize: 112 * unit, lineHeight: 1, letterSpacing: "-0.02em", color: field.ink }}>Gistsmith Keyboard</div>
      <div style={{ marginTop: 26 * unit, fontFamily, fontSize: 42 * unit, fontWeight: 500, color: field.muted, letterSpacing: "-0.01em" }}>Ask. Talk. Type. In any app.</div>
      <div style={{ marginTop: 50 * unit, fontFamily, fontSize: 48 * unit, fontWeight: 600, color: field.copper, letterSpacing: "-0.01em" }}>gistsmith.com</div>
      <div style={{ marginTop: 40 * unit, fontFamily, fontSize: 22 * unit, fontWeight: 500, color: "rgb(169 158 147 / 0.75)" }}>Voice typing in the keyboard needs iOS 26. Asking needs Full Access.</div>
    </AbsoluteFill>
  );
};

const Soundtrack: React.FC = () => (
  <>
    <Audio
      src={staticFile("music/advertime.mp3")}
      volume={(f: number) => interpolate(f, [0, 20, KB_TOTAL - 50, KB_TOTAL], [0, 0.11, 0.11, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })}
    />
    {TAKES.map((take: Take) => (
      <Audio key={take.id} src={staticFile(`vo-keyboard/${take.file}`)} from={voStart(take.id)} />
    ))}
    {[ASK_START, VOICE_START, THEME_START, END_START].map((at: number) => (
      <Audio key={at} src={staticFile("sfx/whoosh.wav")} from={at - 6} volume={0.1} />
    ))}
  </>
);

const KeyboardFilm: React.FC<{ readonly layout: Layout }> = ({ layout }) => {
  const frame: number = useCurrentFrame();
  const p = parts(frame);
  const phonePresence: number = 1 - p.end;
  return (
    <AbsoluteFill style={{ fontFamily, overflow: "hidden" }}>
      <Field frame={frame} />
      <Hero
        frame={frame}
        width={layout.heroWidth}
        left={(layout.width - layout.heroWidth) / 2}
        top={layout.heroTop}
        presence={p.hook * ramp(frame, 0, 18)}
        level={hookLevel(frame)}
        travel={HOOK_TRAVEL[Math.min(ASK_START, frame)] ?? 0}
      />
      <PhoneStage frame={frame} layout={layout} presence={frame < ASK_START - 10 ? 0 : phonePresence} />
      <CopyBlock copy={COPY.hook} presence={p.hook * ramp(frame, 6, 16)} layout={{ ...layout, textLeft: 70, textWidth: layout.width - 140, textAlign: "center", textTop: layout.hookTop }} extra={null} />
      <CopyBlock copy={COPY.ask} presence={p.ask} layout={layout} extra={null} />
      <CopyBlock copy={COPY.voice} presence={p.voice} layout={layout} extra={null} />
      <CopyBlock copy={COPY.theme} presence={p.theme} layout={layout} extra={<AccentChip frame={frame} layout={layout} />} />
      <EndCard presence={p.end} layout={layout} />
      <Hero
        frame={frame}
        width={layout.heroWidth * 0.62}
        left={(layout.width - layout.heroWidth * 0.62) / 2}
        top={layout.height / 2 + Math.min(layout.width, layout.height) * 0.33}
        presence={p.end * ramp(frame, END_START + 6, 20)}
        level={endLevel(frame)}
        travel={END_TRAVEL[Math.max(0, Math.min(KB_TOTAL - END_START, frame - END_START))] ?? 0}
      />
      <Soundtrack />
    </AbsoluteFill>
  );
};

export const KeyboardAIPortrait: React.FC = () => <KeyboardFilm layout={PORTRAIT} />;
export const KeyboardAISquare: React.FC = () => <KeyboardFilm layout={SQUARE} />;
export const KeyboardAILandscape: React.FC = () => <KeyboardFilm layout={LANDSCAPE} />;

/** The website loop (4:5, silent): the voice-typing part on the phone alone. */
export const KeyboardAILoop: React.FC = () => {
  const frame: number = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const scale: number = 1.55;
  const style: CSSProperties = { position: "absolute", left: (width - PHONE_WIDTH * scale) / 2, top: height + 40 - PHONE_HEIGHT * scale };
  const mask: string = "linear-gradient(180deg, transparent 0px, #000 220px, #000 100%)";
  return (
    <AbsoluteFill style={{ fontFamily, overflow: "hidden" }}>
      <Field frame={0} />
      <AbsoluteFill style={{ maskImage: mask, WebkitMaskImage: mask }}>
        <div style={style}>
          <Phone state={loopState(frame % LOOP_TOTAL)} scale={scale} />
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

export { KB_FPS, KB_TOTAL, LOOP_TOTAL };
