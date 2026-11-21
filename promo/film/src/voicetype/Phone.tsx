import type { CSSProperties } from "react";
import { fontFamily } from "../brand";
import { Glyph } from "./Glyph";
import { olive, serifFamily } from "./olive";
import { DICTATED_LINES, type PhoneState, type Touch } from "./script";

/**
 * An iPhone drawn in its own points (440 × 956 pt screen, rim and bezel as on the website's demo,
 * web/src/components/PhoneVoiceTypingDemo.astro), with a reply open in a generic messaging app and the Gistsmith
 * Keyboard drawn after the real one (iOSKeyboard/KeyboardViews.swift `KeyboardDictationView`, `KeyboardWaveform`,
 * `KeyboardDictationGlow`, `KeyboardFinishPulse`; KeyboardGridView.swift). `scale` sizes it in pixels.
 */
export const PHONE_WIDTH = 465.14;
export const PHONE_HEIGHT = 981.14;
/** Outer corner radius of the rim, in points. */
export const PHONE_CORNER = 74.57;
const SCREEN_W = 440;
const SCREEN_H = 956;
const KB_H = 342;
const KB_TOP = SCREEN_H - KB_H;
const FIELD_BOTTOM = 606;
const LINE = 22;

const abs = (style: CSSProperties): CSSProperties => ({ position: "absolute", ...style });

export const Phone: React.FC<{ readonly state: PhoneState; readonly scale: number }> = ({ state, scale }) => (
  <div style={{ width: PHONE_WIDTH * scale, height: PHONE_HEIGHT * scale, position: "relative" }}>
    <div
      style={{
        width: PHONE_WIDTH,
        height: PHONE_HEIGHT,
        transform: `scale(${scale})`,
        transformOrigin: "0 0",
        padding: 3.14,
        borderRadius: PHONE_CORNER,
        background: "linear-gradient(135deg, #8a8784 0%, #3a3937 14%, #232322 48%, #3a3937 86%, #7d7a77 100%)",
        boxShadow: "0 2px 3px rgb(0 0 0 / 0.3), 0 40px 90px rgb(0 0 0 / 0.55)",
        boxSizing: "border-box",
      }}
    >
      <div style={{ padding: 9.43, borderRadius: 71.43, background: "#050505" }}>
        <div
          style={{
            position: "relative",
            width: SCREEN_W,
            height: SCREEN_H,
            overflow: "hidden",
            borderRadius: 62,
            background: "#ffffff",
            color: "#000000",
            fontFamily,
            fontSize: 17,
            lineHeight: 1.3,
            letterSpacing: "-0.01em",
          }}
        >
          <MessagesScreen state={state} />
          <AppScreen state={state} />
          <StatusBar state={state} />
          <div style={abs({ left: 150, bottom: 8, width: 140, height: 5, borderRadius: 3, background: "#000000" })} />
          {state.touches.map((touch: Touch) => (
            <TouchMark key={`${touch.x}-${touch.y}`} touch={touch} />
          ))}
        </div>
      </div>
    </div>
  </div>
);

const StatusBar: React.FC<{ readonly state: PhoneState }> = ({ state }) => (
  <>
    <div style={abs({ top: 18, left: 46, width: 64, fontSize: 17, fontWeight: 600, textAlign: "center", opacity: 1 - state.backLink })}>9:41</div>
    {/* The system back link iOS shows in an app opened from another one. */}
    <div style={abs({ top: 21, left: 30, display: "flex", alignItems: "center", gap: 3, opacity: state.backLink, color: olive.systemLink, fontSize: 13, fontWeight: 600 })}>
      <Glyph name="backTriangle" size={10} color={olive.systemLink} strokeWidth={0} />
      Messages
    </div>
    <div style={abs({ top: 22, right: 34, display: "flex", alignItems: "center", gap: 6 })}>
      <Glyph name="signal" size={17} color="#000000" strokeWidth={0} />
      <Glyph name="wifi" size={17} color="#000000" strokeWidth={0} />
      <div style={{ width: 27, height: 13, padding: 2, border: "1.2px solid rgb(0 0 0 / 0.4)", borderRadius: 4, boxSizing: "border-box" }}>
        <div style={{ width: "78%", height: "100%", borderRadius: 1.5, background: "#000000" }} />
      </div>
    </div>
    <div style={abs({ top: 11, left: 120, width: 200, height: 37.33, borderRadius: 18.67, background: "#000000" })}>
      <div style={abs({ top: 9.5, left: 15, opacity: state.islandWarm })}>
        <Glyph name="keyboardFill" size={19} color={olive.lime} strokeWidth={0} />
      </div>
      <div style={abs({ top: 14.5, right: 17, width: 8, height: 8, borderRadius: 4, background: "#ff9500", opacity: state.islandWarm })} />
    </div>
  </>
);

/** The messaging app with the keyboard; it slides a little left and dims while the Gistsmith app covers it. */
const MessagesScreen: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const words: readonly number[] = state.words;
  const shown: number = words.filter((opacity: number): boolean => opacity > 0.01).length;
  const lineStarts: readonly number[] = DICTATED_LINES.map((_: readonly string[], line: number): number =>
    DICTATED_LINES.slice(0, line).reduce((sum: number, row: readonly string[]): number => sum + row.length, 0),
  );
  const extraLines: number = lineStarts.slice(1).reduce((sum: number, start: number): number => sum + (words[start] ?? 0), 0) * state.replyOpacity;
  const fieldH: number = 36 + LINE * extraLines;
  const fieldTop: number = FIELD_BOTTOM - fieldH;
  const anyText: number = (words[0] ?? 0) * state.replyOpacity;
  return (
    <div style={abs({ inset: 0, translate: `${-state.appShift * 130}px 0px`, filter: `brightness(${1 - 0.25 * state.appShift})` })}>
      <div style={abs({ top: 74, left: 16 })}>
        <Glyph name="chevronLeft" size={24} color="#000000" strokeWidth={2.4} />
      </div>
      <div style={abs({ top: 62, left: 0, right: 0, display: "flex", flexDirection: "column", alignItems: "center", gap: 5 })}>
        <div
          style={{
            width: 52,
            height: 52,
            borderRadius: 26,
            display: "grid",
            placeItems: "center",
            background: "linear-gradient(180deg, #a8adb7, #868b95)",
            color: "#ffffff",
            fontSize: 21,
            fontWeight: 600,
          }}
        >
          AV
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 2, fontSize: 12, fontWeight: 500 }}>
          Aino
          <Glyph name="chevronRight" size={9} color="#8e8e93" strokeWidth={2.6} />
        </div>
      </div>
      <div style={abs({ left: 16, right: 16, bottom: SCREEN_H - (fieldTop - 18), display: "flex", flexDirection: "column", alignItems: "flex-start", gap: 3 })}>
        <div style={{ alignSelf: "center", marginBottom: 8, fontSize: 12, color: "#8e8e93" }}>Today 9:38</div>
        {["Morning! Standup moved to 9:45.", "Are you joining?"].map((message: string) => (
          <div key={message} style={{ maxWidth: "76%", padding: "7px 13px", borderRadius: 18, background: "#e9e9eb", lineHeight: "22px" }}>
            {message}
          </div>
        ))}
      </div>
      <div style={abs({ top: FIELD_BOTTOM - 36, left: 12, width: 36, height: 36, borderRadius: 18, background: "#ededf0", display: "grid", placeItems: "center" })}>
        <Glyph name="plus" size={20} color="#6b6b70" strokeWidth={2.2} />
      </div>
      <div style={abs({ top: fieldTop, left: 56, width: 372, height: fieldH, border: "1px solid #cfcfd4", borderRadius: 18, background: "#ffffff", boxSizing: "border-box" })}>
        <div style={abs({ top: 6, left: 18, lineHeight: `${LINE}px`, color: "#a3a3a8", opacity: shown === 0 ? 1 : 1 - state.replyOpacity })}>Message</div>
        <div style={abs({ top: 6, left: 14, right: 40, lineHeight: `${LINE}px`, opacity: state.replyOpacity })}>
          {shown === 0 ? (
            <div style={{ height: LINE }}>
              <Caret frame={state.frame} />
            </div>
          ) : (
            DICTATED_LINES.map((line: readonly string[], lineIndex: number) => (
              <FieldLine key={line.join(" ")} line={line} start={lineStarts[lineIndex] ?? 0} state={state} shown={shown} />
            ))
          )}
        </div>
        <div
          style={abs({
            right: 4,
            bottom: 3,
            width: 28,
            height: 28,
            borderRadius: 14,
            background: "#1c1714",
            display: "grid",
            placeItems: "center",
            opacity: anyText,
            scale: 0.6 + 0.4 * anyText,
          })}
        >
          <Glyph name="arrowUp" size={16} color="#ffffff" strokeWidth={2.6} />
        </div>
      </div>
      <Keyboard state={state} />
    </div>
  );
};

/** One line of the reply: live (marked) words are underlined in the host's tint, the newest three in the accent. */
const FieldLine: React.FC<{ readonly line: readonly string[]; readonly start: number; readonly state: PhoneState; readonly shown: number }> = ({
  line,
  start,
  state,
  shown,
}) => {
  if ((state.words[start] ?? 0) <= 0.01) {
    return null;
  }
  return (
    <div style={{ whiteSpace: "pre", height: LINE }}>
      {line.map((word: string, offset: number) => {
        const index: number = start + offset;
        const opacity: number = state.words[index] ?? 0;
        const newest: boolean = index >= shown - 3 && state.marked > 0.5;
        const last: boolean = index === shown - 1;
        const spaced: boolean = offset < line.length - 1 && index < shown - 1;
        return (
          <span key={`${word}-${index}`} style={{ position: "relative" }}>
            <span
              style={{
                opacity,
                color: newest ? olive.oliveText : "#000000",
                textDecorationLine: "underline",
                textDecorationColor: `rgb(47 95 138 / ${state.marked * opacity})`,
                textDecorationThickness: 1.5,
                textUnderlineOffset: 3,
              }}
            >
              {spaced ? `${word} ` : word}
            </span>
            {last ? <Caret frame={state.frame} /> : null}
          </span>
        );
      })}
    </div>
  );
};

const Caret: React.FC<{ readonly frame: number }> = ({ frame }) => (
  <span
    style={{
      display: "inline-block",
      width: 2,
      height: 21,
      marginLeft: 1,
      verticalAlign: "-4px",
      borderRadius: 1,
      background: olive.hostTint,
      opacity: Math.floor(frame / 16) % 2 === 0 ? 1 : 0,
    }}
  />
);

/** Key widths in units of the 10-key row (KeyboardCore `keyboardRows`), 6 pt gaps, 434 pt of keys. */
const UNIT = 43.4;
const key = (units: number): number => UNIT * units - 6;

const Keyboard: React.FC<{ readonly state: PhoneState }> = ({ state }) => (
  <div style={abs({ left: 0, right: 0, top: KB_TOP, height: KB_H, borderRadius: "26px 26px 0 0", background: olive.keyboard, overflow: "hidden" })}>
    <div style={abs({ left: 0, right: 0, top: 0, height: 260, opacity: 1 - state.panel })}>
      <TopBar press={state.voicePress} />
      <div style={{ paddingTop: 2 }}>
        <KeyRow keys={[..."QWERTYUIOP"].map((letter: string) => <LetterKey key={letter} label={letter} />)} />
        <KeyRow keys={[..."ASDFGHJKL"].map((letter: string) => <LetterKey key={letter} label={letter} />)} />
        <KeyRow
          keys={[
            <ModKey key="shift" width={key(1.5)} glyph="shiftFill" light />,
            ...[..."ZXCVBNM"].map((letter: string) => <LetterKey key={letter} label={letter} />),
            <ModKey key="delete" width={key(1.5)} glyph="deleteLeft" light={false} />,
          ]}
        />
        <KeyRow
          keys={[
            <TextKey key="123" width={key(1.2)} label="123" mod />,
            <ModKey key="emoji" width={key(1.2)} glyph="faceSmiling" light={false} />,
            <ModKey key="mic" width={key(1.2)} glyph="mic" light={false} />,
            <TextKey key="space" width={key(4.48)} label="English" mod={false} />,
            <ModKey key="return" width={key(1.92)} glyph="returnKey" light={false} />,
          ]}
        />
      </div>
    </div>
    <DictationPanel state={state} />
    <div style={abs({ top: 278, left: 36 })}>
      <Glyph name="globe" size={26} color="#5f6168" strokeWidth={1.6} />
    </div>
  </div>
);

const TopBar: React.FC<{ readonly press: number }> = ({ press }) => (
  <div style={{ display: "flex", alignItems: "center", height: 44, padding: "0 4px" }}>
    <div style={{ width: 44, height: 40, display: "grid", placeItems: "center" }}>
      <Glyph name="textBadgePlus" size={22} color="rgb(0 0 0 / 0.7)" strokeWidth={1.9} />
    </div>
    <div style={{ width: 40, height: 40, display: "grid", placeItems: "center" }}>
      <Glyph name="sparkles" size={21} color={olive.oliveText} strokeWidth={0} />
    </div>
    {/* The wide "Voice type" capsule (KeyboardTopBar `voiceTypeButton`). */}
    <div
      style={{
        position: "relative",
        flex: 1,
        height: 36,
        margin: "0 6px 0 2px",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 8,
        borderRadius: 18,
        border: "0.5px solid rgb(0 0 0 / 0.08)",
        background: `rgb(0 0 0 / ${0.07 + 0.1 * press})`,
        fontSize: 16,
        fontWeight: 500,
        scale: 1 - 0.03 * press,
      }}
    >
      <Glyph name="waveform" size={19} color={olive.oliveText} strokeWidth={2.4} />
      Voice type
    </div>
  </div>
);

const KeyRow: React.FC<{ readonly keys: readonly React.ReactNode[] }> = ({ keys }) => (
  <div style={{ display: "flex", justifyContent: "center", alignItems: "center", height: 53 }}>{keys}</div>
);

const keyStyle = (width: number, background: string): CSSProperties => ({
  flex: "none",
  width,
  height: 42,
  margin: "0 3px",
  display: "grid",
  placeItems: "center",
  borderRadius: 8,
  background,
  boxShadow: "0 1px 0 rgb(0 0 0 / 0.3)",
  lineHeight: 1,
});

const LetterKey: React.FC<{ readonly label: string }> = ({ label }) => (
  <div style={{ ...keyStyle(key(1), "#ffffff"), fontSize: 25 }}>{label}</div>
);

const TextKey: React.FC<{ readonly width: number; readonly label: string; readonly mod: boolean }> = ({ width, label, mod }) => (
  <div style={{ ...keyStyle(width, mod ? olive.keyboardMod : "#ffffff"), fontSize: 16 }}>{label}</div>
);

const ModKey: React.FC<{ readonly width: number; readonly glyph: "shiftFill" | "deleteLeft" | "faceSmiling" | "mic" | "returnKey"; readonly light: boolean }> = ({
  width,
  glyph,
  light,
}) => (
  <div style={keyStyle(width, light ? "#ffffff" : olive.keyboardMod)}>
    <Glyph name={glyph} size={22} color="#000000" strokeWidth={1.6} />
  </div>
);

/** KeyboardDictationView while listening: cancel, finish with its pulse, glow, 28 bars and "Live typing on". */
const DictationPanel: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const loudest: number = Math.max(...state.levels.slice(-4));
  const strength: number = 0.45 + 0.55 * loudest;
  const phase: number = ((state.frame / 30) % 1.6) / 1.6;
  return (
    <div style={abs({ left: 0, right: 0, top: 0, height: 260, opacity: state.panel, scale: 0.97 + 0.03 * state.panel })}>
      {/* KeyboardDictationGlow: the lime fill as a wide radial gradient, brighter with the voice. */}
      <div
        style={abs({
          inset: 0,
          background: `radial-gradient(${(0.36 + 0.1 * strength) * 260 * 1.6}px ${(0.36 + 0.1 * strength) * 260}px at 50% 50%, rgb(181 196 71 / ${0.32 * strength * 1.6}) 0%, rgb(181 196 71 / 0) 100%)`,
        })}
      />
      <div style={abs({ top: 10, left: 12, width: 44, height: 44, borderRadius: 22, background: "rgb(0 0 0 / 0.08)", display: "grid", placeItems: "center" })}>
        <Glyph name="xmark" size={18} color="rgb(0 0 0 / 0.75)" strokeWidth={2.4} />
      </div>
      <div style={abs({ top: 10, right: 12, width: 44, height: 44 })}>
        <div
          style={abs({
            inset: 0,
            borderRadius: 22,
            border: `2px solid ${olive.lime}`,
            boxSizing: "border-box",
            scale: 1 + 0.45 * phase,
            opacity: 0.6 * (1 - phase) * state.marked,
          })}
        />
        <div
          style={abs({
            inset: 0,
            borderRadius: 22,
            background: olive.lime,
            boxShadow: "0 3px 8px rgb(181 196 71 / 0.45)",
            display: "grid",
            placeItems: "center",
          })}
        >
          <Glyph name="checkmark" size={20} color={olive.onLime} strokeWidth={2.8} />
        </div>
      </div>
      <div style={abs({ top: 54, left: 20, right: 20, height: 206, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 14 })}>
        <div style={{ height: 56, display: "flex", alignItems: "center", gap: 4 }}>
          {state.levels.map((level: number, index: number) => (
            <div
              // The bars are positional: index is their identity.
              key={`bar-${index}`}
              style={{
                width: 4,
                height: Math.max(4, 56 * (0.08 + 0.92 * level)),
                borderRadius: 2,
                background: `linear-gradient(180deg, ${olive.oliveText}, rgb(95 107 20 / 0.55))`,
                opacity: 0.45 + (0.55 * (index + 1)) / state.levels.length,
              }}
            />
          ))}
        </div>
        <div
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 6,
            height: 32,
            padding: "0 14px",
            borderRadius: 16,
            border: "0.5px solid rgb(95 107 20 / 0.3)",
            background: "rgb(95 107 20 / 0.14)",
            color: olive.oliveText,
            fontSize: 14,
            fontWeight: 500,
            whiteSpace: "nowrap",
          }}
        >
          <Glyph name="textCursor" size={15} color={olive.oliveText} strokeWidth={2} />
          Live typing on
        </div>
      </div>
    </div>
  );
};

/** The Gistsmith app (Olive light) as the old keyboard flow opened it: "Microphone ready", go back and tap again. */
const AppScreen: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  if (state.appShift <= 0.001) {
    return null;
  }
  return (
    <div style={abs({ inset: 0, translate: `${(1 - state.appShift) * SCREEN_W}px 0px`, background: olive.paper, color: olive.paperInk, boxShadow: "-10px 0 30px rgb(0 0 0 / 0.18)" })}>
      <div style={abs({ top: 74, left: 22, fontFamily: serifFamily, fontSize: 34 })}>Gistsmith</div>
      <div style={abs({ top: 132, left: 22, fontSize: 13, fontWeight: 600, color: olive.paperMuted, letterSpacing: "0.02em" })}>Today</div>
      {["Weekly sync", "Design review", "Customer call"].map((title: string, index: number) => (
        <div
          key={title}
          style={abs({
            top: 158 + index * 86,
            left: 16,
            right: 16,
            height: 74,
            borderRadius: 18,
            background: olive.paperCard,
            border: `1px solid ${olive.paperLine}`,
            padding: "14px 16px",
            boxSizing: "border-box",
          })}
        >
          <div style={{ fontSize: 16, fontWeight: 600 }}>{title}</div>
          <div style={{ marginTop: 8, width: `${70 - index * 12}%`, height: 8, borderRadius: 4, background: olive.paperLine }} />
        </div>
      ))}
      <div style={abs({ inset: 0, background: `rgb(0 0 0 / ${0.32 * state.handoffCard})` })} />
      <div
        style={abs({
          top: 330,
          left: 60,
          width: 320,
          padding: 24,
          boxSizing: "border-box",
          borderRadius: 28,
          background: olive.paperCard,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          gap: 14,
          opacity: state.handoffCard,
          scale: 0.94 + 0.06 * state.handoffCard,
          boxShadow: "0 20px 50px rgb(0 0 0 / 0.25)",
        })}
      >
        <div style={{ width: 72, height: 72, borderRadius: 36, background: olive.oliveSoft, display: "grid", placeItems: "center" }}>
          <Glyph name="waveform" size={32} color={olive.oliveText} strokeWidth={2.4} />
        </div>
        <div style={{ fontFamily: serifFamily, fontSize: 24 }}>Microphone ready</div>
        <div style={{ fontSize: 15, lineHeight: "20px", color: olive.paperMuted, textAlign: "center" }}>
          Go back to the app you were typing in, then tap the microphone on the keyboard.
        </div>
      </div>
    </div>
  );
};

const TouchMark: React.FC<{ readonly touch: Touch }> = ({ touch }) => {
  const rising: boolean = touch.progress < 0.3;
  const opacity: number = rising ? touch.progress / 0.3 : 1 - (touch.progress - 0.3) / 0.7;
  const scale: number = rising ? 0.6 + 0.4 * (touch.progress / 0.3) : 1 + 0.2 * ((touch.progress - 0.3) / 0.7);
  return (
    <div
      style={abs({
        left: touch.x - 23,
        top: touch.y - 23,
        width: 46,
        height: 46,
        borderRadius: 23,
        border: "2px solid rgb(255 255 255 / 0.85)",
        background: "rgb(0 0 0 / 0.22)",
        boxSizing: "border-box",
        opacity,
        scale,
      })}
    />
  );
};
