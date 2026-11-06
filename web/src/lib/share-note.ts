// Bağlantıyla paylaşılan notun açılması (paylaşım sayfası `/s`, src/client/share.ts). Uygulama notu JSON'a yazar, ham
// DEFLATE ile sıkıştırır ve paylaşıma özgü rastgele anahtarla AES-256-GCM ile şifreler (Swift `sealNoteShare`); sunucu
// yalnızca şifreli bloğu saklar. Anahtar bağlantının `#` parçasındadır ve tarayıcıdan hiç çıkmaz. Biçim: `GSS1` ‖ nonce
// (12) ‖ şifreli metin ‖ etiket (16); ek doğrulama verisi `GSS1` + paylaşım kimliği. Bu dosya tarayıcıya ve Node'a özgü
// hiçbir şey kullanmaz (WebCrypto ve DecompressionStream ikisinde de var); Swift'in yazdığı ortak test vektörünü
// scripts/share-note.test.ts açar.

/** Bağlantının `#` parçası eksik ya da biçimsiz. */
export class ShareLinkError extends Error {
  override readonly name: string = "ShareLinkError";
}

/** Blok bu anahtarla açılmadı: yanlış ya da kesilmiş anahtar, değişmiş blok. */
export class ShareDecryptError extends Error {
  override readonly name: string = "ShareDecryptError";
}

/** Açılan not beklenen biçimde değil (bilinmeyen sürüm, bozuk JSON, sınırı aşan boyut). */
export class ShareFormatError extends Error {
  override readonly name: string = "ShareFormatError";
}

/** Bağlantıdaki paylaşım kimliği ve anahtar. */
export interface ShareFragment {
  readonly shareId: string;
  readonly key: Uint8Array<ArrayBuffer>;
}

/** Konu akışında bir bölüm. */
export interface SharedOutlineItem {
  readonly time: string;
  readonly title: string;
  readonly summary: string;
}

/** Bir görev. */
export interface SharedTask {
  readonly owner: string;
  readonly description: string;
  readonly due: string | null;
}

/** Sözlükte bir terim. */
export interface SharedGlossaryEntry {
  readonly term: string;
  readonly meaning: string;
}

/** Transkriptte bir paragraf. */
export interface SharedTranscriptParagraph {
  readonly time: string;
  readonly speaker: string;
  readonly text: string;
}

/** Bölüm başlıkları (gönderenin dilinde). */
export interface SharedNoteHeadings {
  readonly summary: string;
  readonly outline: string;
  readonly decisions: string;
  readonly openQuestions: string;
  readonly tasks: string;
  readonly glossary: string;
  readonly transcript: string;
}

/** Paylaşılan not (sürüm 1; Swift `SharedNotePayload`). */
export interface SharedNote {
  readonly v: 1;
  readonly lang: string;
  readonly rtl: boolean;
  readonly title: string;
  readonly subtitle: string;
  readonly headings: SharedNoteHeadings;
  readonly summary: string;
  readonly outline: readonly SharedOutlineItem[];
  readonly decisions: readonly string[];
  readonly openQuestions: readonly string[];
  readonly tasks: readonly SharedTask[];
  readonly glossary: readonly SharedGlossaryEntry[];
  readonly transcript: readonly SharedTranscriptParagraph[] | null;
}

const magic: string = "GSS1";
const nonceBytes: number = 12;
const tagBytes: number = 16;
/**
 * Açılmış JSON'un üst sınırı. Sunucu en çok 1 MiB şifreli blok saklar; ham DEFLATE ~1000 kat açılabildiği için açma
 * akış hâlinde sayılarak kesilir (sıkıştırma bombası sekmeyi dondurmasın). 4 saatlik transkriptli not ~4 MB'tır.
 */
export const sharedNoteMaxJsonBytes: number = 8 * 1024 * 1024;
/** Tek bir metnin ve bir listenin üst sınırı (biçim denetimi; gerçek notlar çok altındadır). */
const maxTextChars: number = 200_000;
const maxItems: number = 20_000;
const shareIdPattern: RegExp = /^[A-Za-z0-9_-]{22}$/;
const keyPattern: RegExp = /^[A-Za-z0-9_-]{43}$/;
const languagePattern: RegExp = /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;

/** Dolgusuz base64url'i baytlara çevirir. Saf fonksiyondur. */
function base64UrlBytes(text: string): Uint8Array<ArrayBuffer> {
  const standard: string = text.replaceAll("-", "+").replaceAll("_", "/");
  const binary: string = atob(standard + "=".repeat((4 - (standard.length % 4)) % 4));
  return Uint8Array.from(binary, (char: string): number => char.charCodeAt(0));
}

/** `#<kimlik>.<anahtar>` parçasını okur (başındaki `#` olabilir); biçim tutmazsa `ShareLinkError`. Saf fonksiyondur. */
export function parseShareFragment(hash: string): ShareFragment {
  const fragment: string = hash.startsWith("#") ? hash.slice(1) : hash;
  const parts: readonly string[] = fragment.split(".");
  const shareId: string | undefined = parts[0];
  const key: string | undefined = parts[1];
  if (parts.length !== 2 || shareId === undefined || key === undefined || !shareIdPattern.test(shareId) || !keyPattern.test(key)) {
    throw new ShareLinkError("The link's fragment is not <shareId>.<key>.");
  }
  return { shareId, key: base64UrlBytes(key) };
}

/** Şifreli bloğu çözer: sıkıştırılmış JSON. Biçim işareti yoksa `ShareFormatError`, açılmazsa `ShareDecryptError`. */
async function decryptShareBlob(blob: Uint8Array<ArrayBuffer>, fragment: ShareFragment): Promise<Uint8Array<ArrayBuffer>> {
  const header: Uint8Array<ArrayBuffer> = new TextEncoder().encode(magic);
  if (blob.byteLength < header.byteLength + nonceBytes + tagBytes || !header.every((byte: number, index: number): boolean => blob[index] === byte)) {
    throw new ShareFormatError("The stored note is not a GSS1 blob.");
  }
  const key: CryptoKey = await crypto.subtle.importKey("raw", fragment.key, { name: "AES-GCM" }, false, ["decrypt"]);
  const iv: Uint8Array<ArrayBuffer> = blob.slice(header.byteLength, header.byteLength + nonceBytes);
  const sealed: Uint8Array<ArrayBuffer> = blob.slice(header.byteLength + nonceBytes);
  try {
    const plain: ArrayBuffer = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(magic + fragment.shareId), tagLength: tagBytes * 8 },
      key,
      sealed,
    );
    return new Uint8Array(plain);
  } catch (error: unknown) {
    throw new ShareDecryptError(`AES-GCM rejected the note: ${error instanceof Error ? error.name : String(error)}`);
  }
}

/** Ham DEFLATE'i en çok `maxBytes` bayta açar; sınır aşılınca akış kesilir ve `ShareFormatError`. */
async function inflateRaw(compressed: Uint8Array<ArrayBuffer>, maxBytes: number): Promise<Uint8Array<ArrayBuffer>> {
  const reader: ReadableStreamDefaultReader<Uint8Array<ArrayBuffer>> = new Blob([compressed]).stream().pipeThrough(new DecompressionStream("deflate-raw")).getReader();
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let total: number = 0;
  for (;;) {
    let next: ReadableStreamReadResult<Uint8Array<ArrayBuffer>>;
    try {
      next = await reader.read();
    } catch (error: unknown) {
      throw new ShareFormatError(`The note does not decompress: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (next.done) {
      break;
    }
    total += next.value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new ShareFormatError(`The note is larger than ${maxBytes} bytes.`);
    }
    chunks.push(next.value);
  }
  const result: Uint8Array<ArrayBuffer> = new Uint8Array(total);
  let offset: number = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

/** JSON nesnesi (diziler hariç). */
type JsonObject = { readonly [key: string]: unknown };

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Nesnenin yalnızca izinli anahtarları taşıdığını denetler. */
function requireKeys(value: JsonObject, allowed: readonly string[], where: string): void {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      throw new ShareFormatError(`Unknown field ${where}.${key}.`);
    }
  }
}

function text(value: unknown, where: string): string {
  if (typeof value !== "string" || value.length > maxTextChars) {
    throw new ShareFormatError(`${where} must be a string of at most ${maxTextChars} characters.`);
  }
  return value;
}

function optionalText(value: unknown, where: string): string | null {
  return value === undefined || value === null ? null : text(value, where);
}

function list<T>(value: unknown, where: string, item: (entry: unknown, at: string) => T): readonly T[] {
  if (!Array.isArray(value) || value.length > maxItems) {
    throw new ShareFormatError(`${where} must be a list of at most ${maxItems} items.`);
  }
  return value.map((entry: unknown, index: number): T => item(entry, `${where}[${index}]`));
}

function object(value: unknown, where: string, allowed: readonly string[]): JsonObject {
  if (!isObject(value)) {
    throw new ShareFormatError(`${where} must be an object.`);
  }
  requireKeys(value, allowed, where);
  return value;
}

/**
 * Açılmış JSON'u sıkı biçimde doğrular: bilinmeyen alan, yanlış tür, sınırı aşan metin ya da liste ve tanınmayan sürüm
 * `ShareFormatError`. Swift `nil` alanları yazmaz (`due`, `transcript`); yoksa null sayılır. Saf fonksiyondur.
 */
export function parseSharedNote(raw: unknown): SharedNote {
  const root: JsonObject = object(raw, "note", [
    "v",
    "lang",
    "rtl",
    "title",
    "subtitle",
    "headings",
    "summary",
    "outline",
    "decisions",
    "openQuestions",
    "tasks",
    "glossary",
    "transcript",
  ]);
  if (root["v"] !== 1) {
    throw new ShareFormatError(`Unsupported note version ${String(root["v"])}.`);
  }
  const lang: string = text(root["lang"], "lang");
  if (!languagePattern.test(lang)) {
    throw new ShareFormatError("lang is not a language tag.");
  }
  if (typeof root["rtl"] !== "boolean") {
    throw new ShareFormatError("rtl must be a boolean.");
  }
  const headings: JsonObject = object(root["headings"], "headings", ["summary", "outline", "decisions", "openQuestions", "tasks", "glossary", "transcript"]);
  const transcript: unknown = root["transcript"];
  return {
    v: 1,
    lang,
    rtl: root["rtl"],
    title: text(root["title"], "title"),
    subtitle: text(root["subtitle"], "subtitle"),
    headings: {
      summary: text(headings["summary"], "headings.summary"),
      outline: text(headings["outline"], "headings.outline"),
      decisions: text(headings["decisions"], "headings.decisions"),
      openQuestions: text(headings["openQuestions"], "headings.openQuestions"),
      tasks: text(headings["tasks"], "headings.tasks"),
      glossary: text(headings["glossary"], "headings.glossary"),
      transcript: text(headings["transcript"], "headings.transcript"),
    },
    summary: text(root["summary"], "summary"),
    outline: list(root["outline"], "outline", (entry: unknown, at: string): SharedOutlineItem => {
      const item: JsonObject = object(entry, at, ["time", "title", "summary"]);
      return { time: text(item["time"], `${at}.time`), title: text(item["title"], `${at}.title`), summary: text(item["summary"], `${at}.summary`) };
    }),
    decisions: list(root["decisions"], "decisions", text),
    openQuestions: list(root["openQuestions"], "openQuestions", text),
    tasks: list(root["tasks"], "tasks", (entry: unknown, at: string): SharedTask => {
      const item: JsonObject = object(entry, at, ["owner", "description", "due"]);
      return { owner: text(item["owner"], `${at}.owner`), description: text(item["description"], `${at}.description`), due: optionalText(item["due"], `${at}.due`) };
    }),
    glossary: list(root["glossary"], "glossary", (entry: unknown, at: string): SharedGlossaryEntry => {
      const item: JsonObject = object(entry, at, ["term", "meaning"]);
      return { term: text(item["term"], `${at}.term`), meaning: text(item["meaning"], `${at}.meaning`) };
    }),
    transcript:
      transcript === undefined || transcript === null
        ? null
        : list(transcript, "transcript", (entry: unknown, at: string): SharedTranscriptParagraph => {
            const item: JsonObject = object(entry, at, ["time", "speaker", "text"]);
            return { time: text(item["time"], `${at}.time`), speaker: text(item["speaker"], `${at}.speaker`), text: text(item["text"], `${at}.text`) };
          }),
  };
}

/** Şifreli bloğu bağlantının anahtarıyla açar, sınırlı açar ve doğrular. */
export async function openSharedNote(blob: Uint8Array<ArrayBuffer>, fragment: ShareFragment): Promise<SharedNote> {
  const compressed: Uint8Array<ArrayBuffer> = await decryptShareBlob(blob, fragment);
  const json: Uint8Array<ArrayBuffer> = await inflateRaw(compressed, sharedNoteMaxJsonBytes);
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(json));
  } catch (error: unknown) {
    throw new ShareFormatError(`The note is not UTF-8 JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  return parseSharedNote(raw);
}
