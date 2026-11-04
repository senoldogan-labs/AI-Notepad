import { useVideoConfig } from "remotion";

/** The film is rendered as 16:9 for the website and 9:16 for social feeds; scenes keep a layout per format. */
export type Format = "landscape" | "portrait";

export const useFormat = (): Format => {
  const { width, height } = useVideoConfig();
  return height > width ? "portrait" : "landscape";
};
