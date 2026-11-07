// Renders the site's soft 3D "wave landscape" backdrops (layered dunes lit from the upper left, haze, fine grain) at
// 3840 × 2560 into src/assets/photos (`wave-*.jpg`, listed in CREDITS.md). Same output for the same settings.
// Usage (from web/): node scripts/make-wave-backdrops.ts src/assets/photos [name ...]
import { mkdirSync } from "node:fs";
import sharp from "sharp";

const width: number = 3840;
const height: number = 2560;

/** An sRGB colour as three channels in 0…1. */
type Rgb = readonly [number, number, number];

/** One dune layer: base height (0 top … 1 bottom), amplitude, crest and deep colours, haze, shape seed and frequency. */
interface Layer {
  readonly base: number;
  readonly amp: number;
  readonly crest: string;
  readonly deep: string;
  readonly haze: number;
  readonly seed: number;
  readonly freq: number;
  /** Slant of the whole layer across the frame (share of the height from left to right). */
  readonly tilt: number;
}

/** A scene: the sky (top → horizon colours), where the sky ends, a soft glow and the layers from back to front. */
interface Scene {
  readonly sky: readonly [string, string, string];
  readonly horizon: number;
  readonly glow: { readonly x: number; readonly y: number; readonly r: number; readonly color: string; readonly a: number };
  readonly layers: readonly Layer[];
}

/** A wave render name that is not in `scenes`. */
class UnknownSceneError extends Error {
  override readonly name: string = "UnknownSceneError";
}

/** `#rrggbb` → channels. Pure function. */
function hex(value: string): Rgb {
  const channel = (index: number): number => parseInt(value.slice(index, index + 2), 16) / 255;
  return [channel(1), channel(3), channel(5)];
}

/** Linear mix of two colours. Pure function. */
function mix(a: Rgb, b: Rgb, t: number): Rgb {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

/** Clamps to 0…1. Pure function. */
function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

/** Smoothstep easing of 0…1. Pure function. */
function smooth(t: number): number {
  return t * t * (3 - 2 * t);
}

/** Small deterministic random generator (LCG) from a seed. */
function rng(seed: number): () => number {
  let state: number = seed >>> 0;
  return (): number => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

const scenes: Readonly<Record<string, Scene>> = {
  "wave-dawn": {
    sky: ["#8fd6d0", "#d9efe9", "#fbefe6"],
    horizon: 0.6,
    glow: { x: 0.62, y: 0.42, r: 0.5, color: "#ffffff", a: 0.55 },
    layers: [
      { base: 0.5, amp: 0.07, crest: "#f8d6c8", deep: "#f0b3a2", haze: 0.45, seed: 3, freq: 1.4, tilt: 0 },
      { base: 0.58, amp: 0.09, crest: "#f6b9a6", deep: "#e98f7c", haze: 0.25, seed: 11, freq: 1.2, tilt: 0 },
      { base: 0.7, amp: 0.1, crest: "#f3a08d", deep: "#de6f60", haze: 0.1, seed: 21, freq: 1.0, tilt: 0 },
      { base: 0.84, amp: 0.08, crest: "#f29884", deep: "#d65e55", haze: 0.0, seed: 37, freq: 0.8, tilt: 0 },
    ],
  },
  "wave-lilac": {
    sky: ["#e4e0f0", "#f1dcec", "#fbd7e6"],
    horizon: 0.6,
    glow: { x: 0.68, y: 0.28, r: 0.55, color: "#fff4fa", a: 0.6 },
    layers: [
      { base: 0.34, amp: 0.12, crest: "#f6c6e3", deep: "#c4b6ec", haze: 0.5, seed: 5, freq: 1.6, tilt: 0 },
      { base: 0.46, amp: 0.14, crest: "#e7b4e4", deep: "#a59ce6", haze: 0.3, seed: 8, freq: 1.3, tilt: 0 },
      { base: 0.62, amp: 0.12, crest: "#c3b8f2", deep: "#8a84d8", haze: 0.12, seed: 13, freq: 1.1, tilt: 0 },
      { base: 0.8, amp: 0.1, crest: "#ada7ec", deep: "#716bc8", haze: 0.0, seed: 29, freq: 0.9, tilt: 0 },
    ],
  },
  "wave-ocean": {
    sky: ["#071a5a", "#1478b0", "#e889b8"],
    horizon: 0.5,
    glow: { x: 0.5, y: 0.47, r: 0.45, color: "#f0a0c8", a: 0.35 },
    layers: [
      { base: 0.44, amp: 0.08, crest: "#6cbcec", deep: "#2f6cc8", haze: 0.22, seed: 41, freq: 1.3, tilt: 0 },
      { base: 0.56, amp: 0.1, crest: "#4e8fe6", deep: "#2643b0", haze: 0.18, seed: 43, freq: 1.5, tilt: 0 },
      { base: 0.7, amp: 0.1, crest: "#7c72ea", deep: "#4a32b4", haze: 0.06, seed: 47, freq: 1.2, tilt: 0 },
      { base: 0.86, amp: 0.08, crest: "#8e66ec", deep: "#5428bc", haze: 0.0, seed: 53, freq: 0.9, tilt: 0 },
    ],
  },
  "wave-coral": {
    sky: ["#fde3dc", "#fbc3b8", "#f8a597"],
    horizon: 0.6,
    glow: { x: 0.75, y: 0.15, r: 0.6, color: "#fff2ec", a: 0.5 },
    layers: [
      { base: 0.3, amp: 0.12, crest: "#f9a597", deep: "#ef6f68", haze: 0.35, seed: 61, freq: 1.1, tilt: 0.12 },
      { base: 0.48, amp: 0.14, crest: "#f47c70", deep: "#d8343c", haze: 0.15, seed: 67, freq: 0.9, tilt: 0.16 },
      { base: 0.66, amp: 0.14, crest: "#ef5d5c", deep: "#bb1c2e", haze: 0.05, seed: 71, freq: 0.8, tilt: 0.2 },
      { base: 0.86, amp: 0.12, crest: "#f06a63", deep: "#b01828", haze: 0.0, seed: 73, freq: 0.7, tilt: 0.22 },
    ],
  },
  "wave-sunset": {
    sky: ["#f6a9bf", "#fcc7b9", "#ffe0bf"],
    horizon: 0.6,
    glow: { x: 0.85, y: 0.4, r: 0.5, color: "#fff1dc", a: 0.6 },
    layers: [
      { base: 0.36, amp: 0.1, crest: "#ffc29a", deep: "#f79470", haze: 0.35, seed: 81, freq: 1.0, tilt: -0.14 },
      { base: 0.5, amp: 0.12, crest: "#ffa070", deep: "#f06a5e", haze: 0.15, seed: 83, freq: 0.9, tilt: -0.18 },
      { base: 0.66, amp: 0.12, crest: "#e8628c", deep: "#9a3aa6", haze: 0.05, seed: 89, freq: 0.8, tilt: -0.2 },
      { base: 0.86, amp: 0.1, crest: "#78b4ec", deep: "#3d5ac6", haze: 0.0, seed: 97, freq: 0.7, tilt: -0.22 },
    ],
  },
};

/** The layer's ridge height in pixels for a horizontal position 0…1: a sum of seeded sines shaped like a dune. */
function ridgeFunction(layer: Layer): (u: number) => number {
  const random: () => number = rng(layer.seed * 7919);
  const waves: { readonly f: number; readonly p: number; readonly a: number }[] = [];
  for (let k: number = 0; k < 4; k += 1) {
    const f: number = layer.freq * (1 + k * 0.9 + random() * 0.6);
    waves.push({ f, p: random() * Math.PI * 2, a: 1 / (1 + k * 1.7) });
  }
  const norm: number = waves.reduce((sum: number, wave): number => sum + wave.a, 0);
  return (u: number): number => {
    let sum: number = 0;
    for (const wave of waves) {
      sum += wave.a * Math.sin(u * Math.PI * 2 * wave.f + wave.p);
    }
    // Rounder crests, flatter troughs: a dune profile, smooth everywhere (a kink shows as a seam in the lighting).
    const v: number = sum / norm;
    const shaped: number = Math.tanh(1.5 * v) / Math.tanh(1.5) + 0.12 * v * v;
    return (layer.base - layer.amp * shaped + layer.tilt * (u - 0.5)) * height;
  };
}

/** Renders one scene to raw RGB bytes. */
function render(scene: Scene): Buffer {
  const glowColor: Rgb = hex(scene.glow.color);
  const layers = scene.layers.map((layer: Layer) => ({ ...layer, crestColor: hex(layer.crest), deepColor: hex(layer.deep) }));
  const ridges: readonly Float32Array[] = scene.layers.map((layer: Layer): Float32Array => {
    const at: (u: number) => number = ridgeFunction(layer);
    const row: Float32Array = new Float32Array(width);
    for (let x: number = 0; x < width; x += 1) {
      row[x] = at(x / width);
    }
    return row;
  });
  const slopes: readonly Float32Array[] = ridges.map((ridge: Float32Array): Float32Array => {
    const row: Float32Array = new Float32Array(width);
    for (let x: number = 0; x < width; x += 1) {
      row[x] = ((ridge[Math.min(width - 1, x + 2)] ?? 0) - (ridge[Math.max(0, x - 2)] ?? 0)) / 4;
    }
    return row;
  });
  const light: readonly [number, number] = [-0.55, -0.83]; // from the upper left (y grows downward)
  const skyTop: Rgb = hex(scene.sky[0]);
  const skyMiddle: Rgb = hex(scene.sky[1]);
  // The sky's horizon colour is also the haze over the far layers.
  const hazeColor: Rgb = hex(scene.sky[2]);
  const out: Buffer = Buffer.alloc(width * height * 3);
  const grain: () => number = rng(12345);
  for (let y: number = 0; y < height; y += 1) {
    const v: number = y / height;
    const skyT: number = v < scene.horizon ? v / scene.horizon : 1;
    const skyColor: Rgb = skyT < 0.5 ? mix(skyTop, skyMiddle, smooth(skyT * 2)) : mix(skyMiddle, hazeColor, smooth((skyT - 0.5) * 2));
    for (let x: number = 0; x < width; x += 1) {
      const gx: number = x / width - scene.glow.x;
      const gy: number = (y / height - scene.glow.y) * (height / width);
      const glow: number = Math.exp(-(gx * gx + gy * gy) / (scene.glow.r * scene.glow.r * 0.25)) * scene.glow.a;
      let color: Rgb = mix(skyColor, glowColor, glow);
      layers.forEach((layer, index: number): void => {
        const ridgeY: number = ridges[index]?.[x] ?? 0;
        const depth: number = y - ridgeY;
        if (depth < -1.5) {
          return;
        }
        const cover: number = clamp01((depth + 1.5) / 3);
        const slope: number = slopes[index]?.[x] ?? 0;
        const length: number = Math.hypot(slope, 1);
        const lambert: number = Math.max(0, (slope / length) * light[0] + (-1 / length) * light[1]);
        // The surface rolls from the crest toward the viewer: near the crest the normal follows the ridge's slope,
        // lower down it faces forward, so slopes turned to the light stay bright far down and the others fall into shade.
        const t: number = 1 - Math.exp(-Math.max(0, depth) / (0.22 * height));
        const facing: number = 0.5;
        const lit: number = lambert + (facing - lambert) * Math.pow(t, 1.4);
        const base: Rgb = mix(layer.crestColor, layer.deepColor, Math.pow(t, 0.8));
        const shade: number = 0.66 + 0.62 * lit;
        let surface: Rgb = [base[0] * shade, base[1] * shade, base[2] * shade];
        // Soft sheen on the crest.
        surface = mix(surface, [1, 1, 1], Math.exp(-Math.max(0, depth) / 26) * 0.1 * (0.4 + lambert));
        // Mist in the valley where the next layer rises in front.
        const next: number | undefined = ridges[index + 1]?.[x];
        if (next !== undefined && next - y > 0) {
          surface = mix(surface, hazeColor, 0.32 * Math.exp(-(next - y) / 140));
        }
        surface = mix(surface, hazeColor, layer.haze);
        color = mix(color, surface, cover);
      });
      const noise: number = (grain() - 0.5) * (2.4 / 255);
      const offset: number = (y * width + x) * 3;
      out[offset] = clamp01(color[0] + noise) * 255 + 0.5;
      out[offset + 1] = clamp01(color[1] + noise) * 255 + 0.5;
      out[offset + 2] = clamp01(color[2] + noise) * 255 + 0.5;
    }
  }
  return out;
}

/** Writes the named scenes (all by default) as JPEG quality 95, 4:4:4. */
async function main(): Promise<void> {
  const dir: string | undefined = process.argv[2];
  if (dir === undefined) {
    throw new Error("Usage: node scripts/make-wave-backdrops.ts <output dir> [name ...]");
  }
  mkdirSync(dir, { recursive: true });
  const names: readonly string[] = process.argv.length > 3 ? process.argv.slice(3) : Object.keys(scenes);
  for (const name of names) {
    const scene: Scene | undefined = scenes[name];
    if (scene === undefined) {
      throw new UnknownSceneError(`No wave scene ${JSON.stringify(name)}; known: ${Object.keys(scenes).join(", ")}`);
    }
    await sharp(render(scene), { raw: { width, height, channels: 3 } })
      .jpeg({ quality: 95, mozjpeg: true, progressive: true, chromaSubsampling: "4:4:4" })
      .toFile(`${dir}/${name}.jpg`);
    console.log("wave_written", { name });
  }
}

await main();
