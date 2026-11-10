// Site haritası: arama motorlarına açık sayfalar ve blog yazıları. Blog yazıları ve blog dizini `<lastmod>` taşır (yazının
// `updated` ya da `published` günü; dizinde en yeni yazınınki); sürüm geçmişi en yeni sürümün yayın gününü taşır; sabit sayfalar routes.ts `pageModified`'daki günü taşır,
// orada olmayanınki yazılmaz. IndexNow betiği (scripts/indexnow.ts) değişen sayfaları bu dosyanın `<lastmod>`
// değerlerinden seçer.
import type { APIRoute } from "astro";
import { type BlogPost, blogEntries, blogPost, publishedIso } from "../lib/blog";
import { blogPostPath, type PageKey, indexedPages, pageModified, pageUrl } from "../routes";
import { siteConfig } from "../site";
import { changelog } from "../lib/changelog-source";

/** Site haritasındaki adres ve bilinen son değişiklik günü (YYYY-AA-GG; bilinmiyorsa null). */
export interface SitemapEntry {
  readonly loc: string;
  readonly lastmod: string | null;
}

/** Site haritası XML'i (mutlak adresler verilen sırayla). Saf fonksiyondur. */
export function sitemapXml(entries: readonly SitemapEntry[]): string {
  const urls: string[] = entries.map((entry: SitemapEntry): string =>
    entry.lastmod === null ? `  <url>\n    <loc>${entry.loc}</loc>\n  </url>` : `  <url>\n    <loc>${entry.loc}</loc>\n    <lastmod>${entry.lastmod}</lastmod>\n  </url>`,
  );
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`;
}

/**
 * Sayfanın girdisi: blog dizini en yeni yazının değişiklik gününü (yazı yoksa null), sürüm geçmişi en yeni sürümün
 * yayın gününü, diğer sayfalar `pageModified`'daki günü alır. Saf fonksiyondur.
 */
function pageEntry(page: PageKey, origin: string, posts: readonly BlogPost[], newestRelease: string | null): SitemapEntry {
  if (page === "changelog") {
    return { loc: pageUrl(page, origin), lastmod: newestRelease };
  }
  if (page !== "blog") {
    return { loc: pageUrl(page, origin), lastmod: pageModified[page] ?? null };
  }
  const newest: number | null = posts.length === 0 ? null : Math.max(...posts.map((post: BlogPost): number => post.modified.getTime()));
  return { loc: pageUrl(page, origin), lastmod: newest === null ? null : publishedIso(new Date(newest)) };
}

export const GET: APIRoute = async (): Promise<Response> => {
  const origin: string = siteConfig.siteOrigin;
  const posts: readonly BlogPost[] = (await blogEntries()).map(blogPost);
  const entries: readonly SitemapEntry[] = [
    ...indexedPages.map((page: PageKey): SitemapEntry => pageEntry(page, origin, posts, changelog[0]?.date ?? null)),
    ...posts.map((post: BlogPost): SitemapEntry => ({ loc: `${origin}${blogPostPath(post.slug)}`, lastmod: publishedIso(post.modified) })),
  ];
  return new Response(sitemapXml(entries), { headers: { "content-type": "application/xml; charset=utf-8" } });
};
