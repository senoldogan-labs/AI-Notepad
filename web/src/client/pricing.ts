// Fiyat sayfası: sayfa durağandır ve bugün satılan tek planı gösterir (betik olmadan da tamdır). Betik herkese açık
// `GET /v1/pricing`'i okur; sunucu Pro'yu sunuyorsa (üretimde `PRO_TIER_POLICY` açıkken) Pro'nun metinlerini ve çizimini
// ayrı bir parça olarak yükler (`./pro-offer`). Sunucu Pro'yu sunmuyorsa ya da yanıt alınamazsa sayfa değişmez (hata
// konsola yazılır).
import { fetchTiers, proOffered } from "./tiers";
import type { TierOffer } from "../lib/plans";

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  let offers: TierOffer[];
  try {
    offers = await fetchTiers();
  } catch (error: unknown) {
    console.error("pricing_tiers_load_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  if (!proOffered(offers)) {
    return;
  }
  const { showProOnPricingPage } = await import("./pro-offer");
  showProOnPricingPage(offers);
}

void main();
