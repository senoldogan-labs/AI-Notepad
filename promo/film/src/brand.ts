import { loadFont } from "@remotion/fonts";
import { staticFile } from "remotion";

/** Colours from the app's light theme (web/src/styles/global.css mirrors Theme.swift). */
export const color = {
  bg: "#fdfcfc",
  card: "#ffffff",
  line: "#e5e5e5",
  ink: "#0a0a0a",
  muted: "#5f5f5f",
  accent: "#e9896a",
  peach: "#f1b9a1",
  lavender: "#b9a6ec",
  orb: "#c4471f",
} as const;

export const fontFamily = "Inter";

/** Inter variable font, the same file the website serves. */
export const fontReady: Promise<void> = loadFont({
  family: fontFamily,
  url: staticFile("InterVariable-latin.woff2"),
  weight: "100 900",
});

/** Peach-to-lavender text fill used for the emphasised half of a headline, as on gistsmith.com. */
export const gradientText: React.CSSProperties = {
  backgroundImage: `linear-gradient(95deg, ${color.accent} 0%, #d98aa8 45%, ${color.lavender} 100%)`,
  backgroundClip: "text",
  WebkitBackgroundClip: "text",
  color: "transparent",
};
