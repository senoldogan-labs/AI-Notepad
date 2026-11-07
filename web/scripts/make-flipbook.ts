// Draws the footer flip-book (FooterFlipbook.astro): an original, generated scene of a Finnish lake from late afternoon
// to a night with northern lights, one SVG per frame rendered to WebP by sharp. The sun crosses the sky and sets, its
// reflection on the water is the site's horizon waveform (mirrored bars), stars and the aurora come out after dusk.
// Every shape is seeded, so the same command always draws the same frames. The frames are committed under
// src/assets/flipbook/ (Astro serves them with content-hashed names); run again only when the scene changes.
//
// Usage (from web/): node scripts/make-flipbook.ts
import { mkdir, readdir, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import sharp from "sharp";

/** The scene's drawing size (5:2; the footer band crops it to its own shape, see FooterFlipbook.astro). */
const width: number = 1200;
const height: number = 480;
/** Rendered frame width in pixels (the drawing is scaled up: sharp edges on a 2× screen at the band's usual width). */
const outputWidth: number = 1600;
/** Number of frames: enough for a smooth scrub, small enough for the byte budget below. */
const frameCount: number = 36;
/** Total size budget for all frames (bytes); the script fails above it. */
const budgetBytes: number = 600 * 1024;
/** WebP quality: the scene is soft gradients and silhouettes, which compress well. */
const webpQuality: number = 74;
/** The waterline (pixels from the top). */
const horizonY: number = 300;
const outputDir: string = join(import.meta.dirname, "../src/assets/flipbook");

/** The frames together are larger than the budget. */
class FlipbookBudgetError extends Error {
  override readonly name: string = "FlipbookBudgetError";
}

/** An sRGB colour. */
interface Rgb {
  readonly r: number;
  readonly g: number;
  readonly b: number;
}

/** The sky and land colours at one moment of the evening. */
interface Palette {
  readonly at: number;
  readonly skyTop: Rgb;
  readonly skyMid: Rgb;
  readonly skyLow: Rgb;
  readonly farLand: Rgb;
  readonly nearLand: Rgb;
  readonly water: Rgb;
}

/** One point on a silhouette. */
interface Point {
  readonly x: number;
  readonly y: number;
}

/** A star: position, radius and how bright it gets. */
interface Star {
  readonly x: number;
  readonly y: number;
  readonly r: number;
  readonly brightness: number;
}

/** `#rrggbb` to a colour. Pure function. */
function hex(value: string): Rgb {
  const n: number = Number.parseInt(value.slice(1), 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

/** Linear blend of two colours (`t` 0…1). Pure function. */
function mix(a: Rgb, b: Rgb, t: number): Rgb {
  return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t };
}

/** The colour as an SVG value. Pure function. */
function css(color: Rgb): string {
  return `rgb(${Math.round(color.r)} ${Math.round(color.g)} ${Math.round(color.b)})`;
}

/** Smooth step between `from` and `to`. Pure function. */
function smooth(from: number, to: number, value: number): number {
  const t: number = Math.min(1, Math.max(0, (value - from) / (to - from)));
  return t * t * (3 - 2 * t);
}

/** Deterministic pseudo-random numbers (mulberry32). Returns a new generator; pure apart from its own state. */
function seeded(seed: number): () => number {
  let state: number = seed >>> 0;
  return (): number => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t: number = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Palettes from late afternoon (0) to night (1); the frames blend between neighbours. */
const palettes: readonly Palette[] = [
  { at: 0, skyTop: hex("#8fb6e8"), skyMid: hex("#c6dcf3"), skyLow: hex("#fbeedd"), farLand: hex("#8ea6c4"), nearLand: hex("#3f5a5e"), water: hex("#9fbfe3") },
  { at: 0.3, skyTop: hex("#9fa9df"), skyMid: hex("#f0cbc0"), skyLow: hex("#fbd2a0"), farLand: hex("#a08fb4"), nearLand: hex("#3d4655"), water: hex("#c2b4d6") },
  { at: 0.5, skyTop: hex("#7f7cc4"), skyMid: hex("#e79fb3"), skyLow: hex("#f7ad86"), farLand: hex("#7d6a9a"), nearLand: hex("#2c2f45"), water: hex("#b493b8") },
  { at: 0.7, skyTop: hex("#2f3d7c"), skyMid: hex("#7c72b6"), skyLow: hex("#e09aa4"), farLand: hex("#4a4876"), nearLand: hex("#1a1d33"), water: hex("#5d5e95") },
  { at: 1, skyTop: hex("#0b1230"), skyMid: hex("#18255a"), skyLow: hex("#33497a"), farLand: hex("#1d2649"), nearLand: hex("#0a0d1c"), water: hex("#1b2752") },
];

/** The palette at time `t` (0…1). Pure function. */
function paletteAt(t: number): Palette {
  const next: number = palettes.findIndex((palette: Palette): boolean => palette.at >= t);
  const upper: Palette = palettes[Math.max(0, next)] ?? palettes[palettes.length - 1]!;
  const lower: Palette = palettes[Math.max(0, next - 1)] ?? upper;
  const span: number = upper.at - lower.at;
  const k: number = span === 0 ? 0 : (t - lower.at) / span;
  return {
    at: t,
    skyTop: mix(lower.skyTop, upper.skyTop, k),
    skyMid: mix(lower.skyMid, upper.skyMid, k),
    skyLow: mix(lower.skyLow, upper.skyLow, k),
    farLand: mix(lower.farLand, upper.farLand, k),
    nearLand: mix(lower.nearLand, upper.nearLand, k),
    water: mix(lower.water, upper.water, k),
  };
}

/** A soft ridge line from left to right (seeded). Pure function. */
function ridge(seed: number, baseY: number, amplitude: number, steps: number): readonly Point[] {
  const random: () => number = seeded(seed);
  return Array.from({ length: steps + 1 }, (_: unknown, index: number): Point => {
    const x: number = (index / steps) * width;
    const wave: number = Math.sin(index * 0.9 + random() * 2) * 0.5 + random() * 0.5;
    return { x, y: baseY - wave * amplitude };
  });
}

/** Closed path under a ridge down to the waterline. Pure function. */
function landPath(points: readonly Point[]): string {
  const line: string = points.map((point: Point, index: number): string => `${index === 0 ? "M" : "L"}${point.x.toFixed(1)} ${point.y.toFixed(1)}`).join(" ");
  return `${line} L${width} ${horizonY} L0 ${horizonY} Z`;
}

/** A row of spruce silhouettes along the near shore (seeded): stacked triangles of varying height. Pure function. */
function spruces(seed: number, fromX: number, toX: number): string {
  const random: () => number = seeded(seed);
  const parts: string[] = [];
  let x: number = fromX;
  while (x < toX) {
    const treeHeight: number = 26 + random() * 46;
    const half: number = treeHeight * (0.2 + random() * 0.06);
    const base: number = horizonY + 1;
    parts.push(`M${(x - half).toFixed(1)} ${base} L${x.toFixed(1)} ${(base - treeHeight).toFixed(1)} L${(x + half).toFixed(1)} ${base} Z`);
    x += half * (0.9 + random() * 0.8);
  }
  return parts.join(" ");
}

/** Stars for the night sky (seeded, upper sky only). */
const stars: readonly Star[] = ((): readonly Star[] => {
  const random: () => number = seeded(17);
  return Array.from({ length: 70 }, (): Star => ({ x: random() * width, y: random() * (horizonY - 90), r: 0.6 + random() * 1.1, brightness: 0.4 + random() * 0.6 }));
})();

/** A short highlight line on the water. */
interface Ripple {
  readonly x: number;
  readonly y: number;
  readonly length: number;
}

/** Highlights on the water (seeded), longer and sparser towards the shore. */
const rippleLines: readonly Ripple[] = ((): readonly Ripple[] => {
  const random: () => number = seeded(23);
  return Array.from({ length: 26 }, (): Ripple => {
    const depth: number = random();
    return { x: random() * width, y: horizonY + 30 + depth * (height - horizonY - 36), length: 20 + depth * 90 };
  });
})();

/** Heights of the reflection waveform (seeded, 0…1), mirrored like the logo. */
const reflectionBars: readonly number[] = ((): readonly number[] => {
  const random: () => number = seeded(5);
  const half: readonly number[] = Array.from({ length: 9 }, (_: unknown, index: number): number => (0.35 + random() * 0.65) * (1 - index * 0.08));
  return [...[...half].reverse(), ...half.slice(1)];
})();

/** The frame's SVG at time `t` (0 = late afternoon, 1 = night). Pure function. */
function sceneSvg(t: number): string {
  const palette: Palette = paletteAt(t);
  // The sun moves on a shallow arc and sets at about t = 0.6.
  const sunX: number = width * (0.24 + t * 0.5);
  const sunY: number = 70 + smooth(0, 0.62, t) * (horizonY - 40);
  const sunVisible: number = 1 - smooth(0.52, 0.64, t);
  const sunColor: Rgb = mix(hex("#fff3d6"), hex("#ff9e6e"), smooth(0.1, 0.55, t));
  const glow: number = 0.55 + smooth(0.2, 0.5, t) * 0.35;
  const night: number = smooth(0.62, 0.95, t);
  const aurora: number = smooth(0.72, 1, t);
  const far: string = landPath(ridge(3, horizonY - 26, 22, 24));
  const mid: string = landPath(ridge(11, horizonY - 10, 12, 30));
  const trees: string = spruces(29, -10, width * 0.42) + " " + spruces(41, width * 0.78, width + 20);
  const bandWidth: number = 9;
  const reflection: string = reflectionBars
    .map((value: number, index: number): string => {
      const x: number = sunX + (index - (reflectionBars.length - 1) / 2) * (bandWidth + 5) - bandWidth / 2;
      const barHeight: number = 6 + value * 54;
      return `<rect x="${x.toFixed(1)}" y="${(horizonY + 14 + (54 - barHeight) / 2).toFixed(1)}" width="${bandWidth}" height="${barHeight.toFixed(1)}" rx="${bandWidth / 2}"/>`;
    })
    .join("");
  // The aurora: three curtains whose curves drift a little from frame to frame.
  const curtain = (offset: number, lift: number): string => {
    const y0: number = 150 - lift + Math.sin(t * 6 + offset) * 10;
    return `M-40 ${y0} C ${width * 0.25} ${y0 - 90 - offset * 8}, ${width * 0.55} ${y0 + 40}, ${width + 40} ${y0 - 60 + Math.cos(t * 5 + offset) * 14}`;
  };
  const starMarks: string = stars
    .map((star: Star): string => `<circle cx="${star.x.toFixed(1)}" cy="${star.y.toFixed(1)}" r="${star.r.toFixed(2)}" fill-opacity="${(star.brightness * night).toFixed(3)}"/>`)
    .join("");
  const ripples: string = rippleLines
    .map((line: Ripple): string => `<rect x="${line.x.toFixed(1)}" y="${line.y.toFixed(1)}" width="${line.length.toFixed(1)}" height="1.2" rx="0.6"/>`)
    .join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${outputWidth}" height="${(outputWidth * height) / width}" viewBox="0 0 ${width} ${height}">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${css(palette.skyTop)}"/>
      <stop offset="0.62" stop-color="${css(palette.skyMid)}"/>
      <stop offset="1" stop-color="${css(palette.skyLow)}"/>
    </linearGradient>
    <linearGradient id="water" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${css(mix(palette.skyLow, palette.water, 0.45))}"/>
      <stop offset="1" stop-color="${css(mix(palette.water, palette.skyTop, 0.55))}"/>
    </linearGradient>
    <radialGradient id="sun" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="${css(sunColor)}" stop-opacity="${glow.toFixed(3)}"/>
      <stop offset="1" stop-color="${css(sunColor)}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="aurora" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#5df2b5" stop-opacity="0"/>
      <stop offset="0.3" stop-color="#5df2b5"/>
      <stop offset="0.7" stop-color="#7fd7f0"/>
      <stop offset="1" stop-color="#b59cf0" stop-opacity="0"/>
    </linearGradient>
    <filter id="soft" x="-20%" y="-60%" width="140%" height="220%"><feGaussianBlur stdDeviation="14"/></filter>
    <filter id="haze" x="-20%" y="-60%" width="140%" height="220%"><feGaussianBlur stdDeviation="4"/></filter>
  </defs>
  <rect width="${width}" height="${horizonY}" fill="url(#sky)"/>
  <g fill="#ffffff">${starMarks}</g>
  <g fill="none" stroke="url(#aurora)" stroke-linecap="round" filter="url(#soft)" opacity="${(aurora * 0.85).toFixed(3)}">
    <path d="${curtain(0, 0)}" stroke-width="46"/>
    <path d="${curtain(1.7, 34)}" stroke-width="30"/>
    <path d="${curtain(3.1, -22)}" stroke-width="22"/>
  </g>
  <g opacity="${sunVisible.toFixed(3)}">
    <circle cx="${sunX.toFixed(1)}" cy="${sunY.toFixed(1)}" r="150" fill="url(#sun)"/>
    <circle cx="${sunX.toFixed(1)}" cy="${sunY.toFixed(1)}" r="26" fill="${css(sunColor)}"/>
  </g>
  <path d="${far}" fill="${css(palette.farLand)}" filter="url(#haze)"/>
  <path d="${mid}" fill="${css(mix(palette.farLand, palette.nearLand, 0.5))}"/>
  <path d="${trees}" fill="${css(palette.nearLand)}"/>
  <rect y="${horizonY}" width="${width}" height="${height - horizonY}" fill="url(#water)"/>
  <g transform="translate(0 ${horizonY * 2}) scale(1 -1)" opacity="0.32" filter="url(#haze)">
    <path d="${mid}" fill="${css(mix(palette.farLand, palette.nearLand, 0.5))}"/>
    <path d="${trees}" fill="${css(palette.nearLand)}"/>
  </g>
  <g fill="#ffffff" fill-opacity="${(0.22 * (1 - night * 0.6)).toFixed(3)}">${ripples}</g>
  <rect y="${horizonY}" width="${width}" height="1.5" fill="#ffffff" fill-opacity="${(0.35 * (1 - night)).toFixed(3)}"/>
  <g fill="${css(sunColor)}" opacity="${(0.75 * sunVisible).toFixed(3)}">${reflection}</g>
  <g fill="none" stroke="url(#aurora)" stroke-linecap="round" filter="url(#soft)" opacity="${(aurora * 0.25).toFixed(3)}" transform="translate(0 ${horizonY * 1.55}) scale(1 -0.55)">
    <path d="${curtain(0, 0)}" stroke-width="46"/>
  </g>
</svg>`;
}

/** Renders every frame and checks the byte budget. */
async function main(): Promise<void> {
  await mkdir(outputDir, { recursive: true });
  for (const name of await readdir(outputDir)) {
    await rm(join(outputDir, name));
  }
  let total: number = 0;
  for (let index: number = 0; index < frameCount; index += 1) {
    const t: number = index / (frameCount - 1);
    const path: string = join(outputDir, `frame-${String(index).padStart(2, "0")}.webp`);
    await sharp(Buffer.from(sceneSvg(t))).webp({ quality: webpQuality, effort: 6, smartSubsample: true }).toFile(path);
    total += (await stat(path)).size;
  }
  console.log("flipbook_written", { frames: frameCount, totalBytes: total, outputDir });
  if (total > budgetBytes) {
    throw new FlipbookBudgetError(`Frames total ${total} bytes, over the ${budgetBytes}-byte budget: lower webpQuality or frameCount.`);
  }
}

await main();
