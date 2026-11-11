// Puts the app's real screens into Apple's official product bezels (Apple Design Resources → Product Bezels) and writes
// one finished picture per device to `src/assets/devices/` for the Mac, iPhone and Apple Watch section
// (src/components/DevicesPicture.astro). The bezel PNGs themselves never enter the repository or the site: Apple's
// licence allows pictures of mock-ups, not passing the bezels on (src/assets/devices/CREDITS.md). Download the DMGs
// from https://developer.apple.com/design/resources/ and pass the PNGs named below.
//
// The screens:
// - Mac: the Product weekly note window (light and dark capture, scripts/make-screenshots.sh) on a desktop whose
//   wallpaper is one of the site's licensed photographs, with the menu bar hidden, so no system UI is drawn by hand.
// - iPhone: the home screen capture inside its drawn frame (make-iphone-shots.ts); the frame and its drawn Dynamic
//   Island are removed, the bezel's own island covers that spot.
// - Apple Watch: the watch's "iPhone is recording" screen at its native 416 × 496 px (WatchScreensUITests).
// Nothing is added on or around the products (no shadow or reflection), as Apple's marketing guidelines ask.
//
// Usage (from web/): node scripts/make-device-mockups.ts \
//   mac=<MacBook Pro M5 14-inch Space Black.png> iphone=<iPhone 18 Pro - Black - Portrait.png> \
//   watch=<Apple Watch S11 - 46mm - Aluminum Jet Black + Sport Band Black.png>
import { join } from "node:path";
import sharp from "sharp";

/** The command line or an input picture is not what the script expects. */
class MockupInputError extends Error {
  override readonly name: string = "MockupInputError";
}

/** An RGBA picture as raw pixels. */
interface RawImage {
  readonly data: Uint8Array;
  readonly width: number;
  readonly height: number;
}

/** A rectangle in pixels. */
interface Rect {
  readonly left: number;
  readonly top: number;
  readonly width: number;
  readonly height: number;
}

/** A bezel's screen opening: where the screen's pixels may show, and its bounding rectangle. */
interface ScreenOpening {
  /** One byte per bezel pixel: 255 inside the opening (grown by `openingGrowth` under the bezel's soft inner edge). */
  readonly mask: Uint8Array;
  readonly rect: Rect;
}

/** The three bezel paths from the command line. */
interface BezelPaths {
  readonly mac: string;
  readonly iphone: string;
  readonly watch: string;
}

/** One picture to write: its file name, the bezel, the screen's pixels at the opening's size, and the output width. */
interface MockupJob {
  readonly name: string;
  readonly bezel: RawImage;
  readonly opening: ScreenOpening;
  readonly screen: Buffer;
  readonly outputWidth: number;
}

const webDir: string = join(import.meta.dirname, "..");
const outputDir: string = join(webDir, "src/assets/devices");
const screenshotsDir: string = join(webDir, "src/assets/screenshots");
/** The Mac's desktop wallpaper: a licensed photograph the site does not show elsewhere next to this section. */
const wallpaperPath: string = join(webDir, "src/assets/photos/dune-sunset.jpg");
/** Pixels with alpha at or below this are part of the screen opening (the bezel's inner edge fades over ~2 px). */
const openingAlpha: number = 250;
/** The opening grows by this many pixels so the screen runs under the bezel's anti-aliased inner edge. */
const openingGrowth: number = 3;
/** The iPhone capture's drawn frame (make-iphone-shots.ts): 840 px of screen inside 888, so 24 px per side. */
const phoneFrameInset: number = 24;
const phoneScreenWidth: number = 840;
/** make-iphone-shots.ts draws the island 126 × 37.33 pt from 11 pt below the top of a 440 pt wide screen. */
const phoneIslandRatios: { readonly width: number; readonly height: number; readonly top: number } = {
  width: 126 / 440,
  height: 37.33 / 440,
  top: 11 / 440,
};
/** The Mac window's share of the screen's width, and the macOS window shadow under it (screen content, not on the product). */
const macWindowShare: number = 0.9;
/** Output widths: twice the largest CSS width each device is shown at on a 1440 px wide window, with headroom for 4K. */
const outputWidths: { readonly mac: number; readonly iphone: number; readonly watch: number } = {
  mac: 2400,
  iphone: 900,
  watch: 560,
};

/** `name=path` arguments to the three bezel paths. Pure. */
export function parseBezelPaths(args: readonly string[]): BezelPaths {
  const entries: Map<string, string> = new Map(
    args.map((arg: string): [string, string] => {
      const match: RegExpExecArray | null = /^(mac|iphone|watch)=(.+)$/.exec(arg);
      const name: string | undefined = match?.[1];
      const path: string | undefined = match?.[2];
      if (name === undefined || path === undefined) {
        throw new MockupInputError(`Arguments are mac=<png> iphone=<png> watch=<png>; got ${JSON.stringify(arg)}`);
      }
      return [name, path];
    }),
  );
  const mac: string | undefined = entries.get("mac");
  const iphone: string | undefined = entries.get("iphone");
  const watch: string | undefined = entries.get("watch");
  if (mac === undefined || iphone === undefined || watch === undefined) {
    throw new MockupInputError(`All three bezels are needed (mac=, iphone=, watch=); got ${JSON.stringify(args)}`);
  }
  return { mac, iphone, watch };
}

/** The connected region of see-through pixels around the bezel's centre, grown by `growth` pixels. Pure. */
export function findOpening(bezel: RawImage, growth: number): ScreenOpening {
  const { data, width, height } = bezel;
  const alphaAt = (x: number, y: number): number => data[(y * width + x) * 4 + 3] ?? 255;
  const startX: number = Math.floor(width / 2);
  const startY: number = Math.floor(height / 2);
  if (alphaAt(startX, startY) > openingAlpha) {
    throw new MockupInputError(`The bezel's centre (${startX}, ${startY}) is not see-through: is this a product bezel PNG?`);
  }
  const region: Uint8Array = new Uint8Array(width * height);
  const stack: number[] = [startY * width + startX];
  region[startY * width + startX] = 255;
  let left: number = startX;
  let right: number = startX;
  let top: number = startY;
  let bottom: number = startY;
  while (stack.length > 0) {
    const index: number = stack.pop() ?? 0;
    const x: number = index % width;
    const y: number = (index - x) / width;
    left = Math.min(left, x);
    right = Math.max(right, x);
    top = Math.min(top, y);
    bottom = Math.max(bottom, y);
    const neighbours: readonly (readonly [number, number])[] = [
      [x - 1, y],
      [x + 1, y],
      [x, y - 1],
      [x, y + 1],
    ];
    for (const [nx, ny] of neighbours) {
      if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
        throw new MockupInputError(`The see-through centre of the bezel reaches its edge at (${nx}, ${ny}): no closed screen opening.`);
      }
      const next: number = ny * width + nx;
      if (region[next] === 0 && alphaAt(nx, ny) <= openingAlpha) {
        region[next] = 255;
        stack.push(next);
      }
    }
  }
  return { mask: grow(region, width, height, growth), rect: { left, top, width: right - left + 1, height: bottom - top + 1 } };
}

/** The mask grown by `steps` pixels (4-neighbour dilation, one pixel per step). Pure: returns a new mask. */
function grow(mask: Uint8Array, width: number, height: number, steps: number): Uint8Array {
  if (steps === 0) {
    return mask;
  }
  const next: Uint8Array = new Uint8Array(mask);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index: number = y * width + x;
      if (mask[index] === 0) {
        const touches: boolean =
          (x > 0 && mask[index - 1] === 255) ||
          (x < width - 1 && mask[index + 1] === 255) ||
          (y > 0 && mask[index - width] === 255) ||
          (y < height - 1 && mask[index + width] === 255);
        if (touches) {
          next[index] = 255;
        }
      }
    }
  }
  return grow(next, width, height, steps - 1);
}

/** The screen's pixels (RGBA at the bezel's size, see-through outside the opening). Pure. */
function placeScreen(screen: RawImage, opening: ScreenOpening, bezelWidth: number, bezelHeight: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(bezelWidth * bezelHeight * 4);
  const { rect } = opening;
  const pad: number = openingGrowth;
  for (let y = rect.top - pad; y < rect.top + rect.height + pad; y += 1) {
    for (let x = rect.left - pad; x < rect.left + rect.width + pad; x += 1) {
      const index: number = y * bezelWidth + x;
      if ((opening.mask[index] ?? 0) === 255) {
        const sx: number = Math.min(screen.width - 1, Math.max(0, x - rect.left));
        const sy: number = Math.min(screen.height - 1, Math.max(0, y - rect.top));
        const from: number = (sy * screen.width + sx) * 4;
        out.set(screen.data.subarray(from, from + 4), index * 4);
      }
    }
  }
  return out;
}

/** Decodes a picture to raw RGBA pixels. */
async function readRaw(path: string): Promise<RawImage> {
  const { data, info } = await sharp(path).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data: new Uint8Array(data), width: info.width, height: info.height };
}

/** Raw RGBA pixels of an encoded picture (a Buffer from sharp). */
async function bufferToRaw(input: Buffer): Promise<RawImage> {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data: new Uint8Array(data), width: info.width, height: info.height };
}

/** The Mac's screen: the window centred on the wallpaper with the macOS window shadow. */
async function macScreen(windowPath: string, rect: Rect): Promise<Buffer> {
  const windowWidth: number = Math.round(rect.width * macWindowShare);
  const window: Buffer = await sharp(windowPath).resize({ width: windowWidth }).png().toBuffer();
  const windowMeta = await sharp(window).metadata();
  const windowHeight: number = windowMeta.height ?? 0;
  const left: number = Math.round((rect.width - windowWidth) / 2);
  // A little lower than centred: the hidden menu bar's strip (and the notch) stay wallpaper.
  const top: number = Math.round((rect.height - windowHeight) / 2 + rect.height * 0.018);
  const blur: number = Math.round(rect.width * 0.012);
  // The window's silhouette in black at 42 % on a screen-sized canvas, a little lower, blurred: the macOS window shadow.
  const silhouette: Buffer = await sharp(window).extractChannel("alpha").linear(0.42, 0).raw().toBuffer();
  const shadowWindow: Buffer = await sharp({ create: { width: windowWidth, height: windowHeight, channels: 3, background: { r: 0, g: 0, b: 0 } } })
    .joinChannel(silhouette, { raw: { width: windowWidth, height: windowHeight, channels: 1 } })
    .png()
    .toBuffer();
  const shadowLayer: Buffer = await sharp({ create: { width: rect.width, height: rect.height, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: shadowWindow, left, top: top + Math.round(blur * 0.6) }])
    .png()
    .toBuffer();
  const softShadow: Buffer = await sharp(shadowLayer).blur(blur).png().toBuffer();
  return sharp(wallpaperPath)
    .resize(rect.width, rect.height, { fit: "cover", position: "centre" })
    .composite([
      { input: softShadow, left: 0, top: 0 },
      { input: window, left, top },
    ])
    .png()
    .toBuffer();
}

/** The iPhone's screen: the capture without its drawn frame and drawn island, at the opening's size. */
async function phoneScreen(capturePath: string, rect: Rect): Promise<Buffer> {
  const capture = await sharp(capturePath).metadata();
  const captureHeight: number = (capture.height ?? 0) - 2 * phoneFrameInset;
  if (capture.width !== phoneScreenWidth + 2 * phoneFrameInset || captureHeight <= phoneScreenWidth) {
    throw new MockupInputError(`${capturePath} is not a framed iPhone capture from make-iphone-shots.ts (${capture.width ?? "?"} px wide).`);
  }
  const screen: Buffer = await sharp(capturePath)
    .extract({ left: phoneFrameInset, top: phoneFrameInset, width: phoneScreenWidth, height: captureHeight })
    .png()
    .toBuffer();
  const raw: RawImage = await bufferToRaw(screen);
  const islandWidth: number = phoneScreenWidth * phoneIslandRatios.width;
  const islandTop: number = phoneScreenWidth * phoneIslandRatios.top;
  const islandHeight: number = phoneScreenWidth * phoneIslandRatios.height;
  // The status bar's own colour just left of the island covers the drawn island (the bezel draws the real one).
  const sampleX: number = Math.round((phoneScreenWidth - islandWidth) / 2 - 12);
  const sampleY: number = Math.round(islandTop + islandHeight / 2);
  const sample: number = (sampleY * raw.width + sampleX) * 4;
  const colour: { r: number; g: number; b: number } = { r: raw.data[sample] ?? 0, g: raw.data[sample + 1] ?? 0, b: raw.data[sample + 2] ?? 0 };
  const patch: string = `<svg xmlns="http://www.w3.org/2000/svg" width="${phoneScreenWidth}" height="${captureHeight}"><rect x="${(phoneScreenWidth - islandWidth) / 2 - 4}" y="${islandTop - 4}" width="${islandWidth + 8}" height="${islandHeight + 8}" rx="${islandHeight / 2 + 4}" fill="rgb(${colour.r},${colour.g},${colour.b})"/></svg>`;
  const clean: Buffer = await sharp(screen).composite([{ input: Buffer.from(patch) }]).png().toBuffer();
  return sharp(clean).resize(rect.width, rect.height, { fit: "fill", kernel: "lanczos3" }).png().toBuffer();
}

/** The watch's screen at the opening's size (the capture is already the watch's native size). */
async function watchScreen(capturePath: string, rect: Rect): Promise<Buffer> {
  return sharp(capturePath).resize(rect.width, rect.height, { fit: "fill" }).png().toBuffer();
}

/** Writes one device picture: the screen under the bezel, scaled to the output width, as lossless WebP. */
async function writeMockup(job: MockupJob): Promise<string> {
  const screen: RawImage = await bufferToRaw(job.screen);
  const placed: Uint8Array = placeScreen(screen, job.opening, job.bezel.width, job.bezel.height);
  const bezelPng: Buffer = await sharp(job.bezel.data, { raw: { width: job.bezel.width, height: job.bezel.height, channels: 4 } })
    .png()
    .toBuffer();
  const composed: Buffer = await sharp(placed, { raw: { width: job.bezel.width, height: job.bezel.height, channels: 4 } })
    .composite([{ input: bezelPng }])
    .png()
    .toBuffer();
  const output: string = join(outputDir, `${job.name}.webp`);
  await sharp(composed).resize({ width: job.outputWidth, kernel: "lanczos3" }).webp({ quality: 92, alphaQuality: 100, effort: 6 }).toFile(output);
  return output;
}

async function main(args: readonly string[]): Promise<void> {
  const paths: BezelPaths = parseBezelPaths(args);
  const mac: RawImage = await readRaw(paths.mac);
  const iphone: RawImage = await readRaw(paths.iphone);
  const watch: RawImage = await readRaw(paths.watch);
  const macOpening: ScreenOpening = findOpening(mac, openingGrowth);
  const iphoneOpening: ScreenOpening = findOpening(iphone, openingGrowth);
  const watchOpening: ScreenOpening = findOpening(watch, openingGrowth);
  const jobs: readonly MockupJob[] = [
    { name: "mac-light", bezel: mac, opening: macOpening, screen: await macScreen(join(screenshotsDir, "note.webp"), macOpening.rect), outputWidth: outputWidths.mac },
    { name: "mac-dark", bezel: mac, opening: macOpening, screen: await macScreen(join(screenshotsDir, "note-dark.webp"), macOpening.rect), outputWidth: outputWidths.mac },
    { name: "iphone", bezel: iphone, opening: iphoneOpening, screen: await phoneScreen(join(screenshotsDir, "iphone-home.webp"), iphoneOpening.rect), outputWidth: outputWidths.iphone },
    { name: "watch", bezel: watch, opening: watchOpening, screen: await watchScreen(join(screenshotsDir, "watch-recording.png"), watchOpening.rect), outputWidth: outputWidths.watch },
  ];
  for (const job of jobs) {
    console.log(job.name, job.opening.rect, await writeMockup(job));
  }
}

await main(process.argv.slice(2));
