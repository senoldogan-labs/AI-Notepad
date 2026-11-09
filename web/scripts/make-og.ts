// Sitenin paylaşım kartı görüntüsünü (public/og.png, 1200×630) üretir, Warm Ember dilinde: Ember Sand zemin, logo ve ad,
// mürekkepten bakıra süzülen slogan (ana sayfa başlığındaki gibi) ve altta kontur çizgili ember bandı (global.css
// `.ember-band`, çizgiler src/lib/contours.ts). Derlenmiş site sunulurken (scripts/serve.ts) çalıştırılır; çıktı repoya
// girer, derleme bunu çalıştırmaz. Blog yazılarının görselleri ayrıdır (scripts/make-blog-og.ts).
// Kullanım: node scripts/make-og.ts <site adresi> <Chrome yolu>
import { fileURLToPath } from "node:url";
import { type Browser, type BrowserContext, type Page, chromium } from "playwright-core";
import { productName } from "../src/config.ts";
import { contourPaths } from "../src/lib/contours.ts";
import { logoSvg, ogViewport, writeOgPng } from "./og-image.ts";

/** Komut satırı bağımsız değişkeni; yoksa hata. */
function argument(index: number, name: string): string {
  const value: string | undefined = process.argv[index];
  if (value === undefined || value === "") {
    throw new Error(`Eksik bağımsız değişken: ${name}. Kullanım: node scripts/make-og.ts <site> <chrome>`);
  }
  return value;
}

/** Bandın boyu (piksel). */
const bandHeight: number = 210;

/** Bandın kontur çizgileri (SVG). Saf fonksiyondur. */
function contoursSvg(width: number, height: number): string {
  const paths: string = contourPaths("gistsmith-og", width, height, 5)
    .map((d: string): string => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="1"/>`)
    .join("");
  return `<svg class="ember-band__contours" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-hidden="true">${paths}</svg>`;
}

const css: string = `
  html, body { margin: 0; }
  .og { position: relative; width: 1200px; height: 630px; overflow: hidden; background: #f6f0e7; color: #1c1714; }
  .og__content { position: relative; z-index: 1; display: grid; justify-items: center; gap: 22px; padding-top: 70px; text-align: center; }
  .og__brand { display: flex; align-items: center; gap: 16px; }
  .og__name { font-size: 30px; font-weight: 600; letter-spacing: -0.02em; }
  .og__title {
    margin: 0; max-width: 16ch; padding-bottom: 0.1em; font-size: 74px; line-height: 1.02; letter-spacing: -0.045em; font-weight: 600;
    background-image: linear-gradient(100deg, #1c1714 0%, #1c1714 18%, #5a3020 58%, #a8552f 100%);
    -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  .og .ember-band { position: absolute; inset: auto 0 0; height: ${bandHeight}px; }
`;

/** Kartı çizer ve kaydeder. */
async function main(): Promise<void> {
  const base: string = argument(2, "site adresi").replace(/\/$/, "");
  const chromePath: string = argument(3, "Chrome yolu");
  const output: string = fileURLToPath(new URL("../public/og.png", import.meta.url));
  const browser: Browser = await chromium.launch({ executablePath: chromePath, headless: true });
  try {
    // Sitenin stil dosyaları ve yazı tipi için site sayfası açılır; içerik betikle değiştirildiğinden CSP atlanır.
    const context: BrowserContext = await browser.newContext({ viewport: ogViewport, colorScheme: "light", bypassCSP: true });
    const page: Page = await context.newPage();
    await page.goto(`${base}/404`, { waitUntil: "load" });
    await page.addStyleTag({ content: css });
    await page.evaluate(
      ({ contours, mark, name }: { readonly contours: string; readonly mark: string; readonly name: string }): void => {
        document.documentElement.dataset["palette"] = "ember";
        document.documentElement.dataset["theme"] = "light";
        document.body.innerHTML = `<div class="og"><div class="og__content">
          <div class="og__brand">${mark}<span class="og__name">${name}</span></div>
          <p class="og__title">Listens to your meetings, writes your notes.</p></div>
          <div class="ember-band">${contours}</div></div>`;
      },
      { contours: contoursSvg(ogViewport.width, bandHeight), mark: logoSvg(64), name: productName },
    );
    await page.evaluate(async (): Promise<void> => {
      await document.fonts.ready;
    });
    const bytes: number = await writeOgPng(await page.screenshot({ clip: { x: 0, y: 0, ...ogViewport } }), output);
    console.log("og_written", { output, bytes });
  } finally {
    await browser.close();
  }
}

await main();
