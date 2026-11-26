// Karşılaştırma sayfaları (dizin ve /vs): sayfa durağandır ve "ücretsiz seçenek" hücremiz yalnızca denemeyi anlatır.
// Herkese açık `GET /v1/pricing` ücretsiz planı açtıysa (`free` nesnesi) hücre ücretsiz planı da anlatan metinle yazılır
// (`./free-offer`); sunucu ücretsiz planı açmadıysa ya da yanıt alınamazsa sayfa değişmez (hata konsola yazılır).
import { fetchPricing } from "./tiers";
import type { PricingOffer } from "../lib/plans";

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  if (document.querySelector("[data-free-slot]") === null) {
    return;
  }
  let pricing: PricingOffer;
  try {
    pricing = await fetchPricing();
  } catch (error: unknown) {
    console.error("pricing_tiers_load_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  if (pricing.free === null) {
    return;
  }
  const { showFreeTexts } = await import("./free-offer");
  showFreeTexts(pricing.free);
}

void main();
