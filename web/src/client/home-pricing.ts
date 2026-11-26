// Ana sayfanın fiyat bandı: sayfa durağandır ve bugün satılan tek planın giriş ve sınır satırlarını gösterir. Herkese
// açık `GET /v1/pricing` Pro'yu sunuyorsa satırların Pro'lu hâli, ücretsiz planı açtıysa (`free` nesnesi) Personal'in
// önüne ücretsiz plan satırı ayrı parçalardan yüklenip yazılır (`./pro-offer`, `./free-offer`); ikisi de yoksa ya da
// yanıt alınamazsa satırlar değişmez (hata konsola yazılır). Aynı gösterimi kullanan Fince sayfa bunları anlatmaz: bandında
// `data-tier-slot` ve `.price-tag` yoktur ve betik sunucuya hiç sormaz.
import { fetchPricing, proOffered } from "./tiers";
import type { PricingOffer } from "../lib/plans";

/** Bandı başlatır. */
async function main(): Promise<void> {
  if (document.querySelector("#pricing [data-tier-slot]") === null) {
    return;
  }
  let pricing: PricingOffer;
  try {
    pricing = await fetchPricing();
  } catch (error: unknown) {
    console.error("pricing_tiers_load_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  if (proOffered(pricing.tiers)) {
    const { showProOnHome } = await import("./pro-offer");
    showProOnHome(pricing.tiers);
  }
  // Ücretsiz plan sonra yazılır: ana sayfanın "tek plan" cümlesinde ikisi de metin yazarsa ücretsiz planlı olan kalır.
  if (pricing.free !== null) {
    const { showFreeOnHome } = await import("./free-offer");
    showFreeOnHome(pricing.free);
  }
}

void main();
