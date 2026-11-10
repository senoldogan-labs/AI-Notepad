// Ana sayfanın fiyat bandı: sayfa durağandır ve bugün satılan tek planın giriş ve sınır satırlarını gösterir. Herkese
// açık `GET /v1/pricing` Pro'yu sunuyorsa satırların Pro'lu hâli ayrı bir parçadan yüklenip yazılır (`./pro-offer`);
// sunmuyorsa ya da yanıt alınamazsa satırlar değişmez (hata konsola yazılır). Aynı gösterimi kullanan Fince sayfa Pro'yu
// anlatmaz: bandında `data-tier-slot` yoktur ve betik sunucuya hiç sormaz.
import { fetchTiers, proOffered } from "./tiers";
import type { TierOffer } from "../lib/plans";

/** Bandı başlatır. */
async function main(): Promise<void> {
  if (document.querySelector("#pricing [data-tier-slot]") === null) {
    return;
  }
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
  const { showProOnHome } = await import("./pro-offer");
  showProOnHome(offers);
}

void main();
