import { Img, staticFile } from "remotion";
import { color } from "../brand";

/** A real app screenshot framed like a floating macOS window: rounded corners, hairline border, soft shadow. */
export const AppWindow: React.FC<{ readonly file: string; readonly width: number; readonly radius: number }> = ({
  file,
  width,
  radius,
}) => (
  <div
    style={{
      width,
      borderRadius: radius,
      overflow: "hidden",
      backgroundColor: color.card,
      border: `1px solid ${color.line}`,
      boxShadow: "0 2px 4px rgb(10 10 10 / 0.04), 0 30px 80px rgb(60 30 20 / 0.14)",
    }}
  >
    <Img src={staticFile(file)} style={{ display: "block", width: "100%" }} />
  </div>
);
