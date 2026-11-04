import { Audio } from "@remotion/media";
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { color } from "../brand";
import { Backdrop } from "../components/Backdrop";
import { type Format, useFormat } from "../components/format";
import { SpokenLine } from "../components/SpokenLine";
import { laptopFrames, lineIn } from "../timeline";

type MeetLayout = {
  /** Where the 1920×1080 laptop render is drawn. */
  readonly laptop: { readonly left: number; readonly top: number; readonly width: number };
  readonly titleBottom: number;
  readonly title: number;
  readonly subtitle: number;
};

const LAYOUT: Record<Format, MeetLayout> = {
  landscape: { laptop: { left: 0, top: 0, width: 1920 }, titleBottom: 70, title: 112, subtitle: 46 },
  portrait: { laptop: { left: -500, top: 150, width: 2200 }, titleBottom: 560, title: 104, subtitle: 44 },
};

/** One Blender frame (promo/blender/render.sh, transparent background) per scene frame; clamped for premounting. */
const laptopFrame = (frame: number): string =>
  staticFile(`laptop/${String(Math.min(Math.max(frame + 1, 1), laptopFrames())).padStart(4, "0")}.webp`);

/** The product appears: a laptop opens on the Gistsmith home screen while the name is said. */
export const MeetScene: React.FC = () => {
  const frame = useCurrentFrame();
  const layout = LAYOUT[useFormat()];
  const laptopScale = layout.laptop.width / 1920;
  const meet = lineIn("meet", "meet");
  return (
    <AbsoluteFill>
      <Backdrop tone="warm" />
      <div
        style={{
          position: "absolute",
          left: layout.laptop.left + 960 * laptopScale,
          top: layout.laptop.top + 690 * laptopScale,
          width: 1100 * laptopScale,
          height: 90 * laptopScale,
          translate: "-50% 0px",
          borderRadius: "50%",
          background: "radial-gradient(closest-side, rgb(90 50 40 / 0.20), transparent)",
        }}
      />
      <Img
        src={laptopFrame(frame)}
        style={{ position: "absolute", left: layout.laptop.left, top: layout.laptop.top, width: layout.laptop.width, maxWidth: "none" }}
      />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "flex-end", paddingBottom: layout.titleBottom, gap: 6 }}>
        <SpokenLine line={meet} fromWord={0} toWord={2} emphasisFrom={2} fontSize={layout.title} fontWeight={700} textAlign="center" maxWidth={1600} textColor={color.ink} />
        <SpokenLine line={meet} fromWord={2} toWord={8} emphasisFrom={8} fontSize={layout.subtitle} fontWeight={500} textAlign="center" maxWidth={1600} textColor={color.muted} />
      </AbsoluteFill>
      <Audio src={staticFile(`vo/${meet.take.file}`)} from={meet.from} />
    </AbsoluteFill>
  );
};
