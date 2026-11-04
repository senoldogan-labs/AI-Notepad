import { AbsoluteFill, Img, staticFile } from "remotion";
import { color } from "../brand";

export type BackdropTone = "warm" | "cool" | "neutral";

const GLOWS: Record<BackdropTone, string> = {
  warm: `radial-gradient(60% 70% at 18% 20%, ${color.peach}66 0%, transparent 70%), radial-gradient(55% 65% at 85% 85%, ${color.lavender}55 0%, transparent 70%)`,
  cool: `radial-gradient(60% 70% at 82% 18%, ${color.lavender}5c 0%, transparent 70%), radial-gradient(50% 60% at 12% 88%, ${color.peach}4d 0%, transparent 70%)`,
  neutral: `radial-gradient(70% 60% at 50% 0%, #f6efe9 0%, transparent 75%), radial-gradient(60% 50% at 50% 100%, #efeaf7 0%, transparent 75%)`,
};

/** Static pastel film backdrop of the app's "direction C" look: cream base, soft glows, light grain, warm vignette. */
export const Backdrop: React.FC<{ readonly tone: BackdropTone }> = ({ tone }) => (
  <AbsoluteFill style={{ backgroundColor: color.bg }}>
    <AbsoluteFill style={{ backgroundImage: GLOWS[tone] }} />
    <AbsoluteFill style={{ background: "radial-gradient(120% 90% at 50% 50%, transparent 60%, #e9d9cf55 100%)" }} />
    <Img
      src={staticFile("grain.png")}
      style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover", opacity: 0.22, mixBlendMode: "multiply" }}
    />
  </AbsoluteFill>
);
