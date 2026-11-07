// App Store "Growth & Marketing" görsellerini üretir: ürün sayfası başlığı (21:9, 3840×1646), arama sonucu görseli
// (3:2, 3840×2560), iki abonelik tanıtım görseli (1024×1024, Aylık ve Yıllık; fiyat ve metin yok), In-App Event görselleri
// (kart 16:9 ve ayrıntı 9:16; metinsiz), verilen ham çekimlerden ekran görüntüleri (compose.ts ile, make.ts'teki setle
// aynı) ve özel ürün sayfalarının ekran görüntüleri ile başlıkları (config.ts `customPages`). Hepsi sitenin durağan pastel film gradyanı
// ve gren dokusuyla; bokeh ve hareket yok. Simülatör açılmaz: ham çekimler `--raw-dir` klasöründen okunur
// (`<sahne>.png`, 1320×2868); ana setten klasörde olmayan sahne atlanır ve listelenir, başlıkların ve özel ürün
// sayfalarının çekimleri zorunludur (`npm run make` hepsini raw/'a çeker).
//
// Kullanım (repo kökünden):
//   npm --prefix scripts/appstore-screenshots run marketing -- --raw-dir <ham çekimler> --out <çıktı klasörü>
//
// Çıktı (`--out` altında):
//   header-3840x1646.png              ürün sayfası başlığı; önemli içerik ortadaki 3:2 güvenli alanda
//   search-3840x2560.png              arama sonucu görseli
//   subscription-monthly-1024.png     Aylık abonelik tanıtım görseli
//   subscription-yearly-1024.png      Yıllık abonelik tanıtım görseli
//   event-card-3840x2160.png          In-App Event kartı (16:9); alt üçte bir boş, adı ve açıklamayı App Store bindirir
//   event-details-2160x3840.png       In-App Event ayrıntı sayfası (9:16); alt kısım boş
//   6.9/<sıra>-<sahne>.png, 6.5/…, 6.3/…   ekran görüntüleri
//   <sayfa>/6.9/<sıra>-<çekim>.png, <sayfa>/6.3/…   özel ürün sayfasının ekran görüntüleri
//   <sayfa>/header-3840x1646.png      sayfanın kendi başlığı (varsa)
//   previews/*.jpg                    küçük önizlemeler; *-safe-area.jpg güvenli alanı çizer
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import sharp from "sharp";
import { ChromeRenderer, cloudLayers, contactSheet, escapeHtml, flattenToSrgbPng, grainUrl, previewJpeg, sceneHtml } from "./compose.ts";
import {
  type Banner,
  type BannerCopy,
  type CloudSide,
  configProblems,
  type CustomPage,
  customPages,
  customPageSizes,
  eventArt,
  type OutputSize,
  outputSizes,
  type Palette,
  palettes,
  type PageShot,
  productHeader,
  type Scene,
  scenes,
  searchBanner,
  simulator,
} from "./config.ts";

/** Komut satırında hata. */
class UsageError extends Error {
  override readonly name: string = "UsageError";
}

const repoRoot: string = resolve(import.meta.dirname, "../..");
const fontPath: string = join(repoRoot, "web/src/assets/fonts/InterVariable-latin.woff2");
const previewWidth: number = 1400;

/** Ekranı 1320×2868 olan bir iPhone'un sahnedeki yeri. */
export interface PhonePlacement {
  readonly screenshotPath: string;
  /** Dış kenarın sol üst köşesi ve yüksekliği (px); genişlik ekranın en-boy oranından. */
  readonly left: number;
  readonly top: number;
  readonly height: number;
  /** Derece; sıfır düz. */
  readonly rotation: number;
  readonly zIndex: number;
}

/** Bir iPhone çerçevesinin ölçüleri (px). */
export interface PhoneGeometry {
  readonly width: number;
  readonly rim: number;
  readonly bezel: number;
  readonly screenWidth: number;
  readonly screenRadius: number;
}

/** Abonelik tanıtım görselinin türü: Aylık tek not, Yıllık bir yılın notları (üst üste). */
export type PlanArt = "monthly" | "yearly";

/** Çerçeve ölçüleri, dış yükseklikten (compose.ts'teki aygıtla aynı oranlar). Saf fonksiyondur. */
export function phoneGeometry(height: number): PhoneGeometry {
  const rim: number = height * 0.0063;
  const bezel: number = height * 0.018;
  const screenHeight: number = height - 2 * (rim + bezel);
  const screenWidth: number = (screenHeight * simulator.screenWidth) / simulator.screenHeight;
  return { width: screenWidth + 2 * (rim + bezel), rim, bezel, screenWidth, screenRadius: (screenWidth * 62) / 440 };
}

/** Bir iPhone'un HTML'i (çerçeve, ekran, Dynamic Island). Saf fonksiyondur. */
export function phoneHtml(phone: PhonePlacement): string {
  const g: PhoneGeometry = phoneGeometry(phone.height);
  const islandWidth: number = g.screenWidth * (126 / 440);
  const islandHeight: number = g.screenWidth * (37.33 / 440);
  return `<div class="phone" style="left:${phone.left}px;top:${phone.top}px;width:${g.width}px;height:${phone.height}px;z-index:${phone.zIndex};transform:rotate(${phone.rotation}deg);padding:${g.rim}px;border-radius:${g.screenRadius + g.bezel + g.rim}px">
    <div class="bezel" style="padding:${g.bezel}px;border-radius:${g.screenRadius + g.bezel}px">
      <div class="screen" style="border-radius:${g.screenRadius}px">
        <img src="${pathToFileURL(phone.screenshotPath).href}" alt="">
        <div class="island" style="top:${g.screenWidth * (11 / 440)}px;width:${islandWidth}px;height:${islandHeight}px;margin-left:${-islandWidth / 2}px"></div>
      </div>
    </div>
  </div>`;
}

/** Ortak sayfa iskeleti: yazı tipi, film gradyanı, gren ve çerçeve stilleri. Saf fonksiyondur. */
export function pageHtml(width: number, height: number, palette: Palette, clouds: CloudSide, grainTile: number, styles: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  @font-face { font-family: "Inter"; src: url("${pathToFileURL(fontPath).href}") format("woff2"); font-weight: 100 900; font-style: normal; }
  html, body { margin: 0; padding: 0; }
  body {
    width: ${width}px; height: ${height}px; overflow: hidden; position: relative;
    font-family: "Inter", sans-serif; font-feature-settings: "cv11", "ss03"; -webkit-font-smoothing: antialiased; color: #0a0a0a;
    background-color: ${palette.base};
    background-image: ${cloudLayers(palette, clouds)};
  }
  .grain { position: absolute; inset: 0; background-image: url("${grainUrl}"); background-size: ${grainTile}px ${grainTile}px; mix-blend-mode: overlay; opacity: 0.5; }
  .phone { position: absolute; box-sizing: border-box;
    background: linear-gradient(150deg, #8a8784 0%, #3a3937 14%, #232322 48%, #3a3937 86%, #7d7a77 100%);
    box-shadow: 0 90px 160px -40px rgb(40 24 16 / 0.36), 0 36px 64px -24px rgb(40 24 16 / 0.22); }
  .phone .bezel { width: 100%; height: 100%; box-sizing: border-box; background: #050505; }
  .phone .screen { position: relative; width: 100%; height: 100%; overflow: hidden; background: #ffffff; }
  .phone .screen img { display: block; width: 100%; height: 100%; }
  .phone .island { position: absolute; left: 50%; border-radius: 999px; background: #000000; }
${styles}
</style>
</head>
<body>
  <div class="grain"></div>
${body}
</body>
</html>
`;
}

/** Satırları `<br>` ile birleştirir (her satır kaçırılır). Saf fonksiyondur. */
function lines(list: readonly string[]): string {
  return list.map(escapeHtml).join("<br>");
}

/** Üç telefonluk yelpaze: ortada düz, yanlarda biraz küçük ve eğik. `centerX` ortadaki telefonun ortası. Saf fonksiyondur. */
export function phoneFan(shots: readonly [string, string, string], centerX: number, top: number, height: number, spread: number): readonly PhonePlacement[] {
  const sideHeight: number = height * 0.88;
  const center: PhoneGeometry = phoneGeometry(height);
  const side: PhoneGeometry = phoneGeometry(sideHeight);
  const sideTop: number = top + (height - sideHeight) / 2 + height * 0.035;
  return [
    { screenshotPath: shots[0], left: centerX - spread - side.width / 2, top: sideTop, height: sideHeight, rotation: -6, zIndex: 1 },
    { screenshotPath: shots[1], left: centerX - center.width / 2, top, height, rotation: 0, zIndex: 3 },
    { screenshotPath: shots[2], left: centerX + spread - side.width / 2, top: sideTop, height: sideHeight, rotation: 6, zIndex: 2 },
  ];
}

/**
 * Ürün sayfası başlığı (3840×1646). iPhone kenarları kırpar ve üstte gezinme düğmelerini bindirir: metin ve telefonlar
 * ortadaki 3:2 alanda (2469 px), üstte boşluk. Saf fonksiyondur.
 */
export function headerHtml(copy: BannerCopy, shots: readonly [string, string, string], palette: Palette, clouds: CloudSide): string {
  const width: number = 3840;
  const height: number = 1646;
  const phoneHeight: number = 1180;
  const phones: string = phoneFan(shots, 2540, 262, phoneHeight, 300).map(phoneHtml).join("\n");
  const styles: string = `
  .light { position: absolute; inset: 0; background: radial-gradient(ellipse 34% 60% at 34% 52%, rgb(255 255 255 / 0.5) 0%, transparent 100%); }
  .copy { position: absolute; left: 790px; width: 1060px; top: 200px; bottom: 120px; display: flex; flex-direction: column; justify-content: center; }
  .headline { margin: 0; font-size: 128px; line-height: 1.04; font-weight: 650; letter-spacing: -0.038em; white-space: nowrap; }
  .subhead { margin: 48px 0 0; font-size: 56px; line-height: 1.3; font-weight: 450; letter-spacing: -0.012em; color: rgb(10 10 10 / 0.64); white-space: nowrap; }`;
  const body: string = `  <div class="light"></div>
  <div class="copy"><h1 class="headline">${lines(copy.headline)}</h1><p class="subhead">${lines(copy.subhead)}</p></div>
${phones}`;
  return pageHtml(width, height, palette, clouds, 360, styles, body);
}

/** Arama sonucu görseli (3:2, 3840×2560): üstte tek kısa satır, altında üç düz telefon. Saf fonksiyondur. */
export function searchHtml(copy: BannerCopy, shots: readonly [string, string, string], palette: Palette, clouds: CloudSide): string {
  const width: number = 3840;
  const height: number = 2560;
  const phoneHeight: number = 1660;
  const g: PhoneGeometry = phoneGeometry(phoneHeight);
  const gap: number = 120;
  const startX: number = (width - (3 * g.width + 2 * gap)) / 2;
  const phones: string = shots
    .map((shot: string, index: number) =>
      phoneHtml({ screenshotPath: shot, left: startX + index * (g.width + gap), top: 760, height: phoneHeight, rotation: 0, zIndex: 1 }),
    )
    .join("\n");
  const styles: string = `
  .light { position: absolute; inset: 0; background: radial-gradient(ellipse 70% 30% at 50% 10%, rgb(255 255 255 / 0.7) 0%, rgb(255 255 255 / 0.3) 55%, transparent 100%); }
  .copy { position: absolute; left: 200px; right: 200px; top: 150px; height: 520px; display: flex; flex-direction: column; justify-content: center; text-align: center; }
  .headline { margin: 0; font-size: 172px; line-height: 1.04; font-weight: 650; letter-spacing: -0.038em; }
  .subhead { margin: 44px 0 0; font-size: 76px; line-height: 1.28; font-weight: 450; letter-spacing: -0.012em; color: rgb(10 10 10 / 0.64); }`;
  const body: string = `  <div class="light"></div>
  <div class="copy"><h1 class="headline">${lines(copy.headline)}</h1><p class="subhead">${lines(copy.subhead)}</p></div>
${phones}`;
  return pageHtml(width, height, palette, clouds, 360, styles, body);
}

/**
 * In-App Event kartı (16:9, 3840×2160; Apple'ın en büyük ölçüsü, en küçüğü 1920×1080). Metin ve logo yok: App Store
 * rozeti, etkinlik adını ve kısa açıklamayı kendi gradyanıyla alta bindirir. Telefonlar üstteki üçte ikide, alt üçte
 * bir yalnız zemin. Saf fonksiyondur.
 */
export function eventCardHtml(shots: readonly [string, string, string], palette: Palette, clouds: CloudSide): string {
  const phones: string = phoneFan(shots, 1920, 150, 1330, 700).map(phoneHtml).join("\n");
  const styles: string = `
  .light { position: absolute; inset: 0; background: radial-gradient(ellipse 46% 52% at 50% 36%, rgb(255 255 255 / 0.6) 0%, transparent 100%); }`;
  return pageHtml(3840, 2160, palette, clouds, 360, styles, `  <div class="light"></div>\n${phones}`);
}

/**
 * In-App Event ayrıntı sayfası görseli (9:16, 2160×3840; en küçüğü 1080×1920). Metin yok; App Store adı, açıklamayı ve
 * düğmeyi alta bindirir: telefonlar üstteki %59'de. Saf fonksiyondur.
 */
export function eventDetailsHtml(shots: readonly [string, string, string], palette: Palette, clouds: CloudSide): string {
  const phones: string = phoneFan(shots, 1080, 360, 1900, 520).map(phoneHtml).join("\n");
  const styles: string = `
  .light { position: absolute; inset: 0; background: radial-gradient(ellipse 70% 40% at 50% 32%, rgb(255 255 255 / 0.6) 0%, transparent 100%); }`;
  return pageHtml(2160, 3840, palette, clouds, 360, styles, `  <div class="light"></div>\n${phones}`);
}

/** Not kartı: başlık şeridi, metin satırları ve görev kutuları; metin yok (çizgiler yazıyı simgeler). Saf fonksiyondur. */
function noteCard(accent: string, rotation: number, offsetX: number, offsetY: number, zIndex: number): string {
  const task = (done: boolean, width: number): string =>
    `<div class="task"><div class="box${done ? " done" : ""}" style="${done ? `background:${accent};border-color:${accent}` : ""}">${done ? '<svg viewBox="0 0 24 24"><path d="M6 12.5l4 4 8-9" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>' : ""}</div><div class="bar" style="width:${width}px"></div></div>`;
  return `<div class="card" style="transform:translate(${offsetX}px, ${offsetY}px) rotate(${rotation}deg);z-index:${zIndex}">
    <div class="cover" style="background:linear-gradient(135deg, ${accent} 0%, color-mix(in srgb, ${accent} 55%, #ffffff) 100%)"></div>
    <div class="bar strong" style="width:300px"></div>
    <div class="bar" style="width:380px"></div>
    <div class="bar" style="width:340px"></div>
    <div class="rule"></div>
    ${task(true, 300)}
    ${task(false, 250)}
    ${task(false, 280)}
  </div>`;
}

/**
 * Abonelik tanıtım görseli (1024×1024). Apple'ın kuralıyla: fiyat, ekran görüntüsü ve metin yok; köşeler sistemce
 * yuvarlanır, içerik ortada. Aylık tek not kartı, Yıllık üst üste kartlar (bir yılın notları). Saf fonksiyondur.
 */
export function planHtml(art: PlanArt): string {
  const palette: Palette = art === "monthly" ? palettes.coral : palettes.violet;
  const accent: string = art === "monthly" ? "#e46f4c" : "#8d6ad6";
  const cards: string =
    art === "monthly"
      ? noteCard(accent, -4, 0, 0, 3)
      : [noteCard(accent, -13, -70, 24, 1), noteCard(accent, 9, 70, 18, 2), noteCard(accent, -3, 0, -6, 3)].join("\n");
  const styles: string = `
  .light { position: absolute; inset: 0; background: radial-gradient(ellipse 60% 55% at 50% 48%, rgb(255 255 255 / 0.55) 0%, transparent 100%); }
  .stage { position: absolute; inset: 0; display: grid; place-items: center; }
  .card { grid-area: 1 / 1; width: 470px; box-sizing: border-box; padding: 34px 40px 40px; border-radius: 44px; background: #ffffff;
    box-shadow: 0 50px 90px -30px rgb(40 24 16 / 0.34), 0 18px 34px -16px rgb(40 24 16 / 0.2); }
  .cover { height: 120px; border-radius: 24px; margin-bottom: 34px; }
  .bar { height: 18px; border-radius: 9px; background: #e9e6e3; margin-top: 18px; }
  .bar.strong { height: 26px; border-radius: 13px; background: #2a2725; margin-top: 0; }
  .rule { height: 2px; background: #efedeb; margin: 32px 0 10px; }
  .task { display: flex; align-items: center; gap: 22px; margin-top: 22px; }
  .task .bar { margin-top: 0; }
  .box { width: 40px; height: 40px; flex: none; box-sizing: border-box; border-radius: 12px; border: 4px solid #d7d3cf; display: grid; place-items: center; }
  .box svg { width: 30px; height: 30px; }`;
  const body: string = `  <div class="light"></div>
  <div class="stage">
${cards}
  </div>`;
  return pageHtml(1024, 1024, palette, art === "monthly" ? "left" : "right", 240, styles, body);
}

/** Güvenli alan çizimi (önizleme için): ortadaki 3:2 kutu ve üstteki gezinme şeridi. Saf fonksiyondur. */
function safeAreaOverlay(width: number, height: number, navBand: number): Buffer {
  const safeWidth: number = Math.round((height * 3) / 2);
  const left: number = Math.round((width - safeWidth) / 2);
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">
  <rect x="0" y="0" width="${left}" height="${height}" fill="rgb(0 0 0 / 0.35)"/>
  <rect x="${left + safeWidth}" y="0" width="${width - left - safeWidth}" height="${height}" fill="rgb(0 0 0 / 0.35)"/>
  <rect x="${left}" y="0" width="${safeWidth}" height="${navBand}" fill="rgb(255 0 0 / 0.18)"/>
  <rect x="${left}" y="0" width="${safeWidth}" height="${height}" fill="none" stroke="#ff2d55" stroke-width="8"/>
</svg>`);
}

/** Önizleme çizimi: App Store'un metin bindirdiği alt şerit (`fromY`'den aşağısı). Saf fonksiyondur. */
function overlayBandPreview(width: number, height: number, fromY: number): Buffer {
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">
  <rect x="0" y="${fromY}" width="${width}" height="${height - fromY}" fill="rgb(255 0 0 / 0.18)"/>
  <line x1="0" y1="${fromY}" x2="${width}" y2="${fromY}" stroke="#ff2d55" stroke-width="8"/>
</svg>`);
}

/** Dosya var mı. */
async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error: unknown) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

/** HTML'i geçici dosyaya yazar, çizer, sRGB PNG olarak kaydeder ve PNG'yi döndürür. */
async function renderToFile(
  renderer: ChromeRenderer,
  work: string,
  name: string,
  html: string,
  size: { readonly width: number; readonly height: number },
  expectedImages: number,
  output: string,
): Promise<Buffer> {
  const htmlPath: string = join(work, `${name}.html`);
  await writeFile(htmlPath, html, "utf8");
  const png: Buffer = await flattenToSrgbPng(await renderer.render(htmlPath, size.width, size.height, expectedImages), size.width, size.height);
  await writeFile(output, png);
  console.log(output);
  return png;
}

/** Ham çekimi olan sahnelerden App Store ekran görüntüleri; çekimi olmayanların kimliklerini döndürür. */
async function renderScenes(renderer: ChromeRenderer, work: string, rawDir: string, out: string): Promise<readonly string[]> {
  const missing: string[] = [];
  const firstSize: OutputSize | undefined = outputSizes[0];
  if (firstSize === undefined) {
    throw new UsageError("config.ts: outputSizes boş");
  }
  const rendered: Buffer[] = [];
  for (const scene of scenes) {
    const raw: string = join(rawDir, `${scene.id}.png`);
    if (!(await exists(raw))) {
      missing.push(scene.id);
      continue;
    }
    const order: string = String(scenes.indexOf(scene) + 1).padStart(2, "0");
    for (const size of outputSizes) {
      await mkdir(join(out, size.id), { recursive: true });
      const png: Buffer = await renderToFile(renderer, work, `${scene.id}-${size.id}`, sceneHtml(sceneInput(scene, raw, size)), size, 1, join(out, size.id, `${order}-${scene.id}.png`));
      if (size === firstSize) {
        rendered.push(png);
      }
    }
  }
  if (rendered.length > 0) {
    await writeFile(join(out, "previews", "screenshots-overview.jpg"), await contactSheet(rendered, 330, 24));
  }
  return missing;
}

/** compose.ts'in sahne girdisi. Saf fonksiyondur. */
function sceneInput(scene: Scene | PageShot, screenshotPath: string, size: OutputSize): Parameters<typeof sceneHtml>[0] {
  return {
    headline: scene.headline,
    subhead: scene.subhead,
    screenshotPath,
    screenWidth: simulator.screenWidth,
    screenHeight: simulator.screenHeight,
    palette: palettes[scene.palette],
    clouds: scene.clouds,
    fontPath,
    size,
  };
}

/** Özel ürün sayfasının ekran görüntüleri, varsa başlığı ve paftası; çekimi olmayan sayfa `UsageError` verir. */
async function renderPage(renderer: ChromeRenderer, work: string, rawDir: string, out: string, page: CustomPage): Promise<void> {
  const raws: readonly string[] = await requiredRaws(rawDir, page.shots.map((shot: PageShot) => shot.raw));
  const rendered: Buffer[] = [];
  for (const [index, shot] of page.shots.entries()) {
    const raw: string | undefined = raws[index];
    if (raw === undefined) {
      throw new UsageError(`${page.id}: ${shot.raw} çekimi yok`);
    }
    const order: string = String(index + 1).padStart(2, "0");
    for (const size of customPageSizes) {
      await mkdir(join(out, page.id, size.id), { recursive: true });
      const png: Buffer = await renderToFile(
        renderer, work, `${page.id}-${order}-${size.id}`, sceneHtml(sceneInput(shot, raw, size)), size, 1, join(out, page.id, size.id, `${order}-${shot.raw}.png`),
      );
      if (size === customPageSizes[0]) {
        rendered.push(png);
      }
    }
  }
  await writeFile(join(out, "previews", `${page.id}.jpg`), await contactSheet(rendered, 330, 24));
  if (page.header !== null) {
    await renderHeader(renderer, work, rawDir, page.header, join(out, page.id, "header-3840x1646.png"), join(out, "previews", `${page.id}-header-safe-area.jpg`));
  }
}

/** Ürün sayfası başlığı ve güvenli alan önizlemesi. */
async function renderHeader(renderer: ChromeRenderer, work: string, rawDir: string, banner: Banner, output: string, safePreview: string): Promise<void> {
  const html: string = headerHtml(banner.copy, await requiredShots(rawDir, banner.shots), palettes[banner.palette], banner.clouds);
  const png: Buffer = await renderToFile(renderer, work, `header-${banner.shots.join("-")}`, html, { width: 3840, height: 1646 }, 3, output);
  const safe: Buffer = await sharp(png).composite([{ input: safeAreaOverlay(3840, 1646, 190) }]).png().toBuffer();
  await writeFile(safePreview, await previewJpeg(safe, previewWidth));
}

/** Ham çekimlerin yolları; biri yoksa `UsageError`. */
async function requiredRaws(rawDir: string, ids: readonly string[]): Promise<readonly string[]> {
  const paths: readonly string[] = ids.map((id: string) => join(rawDir, `${id}.png`));
  const missing: string[] = [];
  for (const path of paths) {
    if (!(await exists(path))) {
      missing.push(path);
    }
  }
  if (missing.length > 0) {
    throw new UsageError(`Ham çekim yok (npm run make çeker): ${missing.join(", ")}`);
  }
  return paths;
}

/** Başlığın, arama ve etkinlik görsellerinin üç çekimi; biri yoksa `UsageError`. */
async function requiredShots(rawDir: string, ids: readonly [string, string, string]): Promise<readonly [string, string, string]> {
  await requiredRaws(rawDir, ids);
  return [join(rawDir, `${ids[0]}.png`), join(rawDir, `${ids[1]}.png`), join(rawDir, `${ids[2]}.png`)];
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    args: process.argv.slice(2),
    options: { chrome: { type: "string" }, "raw-dir": { type: "string" }, out: { type: "string" } },
    strict: true,
    allowPositionals: false,
  });
  const chrome: string | undefined = values.chrome;
  const rawDirArg: string | undefined = values["raw-dir"];
  const outArg: string | undefined = values.out;
  if (chrome === undefined || rawDirArg === undefined || outArg === undefined) {
    throw new UsageError("Gerekli: --chrome <Chrome yolu> --raw-dir <ham çekimler> --out <çıktı klasörü>");
  }
  const problems: readonly string[] = configProblems();
  if (problems.length > 0) {
    throw new UsageError(`config.ts geçersiz:\n${problems.join("\n")}`);
  }
  const rawDir: string = resolve(rawDirArg);
  const out: string = resolve(outArg);
  await mkdir(join(out, "previews"), { recursive: true });
  const renderer: ChromeRenderer = await ChromeRenderer.launch(chrome);
  const work: string = await mkdtemp(join(tmpdir(), "appstore-marketing-"));
  try {
    await renderHeader(renderer, work, rawDir, productHeader, join(out, "header-3840x1646.png"), join(out, "previews", "header-safe-area.jpg"));
    const searchPng: Buffer = await renderToFile(
      renderer, work, "search",
      searchHtml(searchBanner.copy, await requiredShots(rawDir, searchBanner.shots), palettes[searchBanner.palette], searchBanner.clouds),
      { width: 3840, height: 2560 }, 3, join(out, "search-3840x2560.png"),
    );
    await writeFile(join(out, "previews", "search.jpg"), await previewJpeg(searchPng, previewWidth));
    for (const art of ["monthly", "yearly"] as const) {
      await renderToFile(renderer, work, art, planHtml(art), { width: 1024, height: 1024 }, 0, join(out, `subscription-${art}-1024.png`));
    }
    const eventShots: readonly [string, string, string] = await requiredShots(rawDir, eventArt.shots);
    const eventPalette: Palette = palettes[eventArt.palette];
    const card: Buffer = await renderToFile(
      renderer, work, "event-card", eventCardHtml(eventShots, eventPalette, eventArt.clouds), { width: 3840, height: 2160 }, 3,
      join(out, "event-card-3840x2160.png"),
    );
    const cardBand: Buffer = await sharp(card).composite([{ input: overlayBandPreview(3840, 2160, 1490) }]).png().toBuffer();
    await writeFile(join(out, "previews", "event-card-overlay.jpg"), await previewJpeg(cardBand, previewWidth));
    const details: Buffer = await renderToFile(
      renderer, work, "event-details", eventDetailsHtml(eventShots, eventPalette, eventArt.clouds), { width: 2160, height: 3840 }, 3,
      join(out, "event-details-2160x3840.png"),
    );
    const detailsBand: Buffer = await sharp(details).composite([{ input: overlayBandPreview(2160, 3840, 2420) }]).png().toBuffer();
    await writeFile(join(out, "previews", "event-details-overlay.jpg"), await previewJpeg(detailsBand, 800));
    const missing: readonly string[] = await renderScenes(renderer, work, rawDir, out);
    if (missing.length > 0) {
      console.warn(`Ham çekimi olmayan sahneler (atlandı): ${missing.join(", ")}`);
    }
    for (const page of customPages) {
      await renderPage(renderer, work, rawDir, out, page);
    }
  } finally {
    await renderer.close();
    await rm(work, { recursive: true, force: true });
  }
}

await main();
