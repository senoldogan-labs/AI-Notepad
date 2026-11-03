// Sayfaların adresleri (sonda eğik çizgi yok). Sunucu ve Mac uygulaması bu adreslerin bir kısmını sabit yazar:
// Stripe Checkout dönüşü `/account?payment=done`, Checkout iptali `/pricing`, Müşteri Portalı dönüşü `/account`, Mac
// uygulaması `/sign-in?app=1&nonce=…`, Apple ile giriş dönüşü `/sign-in`, davet bağlantısı `/invite?code=…`
// (server/src/referrals.ts `inviteUrl`; değişirse paylaşılmış bağlantılar kırılır). Burada değişen adres oralarda
// da değişmelidir.

/** Sayfa kimlikleri. */
export type PageKey =
  | "home"
  | "fi"
  | "pricing"
  | "download"
  | "compare"
  | "vsGranola"
  | "vsOtter"
  | "vsFireflies"
  | "languages"
  | "integrations"
  | "blog"
  | "mcp"
  | "signIn"
  | "account"
  | "invite"
  | "contact"
  | "admin"
  | "privacy"
  | "terms"
  | "notFound";

/** Sayfaların yolları. */
export const routes: Readonly<Record<PageKey, string>> = {
  home: "/",
  fi: "/fi",
  pricing: "/pricing",
  download: "/download",
  compare: "/compare",
  vsGranola: "/vs/granola",
  vsOtter: "/vs/otter",
  vsFireflies: "/vs/fireflies",
  languages: "/languages",
  integrations: "/integrations",
  blog: "/blog",
  mcp: "/mcp",
  signIn: "/sign-in",
  account: "/account",
  invite: "/invite",
  contact: "/contact",
  admin: "/admin",
  privacy: "/privacy",
  terms: "/terms",
  notFound: "/404",
};

/**
 * Arama motorlarına açık sayfalar. Hesap, yönetim ve 404 kişiye özel ya da içeriksizdir; giriş ve davet sayfaları
 * yalnızca bir işlemin adımıdır (aramada çıkmaları ziyaretçiye bir şey anlatmaz).
 */
export const indexedPages: readonly PageKey[] = [
  "home",
  "fi",
  "pricing",
  "download",
  "compare",
  "vsGranola",
  "vsOtter",
  "vsFireflies",
  "languages",
  "integrations",
  "blog",
  "mcp",
  "contact",
  "privacy",
  "terms",
];

/**
 * Sabit sayfaların son anlamlı içerik değişikliği (YYYY-AA-GG): site haritası `<lastmod>` olarak yazar, IndexNow betiği
 * (scripts/indexnow.ts) bugün ya da dün değişen sayfaları arama motorlarına bildirir. Bir sayfanın metni ya da verisi
 * anlamlı biçimde değişince (yeni bölüm, fiyat, karşılaştırma değerleri…) o günün tarihini yaz; yazım düzeltmesinde
 * ilerletme. Tarihi olmayan sayfanın `<lastmod>`'u yazılmaz. Blog dizini ve yazıları tarihlerini yazılardan alır.
 */
export const pageModified: Readonly<Partial<Record<PageKey, string>>> = {
  home: "2026-11-03",
  fi: "2026-11-03",
  download: "2026-11-03",
  compare: "2026-11-03",
  vsGranola: "2026-11-03",
  vsOtter: "2026-11-03",
  vsFireflies: "2026-11-03",
  languages: "2026-11-03",
  integrations: "2026-11-03",
  privacy: "2026-11-03",
};

/** Sitenin dilleri (`<html lang>`, `hreflang`). */
export type SiteLang = "en" | "fi";

/**
 * Aynı sayfanın öbür dildeki hâli: `hreflang` bağlantıları ve paylaşım kartının dili bundan üretilir. Yalnızca
 * çevrilmiş sayfaların eşi vardır.
 */
export interface PageAlternate {
  readonly page: PageKey;
  /** Öbür sürümün dili (`<html lang>` ve `hreflang`). */
  readonly lang: SiteLang;
}

/** Sayfaların dil eşleri. */
export const pageAlternates: Readonly<Partial<Record<PageKey, PageAlternate>>> = {
  home: { page: "fi", lang: "fi" },
  fi: { page: "home", lang: "en" },
};

/** Alt bilgideki dil seçiminin bir dili: o dilin ana sayfası ve kendi dilindeki adı. */
export interface SiteLanguage {
  readonly lang: SiteLang;
  readonly page: PageKey;
  readonly label: string;
}

/**
 * Alt bilgideki dil seçimi. Site İngilizce ve dünyanın her yerine yazılır; öbür diller ek sürümdür, bu yüzden dil
 * bağlantısı üst çubukta değil alt bilgidedir. Yeni bir dil buraya ve `pageAlternates`'e eklenir.
 */
export const siteLanguages: readonly SiteLanguage[] = [
  { lang: "en", page: "home", label: "English" },
  { lang: "fi", page: "fi", label: "Suomi" },
];

/** Önbelleğe alınmayan kişiye özel sayfalar. */
export const privatePages: readonly PageKey[] = ["account", "admin"];

/** Sayfanın mutlak adresi (ana sayfa sonda eğik çizgiyle: `https://alan/`). Saf fonksiyondur. */
export function pageUrl(page: PageKey, origin: string): string {
  return `${origin}${routes[page]}`;
}

/** Blog yazılarının yol kalıbı (`_headers` kuralı): `/blog/<kısa ad>`. */
export const blogPostPattern: string = `${routes.blog}/*`;

/** Blogun RSS akışı (src/pages/blog/rss.xml.ts). */
export const blogFeedPath: string = `${routes.blog}/rss.xml`;

/** Blog yazısının yolu: `/blog/<kısa ad>`. Saf fonksiyondur. */
export function blogPostPath(slug: string): string {
  return `${routes.blog}/${slug}`;
}

/**
 * Blog yazısının paylaşım görseli (1200×630 PNG): `/blog/<kısa ad>/og.png`. Derlemeden sonra scripts/make-blog-og.ts
 * üretir; Open Graph, Twitter, JSON-LD ve RSS bu adresi kullanır. Saf fonksiyondur.
 */
export function blogOgImagePath(slug: string): string {
  return `${blogPostPath(slug)}/og.png`;
}

/**
 * Blog yazısının görsellerinin klasörü: `/blog/<kısa ad>/` (depoda `web/public/blog/<kısa ad>/`, panel yükler; yazı
 * silinince klasör de silinir, server/src/blog.ts). Saf fonksiyondur.
 */
export function blogImageFolder(slug: string): string {
  return `${blogPostPath(slug)}/`;
}

/** Blog yazısı: sayfa kimliği yerine kısa adıyla anılır (yazılar içerik koleksiyonundan gelir). */
export interface BlogPostRef {
  readonly blogPostSlug: string;
}

/** Sitedeki bir sayfa: sabit sayfa ya da blog yazısı. */
export type SitePage = PageKey | BlogPostRef;

/** Sayfanın yolu. Saf fonksiyondur. */
export function sitePagePath(page: SitePage): string {
  return typeof page === "string" ? routes[page] : blogPostPath(page.blogPostSlug);
}

/** Sayfanın ait olduğu sayfa kimliği (üst çubukta etkin bağlantı için): blog yazısı blog sayfasına aittir. Saf fonksiyondur. */
export function sitePageKey(page: SitePage): PageKey {
  return typeof page === "string" ? page : "blog";
}
