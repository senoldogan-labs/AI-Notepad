// Paylaşım sayfasının görünüm durumu (saf; DOM src/client/share.ts'te). Her açılış yeni bir istek numarası alır; yanıt
// yalnızca hâlâ en son açılışa aitse uygulanır (A yüklenirken B bağlantısı açıldıysa geç gelen A atılır). Görünürlük
// tek yerden türetilir: aynı anda yalnızca yükleniyor, not ya da hata bölümü görünür.

/** Paylaşım sayfasının görünümü. `Note` notun, `Failure` hata görünümünün tipidir. */
export type ShareView<Note, Failure> =
  | { readonly kind: "loading"; readonly request: number }
  | { readonly kind: "note"; readonly request: number; readonly note: Note }
  | { readonly kind: "error"; readonly request: number; readonly failure: Failure };

/** Açılışın sonucu: hangi isteğe ait olduğu ve not ya da hata. */
export type ShareOutcome<Note, Failure> =
  | { readonly kind: "note"; readonly request: number; readonly note: Note }
  | { readonly kind: "error"; readonly request: number; readonly failure: Failure };

/** Bölümlerin görünürlüğü. */
export interface ShareSections {
  readonly loading: boolean;
  readonly note: boolean;
  readonly error: boolean;
}

/** Sayfa açılmadan önceki durum (henüz istek yok). Saf fonksiyondur. */
export function initialShareView<Note, Failure>(): ShareView<Note, Failure> {
  return { kind: "loading", request: 0 };
}

/** Yeni açılış: istek numarası bir artar, sayfa "yükleniyor"a geçer. Saf fonksiyondur. */
export function shareViewOpening<Note, Failure>(current: ShareView<Note, Failure>): ShareView<Note, Failure> {
  return { kind: "loading", request: current.request + 1 };
}

/** Sonucu uygular; sonuç eski bir isteğe aitse ya da bu istek zaten sonuçlandıysa null (atılır). Saf fonksiyondur. */
export function shareViewSettled<Note, Failure>(current: ShareView<Note, Failure>, outcome: ShareOutcome<Note, Failure>): ShareView<Note, Failure> | null {
  if (current.kind !== "loading" || current.request !== outcome.request) {
    return null;
  }
  return outcome;
}

/** Görünümde hangi bölümler görünür. Saf fonksiyondur. */
export function shareSections<Note, Failure>(view: ShareView<Note, Failure>): ShareSections {
  return { loading: view.kind === "loading", note: view.kind === "note", error: view.kind === "error" };
}

/**
 * Why a share could not be opened. Every failure is a final state with its own copy: `unexpected` covers errors the page
 * does not recognize (a bug, an unexpected exception while decrypting), so the page never stays on "loading".
 */
export type ShareFailureKind = "incomplete" | "gone" | "wrongKey" | "unreadable" | "rateLimited" | "network" | "unexpected";

/**
 * Whether trying again can help: the link and the stored note do not change on retry, the network and the server can,
 * and an unexpected error may be transient. Pure.
 */
export function shareFailureRetries(kind: ShareFailureKind): boolean {
  switch (kind) {
    case "incomplete":
    case "gone":
    case "wrongKey":
    case "unreadable":
      return false;
    case "rateLimited":
    case "network":
    case "unexpected":
      return true;
  }
}

/**
 * The failure a response to `GET /v1/public/shares/:id` stands for, or `null` when the body holds the sealed note. The
 * server answers 404 alike for unknown, expired and removed links (`gone`); any other unsuccessful status is a server or
 * proxy problem (`network`), never `gone`. A wrong key is decided only after the body arrives (`wrongKey`). Pure.
 */
export function shareResponseFailure(status: number): ShareFailureKind | null {
  if (status === 404) {
    return "gone";
  }
  if (status === 429) {
    return "rateLimited";
  }
  return status >= 200 && status <= 299 ? null : "network";
}

/** Belge başlığı: notta "<not başlığı> — <sayfa başlığı>", değilse yalnızca sayfa başlığı. Saf fonksiyondur. */
export function shareDocumentTitle(noteTitle: string | null, baseTitle: string): string {
  return noteTitle === null ? baseTitle : `${noteTitle} — ${baseTitle}`;
}
