import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

/**
 * The apps' default "Olive" palette (Packages/AINotepadCore/Sources/AINotepadUI/Theme.swift `oliveLight`/`oliveDark`,
 * ThemeFamily.swift `ThemePalette.olive`, the default "Zeytin" accent): a flat warm charcoal field for the film, the
 * light surfaces inside the phone, lime fills with near-black ink on them and the darkened olive for accent text on light.
 */
export const olive = {
  /** Film backdrop: Olive dark. */
  night: "#212121",
  nightCard: "#2a2a2a",
  nightLine: "#3a3a3a",
  nightInk: "#f2f2ee",
  nightMuted: "#a3a39d",
  /** Lime: big fills in both modes and accent text on dark. */
  lime: "#b5c447",
  onLime: "#1e1f14",
  /** Accent text and glyphs on light surfaces (AA on the off-white background). */
  oliveText: "#5f6b14",
  oliveSoft: "#e9edcb",
  /** Olive light, the Gistsmith app's surfaces inside the phone. */
  paper: "#f7f6f1",
  paperCard: "#ffffff",
  paperLine: "#e4e2d8",
  paperInk: "#1f1f1c",
  paperMuted: "#5f5f58",
  /** The system keyboard greys and the host app's tint (marked-text underline, caret), as on the website's demo. */
  keyboard: "#d3d5db",
  keyboardMod: "#abb3bd",
  hostTint: "#2f5f8a",
  systemLink: "#0a66d6",
} as const;

export const serifFamily = "Newsreader";

/** Newsreader display (SIL OFL 1.1), the website's heading face (web/src/assets/fonts), one regular weight. */
export const serifReady: Promise<void> = loadFont({
  family: serifFamily,
  url: staticFile("Newsreader-display-latin.woff2"),
  weight: "400",
});
