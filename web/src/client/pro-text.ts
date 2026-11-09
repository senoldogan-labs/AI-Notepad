// Pro sunulunca sayfa metinleri: sayfa durağandır ve bugünkü (Pro'suz) metinleri gösterir; Pro'lu kalıplar aynı öğenin
// `data-pro-text` / `data-pro-meeting-text` özniteliklerindedir (`proTextAttributes`, src/lib/plans.ts). Herkese açık
// `GET /v1/pricing` Pro'yu sunuyorsa kalıplar sunucunun Pro saatleriyle doldurulup öğenin metni olur; sunmuyorsa ya da
// yanıt alınamazsa metinler olduğu gibi kalır.
import { type RawResponse, parsePricing, send } from "./api";
import { siteLocale } from "../config";
import { type ProTextValues, type TierOffer, proText, proTextValues } from "../lib/plans";

/** `GET /v1/pricing`: kimliksiz, ağ hatası ve 502/503/504'te iki deneme. */
export async function fetchTiers(): Promise<TierOffer[]> {
  const path: string = "/v1/pricing";
  const response: RawResponse = await send({ method: "GET", path, body: null, accessToken: null, attempts: 2 });
  return parsePricing(response, path);
}

/** Pro'lu kalıbı olan her öğenin metnini Pro sunulduğundaki metinle değiştirir. */
export function applyProTexts(values: ProTextValues): void {
  for (const owner of Array.from(document.querySelectorAll<HTMLElement>("[data-pro-text], [data-pro-meeting-text]"))) {
    const text: string | null = proText(
      { always: owner.dataset["proText"] ?? null, meetingLengthDiffers: owner.dataset["proMeetingText"] ?? null },
      values,
    );
    if (text !== null) {
      owner.textContent = text;
    }
  }
}

/**
 * Sunulan katmanlardan sayfa metinlerinin değerleri; Pro sunulmuyorsa null (konsola yazılır). `meetingLength` Pro'nun
 * toplantı süresinin saat/dakika kalıplarıdır (`{count}`).
 */
export function offeredProValues(
  offers: readonly TierOffer[],
  meetingLength: { readonly hours: string; readonly minutes: string },
): ProTextValues | null {
  const values: ProTextValues | null = proTextValues(offers, siteLocale, meetingLength);
  if (values === null) {
    console.info("pricing_pro_not_offered", { tiers: offers.map((offer: TierOffer): string => offer.tier) });
  }
  return values;
}
