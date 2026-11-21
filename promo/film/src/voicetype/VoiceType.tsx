import type { CSSProperties } from "react";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { fontFamily } from "../brand";
import { olive, serifFamily } from "./olive";
import { Phone, PHONE_CORNER, PHONE_HEIGHT, PHONE_WIDTH } from "./Phone";
import {
  AFTER_START,
  afterState,
  BEFORE_START,
  beforeState,
  beforeSwitches,
  CROSS,
  END_START,
  loopState,
  ramp,
  window01,
} from "./script";

/**
 * "Voice type without switching apps": a hook, the old way (the keyboard sends you to the Gistsmith app and you find
 * your way back), the new way (the keyboard listens and types in place) and an end card. Silent by design: it reads
 * with the sound off. 9:16 and 1:1 share the parts and differ in layout only (`Layout`).
 */
type Layout = {
  readonly tagTop: number;
  readonly textLeft: number;
  readonly textWidth: number;
  readonly textAlign: "left" | "center";
  readonly headlineTop: number;
  readonly headlineSize: number;
  readonly subSize: number;
  readonly phoneLeft: number;
  readonly phoneTop: number;
  readonly phoneScale: number;
  readonly counterTop: number;
};

const PORTRAIT: Layout = {
  tagTop: 150,
  textLeft: 70,
  textWidth: 940,
  textAlign: "center",
  headlineTop: 238,
  headlineSize: 86,
  subSize: 44,
  phoneLeft: (1080 - PHONE_WIDTH * 1.17) / 2,
  phoneTop: 520,
  phoneScale: 1.17,
  counterTop: 1716,
};

const SQUARE: Layout = {
  tagTop: 132,
  textLeft: 76,
  textWidth: 450,
  textAlign: "left",
  headlineTop: 212,
  headlineSize: 66,
  subSize: 34,
  phoneLeft: 1080 - 64 - PHONE_WIDTH * 0.955,
  phoneTop: (1080 - PHONE_HEIGHT * 0.955) / 2,
  phoneScale: 0.955,
  counterTop: 700,
};

/** Each part's presence (0…1): the previous part's copy fades out before the next one rises in. Pure function. */
const parts = (frame: number): { readonly hook: number; readonly before: number; readonly after: number; readonly end: number } => ({
  hook: 1 - ramp(frame, BEFORE_START - CROSS, CROSS / 2),
  before: window01(frame, BEFORE_START - CROSS / 2, CROSS, AFTER_START - CROSS, CROSS / 2),
  after: window01(frame, AFTER_START - CROSS / 2, CROSS, END_START - CROSS, CROSS / 2),
  end: ramp(frame, END_START - 2, 18),
});

/** The quiet film field: Olive's charcoal, a faint lime light from the top, a little grain. */
const Field: React.FC = () => (
  <AbsoluteFill style={{ backgroundColor: olive.night }}>
    <AbsoluteFill style={{ backgroundImage: "radial-gradient(70% 45% at 50% 0%, rgb(181 196 71 / 0.14) 0%, transparent 70%), radial-gradient(60% 40% at 50% 100%, rgb(255 255 255 / 0.04) 0%, transparent 70%)" }} />
    <Img src={staticFile("grain.png")} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover", opacity: 0.07, mixBlendMode: "screen" }} />
  </AbsoluteFill>
);

/** A line of copy that rises in with its part. */
const Rise: React.FC<{ readonly presence: number; readonly style: CSSProperties; readonly children: React.ReactNode }> = ({ presence, style, children }) => (
  <div style={{ position: "absolute", opacity: presence, translate: `0px ${(1 - presence) * 24}px`, ...style }}>{children}</div>
);

const Tag: React.FC<{ readonly label: string; readonly filled: boolean }> = ({ label, filled }) => (
  <span
    style={{
      display: "inline-block",
      padding: "10px 20px 9px",
      borderRadius: 12,
      fontFamily,
      fontSize: 30,
      fontWeight: 600,
      letterSpacing: "0.01em",
      color: filled ? olive.onLime : olive.nightInk,
      background: filled ? olive.lime : "transparent",
      border: filled ? `2px solid ${olive.lime}` : "2px solid #6a6a64",
    }}
  >
    {label}
  </span>
);

const Copy: React.FC<{ readonly layout: Layout; readonly frame: number }> = ({ layout, frame }) => {
  const on = parts(frame);
  const block: CSSProperties = { left: layout.textLeft, width: layout.textWidth, textAlign: layout.textAlign };
  const headline: CSSProperties = {
    ...block,
    top: layout.headlineTop,
    fontFamily: serifFamily,
    fontSize: layout.headlineSize,
    lineHeight: 1.06,
    letterSpacing: "-0.02em",
    color: olive.nightInk,
    textWrap: "balance",
  };
  const sub: CSSProperties = { fontFamily, fontSize: layout.subSize, fontWeight: 500, lineHeight: 1.25, letterSpacing: "-0.01em", color: olive.nightMuted, marginTop: 26 };
  return (
    <>
      <Rise presence={on.hook * ramp(frame, 4, 16)} style={headline}>
        No more app switching.
        <div style={{ ...sub, opacity: ramp(frame, 18, 14) }}>
          Voice type <span style={{ color: olive.lime }}>right in the keyboard.</span>
        </div>
      </Rise>
      <Rise presence={on.before} style={{ ...block, top: layout.tagTop }}>
        <Tag label="Before" filled={false} />
      </Rise>
      <Rise presence={on.before} style={headline}>
        Tap, leave for the app, find your way back.
      </Rise>
      <Rise presence={on.after} style={{ ...block, top: layout.tagTop }}>
        <Tag label="Now" filled />
      </Rise>
      <Rise presence={on.after} style={headline}>
        Tap and talk.
        <br />
        <span style={{ color: olive.lime }}>It types in place.</span>
      </Rise>
    </>
  );
};

/** "App switches" with its count: it climbs in Before and stays at zero Now. */
const Counter: React.FC<{ readonly layout: Layout; readonly frame: number }> = ({ layout, frame }) => {
  const on = parts(frame);
  const b: number = frame - BEFORE_START;
  const count: number = on.after > on.before ? 0 : beforeSwitches(b);
  const bump: number = window01(b, 26, 3, 30, 8) + window01(b, 76, 3, 80, 8);
  const presence: number = Math.max(on.before, on.after);
  const numberColor: string = on.after > on.before ? olive.lime : olive.nightInk;
  return (
    <div
      style={{
        position: "absolute",
        top: layout.counterTop,
        left: layout.textLeft,
        width: layout.textWidth,
        display: "flex",
        alignItems: "baseline",
        justifyContent: layout.textAlign === "center" ? "center" : "flex-start",
        gap: 22,
        opacity: presence,
      }}
    >
      <span style={{ fontFamily: serifFamily, fontSize: 120, lineHeight: 1, color: numberColor, display: "inline-block", scale: 1 + 0.12 * bump, fontVariantNumeric: "tabular-nums" }}>{count}</span>
      <span style={{ fontFamily, fontSize: 36, fontWeight: 500, color: olive.nightMuted }}>{count === 1 ? "app switch" : "app switches"}</span>
    </div>
  );
};

const EndCard: React.FC<{ readonly frame: number; readonly presence: number }> = ({ frame, presence }) => (
  <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: presence, scale: interpolate(frame, [END_START, END_START + 90], [0.97, 1.01], { extrapolateRight: "clamp" }) }}>
    <Img src={staticFile("icon.png")} style={{ width: 250, height: 250, marginBottom: 8, filter: "drop-shadow(0 24px 40px rgb(0 0 0 / 0.45))" }} />
    <div style={{ fontFamily: serifFamily, fontSize: 132, lineHeight: 1, letterSpacing: "-0.02em", color: olive.nightInk }}>Gistsmith</div>
    <div style={{ marginTop: 26, fontFamily, fontSize: 40, fontWeight: 500, color: olive.nightMuted, letterSpacing: "-0.01em" }}>Gistsmith Keyboard · iPhone</div>
    <div style={{ marginTop: 54, fontFamily, fontSize: 46, fontWeight: 600, color: olive.lime, letterSpacing: "-0.01em" }}>gistsmith.com</div>
  </AbsoluteFill>
);

const PhoneStage: React.FC<{ readonly layout: Layout; readonly frame: number }> = ({ layout, frame }) => {
  const enter: number = ramp(frame, 12, 30);
  const leave: number = ramp(frame, END_START - 8, 18);
  const afterOn: number = interpolate(frame, [AFTER_START - 10, AFTER_START + 6], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.inOut(Easing.cubic),
  });
  const place: CSSProperties = {
    position: "absolute",
    left: layout.phoneLeft,
    top: layout.phoneTop,
    translate: `0px ${(1 - enter) * 260 + leave * 160}px`,
    opacity: enter * (1 - leave),
  };
  return (
    <>
      {/* Before gives way to Now with a wipe across the phone, a lime edge leading it. */}
      {afterOn < 1 ? (
        <div style={place}>
          <Phone state={beforeState(frame - BEFORE_START, frame)} scale={layout.phoneScale} />
        </div>
      ) : null}
      {afterOn > 0 ? (
        <div style={afterOn < 1 ? { ...place, clipPath: `inset(0 ${(1 - afterOn) * 100}% 0 0 round ${PHONE_CORNER * layout.phoneScale}px)` } : place}>
          <Phone state={afterState(frame - AFTER_START, frame)} scale={layout.phoneScale} />
        </div>
      ) : null}
      {afterOn > 0 && afterOn < 1 ? (
        <div
          style={{
            position: "absolute",
            left: layout.phoneLeft + afterOn * PHONE_WIDTH * layout.phoneScale - 3,
            top: layout.phoneTop - 30,
            width: 6,
            height: PHONE_HEIGHT * layout.phoneScale + 60,
            borderRadius: 3,
            background: olive.lime,
            boxShadow: "0 0 30px rgb(181 196 71 / 0.6)",
          }}
        />
      ) : null}
    </>
  );
};

/** The announcement film, laid out for the frame it is rendered in (9:16 or 1:1). */
export const VoiceTypeBeforeAfter: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const layout: Layout = height > width ? PORTRAIT : SQUARE;
  return (
    <AbsoluteFill>
      <Field />
      <Copy layout={layout} frame={frame} />
      <PhoneStage layout={layout} frame={frame} />
      <Counter layout={layout} frame={frame} />
      <EndCard frame={frame} presence={parts(frame).end} />
    </AbsoluteFill>
  );
};

/** The website loop: the new way alone, phone only, seamless (1080 × 1350). */
export const VoiceTypeLoop: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const scale: number = (height - 100) / PHONE_HEIGHT;
  return (
    <AbsoluteFill>
      <Field />
      <div style={{ position: "absolute", left: (width - PHONE_WIDTH * scale) / 2, top: (height - PHONE_HEIGHT * scale) / 2 }}>
        <Phone state={loopState(frame)} scale={scale} />
      </div>
    </AbsoluteFill>
  );
};
