// Ücretsiz plan açılınca sayfa: bu parça yalnızca sunucu ücretsiz planı açtığında (`GET /v1/pricing` `free` nesnesi)
// dinamik olarak yüklenir (`./pricing`, `./home-pricing`, `./compare-pricing`); ücretsiz planın metinleri
// (src/lib/free-copy.ts) bu yüzden plan kapalıyken tarayıcıya hiç gelmez.
// - `data-free-slot` taşıyan öğelerin metni ücretsiz plan açıkken geçerli kalıpla, sunucunun sayılarıyla yazılır.
// - Fiyat sayfasında Personal kartlarının önüne bir Ücretsiz kartı eklenir (Personal kartının kopyasından, kopya sayfanın
//   kapsamlı stillerini taşır); ana sayfanın fiyat bandında Personal'in önüne kısa bir Ücretsiz bloğu eklenir.
// - Ücretsiz plan bir deneme değildir: kartın düğmesi indirme sayfasına gider, deneme her zaman önce gelir.
import { siteLocale } from "../config";
import { type FreePlanOffer, type FreeTextSlot, freeTextSlotOf } from "../lib/plans";
import { type FreeValues, fillFree, freeCard, freeHome, freeTexts, freeValues } from "../lib/free-copy";
import { routes } from "../routes";

const svgNamespace: "http://www.w3.org/2000/svg" = "http://www.w3.org/2000/svg";

/** `data-free-slot` taşıyan her öğenin metnini ücretsiz plan açıkken geçerli kalıpla değiştirir. */
function applyFreeTexts(values: FreeValues): void {
  for (const owner of Array.from(document.querySelectorAll<HTMLElement>("[data-free-slot]"))) {
    const slot: FreeTextSlot | null = freeTextSlotOf(owner.dataset["freeSlot"]);
    if (slot === null) {
      throw new Error(`Bilinmeyen data-free-slot: ${JSON.stringify(owner.dataset["freeSlot"] ?? null)}`);
    }
    owner.textContent = fillFree(freeTexts[slot], values);
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

/** Onay işareti (karşılaştırma tablosundakiyle aynı çizim); ekran okuyucudan gizli. */
function checkIcon(): SVGSVGElement {
  const svg: SVGSVGElement = document.createElementNS(svgNamespace, "svg");
  svg.setAttribute("width", "18");
  svg.setAttribute("height", "18");
  svg.setAttribute("viewBox", "0 0 18 18");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.classList.add("plan-option__check");
  const circle: SVGCircleElement = document.createElementNS(svgNamespace, "circle");
  circle.setAttribute("cx", "9");
  circle.setAttribute("cy", "9");
  circle.setAttribute("r", "8");
  circle.setAttribute("fill", "none");
  circle.setAttribute("stroke", "currentColor");
  circle.setAttribute("stroke-width", "1.4");
  const path: SVGPathElement = document.createElementNS(svgNamespace, "path");
  path.setAttribute("d", "M5.4 9.2l2.4 2.4 4.8-5");
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.6");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  svg.append(circle, path);
  return svg;
}

/** Özellik listesi: her satır bir onay işareti ve metin. */
function featureList(features: readonly string[]): HTMLUListElement {
  const list: HTMLUListElement = document.createElement("ul");
  list.className = "plan-option__features";
  for (const text of features) {
    const item: HTMLLIElement = document.createElement("li");
    const label: HTMLSpanElement = document.createElement("span");
    label.textContent = text;
    item.append(checkIcon(), label);
    list.append(item);
  }
  return list;
}

/** Küçük, soluk açıklama satırı. */
function note(text: string): HTMLParagraphElement {
  const line: HTMLParagraphElement = document.createElement("p");
  line.className = "plan-option__free-note small muted";
  line.textContent = text;
  return line;
}

/**
 * Personal kartının kopyasından Ücretsiz kartı: başlık, fiyat, ayrıntı ve düğme ücretsiz planınkiyle; rozet ve plan
 * özniteliği yok (Pro kartları yalnızca `data-plan-card` taşıyan Personal kartlarını kopyalar). Kartın sol sütununa
 * başlık, fiyat, ayrıntı ve düğme, sağ sütununa özellikler ve Personal'in eklediği gelir.
 */
function freeCardElement(personalCard: HTMLElement, values: FreeValues): HTMLElement {
  const card: HTMLElement = personalCard.cloneNode(true) as HTMLElement;
  card.classList.remove("plan-option--featured");
  card.classList.add("plan-option--free");
  delete card.dataset["planCard"];
  card.dataset["freeCard"] = "";
  card.setAttribute("aria-labelledby", "plan-free");
  const title: HTMLElement = part(card, ".plan-option__name");
  title.id = "plan-free";
  title.textContent = freeCard.name;
  card.querySelector<HTMLElement>(".plan-option__save")?.remove();
  part(card, ".plan-option__price .tabular").textContent = freeCard.price;
  part(card, ".plan-option__per").textContent = freeCard.per;
  part(card, ".plan-option__price + .small").textContent = freeCard.detail;
  const button: HTMLAnchorElement = part(card, "a.button") as HTMLAnchorElement;
  button.textContent = freeCard.cta;
  button.classList.replace("button--primary", "button--secondary");
  button.href = routes.download;
  const body: HTMLElement = part(card, ".plan-option__body");
  const summary: HTMLDivElement = document.createElement("div");
  summary.className = "plan-option__free-summary";
  summary.append(...Array.from(body.children));
  const details: HTMLDivElement = document.createElement("div");
  details.className = "plan-option__free-details";
  details.append(
    featureList(freeCard.features.map((feature: string): string => fillFree(feature, values))),
    note(freeCard.upgrade),
    note(freeCard.requirements),
  );
  body.append(summary, details);
  return card;
}

/** Fiyat sayfası: Personal kartlarının önüne Ücretsiz kartı, ve ücretsiz plan açıkken geçerli SSS metni. */
export function showFreeOnPricingPage(offer: FreePlanOffer): void {
  const values: FreeValues = freeValues(offer, siteLocale);
  const plans: HTMLElement | null = document.querySelector<HTMLElement>("#plans");
  const source: HTMLElement | null = document.querySelector<HTMLElement>("#plans [data-plan-card]");
  if (plans === null || source === null) {
    throw new Error("Fiyat sayfasında Ücretsiz kartı eklenecek plan kartı yok.");
  }
  plans.prepend(freeCardElement(source, values));
  applyFreeTexts(values);
}

/** Ana sayfanın fiyat bandı: Personal'in önüne kısa Ücretsiz bloğu, ve ücretsiz plan açıkken geçerli SSS metni. */
export function showFreeOnHome(offer: FreePlanOffer): void {
  const values: FreeValues = freeValues(offer, siteLocale);
  const tag: HTMLElement | null = document.querySelector<HTMLElement>("#pricing .price-tag");
  if (tag === null) {
    throw new Error("Ana sayfanın fiyat bandında .price-tag yok.");
  }
  const free: HTMLDivElement = document.createElement("div");
  free.className = "price-tag__free";
  const head: HTMLParagraphElement = document.createElement("p");
  head.className = "price-tag__free-head";
  const name: HTMLSpanElement = document.createElement("span");
  name.textContent = freeHome.name;
  const price: HTMLSpanElement = document.createElement("span");
  price.className = "tabular";
  price.textContent = freeHome.price;
  head.append(name, price);
  const text: HTMLParagraphElement = document.createElement("p");
  text.className = "price-tag__free-text";
  text.textContent = fillFree(freeHome.text, values);
  free.append(head, text);
  const personal: HTMLParagraphElement = document.createElement("p");
  personal.className = "price-tag__free-head price-tag__personal";
  personal.textContent = freeHome.personalName;
  tag.prepend(free, personal);
  applyFreeTexts(values);
}

/** Yalnızca `data-free-slot` metinleri (karşılaştırma sayfaları). */
export function showFreeTexts(offer: FreePlanOffer): void {
  applyFreeTexts(freeValues(offer, siteLocale));
}
