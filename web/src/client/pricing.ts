// Fiyat sayfasının Pro katmanı: sayfa durağandır ve Pro kartı HTML'de gizlidir. Betik herkese açık `GET /v1/pricing`'i
// okur; sunucu Pro'yu sunuyorsa (üretimde `PRO_TIER_POLICY` açıkken) Pro kartını ve Personal kartlarının katman satırını
// sunucunun saatleriyle doldurup gösterir. Sunucu Pro'yu sunmuyorsa ya da yanıt alınamazsa Pro gizli kalır (hata
// konsola yazılır); sayfanın geri kalanı (Personal planları) betik olmadan da tamdır.
import { type RawResponse, parsePricing, send } from "./api";
import { dataValue, element } from "./dom";
import { siteLocale } from "../config";
import { type PricingTierLines, type TierLimitsTemplates, type TierOffer, pricingTierLines } from "../lib/plans";

/** `GET /v1/pricing`: kimliksiz, ağ hatası ve 502/503/504'te iki deneme. */
async function fetchTiers(): Promise<TierOffer[]> {
  const path: string = "/v1/pricing";
  const response: RawResponse = await send({ method: "GET", path, body: null, accessToken: null, attempts: 2 });
  return parsePricing(response, path);
}

/** Katman satırlarını yazar ve Pro kartıyla Personal kartlarının katman satırlarını gösterir. */
function reveal(lines: PricingTierLines): void {
  for (const line of Array.from(document.querySelectorAll<HTMLElement>("[data-tier-line]"))) {
    line.textContent = line.dataset["tierLine"] === "pro" ? lines.pro : lines.personal;
  }
  for (const hidden of Array.from(document.querySelectorAll<HTMLElement>("[data-pro-reveal]"))) {
    hidden.classList.remove("hidden");
  }
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const plans: HTMLElement = element("plans", HTMLElement);
  const templates: TierLimitsTemplates = {
    limits: dataValue(plans, "tierLimits"),
    meetingLength: { hours: dataValue(plans, "meetingHours"), minutes: dataValue(plans, "meetingMinutes") },
  };
  let offers: TierOffer[];
  try {
    offers = await fetchTiers();
  } catch (error: unknown) {
    console.error("pricing_tiers_load_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  const lines: PricingTierLines | null = pricingTierLines(offers, siteLocale, templates);
  if (lines === null) {
    console.info("pricing_pro_not_offered", { tiers: offers.map((offer: TierOffer): string => offer.tier) });
    return;
  }
  reveal(lines);
}

void main();
