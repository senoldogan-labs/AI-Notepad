// Sitenin yapılandırılmış verisi (schema.org JSON-LD): ana sayfada uygulama (`SoftwareApplication`: özellik listesi,
// aylık ve yıllık plan ile ücretsiz deneme; işletim sistemi Mac ve iPhone gereksinimleri), onu sunan işletme (`Organization`) ve sık sorulan sorular (`FAQPage`); fiyat
// sayfasında abonelik ürünü (`Product`: aylık ve yıllık teklif) ve soruları; karşılaştırma, dil ve entegrasyon sayfalarında gezinti izi (`BreadcrumbList`) ve varsa
// soruları; blog yazılarında `BlogPosting` ve gezinti izi (ön bilgisinden: src/content/blog). Değerler sitenin tek
// kaynaklarından gelir: ürün adı (config.ts), fiyat, deneme, gereksinimler, özellikler ve sorular (copy.ts), işletme
// (legal/operator.ts). `<script type="application/ld+json">` veri bloğudur, çalıştırılmaz; CSP onu engellemez.
import { productName, type SiteConfig } from "../config";
import type { CommonCopy, Faq, PageMeta } from "../copy";
import type { Operator } from "../legal/operator";
import { pageUrl } from "../routes";

/** İşletme düğümü. */
interface OrganizationNode {
  readonly "@type": "Organization";
  readonly "@id": string;
  readonly name: string;
  readonly url: string;
  readonly email: string;
  readonly logo: string;
  readonly address: string;
}

/** Abonelik döneminin fiyat tanımı: aylık (`MON`, `P1M`) ya da yıllık (`ANN`, `P1Y`). */
interface PeriodPriceNode {
  readonly "@type": "UnitPriceSpecification";
  readonly price: string;
  readonly priceCurrency: string;
  readonly unitCode: "MON" | "ANN";
  readonly billingDuration: "P1M" | "P1Y";
  readonly valueAddedTaxIncluded: true;
}

/** Abonelik teklifi (planın adı `name`'dedir). */
interface OfferNode {
  readonly "@type": "Offer";
  readonly name: string;
  readonly price: string;
  readonly priceCurrency: string;
  readonly url: string;
  readonly priceSpecification: PeriodPriceNode;
}

/** Ücretsiz deneme teklifi: fiyatı sıfır, koşulları `description`'da. */
interface TrialOfferNode {
  readonly "@type": "Offer";
  readonly name: string;
  readonly price: "0.00";
  readonly priceCurrency: string;
  readonly url: string;
  readonly description: string;
}

/** Uygulama düğümü; yayıncı işletme düğümüne `@id` ile bağlanır. */
interface SoftwareApplicationNode {
  readonly "@type": "SoftwareApplication";
  readonly name: string;
  readonly description: string;
  readonly url: string;
  readonly image: string;
  readonly downloadUrl: string;
  readonly applicationCategory: "BusinessApplication";
  readonly operatingSystem: string;
  readonly processorRequirements: string;
  readonly featureList: readonly string[];
  /** Aylık ve yıllık plan, ücretsiz deneme. */
  readonly offers: readonly [OfferNode, OfferNode, TrialOfferNode];
  readonly publisher: { readonly "@id": string };
}

/** Sık sorulan sorunun yanıtı. */
interface AnswerNode {
  readonly "@type": "Answer";
  readonly text: string;
}

/** Sık sorulan soru. */
interface QuestionNode {
  readonly "@type": "Question";
  readonly name: string;
  readonly acceptedAnswer: AnswerNode;
}

/** Sayfadaki sık sorulan sorular (yalnızca sayfada görünen soru ve yanıtlar). */
interface FaqPageNode {
  readonly "@type": "FAQPage";
  readonly "@id": string;
  readonly url: string;
  readonly mainEntity: readonly QuestionNode[];
}

/** Ana sayfaya yazılan JSON-LD belgesi. */
export interface StructuredDataDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [SoftwareApplicationNode, OrganizationNode, FaqPageNode];
}

/** The subscription as a product (pricing page): its two plans as offers, sold by the business behind the site. */
interface ProductNode {
  readonly "@type": "Product";
  readonly "@id": string;
  readonly name: string;
  readonly description: string;
  readonly url: string;
  readonly image: string;
  readonly brand: { readonly "@type": "Brand"; readonly name: string };
  readonly offers: readonly [OfferNode, OfferNode];
}

/** The pricing page's JSON-LD: the product with its monthly and yearly offers, and the page's questions. */
export interface PricingDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [ProductNode, FaqPageNode];
}

/** Bilgi sayfasının JSON-LD belgesi (karşılaştırma, diller, entegrasyonlar): gezinti izi ve varsa sık sorulan sorular. */
export interface InfoPageDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [BreadcrumbListNode] | readonly [BreadcrumbListNode, FaqPageNode];
}

/**
 * Sayfanın sık sorulan soruları (`FAQPage`): sayfadaki `Faq` bileşeninin gösterdiği aynı `copy.ts` girdilerinden
 * üretilir, metin kopyalanmaz. Saf fonksiyondur.
 */
export function faqPageNode(items: readonly Faq[], url: string): FaqPageNode {
  return {
    "@type": "FAQPage",
    "@id": `${url}#faq`,
    url,
    mainEntity: items.map((item: Faq): QuestionNode => ({ "@type": "Question", name: item.question, acceptedAnswer: { "@type": "Answer", text: item.answer } })),
  };
}

/**
 * The pricing page's JSON-LD: the subscription as a `Product` with the monthly and yearly plans (prices from copy.ts,
 * taxes included; no ratings) and the page's questions. Pure function.
 */
export function pricingStructuredData(config: SiteConfig, common: CommonCopy, meta: PageMeta, faq: readonly Faq[]): PricingDocument {
  const origin: string = config.siteOrigin;
  const url: string = pageUrl("pricing", origin);
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Product",
        "@id": `${url}#product`,
        name: productName,
        description: meta.description,
        url,
        image: `${origin}/og.png`,
        brand: { "@type": "Brand", name: productName },
        offers: [
          planOffer(`${productName} monthly`, usdPrice(common.price), "month", url),
          planOffer(`${productName} yearly`, usdPrice(common.yearlyPrice), "year", url),
        ],
      },
      faqPageNode(faq, url),
    ],
  };
}

/** Fiyat ya da gereksinim metni beklenen biçimde değil: copy.ts değişti, yapılandırılmış veri güncellenmeli. */
export class StructuredDataSourceError extends Error {
  override readonly name: string = "StructuredDataSourceError";
}

/** Dolar fiyatı ve para birimi. */
interface UsdPrice {
  readonly amount: string;
  readonly currency: "USD";
}

/**
 * `$5.99` ya da `$49` biçimindeki fiyat metnini iki ondalıklı tutara çevirir (`49.00`); başka biçimde
 * `StructuredDataSourceError`. Saf fonksiyondur.
 */
function usdPrice(price: string): UsdPrice {
  const match: RegExpExecArray | null = /^\$([0-9]+)(?:\.([0-9]{2}))?$/.exec(price);
  const whole: string | undefined = match?.[1];
  if (match === null || whole === undefined) {
    throw new StructuredDataSourceError(`Fiyat "$<tutar>" biçiminde olmalı; gelen: ${JSON.stringify(price)} (copy.common.price, copy.common.yearlyPrice).`);
  }
  return { amount: `${whole}.${match[2] ?? "00"}`, currency: "USD" };
}

/** Planın teklifi: fiyat ve dönemi (vergiler dahil). Saf fonksiyondur. */
function planOffer(name: string, price: UsdPrice, period: "month" | "year", url: string): OfferNode {
  return {
    "@type": "Offer",
    name,
    price: price.amount,
    priceCurrency: price.currency,
    url,
    priceSpecification: {
      "@type": "UnitPriceSpecification",
      price: price.amount,
      priceCurrency: price.currency,
      unitCode: period === "month" ? "MON" : "ANN",
      billingDuration: period === "month" ? "P1M" : "P1Y",
      valueAddedTaxIncluded: true,
    },
  };
}

/** İşletim sistemi ve işlemci gereksinimi. */
interface Requirements {
  readonly operatingSystem: string;
  readonly processor: string;
}

/** `macOS 15 or later · Apple silicon` biçimindeki metni ikiye ayırır; başka biçimde `StructuredDataSourceError`. Saf fonksiyondur. */
function requirements(text: string): Requirements {
  const parts: readonly string[] = text.split(" · ");
  const operatingSystem: string | undefined = parts[0];
  const processor: string | undefined = parts[1];
  if (parts.length !== 2 || operatingSystem === undefined || processor === undefined) {
    throw new StructuredDataSourceError(`Gereksinim "<sistem> · <işlemci>" biçiminde olmalı; gelen: ${JSON.stringify(text)} (copy.common.requirementsShort).`);
  }
  return { operatingSystem, processor };
}

/** Ana sayfanın JSON-LD girdileri (sayfanın diliyle: `/` ya da `/fi`). */
export interface HomeStructuredDataInput {
  readonly common: CommonCopy;
  readonly meta: PageMeta;
  readonly faq: readonly Faq[];
  /** Uygulamanın özellikleri (`featureList`). */
  readonly features: readonly string[];
  /** Ücretsiz denemenin koşulları (ör. "3 meetings or 7 days…"). */
  readonly trial: string;
  /** Hangi dildeki gösterim çiziliyor: adresler bundan üretilir. */
  readonly page: "home" | "fi";
}

/** Ana sayfanın JSON-LD belgesi: uygulama, işletme ve sayfadaki sık sorulan sorular. Saf fonksiyondur. */
export function homeStructuredData(config: SiteConfig, operator: Operator, input: HomeStructuredDataInput): StructuredDataDocument {
  const { common, meta, faq, page } = input;
  const origin: string = config.siteOrigin;
  const organizationId: string = `${origin}/#organization`;
  const pricingUrl: string = pageUrl("pricing", origin);
  const needs: Requirements = requirements(common.requirementsShort);
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        name: productName,
        description: meta.description,
        url: pageUrl(page, origin),
        image: `${origin}/og.png`,
        downloadUrl: pageUrl("download", origin),
        applicationCategory: "BusinessApplication",
        operatingSystem: `${needs.operatingSystem}, ${common.iphoneRequirementsShort}`,
        processorRequirements: `${needs.processor} (Mac)`,
        featureList: input.features,
        offers: [
          planOffer(`${productName} monthly`, usdPrice(common.price), "month", pricingUrl),
          planOffer(`${productName} yearly`, usdPrice(common.yearlyPrice), "year", pricingUrl),
          { "@type": "Offer", name: `${productName} free trial`, price: "0.00", priceCurrency: "USD", url: pageUrl("download", origin), description: input.trial },
        ],
        publisher: { "@id": organizationId },
      },
      {
        "@type": "Organization",
        "@id": organizationId,
        name: operator.name,
        url: origin,
        email: operator.email,
        logo: `${origin}/apple-touch-icon.png`,
        address: operator.address,
      },
      faqPageNode(faq, pageUrl(page, origin)),
    ],
  };
}

/** Yazar. */
interface PersonNode {
  readonly "@type": "Person";
  readonly name: string;
}

/** Görsel (paylaşım görseli, boyutlarıyla). */
interface ImageObjectNode {
  readonly "@type": "ImageObject";
  readonly url: string;
  readonly width: number;
  readonly height: number;
}

/** Blog yazısı; yayıncı işletme düğümüne (ana sayfadaki `Organization`) `@id` ile bağlanır. */
interface BlogPostingNode {
  readonly "@type": "BlogPosting";
  readonly "@id": string;
  readonly headline: string;
  readonly description: string;
  readonly url: string;
  readonly mainEntityOfPage: string;
  readonly image: ImageObjectNode;
  readonly datePublished: string;
  readonly dateModified: string;
  readonly inLanguage: "en";
  readonly author: PersonNode;
  readonly publisher: { readonly "@type": "Organization"; readonly "@id": string; readonly name: string; readonly url: string };
}

/** Gezinti izinin bir basamağı (1'den başlar). */
interface ListItemNode {
  readonly "@type": "ListItem";
  readonly position: number;
  readonly name: string;
  readonly item: string;
}

/** Gezinti izi: ana sayfa › … › sayfa. */
interface BreadcrumbListNode {
  readonly "@type": "BreadcrumbList";
  readonly "@id": string;
  readonly itemListElement: readonly ListItemNode[];
}

/** Gezinti izinin bir basamağı: adı ve mutlak adresi. */
export interface Crumb {
  readonly name: string;
  readonly url: string;
}

/** Gezinti izi: ana sayfadan başlar, basamaklar verilen sırayla, son basamak sayfanın kendisi. Saf fonksiyondur. */
export function breadcrumbNode(config: SiteConfig, crumbs: readonly Crumb[]): BreadcrumbListNode {
  const all: readonly Crumb[] = [{ name: productName, url: pageUrl("home", config.siteOrigin) }, ...crumbs];
  const last: Crumb | undefined = all.at(-1);
  if (last === undefined) {
    throw new StructuredDataSourceError("Gezinti izi boş olamaz.");
  }
  return {
    "@type": "BreadcrumbList",
    "@id": `${last.url}#breadcrumbs`,
    itemListElement: all.map((crumb: Crumb, index: number): ListItemNode => ({ "@type": "ListItem", position: index + 1, name: crumb.name, item: crumb.url })),
  };
}

/**
 * Bilgi sayfasının JSON-LD belgesi: gezinti izi ve sayfada sık sorulan sorular görünüyorsa onlar (`faq` boşsa
 * `FAQPage` yazılmaz). Saf fonksiyondur.
 */
export function infoPageStructuredData(config: SiteConfig, crumbs: readonly Crumb[], faq: readonly Faq[]): InfoPageDocument {
  const breadcrumbs: BreadcrumbListNode = breadcrumbNode(config, crumbs);
  const page: Crumb | undefined = crumbs.at(-1);
  if (page === undefined || faq.length === 0) {
    return { "@context": "https://schema.org", "@graph": [breadcrumbs] };
  }
  return { "@context": "https://schema.org", "@graph": [breadcrumbs, faqPageNode(faq, page.url)] };
}

/** Blog yazısı sayfasının JSON-LD belgesi: yazı ve gezinti izi. */
export interface BlogPostingDocument {
  readonly "@context": "https://schema.org";
  readonly "@graph": readonly [BlogPostingNode, BreadcrumbListNode];
}

/** Blog yazısının JSON-LD'ye giren bilgileri. */
export interface BlogPostingInput {
  readonly url: string;
  readonly title: string;
  readonly description: string;
  readonly author: string;
  /** YYYY-AA-GG. */
  readonly published: string;
  /** Son anlamlı değişiklik (YYYY-AA-GG): `updated`, yoksa `published`. */
  readonly modified: string;
  /** Yazının paylaşım görselinin mutlak adresi (`ogImageSize`). */
  readonly image: string;
  /** Gezinti izindeki blog basamağının adı. */
  readonly blogName: string;
}

/** Paylaşım görsellerinin boyutu (site kartı public/og.png ve yazıların görselleri). */
export const ogImageSize = { width: 1200, height: 630 } as const;

/** Blog yazısının JSON-LD belgesi (`BlogPosting` ve `BreadcrumbList`). Saf fonksiyondur. */
export function blogPostingStructuredData(config: SiteConfig, operator: Operator, post: BlogPostingInput): BlogPostingDocument {
  const origin: string = config.siteOrigin;
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "BlogPosting",
        "@id": `${post.url}#post`,
        headline: post.title,
        description: post.description,
        url: post.url,
        mainEntityOfPage: post.url,
        image: { "@type": "ImageObject", url: post.image, width: ogImageSize.width, height: ogImageSize.height },
        datePublished: post.published,
        dateModified: post.modified,
        inLanguage: "en",
        author: { "@type": "Person", name: post.author },
        publisher: { "@type": "Organization", "@id": `${origin}/#organization`, name: operator.name, url: origin },
      },
      breadcrumbNode(config, [
        { name: post.blogName, url: pageUrl("blog", origin) },
        { name: post.title, url: post.url },
      ]),
    ],
  };
}

/**
 * JSON-LD belgesini `<script>` içine güvenle yazılacak metne çevirir: `<` kaçırılır, böylece metindeki `</script>`
 * bloğu erken kapatamaz. Saf fonksiyondur.
 */
export function structuredDataJson(document: StructuredDataDocument | PricingDocument | BlogPostingDocument | InfoPageDocument): string {
  return JSON.stringify(document).replaceAll("<", "\\u003c");
}
