// Ana sayfanın fiyat bandı: sayfa durağandır ve bugünkü (Pro'suz) giriş ve sınır satırlarını gösterir. Herkese açık
// `GET /v1/pricing` Pro'yu sunuyorsa satırların Pro'lu kalıpları sunucunun Pro saatleriyle yazılır (`./pro-text`);
// sunmuyorsa ya da yanıt alınamazsa satırlar değişmez (hata konsola yazılır). Aynı gösterimi kullanan Fince sayfa Pro'yu
// anlatmaz: bandında Pro'lu kalıp yoktur ve betik sunucuya hiç sormaz.
import { dataValue, element } from "./dom";
import { applyProTexts, fetchTiers, offeredProValues } from "./pro-text";
import type { ProTextValues, TierOffer } from "../lib/plans";

/** Bandı başlatır. */
async function main(): Promise<void> {
  const band: HTMLElement = element("pricing", HTMLElement);
  if (band.querySelector("[data-pro-text], [data-pro-meeting-text]") === null) {
    return;
  }
  const meetingLength: { readonly hours: string; readonly minutes: string } = {
    hours: dataValue(band, "meetingHours"),
    minutes: dataValue(band, "meetingMinutes"),
  };
  let offers: TierOffer[];
  try {
    offers = await fetchTiers();
  } catch (error: unknown) {
    console.error("pricing_tiers_load_failed", { error: error instanceof Error ? error.message : String(error) });
    return;
  }
  const values: ProTextValues | null = offeredProValues(offers, meetingLength);
  if (values !== null) {
    applyProTexts(values);
  }
}

void main();
