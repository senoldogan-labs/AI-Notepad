/**
 * Colours of the Gistsmith Keyboard film. The film field is the Ember dark palette (Theme.swift `emberDark`: warm black,
 * copper and sand light); the keyboard takes the user's Appearance accent exactly as the app writes it for the
 * keyboard (PhoneKeyboardHost.swift `phoneKeyboardTheme`, ThemeFamily.swift accents): tint, fill and the ink on fill,
 * per light and dark.
 */
export const field = {
  night: "#100e0d",
  card: "#1a1715",
  line: "#2e2824",
  ink: "#f5ede4",
  muted: "#a99e93",
  copper: "#e39a72",
  sand: "#d9c19e",
} as const;

export type KeyboardAccent = {
  readonly name: string;
  readonly tintLight: string;
  readonly tintDark: string;
  readonly fillLight: string;
  readonly fillDark: string;
  readonly onFillLight: string;
  readonly onFillDark: string;
};

/** Olive "Zeytin" (the apps' default accent). */
export const OLIVE_LIME: KeyboardAccent = {
  name: "Olive",
  tintLight: "#5f6b14",
  tintDark: "#b5c447",
  fillLight: "#b5c447",
  fillDark: "#b5c447",
  onFillLight: "#1e1f14",
  onFillDark: "#1e1f14",
};

/** Ember "Kor" (copper). */
export const EMBER_COPPER: KeyboardAccent = {
  name: "Ember",
  tintLight: "#984b2c",
  tintDark: "#e39a72",
  fillLight: "#984b2c",
  fillDark: "#e39a72",
  onFillLight: "#fffbf5",
  onFillDark: "#141110",
};

/** Olive "Mor" (violet). */
export const OLIVE_VIOLET: KeyboardAccent = {
  name: "Violet",
  tintLight: "#6640d6",
  tintDark: "#b7a2fa",
  fillLight: "#b7a2fa",
  fillDark: "#b7a2fa",
  onFillLight: "#1e1f14",
  onFillDark: "#1e1f14",
};

/** Olive "Mavi" (blue). */
export const OLIVE_BLUE: KeyboardAccent = {
  name: "Blue",
  tintLight: "#3755d0",
  tintDark: "#93a8f5",
  fillLight: "#93a8f5",
  fillDark: "#93a8f5",
  onFillLight: "#1e1f14",
  onFillDark: "#1e1f14",
};

/** The phone's system surfaces in dark and light (the keyboard greys from KeyboardGridView: white 0.42 / 0.27). */
export type Surfaces = {
  readonly screen: string;
  readonly ink: string;
  readonly muted: string;
  readonly bubbleIn: string;
  readonly bubbleOut: string;
  readonly onBubbleOut: string;
  readonly field: string;
  readonly fieldLine: string;
  readonly sheet: string;
  readonly key: string;
  readonly keyMod: string;
  readonly keyInk: string;
};

export const DARK: Surfaces = {
  screen: "#000000",
  ink: "#ffffff",
  muted: "#8e8e93",
  bubbleIn: "#262628",
  bubbleOut: "#0a84ff",
  onBubbleOut: "#ffffff",
  field: "#1c1c1e",
  fieldLine: "#3a3a3c",
  sheet: "#232323",
  key: "#6b6b6b",
  keyMod: "#454545",
  keyInk: "#ffffff",
};

export const LIGHT: Surfaces = {
  screen: "#ffffff",
  ink: "#000000",
  muted: "#8e8e93",
  bubbleIn: "#e9e9eb",
  bubbleOut: "#0a84ff",
  onBubbleOut: "#ffffff",
  field: "#ffffff",
  fieldLine: "#d1d1d6",
  sheet: "#e3e4e8",
  key: "#ffffff",
  keyMod: "#abb3bd",
  keyInk: "#000000",
};

/** Linear mix of two hex colours (`t` 0 → a, 1 → b). Pure function. */
export const mix = (a: string, b: string, t: number): string => {
  const parse = (hex: string): readonly number[] => [1, 3, 5].map((at: number): number => parseInt(hex.slice(at, at + 2), 16));
  const [ar, ag, ab] = parse(a);
  const [br, bg, bb] = parse(b);
  const channel = (x: number | undefined, y: number | undefined): string =>
    Math.round((x ?? 0) + ((y ?? 0) - (x ?? 0)) * Math.min(1, Math.max(0, t)))
      .toString(16)
      .padStart(2, "0");
  return `#${channel(ar, br)}${channel(ag, bg)}${channel(ab, bb)}`;
};

/** Blend of two accents. Pure function. */
export const mixAccent = (a: KeyboardAccent, b: KeyboardAccent, t: number): KeyboardAccent => ({
  name: t < 0.5 ? a.name : b.name,
  tintLight: mix(a.tintLight, b.tintLight, t),
  tintDark: mix(a.tintDark, b.tintDark, t),
  fillLight: mix(a.fillLight, b.fillLight, t),
  fillDark: mix(a.fillDark, b.fillDark, t),
  onFillLight: mix(a.onFillLight, b.onFillLight, t),
  onFillDark: mix(a.onFillDark, b.onFillDark, t),
});

/** Blend of two surface sets. Pure function. */
export const mixSurfaces = (a: Surfaces, b: Surfaces, t: number): Surfaces => ({
  screen: mix(a.screen, b.screen, t),
  ink: mix(a.ink, b.ink, t),
  muted: mix(a.muted, b.muted, t),
  bubbleIn: mix(a.bubbleIn, b.bubbleIn, t),
  bubbleOut: mix(a.bubbleOut, b.bubbleOut, t),
  onBubbleOut: mix(a.onBubbleOut, b.onBubbleOut, t),
  field: mix(a.field, b.field, t),
  fieldLine: mix(a.fieldLine, b.fieldLine, t),
  sheet: mix(a.sheet, b.sheet, t),
  key: mix(a.key, b.key, t),
  keyMod: mix(a.keyMod, b.keyMod, t),
  keyInk: mix(a.keyInk, b.keyInk, t),
});
