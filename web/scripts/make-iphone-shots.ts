// Sitenin iPhone görsellerini üretir: iPhone uygulamasının ekran çekimini (App Store çekim hattının ham çekimi,
// `scripts/appstore-screenshots` → `.build/appstore-screenshots/raw/<sahne>.png`) saydam zeminli bir telefon çerçevesine
// yerleştirir ve `src/assets/screenshots/iphone-<ad>.webp` olarak kayıpsız yazar. Çerçeve App Store görsellerindekiyle
// aynı oranlardadır (`scripts/appstore-screenshots/compose.ts`: metal kenar, siyah ekran kenarı, ekran köşesi, Dynamic
// Island); gölgeyi site CSS'i çizer. AVIF/WebP boyutlarını derlemede Astro üretir.
//
// Kullanım (web/ içinden): node scripts/make-iphone-shots.ts home=<çekim.png> live=<çekim.png> …
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import sharp, { type Metadata } from "sharp";

/** Komut satırı ya da girdi görseli beklenen biçimde değil. */
class ShotInputError extends Error {
  override readonly name: string = "ShotInputError";
}

/** Bir görsel işi: çıktı adı ve ekran çekiminin yolu. */
interface ShotJob {
  readonly name: string;
  readonly screenPath: string;
}

/** Telefon çerçevesinin piksel ölçüleri. */
interface FrameGeometry {
  readonly screenWidth: number;
  readonly screenHeight: number;
  readonly rim: number;
  readonly bezel: number;
  readonly screenRadius: number;
  readonly outerWidth: number;
  readonly outerHeight: number;
  readonly islandWidth: number;
  readonly islandHeight: number;
  readonly islandTop: number;
}

const outputDir: string = join(import.meta.dirname, "../src/assets/screenshots");
/** Çıktıdaki ekran genişliği (piksel): sitede en geniş ~420 CSS px × 2. */
const screenWidth: number = 840;
/** compose.ts ile aynı oranlar: 943,5 px ekrana 7 px metal kenar ve 20 px siyah kenar; 440 pt ekranda 62 pt köşe. */
const rimRatio: number = 7 / 943.5;
const bezelRatio: number = 20 / 943.5;
const screenCornerRatio: number = 62 / 440;
const islandWidthRatio: number = 126 / 440;
const islandHeightRatio: number = 37.33 / 440;
const islandTopRatio: number = 11 / 440;

/** `ad=yol` argümanlarını işlere çevirir. Saf fonksiyondur. */
export function parseJobs(args: readonly string[]): readonly ShotJob[] {
  if (args.length === 0) {
    throw new ShotInputError("En az bir `ad=çekim.png` argümanı gerekli (ör. home=.build/appstore-screenshots/raw/home.png).");
  }
  return args.map((arg: string): ShotJob => {
    const match: RegExpExecArray | null = /^([a-z][a-z0-9-]*)=(.+)$/.exec(arg);
    const name: string | undefined = match?.[1];
    const screenPath: string | undefined = match?.[2];
    if (name === undefined || screenPath === undefined) {
      throw new ShotInputError(`Argüman "ad=yol" biçiminde olmalı (ad küçük harf, rakam ve tire); gelen: ${JSON.stringify(arg)}`);
    }
    return { name, screenPath };
  });
}

/** Ekranın en-boy oranından çerçeve ölçüleri. Saf fonksiyondur. */
export function frameGeometry(width: number, height: number): FrameGeometry {
  const rim: number = Math.round(width * rimRatio);
  const bezel: number = Math.round(width * bezelRatio);
  return {
    screenWidth: width,
    screenHeight: height,
    rim,
    bezel,
    screenRadius: width * screenCornerRatio,
    outerWidth: width + 2 * (rim + bezel),
    outerHeight: height + 2 * (rim + bezel),
    islandWidth: width * islandWidthRatio,
    islandHeight: width * islandHeightRatio,
    islandTop: width * islandTopRatio,
  };
}

/** Çerçevenin SVG'si (ekranın yeri boş kalır, üstüne ekran bindirilir). Saf fonksiyondur. */
function frameSvg(frame: FrameGeometry): string {
  const inset: number = frame.rim + frame.bezel;
  const innerRadius: number = frame.screenRadius + frame.bezel;
  const outerRadius: number = innerRadius + frame.rim;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${frame.outerWidth}" height="${frame.outerHeight}">
  <defs>
    <linearGradient id="rim" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#8a8784"/><stop offset="0.14" stop-color="#3a3937"/><stop offset="0.48" stop-color="#232322"/>
      <stop offset="0.86" stop-color="#3a3937"/><stop offset="1" stop-color="#7d7a77"/>
    </linearGradient>
  </defs>
  <rect width="${frame.outerWidth}" height="${frame.outerHeight}" rx="${outerRadius}" fill="url(#rim)"/>
  <rect x="${frame.rim}" y="${frame.rim}" width="${frame.outerWidth - 2 * frame.rim}" height="${frame.outerHeight - 2 * frame.rim}" rx="${innerRadius}" fill="#050505"/>
  <rect x="${inset}" y="${inset}" width="${frame.screenWidth}" height="${frame.screenHeight}" rx="${frame.screenRadius}" fill="#ffffff"/>
</svg>`;
}

/** Ekranın köşelerini yuvarlayan maske. Saf fonksiyondur. */
function screenMaskSvg(frame: FrameGeometry): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${frame.screenWidth}" height="${frame.screenHeight}"><rect width="${frame.screenWidth}" height="${frame.screenHeight}" rx="${frame.screenRadius}" fill="#fff"/></svg>`;
}

/** Dynamic Island (çekimde yoksa çizilir; varsa aynı yere düşer). Saf fonksiyondur. */
function islandSvg(frame: FrameGeometry): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${frame.screenWidth}" height="${frame.screenHeight}"><rect x="${(frame.screenWidth - frame.islandWidth) / 2}" y="${frame.islandTop}" width="${frame.islandWidth}" height="${frame.islandHeight}" rx="${frame.islandHeight / 2}" fill="#000"/></svg>`;
}

/** Bir çekimi çerçeveleyip yazar; yazılan yolu döndürür. */
async function makeShot(job: ShotJob): Promise<string> {
  const metadata: Metadata = await sharp(job.screenPath).metadata();
  if (metadata.width === undefined || metadata.height === undefined || metadata.height <= metadata.width) {
    throw new ShotInputError(`Çekim dikey bir iPhone ekranı olmalı: ${job.screenPath} (${metadata.width ?? "?"}×${metadata.height ?? "?"}).`);
  }
  const height: number = Math.round((screenWidth * metadata.height) / metadata.width);
  const frame: FrameGeometry = frameGeometry(screenWidth, height);
  const screen: Buffer = await sharp(job.screenPath)
    .resize(screenWidth, height, { fit: "fill" })
    .composite([
      { input: Buffer.from(islandSvg(frame)), blend: "over" },
      { input: Buffer.from(screenMaskSvg(frame)), blend: "dest-in" },
    ])
    .png()
    .toBuffer();
  const inset: number = frame.rim + frame.bezel;
  const output: string = join(outputDir, `iphone-${job.name}.webp`);
  await sharp(Buffer.from(frameSvg(frame)))
    .composite([{ input: screen, left: inset, top: inset }])
    .webp({ lossless: true, effort: 6 })
    .toFile(output);
  return output;
}

/** Komut satırındaki her çekimi sırayla işler. */
async function main(args: readonly string[]): Promise<void> {
  const jobs: readonly ShotJob[] = parseJobs(args);
  await mkdir(outputDir, { recursive: true });
  for (const job of jobs) {
    const output: string = await makeShot(job);
    console.log(output);
  }
}

await main(process.argv.slice(2));
