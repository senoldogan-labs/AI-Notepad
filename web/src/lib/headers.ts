// Cloudflare Pages `_headers` dosyası: sıkı CSP, HSTS, Referrer-Policy, Permissions-Policy ve önbellek kuralları.
// Derlemede yapılandırmadan üretilir (astro.config.ts).
//
// CSP iki katmanlıdır. Pages, birden çok kurala uyan adreste aynı başlığın değerlerini virgülle birleştirir; tarayıcı
// virgülle ayrılmış her politikayı ayrı ayrı uygular (hepsine uyan yüklenir). `/*` kuralı tüm dış hizmetlere izin veren
// geniş politikayı taşır (sayfası olmayan adresler, ör. bilinmeyen adresin 404'ü, için); her sayfanın kendi kuralı
// yalnızca o sayfanın kullandığı hizmetlere izin veren dar politikayı ekler. Böylece Apple betiği yalnızca giriş
// sayfasında, Turnstile yalnızca iletişim sayfasında çalışabilir. Google ile giriş Google'a yönlendirir; betik yüklenmez.
// Cloudflare Web Analytics işaretçisi her sayfada olduğundan iki katmanın da tüm politikalarında açıktır.
import { createHash } from "node:crypto";
import { appleAuthScriptUrl, appleIdOrigin, type SiteConfig, turnstileOrigin } from "../config";
import { blogPostPattern, type PageKey, privatePages, routes } from "../routes";

/**
 * Sayfaların yüklediği dış hizmetler ve ek kaynaklar. `localImagePreview`: yönetim panelinin blog düzenleyicisi
 * yüklenecek görseli ve bu oturumda yüklenenleri tarayıcıdaki kopyasından (`blob:`) gösterir.
 */
export type ExternalService = "appleSignIn" | "turnstile" | "localImagePreview";

/** Bir dış hizmetin CSP yönergelerine eklediği kaynaklar. */
interface ServiceSources {
  readonly script: readonly string[];
  readonly style: readonly string[];
  readonly img: readonly string[];
  readonly connect: readonly string[];
  readonly frame: readonly string[];
  readonly formAction: readonly string[];
}

/** Adresin kaynağı (şema + alan adı + kapı). Saf fonksiyondur. */
function originOf(url: string): string {
  return new URL(url).origin;
}

/**
 * Hizmetlerin kaynakları. Apple ile giriş açılır pencere kullanır; betik Apple'ın CDN'inden gelir.
 */
const serviceSources: Readonly<Record<ExternalService, ServiceSources>> = {
  appleSignIn: { script: [originOf(appleAuthScriptUrl)], style: [], img: [], connect: [], frame: [appleIdOrigin], formAction: [appleIdOrigin] },
  turnstile: { script: [turnstileOrigin], style: [], img: [], connect: [], frame: [turnstileOrigin], formAction: [] },
  localImagePreview: { script: [], style: [], img: ["blob:"], connect: [], frame: [], formAction: [] },
};

/**
 * Cloudflare Web Analytics (çerezsiz): Pages projesinde panelden açılır ve işaretçi betiğini her sayfaya kendisi ekler.
 * Betik bu kaynaktan yüklenir, ölçümleri ikinci kaynağa gönderir. Her sayfada çalıştığı için hizmet listesine değil
 * geniş ve dar politikaların hepsine eklenir (birleşen politikalardan biri izin vermezse betik engellenir).
 */
const webAnalyticsScriptOrigin: string = "https://static.cloudflareinsights.com";
const webAnalyticsConnectOrigin: string = "https://cloudflareinsights.com";

/** Tüm dış hizmetler (geniş politika). */
const allServices: readonly ExternalService[] = ["appleSignIn", "turnstile", "localImagePreview"];

/** Sayfaların kullandığı dış hizmetler: giriş sayfası Apple, iletişim sayfası Turnstile, yönetim paneli yerel görsel önizlemesi; diğerleri hiçbiri. */
export const pageServices: Readonly<Record<PageKey, readonly ExternalService[]>> = {
  home: [],
  fi: [],
  pricing: [],
  download: [],
  compare: [],
  vsGranola: [],
  vsOtter: [],
  vsFireflies: [],
  vsPoffle: [],
  languages: [],
  integrations: [],
  blog: [],
  mcp: [],
  signIn: ["appleSignIn"],
  account: [],
  invite: [],
  contact: ["turnstile"],
  admin: ["localImagePreview"],
  privacy: [],
  terms: [],
  notFound: [],
};

/** Derlenen sayfalardaki satır içi betik ve stillerin CSP kaynak ifadeleri (`'sha256-…'`). */
export interface InlineHashes {
  readonly script: readonly string[];
  readonly style: readonly string[];
}

/** Metnin CSP özet ifadesi. Saf fonksiyondur. */
function cspHash(content: string): string {
  return `'sha256-${createHash("sha256").update(content, "utf8").digest("base64")}'`;
}

/**
 * Sayfalardaki satır içi `<script>` (dış kaynaksız, çalıştırılan) ve `<style>` içeriklerinin tekil özetleri. JSON-LD gibi
 * veri blokları çalıştırılmaz, CSP'ye girmez. Saf fonksiyondur.
 */
export function inlineHashes(pages: readonly string[]): InlineHashes {
  const scripts: Set<string> = new Set<string>();
  const styles: Set<string> = new Set<string>();
  for (const html of pages) {
    for (const match of html.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
      const attributes: string = match[1] ?? "";
      const body: string = match[2] ?? "";
      if (/\ssrc=/.test(attributes) || /type="application\/(ld\+)?json"/.test(attributes) || body.length === 0) {
        continue;
      }
      scripts.add(cspHash(body));
    }
    for (const match of html.matchAll(/<style(?:\s[^>]*)?>([\s\S]*?)<\/style>/g)) {
      styles.add(cspHash(match[1] ?? ""));
    }
  }
  return { script: [...scripts].sort(), style: [...styles].sort() };
}

/** Yönergenin değeri: sabit kaynaklar ve hizmetlerin kaynakları; hiç kaynak yoksa `'none'`. Saf fonksiyondur. */
function directive(name: string, base: readonly string[], services: readonly ExternalService[], pick: (sources: ServiceSources) => readonly string[]): string {
  const sources: readonly string[] = [...base, ...services.flatMap((service: ExternalService): readonly string[] => pick(serviceSources[service]))];
  return `${name} ${sources.length === 0 ? "'none'" : sources.join(" ")}`;
}

/**
 * Verilen dış hizmetlere izin veren içerik güvenlik politikası. Satır içi betik ve stile yalnızca özetleriyle izin verilir;
 * `'unsafe-inline'` kullanılmaz. Saf fonksiyondur.
 */
export function contentSecurityPolicy(config: SiteConfig, services: readonly ExternalService[], hashes: InlineHashes): string {
  const directives: readonly string[] = [
    "default-src 'none'",
    directive("script-src", ["'self'", webAnalyticsScriptOrigin, ...hashes.script], services, (sources: ServiceSources): readonly string[] => sources.script),
    directive("style-src", ["'self'", ...hashes.style], services, (sources: ServiceSources): readonly string[] => sources.style),
    directive("img-src", ["'self'"], services, (sources: ServiceSources): readonly string[] => sources.img),
    // Ana sayfadaki sessiz tanıtım videosu (public/video) yalnızca siteden yüklenir.
    "media-src 'self'",
    "font-src 'self'",
    directive("connect-src", ["'self'", originOf(config.apiBase), webAnalyticsConnectOrigin], services, (sources: ServiceSources): readonly string[] => sources.connect),
    directive("frame-src", [], services, (sources: ServiceSources): readonly string[] => sources.frame),
    "manifest-src 'self'",
    directive("form-action", ["'self'"], services, (sources: ServiceSources): readonly string[] => sources.formAction),
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    ...(config.siteOrigin.startsWith("https:") ? ["upgrade-insecure-requests"] : []),
  ];
  return directives.join("; ");
}

/**
 * Tarayıcı özellikleri: kendiliğinden oynatma yalnızca sitenin kendisine açık (ana sayfadaki sessiz tanıtım videosu,
 * src/client/launch-video.ts); diğerlerinin hiçbirine ihtiyaç yok.
 */
const permissionsPolicy: string = [
  "accelerometer=()",
  "autoplay=(self)",
  "camera=()",
  "display-capture=()",
  "geolocation=()",
  "gyroscope=()",
  "magnetometer=()",
  "microphone=()",
  "midi=()",
  "payment=()",
  "usb=()",
  "browsing-topics=()",
].join(", ");

/** Tüm sayfa kimlikleri (`routes` sırasıyla). */
const allPages: readonly PageKey[] = Object.keys(routes) as PageKey[];

/** `_headers` dosyasının içeriği. Saf fonksiyondur. */
export function pagesHeaders(config: SiteConfig, hashes: InlineHashes): string {
  const lines: readonly string[] = [
    "/*",
    `  Content-Security-Policy: ${contentSecurityPolicy(config, allServices, hashes)}`,
    "  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload",
    "  Referrer-Policy: strict-origin-when-cross-origin",
    `  Permissions-Policy: ${permissionsPolicy}`,
    "  X-Content-Type-Options: nosniff",
    "  X-Frame-Options: DENY",
    // Apple ile giriş açılır pencere kullanır: açtığımız pencereyle bağ korunur, başka sayfalar bizi açamaz.
    "  Cross-Origin-Opener-Policy: same-origin-allow-popups",
    "  Cross-Origin-Resource-Policy: same-origin",
    "",
    // Her sayfanın dar politikası (geniş politikaya eklenir, ikisi birlikte uygulanır).
    ...allPages.flatMap((page: PageKey): string[] => [
      routes[page],
      `  Content-Security-Policy: ${contentSecurityPolicy(config, pageServices[page], hashes)}`,
      ...(privatePages.includes(page) ? ["  Cache-Control: no-store"] : []),
      "",
    ]),
    // Blog yazıları (`/blog/<kısa ad>`) sayfa kimliği taşımaz; hepsi dış hizmetsiz dar politikayı alır.
    blogPostPattern,
    `  Content-Security-Policy: ${contentSecurityPolicy(config, [], hashes)}`,
    "",
    // Adı içerik özeti taşıyan derleme çıktıları değişmez.
    "/_astro/*",
    "  Cache-Control: public, max-age=31536000, immutable",
    "",
    // Yazı tipinin adında özet yok: güncellenirse ayda bir tazelenir.
    "/fonts/*",
    "  Cache-Control: public, max-age=2592000",
    "",
    // Tanıtım videosu ve kapak görseli: adlarında özet yok, ayda bir tazelenir.
    "/video/*",
    "  Cache-Control: public, max-age=2592000",
    "",
  ];
  return lines.join("\n");
}
