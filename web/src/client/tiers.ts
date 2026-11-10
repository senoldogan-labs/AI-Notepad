// Satılan katmanlar: herkese açık `GET /v1/pricing`. Fiyat sayfası ve ana sayfa bugünkü tek planı durağan HTML'de
// gösterir; sunucu Pro'yu sunuyorsa Pro'nun metinleri ve çizimi ayrı bir parça olarak yüklenir (`./pro-offer`), böylece
// Pro kapalıyken sayfanın ne HTML'inde ne de betiğinde Pro bulunur.
import { type RawResponse, parsePricing, send } from "./api";
import { type TierOffer, tierOffer } from "../lib/plans";

/** `GET /v1/pricing`: kimliksiz, ağ hatası ve 502/503/504'te iki deneme. */
export async function fetchTiers(): Promise<TierOffer[]> {
  const path: string = "/v1/pricing";
  const response: RawResponse = await send({ method: "GET", path, body: null, accessToken: null, attempts: 2 });
  return parsePricing(response, path);
}

/** Sunucu Pro'yu (ve Personal'i) sunuyor mu; sunmuyorsa konsola yazar. */
export function proOffered(offers: readonly TierOffer[]): boolean {
  const offered: boolean = tierOffer(offers, "pro") !== null && tierOffer(offers, "personal") !== null;
  if (!offered) {
    console.info("pricing_pro_not_offered", { tiers: offers.map((offer: TierOffer): string => offer.tier) });
  }
  return offered;
}
