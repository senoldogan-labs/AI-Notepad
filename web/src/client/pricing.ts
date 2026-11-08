// Fiyat sayfasının Pro katmanı: sayfa durağandır ve Pro kartı HTML'de gizlidir. Betik herkese açık `GET /v1/pricing`'i
// okur; sunucu Pro'yu sunuyorsa (üretimde `PRO_TIER_POLICY` açıkken) Pro kartını ve Personal kartlarının katman satırını
// sunucunun saatleriyle doldurup gösterir, sınırların ve SSS'nin Pro'lu kalıplarını yazar (`./pro-text`). Sunucu Pro'yu
// sunmuyorsa ya da yanıt alınamazsa Pro gizli kalır ve metinler değişmez (hata konsola yazılır); sayfanın geri kalanı
// (Personal planları) betik olmadan da tamdır.
import { dataValue, element } from "./dom";
import { applyProTexts, fetchTiers, offeredProValues } from "./pro-text";
import { siteLocale } from "../config";
import { type PricingTierLines, type ProTextValues, type TierLimitsTemplates, type TierOffer, pricingTierLines } from "../lib/plans";

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
  const values: ProTextValues | null = offeredProValues(offers, templates.meetingLength);
  if (lines === null || values === null) {
    return;
  }
  reveal(lines);
  applyProTexts(values);
}

void main();
