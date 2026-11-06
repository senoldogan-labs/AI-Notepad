// Paylaşım sayfası (`/s#<kimlik>.<anahtar>`): anahtarı adresin `#` parçasından okur, şifreli notu sunucudan alır, tarayıcıda
// çözer (src/lib/share-note.ts) ve DOM öğeleriyle çizer. Çözülen metin hiçbir zaman HTML olarak yorumlanmaz
// (`textContent`; innerHTML yok): gönderen notun her metnini belirler. Anahtar ne sunucuya ne konsola yazılır.
import { dataValue, element } from "./dom";
import {
  type ShareFragment,
  type SharedNote,
  ShareDecryptError,
  ShareFormatError,
  ShareLinkError,
  openSharedNote,
  parseShareFragment,
} from "../lib/share-note";
import { siteConfig } from "../site";

/** Sunucunun cevabı: not bulunamadı (süresi dolmuş, kaldırılmış ya da hiç olmamış). */
class ShareGoneError extends Error {
  override readonly name: string = "ShareGoneError";
}

/** Sunucunun cevabı: bu ağdan çok istek geldi. */
class ShareRateLimitedError extends Error {
  override readonly name: string = "ShareRateLimitedError";
}

/** Sunucuya ulaşılamadı ya da beklenmeyen durum döndü. */
class ShareNetworkError extends Error {
  override readonly name: string = "ShareNetworkError";
}

/** Şifreli notu alır. Çerez, Referer ve önbellek kullanılmaz. */
async function fetchSealedNote(shareId: string): Promise<Uint8Array<ArrayBuffer>> {
  let response: Response;
  try {
    response = await fetch(`${siteConfig.apiBase}/v1/public/shares/${shareId}`, {
      method: "GET",
      cache: "no-store",
      credentials: "omit",
      referrerPolicy: "no-referrer",
    });
  } catch (error: unknown) {
    throw new ShareNetworkError(error instanceof Error ? error.message : String(error));
  }
  if (response.status === 404) {
    throw new ShareGoneError("The link expired or was removed.");
  }
  if (response.status === 429) {
    throw new ShareRateLimitedError("Too many requests.");
  }
  if (!response.ok) {
    throw new ShareNetworkError(`Unexpected status ${response.status}.`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

/** Metinli öğe. */
function textElement<K extends keyof HTMLElementTagNameMap>(tag: K, text: string, className: string | null): HTMLElementTagNameMap[K] {
  const node: HTMLElementTagNameMap[K] = document.createElement(tag);
  node.textContent = text;
  if (className !== null) {
    node.className = className;
  }
  return node;
}

/** Başlıklı bölüm. */
function section(heading: string, content: HTMLElement): HTMLElement {
  const node: HTMLElement = document.createElement("section");
  node.append(textElement("h2", heading, null), content);
  return node;
}

/** Madde listesi. */
function bulletList(items: readonly string[]): HTMLElement {
  const list: HTMLUListElement = document.createElement("ul");
  list.append(...items.map((item: string): HTMLElement => textElement("li", item, null)));
  return list;
}

/** Notun bölümleri; boş bölümler atlanır. Saf DOM üretimi (belgeye eklemez). */
function noteSections(note: SharedNote, showTranscript: string): HTMLElement[] {
  const sections: HTMLElement[] = [];
  if (note.summary.length > 0) {
    sections.push(section(note.headings.summary, textElement("p", note.summary, null)));
  }
  if (note.outline.length > 0) {
    const list: HTMLOListElement = document.createElement("ol");
    list.className = "shared__plain";
    for (const item of note.outline) {
      const row: HTMLLIElement = document.createElement("li");
      row.append(textElement("span", item.time, "shared__time"), textElement("strong", item.title, null), document.createTextNode(` — ${item.summary}`));
      list.append(row);
    }
    sections.push(section(note.headings.outline, list));
  }
  if (note.decisions.length > 0) {
    sections.push(section(note.headings.decisions, bulletList(note.decisions)));
  }
  if (note.openQuestions.length > 0) {
    sections.push(section(note.headings.openQuestions, bulletList(note.openQuestions)));
  }
  if (note.tasks.length > 0) {
    const list: HTMLUListElement = document.createElement("ul");
    list.className = "shared__plain";
    for (const task of note.tasks) {
      const row: HTMLLIElement = document.createElement("li");
      row.className = "shared__task";
      row.append(textElement("strong", task.owner, null), textElement("span", task.description, null));
      if (task.due !== null) {
        row.append(textElement("span", task.due, "shared__due"));
      }
      list.append(row);
    }
    sections.push(section(note.headings.tasks, list));
  }
  if (note.glossary.length > 0) {
    const list: HTMLDListElement = document.createElement("dl");
    for (const entry of note.glossary) {
      list.append(textElement("dt", entry.term, null), textElement("dd", entry.meaning, null));
    }
    sections.push(section(note.headings.glossary, list));
  }
  if (note.transcript !== null && note.transcript.length > 0) {
    const details: HTMLDetailsElement = document.createElement("details");
    const body: HTMLDivElement = document.createElement("div");
    body.className = "shared__transcript";
    for (const paragraph of note.transcript) {
      const row: HTMLParagraphElement = document.createElement("p");
      row.append(textElement("span", paragraph.time, "shared__time"), textElement("strong", `${paragraph.speaker}: `, null), document.createTextNode(paragraph.text));
      body.append(row);
    }
    details.append(textElement("summary", showTranscript, null), body);
    sections.push(section(note.headings.transcript, details));
  }
  return sections;
}

/** Hata görünümü. */
interface ErrorView {
  readonly title: string;
  readonly text: string;
  readonly retry: boolean;
}

/** Hatanın görünümü; tanınmayan hata olduğu gibi fırlatılır (yutulmaz). */
function errorView(error: unknown, copy: HTMLElement): ErrorView {
  if (error instanceof ShareLinkError) {
    return { title: dataValue(copy, "incompleteTitle"), text: dataValue(copy, "incomplete"), retry: false };
  }
  if (error instanceof ShareGoneError) {
    return { title: dataValue(copy, "goneTitle"), text: dataValue(copy, "gone"), retry: false };
  }
  if (error instanceof ShareDecryptError) {
    return { title: dataValue(copy, "wrongKeyTitle"), text: dataValue(copy, "wrongKey"), retry: false };
  }
  if (error instanceof ShareFormatError) {
    return { title: dataValue(copy, "unreadableTitle"), text: dataValue(copy, "unreadable"), retry: false };
  }
  if (error instanceof ShareRateLimitedError) {
    return { title: dataValue(copy, "networkTitle"), text: dataValue(copy, "rateLimited"), retry: true };
  }
  if (error instanceof ShareNetworkError) {
    return { title: dataValue(copy, "networkTitle"), text: dataValue(copy, "network"), retry: true };
  }
  throw error;
}

/** Notu çizer. */
function showNote(note: SharedNote, copy: HTMLElement): void {
  const container: HTMLElement = element("share-note", HTMLElement);
  container.lang = note.lang;
  container.dir = note.rtl ? "rtl" : "ltr";
  element("share-title", HTMLElement).textContent = note.title;
  element("share-subtitle", HTMLElement).textContent = note.subtitle;
  element("share-body", HTMLElement).replaceChildren(...noteSections(note, dataValue(copy, "showTranscript")));
  document.title = `${note.title} — ${document.title}`;
  element("share-loading", HTMLElement).classList.add("hidden");
  element("share-error", HTMLElement).classList.add("hidden");
  container.classList.remove("hidden");
}

/** Hatayı gösterir; ayrıntı (anahtarsız) konsola yazılır. */
function showError(error: unknown, copy: HTMLElement): void {
  const view: ErrorView = errorView(error, copy);
  console.warn("share_open_failed", { error: error instanceof Error ? error.name : String(error) });
  element("share-error-title", HTMLElement).textContent = view.title;
  element("share-error-text", HTMLElement).textContent = view.text;
  element("share-retry", HTMLButtonElement).classList.toggle("hidden", !view.retry);
  element("share-loading", HTMLElement).classList.add("hidden");
  element("share-error", HTMLElement).classList.remove("hidden");
}

/** Bağlantıyı okur, notu alır, çözer ve gösterir. */
async function open(copy: HTMLElement): Promise<void> {
  element("share-loading", HTMLElement).classList.remove("hidden");
  element("share-error", HTMLElement).classList.add("hidden");
  try {
    const fragment: ShareFragment = parseShareFragment(window.location.hash);
    showNote(await openSharedNote(await fetchSealedNote(fragment.shareId), fragment), copy);
  } catch (error: unknown) {
    showError(error, copy);
  }
}

function main(): void {
  const copy: HTMLElement = element("share-copy", HTMLElement);
  element("share-retry", HTMLButtonElement).addEventListener("click", (): void => {
    void open(copy);
  });
  // Bağlantı aynı sekmede değişirse (başka paylaşım yapıştırıldı) yeni not açılır.
  window.addEventListener("hashchange", (): void => {
    void open(copy);
  });
  void open(copy);
}

main();
