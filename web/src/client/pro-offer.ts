// Pro sunulunca sayfa: bu parça yalnızca sunucu Pro'yu sunduğunda dinamik olarak yüklenir (`./pricing`, `./home-pricing`);
// Pro'nun metinleri ve fiyatları (src/lib/pro-copy.ts) bu yüzden Pro kapalıyken tarayıcıya hiç gelmez.
// - `data-tier-slot` taşıyan öğelerin metni Pro'lu kalıpla, sunucunun Pro saatleriyle yazılır.
// - Fiyat sayfasında Personal kartlarının üstüne katman satırı eklenir ve her planın Personal kartının kopyasından bir Pro
//   kartı yapılır (kopya, sayfanın kapsamlı stillerini taşır); Pro düğmeleri `/account?plan=…&tier=pro&checkout=1`'e gider.
import { siteLocale } from "../config";
import type { PlanOptionCopy } from "../copy";
import {
  type PricingTierLines,
  type ProTextValues,
  type TierLimitsTemplates,
  type TierOffer,
  type TierTextSlot,
  billingPlanOf,
  proText,
  pricingTierLines,
  proTextValues,
  tierTextSlotOf,
} from "../lib/plans";
import { proTier, proTexts } from "../lib/pro-copy";

/** Katman satırının kalıpları (Pro'nun metinlerinden). */
const limitsTemplates: TierLimitsTemplates = { limits: proTier.limits, meetingLength: proTier.meetingLength };

/** Sunulan katmanlardan Pro'lu kalıpların değerleri; Pro ya da Personal sunulmuyorsa hata (çağıran önce denetler). */
function offeredValues(offers: readonly TierOffer[]): ProTextValues {
  const values: ProTextValues | null = proTextValues(offers, siteLocale, proTier.meetingLength);
  if (values === null) {
    throw new Error(`Pro metinleri yazılamadı: sunucu Pro'yu ve Personal'i birlikte sunmuyor (${offers.map((offer: TierOffer): string => offer.tier).join(", ")}).`);
  }
  return values;
}

/** `data-tier-slot` taşıyan her öğenin metnini Pro'lu kalıpla değiştirir (kalıbın koşulu tutmuyorsa metin kalır). */
function applyProTexts(values: ProTextValues): void {
  for (const owner of Array.from(document.querySelectorAll<HTMLElement>("[data-tier-slot]"))) {
    const slot: TierTextSlot | null = tierTextSlotOf(owner.dataset["tierSlot"]);
    if (slot === null) {
      throw new Error(`Bilinmeyen data-tier-slot: ${JSON.stringify(owner.dataset["tierSlot"] ?? null)}`);
    }
    const text: string | null = proText(proTexts[slot], values);
    if (text !== null) {
      owner.textContent = text;
    }
  }
}

/** Kartın içindeki öğe (sınıfıyla); yoksa hata. */
function part(card: HTMLElement, selector: string): HTMLElement {
  const found: HTMLElement | null = card.querySelector<HTMLElement>(selector);
  if (found === null) {
    throw new Error(`Plan kartında ${selector} yok (${card.dataset["planCard"] ?? "?"}).`);
  }
  return found;
}

/** Katman satırı: katmanın adı ve saatleri. */
function tierLine(name: string, hours: string): HTMLParagraphElement {
  const line: HTMLParagraphElement = document.createElement("p");
  line.className = "plan-option__tier small";
  const label: HTMLSpanElement = document.createElement("span");
  label.className = "plan-option__tier-name";
  label.textContent = name;
  const value: HTMLSpanElement = document.createElement("span");
  value.textContent = hours;
  line.append(label, value);
  return line;
}

/** Personal kartının kopyasından Pro kartı: başlık, rozet, fiyat, ayrıntı ve düğme Pro'nunkiyle. */
function proCard(personalCard: HTMLElement, option: PlanOptionCopy, hours: string): HTMLElement {
  const card: HTMLElement = personalCard.cloneNode(true) as HTMLElement;
  card.classList.remove("plan-option--featured");
  card.dataset["planCard"] = `pro-${option.plan}`;
  const titleId: string = `plan-pro-${option.plan}`;
  card.setAttribute("aria-labelledby", titleId);
  const title: HTMLElement = part(card, ".plan-option__name");
  title.id = titleId;
  title.textContent = option.name;
  const badge: HTMLElement | null = card.querySelector<HTMLElement>(".plan-option__save");
  if (option.badge === null) {
    badge?.remove();
  } else if (badge === null) {
    throw new Error(`Pro ${option.plan} kartının rozeti var ama Personal kartında rozet yeri yok.`);
  } else {
    badge.textContent = option.badge;
  }
  part(card, ".plan-option__price .tabular").textContent = option.price;
  part(card, ".plan-option__per").textContent = option.per;
  part(card, ".plan-option__price + .small").textContent = option.detail;
  const button: HTMLAnchorElement = part(card, "a.button") as HTMLAnchorElement;
  button.textContent = option.cta;
  button.classList.replace("button--primary", "button--secondary");
  const href: URL = new URL(button.href);
  href.searchParams.set("tier", "pro");
  button.href = `${href.pathname}${href.search}`;
  part(card, ".plan-option__body").prepend(tierLine(proTier.name, hours));
  return card;
}

/** Fiyat sayfası: katman satırları, Pro kartları ve Pro'lu sınır ve SSS metinleri. */
export function showProOnPricingPage(offers: readonly TierOffer[]): void {
  const lines: PricingTierLines | null = pricingTierLines(offers, siteLocale, limitsTemplates);
  if (lines === null) {
    throw new Error("Fiyat sayfasında Pro gösterilemedi: sunucu Pro'yu ve Personal'i birlikte sunmuyor.");
  }
  const values: ProTextValues = offeredValues(offers);
  const cards: HTMLElement[] = Array.from(document.querySelectorAll<HTMLElement>("#plans [data-plan-card]"));
  const proCards: HTMLElement[] = proTier.plans.map((option: PlanOptionCopy): HTMLElement => {
    const source: HTMLElement | undefined = cards.find((card: HTMLElement): boolean => billingPlanOf(card.dataset["planCard"] ?? null) === option.plan);
    if (source === undefined) {
      throw new Error(`Fiyat sayfasında "${option.plan}" planının kartı yok.`);
    }
    return proCard(source, option, lines.pro);
  });
  for (const card of cards) {
    part(card, ".plan-option__body").prepend(tierLine(proTier.personalName, lines.personal));
  }
  const last: HTMLElement | undefined = cards.at(-1);
  if (last === undefined) {
    throw new Error("Fiyat sayfasında plan kartı yok.");
  }
  last.after(...proCards);
  applyProTexts(values);
}

/** Ana sayfanın fiyat bandı: giriş ve sınır satırlarının Pro'lu hâli. */
export function showProOnHome(offers: readonly TierOffer[]): void {
  applyProTexts(offeredValues(offers));
}
