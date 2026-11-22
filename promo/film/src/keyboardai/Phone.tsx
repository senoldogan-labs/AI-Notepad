import type { CSSProperties } from "react";
import { fontFamily } from "../brand";
import { Glyph } from "../voicetype/Glyph";
import { ParticleField } from "./ParticleField";
import type { ChatMessage, Panel, PhoneState, TopBar, Touch } from "./script";
import type { KeyboardAccent, Surfaces } from "./theme";

/**
 * An iPhone (440 × 956 pt screen) with a chat open and the Gistsmith Keyboard drawn after the real one: the iOS 26
 * keyboard sheet, the top bar (KeyboardViews.swift `KeyboardTopBar`: suggestions with "Ask Gistsmith" and "Voice type",
 * the ask field with its caret, the answering and answered strips with Copy and Add), the key grid
 * (KeyboardGridView.swift: white 0.42 keys, white 0.27 modifiers, 8.5 pt corners, pop-up preview) and the compact
 * dictation panel (`KeyboardDictationView`: status line, capsule with cancel, the voice field and Done, the space,
 * delete and return row). `scale` sizes it in pixels.
 */
export const PHONE_WIDTH = 465.14;
export const PHONE_HEIGHT = 981.14;
export const PHONE_CORNER = 74.57;
const SCREEN_W = 440;
const SCREEN_H = 956;
/** Keyboard sheet tops with keys and with the dictation panel (KeyboardViewController `keyboardHeight`: 260 / 166 + the system bar). */
const SHEET_TOP_KEYS = 571;
const SHEET_TOP_PANEL = 699;

const abs = (style: CSSProperties): CSSProperties => ({ position: "absolute", ...style });
const alpha = (hex: string, opacity: number): string => {
  const value: number = parseInt(hex.slice(1), 16);
  return `rgb(${(value >> 16) & 255} ${(value >> 8) & 255} ${value & 255} / ${opacity})`;
};
const tint = (accent: KeyboardAccent, isDark: boolean): string => (isDark ? accent.tintDark : accent.tintLight);
const fill = (accent: KeyboardAccent, isDark: boolean): string => (isDark ? accent.fillDark : accent.fillLight);
const onFill = (accent: KeyboardAccent, isDark: boolean): string => (isDark ? accent.onFillDark : accent.onFillLight);

export const sheetTop = (panel: Panel): number => SHEET_TOP_KEYS + (SHEET_TOP_PANEL - SHEET_TOP_KEYS) * panel.shown;

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
        background: "linear-gradient(135deg, #8d8682 0%, #3b3633 14%, #221f1d 48%, #3b3633 86%, #7f7873 100%)",
        boxShadow: "0 2px 3px rgb(0 0 0 / 0.35), 0 50px 120px rgb(0 0 0 / 0.6)",
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
            background: state.surfaces.screen,
            color: state.surfaces.ink,
            fontFamily,
            fontSize: 17,
            lineHeight: 1.3,
            letterSpacing: "-0.01em",
          }}
        >
          <ChatScreen state={state} />
          <KeyboardSheet state={state} />
          <StatusBar state={state} />
          <div style={abs({ left: 150, bottom: 8, width: 140, height: 5, borderRadius: 3, background: state.surfaces.ink, opacity: 0.85 })} />
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
    <div style={abs({ top: 18, left: 46, width: 64, fontSize: 17, fontWeight: 600, textAlign: "center" })}>9:41</div>
    <div style={abs({ top: 22, right: 34, display: "flex", alignItems: "center", gap: 6 })}>
      <Glyph name="signal" size={17} color={state.surfaces.ink} strokeWidth={0} />
      <Glyph name="wifi" size={17} color={state.surfaces.ink} strokeWidth={0} />
      <div style={{ width: 27, height: 13, padding: 2, border: `1.2px solid ${alpha(state.surfaces.ink, 0.4)}`, borderRadius: 4, boxSizing: "border-box" }}>
        <div style={{ width: "82%", height: "100%", borderRadius: 1.5, background: state.surfaces.ink }} />
      </div>
    </div>
    <div style={abs({ top: 11, left: 120, width: 200, height: 37.33, borderRadius: 18.67, background: "#000000" })} />
  </>
);

// MARK: Chat

const ChatScreen: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const s: Surfaces = state.surfaces;
  const top: number = sheetTop(state.panel);
  const text: string = state.draft + state.marked;
  const lines: number = text.length === 0 ? 1 : text.split("\n").reduce((sum: number, line: string): number => sum + Math.max(1, Math.ceil(line.length / 34)), 0);
  const fieldH: number = 16 + 22 * Math.min(4, lines);
  const fieldTop: number = top - 12 - fieldH;
  return (
    <div style={abs({ inset: 0 })}>
      <div style={abs({ top: 70, left: 0, right: 0, height: 74, borderBottom: `0.5px solid ${alpha(s.ink, 0.12)}` })}>
        <div style={abs({ top: 12, left: 16 })}>
          <Glyph name="chevronLeft" size={24} color="#0a84ff" strokeWidth={2.4} />
        </div>
        <div style={abs({ top: 0, left: 0, right: 0, display: "flex", flexDirection: "column", alignItems: "center", gap: 4 })}>
          <div style={{ width: 44, height: 44, borderRadius: 22, display: "grid", placeItems: "center", background: "linear-gradient(180deg, #c99a7e, #9c6d55)", color: "#ffffff", fontSize: 18, fontWeight: 600 }}>
            E
          </div>
          <div style={{ fontSize: 12, fontWeight: 500 }}>Ella</div>
        </div>
      </div>
      <div style={abs({ left: 14, right: 14, top: 145, bottom: SCREEN_H - (fieldTop - 14), display: "flex", flexDirection: "column", justifyContent: "flex-end", gap: 6, overflow: "hidden" })}>
        <div style={{ alignSelf: "center", margin: "0 0 4px", fontSize: 12, color: s.muted, flex: "none" }}>Today 9:38</div>
        {state.messages.map((message: ChatMessage) => (
          <Bubble key={message.text} message={message} surfaces={s} />
        ))}
      </div>
      <div style={abs({ top: fieldTop + fieldH - 34, left: 12, width: 34, height: 34, borderRadius: 17, background: alpha(s.ink, 0.1), display: "grid", placeItems: "center" })}>
        <Glyph name="plus" size={19} color={alpha(s.ink, 0.6)} strokeWidth={2.2} />
      </div>
      <div style={abs({ top: fieldTop, left: 54, width: 374, height: fieldH, border: `1px solid ${s.fieldLine}`, borderRadius: 18, background: s.field, boxSizing: "border-box" })}>
        <div style={abs({ top: 7, left: 14, right: 40, lineHeight: "22px", whiteSpace: "pre-wrap", overflow: "hidden", maxHeight: 88, display: "flex", flexDirection: "column", justifyContent: "flex-end" })}>
          {text.length === 0 ? (
            <div>
              {state.caret ? <Caret frame={state.frame} /> : null}
              <span style={{ color: s.muted }}>Message</span>
            </div>
          ) : (
            <div>
              <span>{state.draft}</span>
              <span style={{ textDecorationLine: "underline", textDecorationColor: alpha("#0a84ff", 0.9), textDecorationThickness: 1.5, textUnderlineOffset: 3 }}>{state.marked}</span>
              {state.caret ? <Caret frame={state.frame} /> : null}
            </div>
          )}
        </div>
        <div
          style={abs({
            right: 4,
            bottom: 3,
            width: 28,
            height: 28,
            borderRadius: 14,
            background: "#0a84ff",
            display: "grid",
            placeItems: "center",
            opacity: text.length > 0 ? 1 : 0,
            scale: 1 - 0.12 * state.sendPress,
          })}
        >
          <Glyph name="arrowUp" size={16} color="#ffffff" strokeWidth={2.6} />
        </div>
      </div>
    </div>
  );
};

const Bubble: React.FC<{ readonly message: ChatMessage; readonly surfaces: Surfaces }> = ({ message, surfaces }) => (
  <div
    style={{
      alignSelf: message.mine ? "flex-end" : "flex-start",
      maxWidth: "76%",
      padding: "7px 13px",
      borderRadius: 18,
      background: message.mine ? surfaces.bubbleOut : surfaces.bubbleIn,
      color: message.mine ? surfaces.onBubbleOut : surfaces.ink,
      lineHeight: "22px",
      whiteSpace: "pre-wrap",
      flex: "none",
      opacity: message.opacity,
      translate: `0px ${(1 - message.opacity) * 10}px`,
    }}
  >
    {message.text}
  </div>
);

const Caret: React.FC<{ readonly frame: number }> = ({ frame }) => (
  <span
    style={{
      display: "inline-block",
      width: 2,
      height: 21,
      margin: "0 1px",
      verticalAlign: "-4px",
      borderRadius: 1,
      background: "#0a84ff",
      opacity: Math.floor(frame / 16) % 2 === 0 ? 1 : 0,
    }}
  />
);

// MARK: Keyboard

const KeyboardSheet: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const top: number = sheetTop(state.panel);
  return (
    <div style={abs({ left: 0, right: 0, top, bottom: 0, borderRadius: "30px 30px 0 0", background: state.surfaces.sheet, overflow: "hidden" })}>
      <div style={abs({ left: 0, right: 0, top: 0, height: 320, opacity: 1 - state.panel.shown })}>
        <TopBarView state={state} />
        <Keys state={state} />
      </div>
      {state.panel.shown > 0.01 ? <DictationPanel state={state} /> : null}
      <div style={abs({ bottom: 30, left: 32 })}>
        <Glyph name="globe" size={30} color={alpha(state.surfaces.ink, 0.85)} strokeWidth={1.5} />
      </div>
    </div>
  );
};

const xmarkCircle = (s: Surfaces, size: number, isDark: boolean): React.ReactNode => (
  <div style={{ flex: "none", width: size, height: size, borderRadius: size / 2, display: "grid", placeItems: "center", background: alpha(s.ink, isDark ? 0.12 : 0.08) }}>
    <Glyph name="xmark" size={size * 0.42} color={alpha(s.ink, 0.7)} strokeWidth={2.4} />
  </div>
);

const pill = (label: string, background: string, color: string, pressed: number): React.ReactNode => (
  <div style={{ flex: "none", height: 34, padding: "0 14px", borderRadius: 17, display: "grid", placeItems: "center", background, color, fontSize: 15, fontWeight: 600, scale: 1 - 0.06 * pressed }}>
    {label}
  </div>
);

const TopBarView: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const s: Surfaces = state.surfaces;
  const bar: TopBar = state.topBar;
  const accent: string = tint(state.accent, state.isDark);
  const row: CSSProperties = abs({ top: 20, left: 0, right: 0, height: 44, display: "flex", alignItems: "center", gap: 8, padding: "0 8px", boxSizing: "border-box" });
  switch (bar.kind) {
    case "suggestions":
      return (
        <div style={{ ...row, gap: 0, padding: "0 4px" }}>
          <div style={{ width: 44, height: 40, display: "grid", placeItems: "center" }}>
            <Glyph name="textBadgePlus" size={22} color={alpha(s.ink, 0.7)} strokeWidth={1.9} />
          </div>
          <div style={{ width: 40, height: 40, display: "grid", placeItems: "center", borderRadius: 20, background: alpha(s.ink, 0.12 * bar.sparklePress), scale: 1 - 0.08 * bar.sparklePress }}>
            <Glyph name="sparkles" size={21} color={accent} strokeWidth={0} />
          </div>
          <div
            style={{
              flex: 1,
              height: 36,
              margin: "0 6px 0 2px",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 8,
              borderRadius: 18,
              border: `0.5px solid ${alpha(s.ink, 0.08)}`,
              background: alpha(s.ink, (state.isDark ? 0.14 : 0.07) + 0.12 * bar.voicePress),
              fontSize: 16,
              fontWeight: 500,
              scale: 1 - 0.03 * bar.voicePress,
            }}
          >
            <Glyph name="waveform" size={19} color={accent} strokeWidth={2.4} />
            Voice type
          </div>
        </div>
      );
    case "askField":
      return (
        <div style={row}>
          {xmarkCircle(s, 36, state.isDark)}
          <Glyph name="sparkles" size={19} color={accent} strokeWidth={0} />
          <div style={{ flex: 1, minWidth: 0, display: "flex", alignItems: "center", fontSize: 15, whiteSpace: "nowrap", overflow: "hidden" }}>
            {bar.question.length === 0 ? <AskCaret frame={state.frame} color={accent} /> : null}
            <span style={{ color: bar.question.length === 0 ? alpha(s.ink, 0.5) : s.ink }}>{bar.question.length === 0 ? "Ask Gistsmith…" : bar.question}</span>
            {bar.question.length > 0 ? <AskCaret frame={state.frame} color={accent} /> : null}
          </div>
          {pill("Ask", accent, "#ffffff", bar.askPress)}
        </div>
      );
    case "answering":
      return (
        <div style={row}>
          {xmarkCircle(s, 36, state.isDark)}
          <Spinner frame={state.frame} color={alpha(s.ink, 0.6)} />
          <div style={{ flex: 1, fontSize: 15, color: alpha(s.ink, 0.55), whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>Gistsmith is checking your meetings…</div>
        </div>
      );
    case "answered":
      return (
        <div style={row}>
          {xmarkCircle(s, 36, state.isDark)}
          <div style={{ flex: 1, minWidth: 0, fontSize: 15, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{bar.answer}</div>
          {pill("Copy", alpha(s.ink, 0.08), accent, 0)}
          {pill("Add", accent, "#ffffff", bar.addPress)}
        </div>
      );
  }
};

/** KeyboardAskCaret: a blinking accent bar. */
const AskCaret: React.FC<{ readonly frame: number; readonly color: string }> = ({ frame, color }) => (
  <span style={{ flex: "none", display: "inline-block", width: 2, height: 19, margin: "0 1px", borderRadius: 1, background: color, opacity: Math.floor(frame / 15) % 2 === 0 ? 1 : 0.1 }} />
);

/** The system ProgressView: eight fading spokes. */
const Spinner: React.FC<{ readonly frame: number; readonly color: string }> = ({ frame, color }) => (
  <svg width={20} height={20} viewBox="-10 -10 20 20" style={{ flex: "none" }}>
    {Array.from({ length: 8 }, (_: unknown, index: number) => {
      const angle: number = (index / 8) * Math.PI * 2;
      const lead: number = (Math.floor(frame / 3) % 8) - index;
      const opacity: number = 0.25 + 0.75 * (((lead % 8) + 8) % 8 === 0 ? 1 : Math.max(0, 1 - (((lead % 8) + 8) % 8) / 6));
      return (
        <line
          key={index}
          x1={Math.cos(angle) * 4.5}
          y1={Math.sin(angle) * 4.5}
          x2={Math.cos(angle) * 8}
          y2={Math.sin(angle) * 8}
          stroke={color}
          strokeWidth={2.1}
          strokeLinecap="round"
          opacity={opacity}
        />
      );
    })}
  </svg>
);

/** Row centres relative to the sheet top, key height 45, 6 pt gaps: the 10-key row fills 434 pt. */
const ROW_Y: readonly number[] = [97, 156, 213, 272];
const KEY_H = 45;
const KEY_W = 38;

type KeySpec = { readonly id: string; readonly width: number; readonly mod: boolean; readonly content: React.ReactNode };

const Keys: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const s: Surfaces = state.surfaces;
  const letter = (character: string): KeySpec => ({ id: character, width: KEY_W, mod: false, content: <span style={{ fontSize: 25 }}>{character}</span> });
  const rows: readonly (readonly KeySpec[])[] = [
    [..."QWERTYUIOP"].map(letter),
    [..."ASDFGHJKL"].map(letter),
    [
      { id: "shift", width: 50, mod: true, content: <Glyph name="shiftFill" size={22} color={s.keyInk} strokeWidth={0} /> },
      ...[..."ZXCVBNM"].map(letter),
      { id: "delete", width: 50, mod: true, content: <Glyph name="deleteLeft" size={23} color={s.keyInk} strokeWidth={1.7} /> },
    ],
    [
      { id: "123", width: 44, mod: true, content: <span style={{ fontSize: 17 }}>123</span> },
      { id: "emoji", width: 42, mod: true, content: <Glyph name="faceSmiling" size={24} color={s.keyInk} strokeWidth={1.7} /> },
      { id: "space", width: 206, mod: false, content: <span style={{ fontSize: 16 }}>space</span> },
      { id: "mic", width: 42, mod: true, content: <Glyph name="mic" size={22} color={tint(state.accent, state.isDark)} strokeWidth={1.9} /> },
      { id: "return", width: 70, mod: true, content: <Glyph name="returnKey" size={23} color={s.keyInk} strokeWidth={1.9} /> },
    ],
  ];
  return (
    <>
      {rows.map((row: readonly KeySpec[], rowIndex: number) => {
        const total: number = row.reduce((sum: number, spec: KeySpec): number => sum + spec.width, 0) + 6 * (row.length - 1);
        let x: number = (SCREEN_W - total) / 2;
        return row.map((spec: KeySpec) => {
          const left: number = x;
          x += spec.width + 6;
          const down: boolean = state.keyDown === spec.id;
          const top: number = (ROW_Y[rowIndex] ?? 0) - KEY_H / 2;
          return (
            <div key={spec.id}>
              <div
                style={abs({
                  left,
                  top,
                  width: spec.width,
                  height: KEY_H,
                  borderRadius: 8.5,
                  display: "grid",
                  placeItems: "center",
                  background: down ? (spec.mod ? s.key : s.keyMod) : spec.mod ? s.keyMod : s.key,
                  boxShadow: `0 1px 0 rgb(0 0 0 / ${state.isDark ? 0.35 : 0.22})`,
                  color: s.keyInk,
                  lineHeight: 1,
                  backgroundImage: `linear-gradient(180deg, ${alpha("#ffffff", state.isDark ? 0.06 : 0.0)}, transparent 60%)`,
                })}
              >
                {spec.content}
              </div>
              {down && !spec.mod && spec.id !== "space" ? <KeyPopup left={left} top={top} width={spec.width} label={spec.id} surfaces={s} /> : null}
            </div>
          );
        });
      })}
    </>
  );
};

/** KeyPopupView's preview: the letter, larger, above the finger. */
const KeyPopup: React.FC<{ readonly left: number; readonly top: number; readonly width: number; readonly label: string; readonly surfaces: Surfaces }> = ({
  left,
  top,
  width,
  label,
  surfaces,
}) => (
  <div
    style={abs({
      left: left - 8,
      top: top - 60,
      width: width + 16,
      height: 58,
      borderRadius: 10,
      background: surfaces.key,
      boxShadow: "0 2px 4px rgb(0 0 0 / 0.25)",
      display: "grid",
      placeItems: "center",
      fontSize: 34,
      color: surfaces.keyInk,
    })}
  >
    {label}
  </div>
);

// MARK: Dictation panel

const DictationPanel: React.FC<{ readonly state: PhoneState }> = ({ state }) => {
  const s: Surfaces = state.surfaces;
  const panel: Panel = state.panel;
  const seconds: number = Math.floor(panel.seconds);
  const listening: boolean = panel.stage === "listening";
  return (
    <div style={abs({ left: 6, right: 6, top: 10, opacity: panel.shown, translate: `0px ${(1 - panel.shown) * 14}px` })}>
      <div style={{ height: 22, margin: "0 10px", display: "flex", alignItems: "center", gap: 8, fontSize: 15, fontWeight: 500 }}>
        {listening ? (
          <>
            <div style={{ width: 8, height: 8, borderRadius: 4, background: "#ff3b30" }} />
            <span style={{ color: alpha(s.ink, 0.85), fontVariantNumeric: "tabular-nums" }}>{`${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`}</span>
          </>
        ) : (
          <span style={{ color: alpha(s.ink, 0.6) }}>Transcribing…</span>
        )}
        <span style={{ flex: 1 }} />
        <span style={{ color: alpha(s.ink, 0.55) }}>English</span>
      </div>
      <div
        style={{
          marginTop: 10,
          height: 52,
          padding: "0 6px",
          display: "flex",
          alignItems: "center",
          gap: 8,
          borderRadius: 26,
          background: alpha(s.ink, state.isDark ? 0.07 : 0.045),
          boxShadow: `inset 0 0 0 0.5px ${alpha(s.ink, state.isDark ? 0.08 : 0.06)}`,
        }}
      >
        {xmarkCircle(s, 40, state.isDark)}
        <div style={{ flex: 1, height: 40 }}>
          <ParticleField width={262} height={40} accent={state.accent} isDark={state.isDark} level={listening ? panel.level : 0} mode={listening ? "listening" : "processing"} travel={panel.travel} time={state.frame / 30} />
        </div>
        <div
          style={{
            flex: "none",
            height: 40,
            padding: "0 18px",
            borderRadius: 20,
            display: "grid",
            placeItems: "center",
            background: fill(state.accent, state.isDark),
            color: onFill(state.accent, state.isDark),
            fontSize: 16,
            fontWeight: 600,
            opacity: listening ? 1 : 0.45,
            scale: 1 - 0.06 * panel.donePress,
          }}
        >
          Done
        </div>
      </div>
      <div style={{ marginTop: 10, height: 46, display: "flex", gap: 6 }}>
        {[
          { id: "space", width: 0, content: <span style={{ fontSize: 16 }}>space</span> },
          { id: "delete", width: 64, content: <Glyph name="deleteLeft" size={20} color={alpha(s.ink, 0.85)} strokeWidth={1.7} /> },
          { id: "return", width: 72, content: <Glyph name="returnKey" size={20} color={alpha(s.ink, 0.85)} strokeWidth={1.9} /> },
        ].map((spec: { readonly id: string; readonly width: number; readonly content: React.ReactNode }) => (
          <div
            key={spec.id}
            style={{
              flex: spec.width === 0 ? 1 : "none",
              width: spec.width === 0 ? undefined : spec.width,
              borderRadius: 8.5,
              display: "grid",
              placeItems: "center",
              color: alpha(s.ink, 0.85),
              background: alpha(s.ink, state.isDark ? 0.14 : 0.08),
            }}
          >
            {spec.content}
          </div>
        ))}
      </div>
    </div>
  );
};

const TouchMark: React.FC<{ readonly touch: Touch }> = ({ touch }) => {
  const grow: number = Math.min(1, touch.progress / 0.3);
  const fade: number = touch.progress < 0.3 ? 1 : 1 - (touch.progress - 0.3) / 0.7;
  return (
    <div
      style={abs({
        left: touch.x - 22,
        top: touch.y - 22,
        width: 44,
        height: 44,
        borderRadius: 22,
        background: "rgb(255 255 255 / 0.35)",
        border: "1.5px solid rgb(255 255 255 / 0.7)",
        boxShadow: "0 0 0 1px rgb(0 0 0 / 0.15)",
        opacity: 0.9 * fade,
        scale: 0.6 + 0.4 * grow,
      })}
    />
  );
};
