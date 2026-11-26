// Fiyat sayfası: sayfa durağandır ve bugün satılan tek planı gösterir (betik olmadan da tamdır). Betik herkese açık
// `GET /v1/pricing`'i okur; sunucu Pro'yu sunuyorsa (üretimde `PRO_TIER_POLICY` açıkken) Pro'nun metinlerini ve çizimini,
// ücretsiz planı açtıysa (`free` nesnesi) ücretsiz planın kartını ve metinlerini ayrı parçalar olarak yükler
// (`./pro-offer`, `./free-offer`). Sunucu ikisini de sunmuyorsa ya da yanıt alınamazsa sayfa değişmez (hata konsola
// yazılır).
import { fetchPricing, proOffered } from "./tiers";
import type { PricingOffer } from "../lib/plans";

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  let pricing: PricingOffer;
  try {
    pricing = await fetchPricing();
  } catch (error: unknown) {
    console.error("pricing_tiers_load_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  if (pricing.free !== null) {
    const { showFreeOnPricingPage } = await import("./free-offer");
    showFreeOnPricingPage(pricing.free);
  }
  if (proOffered(pricing.tiers)) {
    const { showProOnPricingPage } = await import("./pro-offer");
    showProOnPricingPage(pricing.tiers);
  }
}

void main();
