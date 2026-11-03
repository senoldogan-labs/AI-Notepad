// Ham Simülatör çekimini App Store görseline dönüştürür: üstte başlık ve alt başlık, altında CSS ile çizilmiş bir iPhone
// çerçevesi (Apple'ın aygıt çizimleri kullanılmaz), arkada sitenin durağan pastel film gradyanı ve onun hafif greni
// (sitedeki `web/public/grain.png`, aynı overlay karışımıyla; bokeh ve hareket yok). Sayfa 1320 px genişlikte bir
// sahnede düzenlenir ve çıktı boyutuna `zoom` ile ölçeklenir: her boyutta ve her sahnede aygıt aynı ölçekte ve aynı
// yerdedir.
import { pathToFileURL } from "node:url";
import { type Browser, chromium, type Page } from "playwright-core";
import sharp, { type Metadata } from "sharp";
import type { CloudSide, OutputSize, Palette } from "./config.ts";

/** Çıktı beklenen ölçüde değil ya da beklenmeyen biçimde. */
export class ComposeError extends Error {
  override readonly name: string = "ComposeError";
}

/** Bir görselin şablon girdisi. */
export interface SceneHtmlInput {
  readonly headline: string;
  readonly subhead: string | null;
  readonly screenshotPath: string;
  /** Ham çekimin piksel ölçüsü (ekranın en-boy oranı buradan). */
  readonly screenWidth: number;
  readonly screenHeight: number;
  readonly palette: Palette;
  readonly clouds: CloudSide;
  readonly fontPath: string;
  readonly size: OutputSize;
}

/** Sitenin gren dokusu (`web/src/styles/global.css` `.film::before` ile aynı döşeme). */
export const grainUrl: string = new URL("../../web/public/grain.png", import.meta.url).href;

/** Düzenin genişliği: tüm ölçüler bu genişlikte yazılır, çıktıya `zoom` ile ölçeklenir. */
const stageWidth: number = 1320;
/** Aygıtın üst kenarı (sahne px): başlık ve iki satıra kadar alt başlık bunun üstüne sığar. */
const deviceTop: number = 668;
/** Metin bloğunun alanı: üstten boşluk ve aygıta kalan en az boşluk (sahne px). */
const copyTop: number = 96;
const copyBottomGap: number = 56;
/** Aygıtın altındaki boşluk (sahne px; gölge sığar). */
const deviceBottomGap: number = 96;
/** Çerçevenin dış metal kenarı ve siyah ekran kenarı (sahne px). */
const rimWidth: number = 7;
const bezelWidth: number = 20;
/** Ekran köşe yarıçapı ve Dynamic Island ölçüleri, ekran genişliğine oranla (440 pt genişlikte 62 pt köşe; ada 126 × 37 pt, üstten 11 pt). */
const screenCornerRatio: number = 62 / 440;
const islandWidthRatio: number = 126 / 440;
const islandHeightRatio: number = 37.33 / 440;
const islandTopRatio: number = 11 / 440;

/** HTML'e yazılacak metni kaçırır. Saf fonksiyondur. */
export function escapeHtml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

/** Sitedeki `.film--clouds-left/right` katmanları; `right` yatayda aynadır. Saf fonksiyondur. */
export function cloudLayers(palette: Palette, side: CloudSide): string {
  const x = (left: number): number => (side === "left" ? left : 100 - left);
  const mix = (color: string, percent: number): string => `color-mix(in srgb, ${color} ${percent}%, transparent)`;
  return [
    `radial-gradient(ellipse 34% 30% at ${x(82)}% 34%, ${mix(palette.c1, 92)} 0%, ${mix(palette.c1, 45)} 45%, transparent 100%)`,
    `radial-gradient(ellipse 30% 22% at ${x(28)}% 48%, ${mix(palette.c0, 45)} 0%, transparent 100%)`,
    `radial-gradient(ellipse 26% 18% at ${x(70)}% 82%, ${mix(palette.c3, 38)} 0%, transparent 100%)`,
    `radial-gradient(ellipse 48% 40% at ${x(64)}% 66%, ${mix(palette.c0, 80)} 0%, ${mix(palette.c0, 30)} 50%, transparent 100%)`,
    `radial-gradient(ellipse 66% 52% at ${x(6)}% 100%, ${mix(palette.c2, 95)} 0%, ${mix(palette.c2, 45)} 50%, transparent 100%)`,
    `radial-gradient(ellipse 80% 58% at ${x(48)}% -6%, ${mix(palette.c3, 92)} 0%, ${mix(palette.c3, 40)} 50%, transparent 100%)`,
  ].join(",\n      ");
}

/** Aygıtın sahnedeki ölçüleri (sahne px). */
export interface DeviceGeometry {
  readonly outerWidth: number;
  readonly outerHeight: number;
  readonly screenWidth: number;
  readonly screenHeight: number;
  readonly screenRadius: number;
}

/**
 * Aygıt ölçüleri: yükseklik sahneye sığacak kadar (üst kenar sabit, altta boşluk), genişlik ekranın en-boy oranından.
 * Saf fonksiyondur.
 */
export function deviceGeometry(stageHeight: number, screenWidth: number, screenHeight: number): DeviceGeometry {
  const outerHeight: number = stageHeight - deviceTop - deviceBottomGap;
  const innerHeight: number = outerHeight - 2 * (rimWidth + bezelWidth);
  const innerWidth: number = (innerHeight * screenWidth) / screenHeight;
  return {
    outerWidth: innerWidth + 2 * (rimWidth + bezelWidth),
    outerHeight,
    screenWidth: innerWidth,
    screenHeight: innerHeight,
    screenRadius: innerWidth * screenCornerRatio,
  };
}

/** Bir görselin HTML'i. Saf fonksiyondur. */
export function sceneHtml(input: SceneHtmlInput): string {
  const zoom: number = input.size.width / stageWidth;
  const stageHeight: number = input.size.height / zoom;
  const device: DeviceGeometry = deviceGeometry(stageHeight, input.screenWidth, input.screenHeight);
  const islandWidth: number = device.screenWidth * islandWidthRatio;
  const islandHeight: number = device.screenWidth * islandHeightRatio;
  const islandTop: number = device.screenWidth * islandTopRatio;
  const innerRadius: number = device.screenRadius + bezelWidth;
  const outerRadius: number = innerRadius + rimWidth;
  const subhead: string = input.subhead === null ? "" : `<p class="subhead">${escapeHtml(input.subhead)}</p>`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  @font-face {
    font-family: "Inter";
    src: url("${pathToFileURL(input.fontPath).href}") format("woff2");
    font-weight: 100 900;
    font-style: normal;
  }
  html, body { margin: 0; padding: 0; }
  html { zoom: ${zoom}; }
  body {
    width: ${stageWidth}px;
    height: ${stageHeight}px;
    overflow: hidden;
    position: relative;
    font-family: "Inter", sans-serif;
    font-feature-settings: "cv11", "ss03";
    -webkit-font-smoothing: antialiased;
    color: #0a0a0a;
    background-color: ${input.palette.base};
    background-image:
      ${cloudLayers(input.palette, input.clouds)};
  }
  /* Film greni: sitedeki gibi overlay ile hem aydınlatır hem karartır; yalnızca zemindedir, telefonun üstüne düşmez. */
  .grain {
    position: absolute;
    inset: 0;
    background-image: url("${grainUrl}");
    background-size: 240px 240px;
    mix-blend-mode: overlay;
    opacity: 0.55;
  }
  /* Üstte metnin arkasında yumuşak beyaz ışık: başlık her paletle aynı kontrastta okunur. */
  .light {
    position: absolute;
    inset: 0;
    background:
      radial-gradient(ellipse 95% 34% at 50% 6%, rgb(255 255 255 / 0.78) 0%, rgb(255 255 255 / 0.42) 52%, transparent 100%);
  }
  /* Metin bloğu telefonun üstündeki alanda dikeyde ortalanır: tek ya da iki satırlık alt başlıkta denge aynı kalır. */
  .copy {
    position: absolute;
    left: 100px;
    right: 100px;
    top: ${copyTop}px;
    height: ${deviceTop - copyTop - copyBottomGap}px;
    display: flex;
    flex-direction: column;
    justify-content: center;
    text-align: center;
  }
  .headline {
    margin: 0;
    font-size: 112px;
    line-height: 1.04;
    font-weight: 650;
    letter-spacing: -0.036em;
    text-wrap: balance;
  }
  .subhead {
    margin: 34px auto 0;
    max-width: 1000px;
    font-size: 48px;
    line-height: 1.28;
    font-weight: 450;
    letter-spacing: -0.012em;
    color: rgb(10 10 10 / 0.64);
    text-wrap: balance;
  }
  .device {
    position: absolute;
    top: ${deviceTop}px;
    left: ${(stageWidth - device.outerWidth) / 2}px;
    width: ${device.outerWidth}px;
    height: ${device.outerHeight}px;
    box-sizing: border-box;
    padding: ${rimWidth}px;
    border-radius: ${outerRadius}px;
    /* Metal kenar: koyu titanyum, köşelerde hafif ışık. */
    background: linear-gradient(150deg, #8a8784 0%, #3a3937 14%, #232322 48%, #3a3937 86%, #7d7a77 100%);
    box-shadow:
      0 70px 120px -30px rgb(40 24 16 / 0.34),
      0 28px 48px -18px rgb(40 24 16 / 0.22);
  }
  .bezel {
    width: 100%;
    height: 100%;
    box-sizing: border-box;
    padding: ${bezelWidth}px;
    border-radius: ${innerRadius}px;
    background: #050505;
    box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.08);
  }
  .screen {
    position: relative;
    width: ${device.screenWidth}px;
    height: ${device.screenHeight}px;
    border-radius: ${device.screenRadius}px;
    overflow: hidden;
    background: #ffffff;
  }
  .screen img {
    display: block;
    width: 100%;
    height: 100%;
  }
  .island {
    position: absolute;
    top: ${islandTop}px;
    left: ${(device.screenWidth - islandWidth) / 2}px;
    width: ${islandWidth}px;
    height: ${islandHeight}px;
    border-radius: ${islandHeight / 2}px;
    background: #000000;
  }
  /* Yan düğmeler: solda eylem ve ses, sağda yan düğme ve kamera denetimi. */
  .button {
    position: absolute;
    width: 6px;
    border-radius: 3px;
    background: linear-gradient(90deg, #4a4846, #2a2928);
  }
  .button.left { left: -5px; }
  .button.right { right: -5px; }
</style>
</head>
<body>
  <div class="grain"></div>
  <div class="light"></div>
  <div class="copy">
    <h1 class="headline">${escapeHtml(input.headline)}</h1>
    ${subhead}
  </div>
  <div class="device">
    <div class="button left" style="top: ${device.outerHeight * 0.17}px; height: ${device.outerHeight * 0.036}px"></div>
    <div class="button left" style="top: ${device.outerHeight * 0.235}px; height: ${device.outerHeight * 0.066}px"></div>
    <div class="button left" style="top: ${device.outerHeight * 0.315}px; height: ${device.outerHeight * 0.066}px"></div>
    <div class="button right" style="top: ${device.outerHeight * 0.26}px; height: ${device.outerHeight * 0.1}px"></div>
    <div class="button right" style="top: ${device.outerHeight * 0.56}px; height: ${device.outerHeight * 0.06}px"></div>
    <div class="bezel">
      <div class="screen">
        <img src="${pathToFileURL(input.screenshotPath).href}" alt="">
        <div class="island"></div>
      </div>
    </div>
  </div>
</body>
</html>
`;
}

/** Headless Chrome adaptörü: HTML dosyasını verilen ölçüde PNG'ye çevirir. */
export class ChromeRenderer {
  private readonly browser: Browser;

  private constructor(browser: Browser) {
    this.browser = browser;
  }

  static async launch(executablePath: string): Promise<ChromeRenderer> {
    return new ChromeRenderer(await chromium.launch({ executablePath, headless: true }));
  }

  /**
   * HTML dosyasını açar, yazı tipi ve görseller yüklenince ekranın tamamını çeker. Sayfadaki `<img>` sayısı
   * `expectedImages` değilse ya da biri yüklenmediyse `ComposeError`.
   */
  async render(htmlPath: string, width: number, height: number, expectedImages: number): Promise<Buffer> {
    const page: Page = await this.browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    try {
      await page.goto(pathToFileURL(htmlPath).href, { waitUntil: "load" });
      // Inter, sayfada metin olmasa da yüklenir (ör. metinsiz abonelik görseli): denetim yüklenmemiş yazı tipinde false döner.
      await page.evaluate(async (): Promise<void> => {
        await document.fonts.load('650 112px "Inter"');
        await document.fonts.ready;
      });
      const interLoaded: boolean = await page.evaluate((): boolean => document.fonts.check('650 112px "Inter"'));
      if (!interLoaded) {
        throw new ComposeError(`Inter yüklenmedi: ${htmlPath}`);
      }
      const loadedImages: number = await page.evaluate(
        (): number => Array.from(document.images).filter((image: HTMLImageElement) => image.complete && image.naturalWidth > 0).length,
      );
      const totalImages: number = await page.evaluate((): number => document.images.length);
      if (totalImages !== expectedImages || loadedImages !== totalImages) {
        throw new ComposeError(`Görseller: beklenen ${expectedImages}, sayfada ${totalImages}, yüklenen ${loadedImages}: ${htmlPath}`);
      }
      return await page.screenshot({ type: "png", fullPage: false });
    } finally {
      await page.close();
    }
  }

  async close(): Promise<void> {
    await this.browser.close();
  }
}

/** PNG'yi saydamlıksız, sRGB profilli PNG'ye çevirir ve ölçüsünü denetler. */
export async function flattenToSrgbPng(input: Buffer, width: number, height: number): Promise<Buffer> {
  const output: Buffer = await sharp(input).removeAlpha().toColourspace("srgb").withIccProfile("srgb").png({ compressionLevel: 9 }).toBuffer();
  const meta: Metadata = await sharp(output).metadata();
  if (meta.width !== width || meta.height !== height || meta.hasAlpha || meta.channels !== 3) {
    throw new ComposeError(
      `Beklenen ${width}×${height} RGB, gelen ${meta.width}×${meta.height}, kanal ${meta.channels}, saydamlık ${meta.hasAlpha}`,
    );
  }
  return output;
}

/** Küçük JPEG önizleme (PR'da ve gözden geçirmede). */
export async function previewJpeg(input: Buffer, width: number): Promise<Buffer> {
  return await sharp(input).resize({ width }).jpeg({ quality: 82, mozjpeg: true }).toBuffer();
}

/** Görsellerin yan yana küçük bir paftası (tüm setin tutarlılığını tek bakışta görmek için). */
export async function contactSheet(images: readonly Buffer[], tileWidth: number, gap: number): Promise<Buffer> {
  if (images.length === 0) {
    throw new ComposeError("Pafta: görsel yok");
  }
  const tiles: Buffer[] = await Promise.all(images.map(async (image: Buffer) => await sharp(image).resize({ width: tileWidth }).png().toBuffer()));
  const firstMeta: Metadata = await sharp(tiles[0]).metadata();
  if (firstMeta.height === undefined) {
    throw new ComposeError("Pafta: ilk görselin yüksekliği okunamadı");
  }
  const tileHeight: number = firstMeta.height;
  const width: number = tiles.length * tileWidth + (tiles.length + 1) * gap;
  const height: number = tileHeight + 2 * gap;
  return await sharp({ create: { width, height, channels: 3, background: "#f5f5f5" } })
    .composite(tiles.map((tile: Buffer, index: number) => ({ input: tile, left: gap + index * (tileWidth + gap), top: gap })))
    .jpeg({ quality: 84, mozjpeg: true })
    .toBuffer();
}
