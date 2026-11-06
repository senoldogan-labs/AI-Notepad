// Astro yapılandırması: durağan çıktı (Cloudflare Pages), sonda eğik çizgisiz adresler. Sitenin tek CSS'i ve tema betiği
// sayfaya gömülür; CSP onlara 'unsafe-inline' ile değil, derlenen sayfalardan hesaplanan sha256 özetleriyle izin verir. Derleme sonunda `_headers` yapılandırmadan yazılır; yazı tipi lisansı ve uygulama
// simgesi uygulamanın dosyalarından kopyalanır (tek kaynak).
import { copyFile, readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { satteri } from "@astrojs/markdown-satteri";
import { defineConfig } from "astro/config";
import type { AstroIntegration } from "astro";
import { type SiteConfig, parseWebTarget, siteConfigs } from "./src/config";
import { blogImagesPlugin } from "./src/lib/blog-images";
import { type InlineHashes, inlineHashes, pagesHeaders } from "./src/lib/headers";

const config: SiteConfig = siteConfigs[parseWebTarget(process.env["PUBLIC_WEB_TARGET"])];

/** Uygulama klasöründen siteye kopyalanan dosyalar: kaynak (repo köküne göre) → hedef (çıktıya göre). */
const appFiles: readonly { readonly from: string; readonly to: string }[] = [
  { from: "App/Fonts/Inter-OFL.txt", to: "fonts/Inter-OFL.txt" },
  { from: "App/Assets.xcassets/AppIcon.appiconset/icon_256.png", to: "apple-touch-icon.png" },
];

/** Derleme sonunda Cloudflare Pages dosyalarını yazar ve uygulama dosyalarını kopyalar. */
function cloudflarePagesFiles(siteConfig: SiteConfig): AstroIntegration {
  return {
    name: "ainotepad-cloudflare-pages",
    hooks: {
      "astro:build:done": async ({ dir }: { dir: URL }): Promise<void> => {
        const htmlFiles: readonly string[] = (await readdir(dir, { recursive: true }))
          .filter((path: string): boolean => path.endsWith(".html"))
          .map((path: string): string => fileURLToPath(new URL(path, dir)));
        const pages: readonly string[] = await Promise.all(htmlFiles.map((path: string): Promise<string> => readFile(path, "utf8")));
        const hashes: InlineHashes = inlineHashes(pages);
        await writeFile(new URL("_headers", dir), pagesHeaders(siteConfig, hashes), "utf8");
        const repoRoot: URL = new URL("../", import.meta.url);
        for (const file of appFiles) {
          await copyFile(fileURLToPath(new URL(file.from, repoRoot)), fileURLToPath(new URL(file.to, dir)));
        }
      },
    },
  };
}

export default defineConfig({
  site: config.siteOrigin,
  output: "static",
  trailingSlash: "never",
  build: {
    format: "file",
    // Tek CSS dosyası yavaş telefonda ilk boyamayı bir gidiş dönüş geciktiriyordu (Lighthouse mobil LCP ~2,3 sn); gömülü
    // stil ilk yanıtla gelir.
    inlineStylesheets: "always",
  },
  vite: {
    build: {
      // Küçük betikler de dosya olarak çıkar: satır içi yalnız tema betiği (özetle izinli).
      assetsInlineLimit: 0,
      // Tüm sitenin CSS'i tek parça (~20 KB brotli) ve her sayfaya aynısı gömülür: CSP'de tek stil özeti olur.
      cssCodeSplit: false,
    },
  },
  // Blog yazılarındaki kod blokları renklendirilmez: Shiki satır içi `style` yazar, CSP buna izin vermez. Görsellere
  // boyut ve tembel yükleme derlemede yazılır (src/lib/blog-images.ts).
  markdown: { syntaxHighlight: false, processor: satteri({ hastPlugins: [blogImagesPlugin(new URL("./public/", import.meta.url))] }) },
  devToolbar: { enabled: false },
  integrations: [cloudflarePagesFiles(config)],
});
