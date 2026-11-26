import { fontFamily } from "../brand";
import { field } from "./theme";

type Tile = { readonly name: string; readonly bg: string };

const TILES: readonly Tile[] = [
  { name: "Anna", bg: "linear-gradient(160deg, #4a3a2f, #2c231d)" },
  { name: "Mikko", bg: "linear-gradient(160deg, #31393f, #1f2529)" },
  { name: "Lena", bg: "linear-gradient(160deg, #3c382e, #25221b)" },
  { name: "You", bg: "linear-gradient(160deg, #2f3d36, #1d2722)" },
];

/** Base size the window is drawn at; placed with `scale`. */
export const CALL_WIDTH = 940;
export const CALL_HEIGHT = 560;

const Button: React.FC<{ readonly red: boolean }> = ({ red }) => (
  <div style={{ width: red ? 92 : 48, height: 48, borderRadius: 24, backgroundColor: red ? "#d4432f" : "#3a3633", display: "flex", alignItems: "center", justifyContent: "center" }}>
    <div style={{ width: red ? 34 : 20, height: red ? 8 : 20, borderRadius: red ? 4 : 10, backgroundColor: red ? "#fff" : "#cfc6bd", opacity: red ? 1 : 0.85 }} />
  </div>
);

/**
 * A generic video-call window: four participants, nobody else. Drawn from plain shapes, no real product's name or
 * logo. `ended` (0…1) dims it and shows "Call ended".
 */
export const CallWindow: React.FC<{ readonly frame: number; readonly x: number; readonly y: number; readonly scale: number; readonly presence: number; readonly ended: number }> = ({ frame, x, y, scale, presence, ended }) => {
  const speaker = Math.floor(frame / 55) % 3;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        width: CALL_WIDTH,
        height: CALL_HEIGHT,
        transformOrigin: "0 0",
        scale,
        opacity: presence,
        borderRadius: 36,
        overflow: "hidden",
        backgroundColor: "#171412",
        border: "2px solid #3a3430",
        boxShadow: "0 40px 100px rgb(0 0 0 / 0.5)",
        fontFamily,
      }}
    >
      <div style={{ height: 52, display: "flex", alignItems: "center", padding: "0 24px", gap: 10, backgroundColor: "#1f1b19" }}>
        {[0, 1, 2].map((i) => (
          <div key={i} style={{ width: 14, height: 14, borderRadius: 7, backgroundColor: "#4a443f" }} />
        ))}
        <div style={{ flex: 1, textAlign: "center", color: "#cfc6bd", fontSize: 22, fontWeight: 600 }}>Team sync</div>
        <div style={{ color: "#a99e93", fontSize: 20, fontWeight: 600 }}>4 in call</div>
      </div>
      <div style={{ height: 432, padding: 16, display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
        {TILES.map((tile, index) => (
          <div key={tile.name} style={{ position: "relative", borderRadius: 20, background: tile.bg, border: index === speaker ? "4px solid #e8e2db" : "4px solid transparent", display: "flex", alignItems: "center", justifyContent: "center" }}>
            <div style={{ width: 92, height: 92, borderRadius: 46, backgroundColor: "rgb(255 255 255 / 0.14)", color: "#f1ebe4", fontSize: 40, fontWeight: 600, display: "flex", alignItems: "center", justifyContent: "center" }}>{tile.name.slice(0, 1)}</div>
            <div style={{ position: "absolute", left: 14, bottom: 12, padding: "4px 12px", borderRadius: 10, backgroundColor: "rgb(0 0 0 / 0.5)", color: "#f1ebe4", fontSize: 20, fontWeight: 500 }}>{tile.name}</div>
          </div>
        ))}
      </div>
      <div style={{ height: 76, display: "flex", alignItems: "center", justifyContent: "center", gap: 18, backgroundColor: "#1f1b19" }}>
        <Button red={false} />
        <Button red={false} />
        <Button red={false} />
        <Button red />
      </div>
      <div style={{ position: "absolute", inset: 0, opacity: ended, backgroundColor: "rgb(16 14 13 / 0.78)", display: "flex", alignItems: "center", justifyContent: "center", color: field.ink, fontSize: 64, fontWeight: 600, letterSpacing: "-0.01em" }}>Call ended</div>
    </div>
  );
};
