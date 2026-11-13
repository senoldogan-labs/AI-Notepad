// İndirme kampanyası: reklam ve lansman bağlantısıyla gelen ziyaretçinin `utm_source` ve `utm_campaign` değerleri,
// indirmeyi başlatan bağlantıların adresine eklenir. Düğmeler `data-mac-download` taşır ve adreslerinde kaynak (`?src=`)
// zaten vardır (`config.ts` `macDownloadUrl`); sunucu kampanyayı `download_campaigns` sayacında toplar
// (server/src/downloads.ts `downloadCampaignOf`). Aksi hâlde Product Hunt, Reddit ya da Google reklamından gelen indirme
// yalnız `src` ile sayılır ve kampanyası kaybolur.
// Fiyat, karşılaştırma, blog ve MCP sayfalarındaki çağrılar doğrudan DMG'ye değil indirme sayfasına gider; kampanya o
// sıçramada kaybolmasın diye indirme sayfasının bağlantıları da aynı parametreleri taşır ve sayfanın kendi düğmesi
// kampanyayı adresinden okur. Sayfada indirme bağlantısı yoksa betik hiçbir şey yapmaz.
// Değer biçimi sunucunun izin verdiği kadardır: küçük harf, rakam ve `-`, en çok 32 karakter; uymayan değer eklenmez
// (adrese döngüyle rastgele kampanya yazılamaz). Sunucu da değerleri küçük harfe çevirip denetler, bu yüzden burada da
// küçük harfe çevrilir.
import { routes } from "../routes";

/** Kampanya değerinin biçimi: sunucunun kabul ettiği en geniş küme (32 karakter, küçük harf, rakam, `-`). */
const campaignValuePattern: RegExp = /^[a-z0-9-]{1,32}$/;

/** Adresteki kampanya parametresinin değeri: yoksa ya da biçimi geçmiyorsa null. Saf fonksiyondur. */
function campaignValue(params: URLSearchParams, name: string): string | null {
  const raw: string | null = params.get(name);
  if (raw === null) {
    return null;
  }
  const value: string = raw.trim().toLowerCase();
  return campaignValuePattern.test(value) ? value : null;
}

/**
 * Bağlantı kampanyayı taşımalı mı: indirme düğmesi ya da kendi sitemizdeki indirme, fiyat ve hesap sayfası. Hesap
 * sayfası ödemeyi açar (`account.ts` kampanyayı adresinden okuyup `POST /v1/billing/checkout` gövdesine yazar), fiyat
 * sayfası ona götürür; böylece kampanyanın ödeme sayfası sayıları kampanyaya yazılır. Çerez ya da tarayıcı depolaması
 * kullanılmaz: kampanya yalnızca sitenin kendi bağlantılarında taşınır.
 */
function carriesCampaign(link: HTMLAnchorElement): boolean {
  const campaignPaths: readonly string[] = [routes.download, routes.pricing, routes.account];
  return link.hasAttribute("data-mac-download") || (link.origin === window.location.origin && campaignPaths.includes(link.pathname));
}

/**
 * Bağlantı adresine kampanya parametrelerini ekler. Adreste `src` zaten olduğu için parametreler `&` ile eklenir;
 * `URL` sorgu dizesini kendisi kurar (değerler kodlanır). Saf fonksiyondur.
 */
function withCampaign(href: string, source: string | null, campaign: string | null): string {
  const url: URL = new URL(href);
  if (source !== null) {
    url.searchParams.set("utm_source", source);
  }
  if (campaign !== null) {
    url.searchParams.set("utm_campaign", campaign);
  }
  return url.toString();
}

/** Sayfadaki indirme bağlantılarına adresteki kampanyayı yazar; adreste kampanya yoksa dokunmaz. */
function main(): void {
  const params: URLSearchParams = new URLSearchParams(window.location.search);
  const source: string | null = campaignValue(params, "utm_source");
  const campaign: string | null = campaignValue(params, "utm_campaign");
  if (source === null && campaign === null) {
    return;
  }
  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[href]")) {
    if (carriesCampaign(link)) {
      link.href = withCampaign(link.href, source, campaign);
    }
  }
}

main();
