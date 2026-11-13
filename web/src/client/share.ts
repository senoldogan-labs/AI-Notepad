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
import {
  type ShareFailureKind,
  type ShareOutcome,
  type ShareSections,
  type ShareView,
  initialShareView,
  shareDocumentTitle,
  shareFailureRetries,
  shareResponseFailure,
  shareSections,
  shareViewOpening,
  shareViewSettled,
} from "../lib/share-view";
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
  const failure: ShareFailureKind | null = shareResponseFailure(response.status);
  if (failure === "gone") {
    throw new ShareGoneError("The link expired or was removed.");
  }
  if (failure === "rateLimited") {
    throw new ShareRateLimitedError("Too many requests.");
  }
  if (failure !== null) {
    throw new ShareNetworkError(`Unexpected status ${response.status}.`);
  }
  try {
    return new Uint8Array(await response.arrayBuffer());
  } catch (error: unknown) {
    // The connection dropped while the body was read.
    throw new ShareNetworkError(error instanceof Error ? error.message : String(error));
  }
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

/** The failure an error stands for; an error the page does not recognize is `unexpected` (logged by the caller). */
function failureKind(error: unknown): ShareFailureKind {
  if (error instanceof ShareLinkError) {
    return "incomplete";
  }
  if (error instanceof ShareGoneError) {
    return "gone";
  }
  if (error instanceof ShareDecryptError) {
    return "wrongKey";
  }
  if (error instanceof ShareFormatError) {
    return "unreadable";
  }
  if (error instanceof ShareRateLimitedError) {
    return "rateLimited";
  }
  if (error instanceof ShareNetworkError) {
    return "network";
  }
  return "unexpected";
}

/** Title and text of a failure (the page's `data-*` copy). */
function failureCopy(kind: ShareFailureKind, copy: HTMLElement): { readonly title: string; readonly text: string } {
  switch (kind) {
    case "incomplete":
      return { title: dataValue(copy, "incompleteTitle"), text: dataValue(copy, "incomplete") };
    case "gone":
      return { title: dataValue(copy, "goneTitle"), text: dataValue(copy, "gone") };
    case "wrongKey":
      return { title: dataValue(copy, "wrongKeyTitle"), text: dataValue(copy, "wrongKey") };
    case "unreadable":
      return { title: dataValue(copy, "unreadableTitle"), text: dataValue(copy, "unreadable") };
    case "rateLimited":
      return { title: dataValue(copy, "networkTitle"), text: dataValue(copy, "rateLimited") };
    case "network":
      return { title: dataValue(copy, "networkTitle"), text: dataValue(copy, "network") };
    case "unexpected":
      return { title: dataValue(copy, "networkTitle"), text: dataValue(copy, "unexpected") };
  }
}

/** Hatanın görünümü. */
function errorView(kind: ShareFailureKind, copy: HTMLElement): ErrorView {
  return { ...failureCopy(kind, copy), retry: shareFailureRetries(kind) };
}

/** Sayfanın görünümü. */
type PageView = ShareView<SharedNote, ErrorView>;

/** Notun içeriğini yazar (görünürlüğe dokunmaz). */
function fillNote(note: SharedNote, copy: HTMLElement): void {
  const container: HTMLElement = element("share-note", HTMLElement);
  container.lang = note.lang;
  container.dir = note.rtl ? "rtl" : "ltr";
  element("share-title", HTMLElement).textContent = note.title;
  element("share-subtitle", HTMLElement).textContent = note.subtitle;
  element("share-body", HTMLElement).replaceChildren(...noteSections(note, dataValue(copy, "showTranscript")));
}

/** Hata kartını yazar (görünürlüğe dokunmaz). */
function fillError(failure: ErrorView): void {
  element("share-error-title", HTMLElement).textContent = failure.title;
  element("share-error-text", HTMLElement).textContent = failure.text;
  element("share-retry", HTMLButtonElement).classList.toggle("hidden", !failure.retry);
}

/** Görünümü çizer: içerik yazılır, aynı anda yalnızca bir bölüm görünür, belge başlığı sayfa başlığından yeniden kurulur. */
function render(view: PageView, copy: HTMLElement, baseTitle: string): void {
  if (view.kind === "note") {
    fillNote(view.note, copy);
  } else if (view.kind === "error") {
    fillError(view.failure);
  }
  const sections: ShareSections = shareSections(view);
  element("share-loading", HTMLElement).classList.toggle("hidden", !sections.loading);
  element("share-note", HTMLElement).classList.toggle("hidden", !sections.note);
  element("share-error", HTMLElement).classList.toggle("hidden", !sections.error);
  document.title = shareDocumentTitle(view.kind === "note" ? view.note.title : null, baseTitle);
}

/**
 * Bağlantıyı okur, notu alır ve çözer; sonuç hangi açılışa ait olduğuyla döner. Never rejects: every failure, an
 * unrecognized one included, settles as an error view.
 */
async function loadOutcome(request: number, copy: HTMLElement): Promise<ShareOutcome<SharedNote, ErrorView>> {
  try {
    const fragment: ShareFragment = parseShareFragment(window.location.hash);
    const note: SharedNote = await openSharedNote(await fetchSealedNote(fragment.shareId), fragment);
    return { kind: "note", request, note };
  } catch (error: unknown) {
    const kind: ShareFailureKind = failureKind(error);
    // Only the error's name goes to the console (a message could carry part of the link's key); unrecognized errors at
    // error level.
    const detail: { readonly request: number; readonly kind: ShareFailureKind; readonly error: string } = {
      request,
      kind,
      error: error instanceof Error ? error.name : typeof error,
    };
    if (kind === "unexpected") {
      console.error("share_open_failed", detail);
    } else {
      console.warn("share_open_failed", detail);
    }
    return { kind: "error", request, failure: errorView(kind, copy) };
  }
}

/** Bağlantıyı açan fonksiyon: her açılış yeni istek numarası alır, eski açılışın geç gelen sonucu atılır. */
function shareOpener(copy: HTMLElement, baseTitle: string): () => Promise<void> {
  let view: PageView = initialShareView();
  return async (): Promise<void> => {
    view = shareViewOpening(view);
    const request: number = view.request;
    render(view, copy, baseTitle);
    const next: PageView | null = shareViewSettled(view, await loadOutcome(request, copy));
    if (next === null) {
      console.info("share_open_superseded", { request, current: view.request });
      return;
    }
    view = next;
    render(view, copy, baseTitle);
  };
}

function main(): void {
  const copy: HTMLElement = element("share-copy", HTMLElement);
  const open: () => Promise<void> = shareOpener(copy, document.title);
  element("share-retry", HTMLButtonElement).addEventListener("click", (): void => {
    void open();
  });
  // Bağlantı aynı sekmede değişirse (başka paylaşım yapıştırıldı) yeni not açılır; yoldaki eski açılış atılır.
  window.addEventListener("hashchange", (): void => {
    void open();
  });
  void open();
}

main();
