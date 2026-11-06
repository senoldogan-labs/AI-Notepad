// Paylaşım sayfasının şifre çözümü (src/lib/share-note.ts) uygulamanın Swift biçimiyle uyuşuyor mu: Swift testinin
// yazdığı ortak vektörü (Packages/AINotepadCore/Tests/AINotepadCoreTests/Fixtures/NoteShareVector.json,
// `NoteShareVectorTests`) bu kodla açar; yanlış anahtar, başka kimlik, bozuk blok, biçimsiz bağlantı ve şema dışı
// alanlar reddedilir, sıkıştırma bombası sınırda kesilir. Derleme gerektirmez (`npm test` derlemeden sonra da çalıştırır).
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { deflateRawSync } from "node:zlib";
import {
  type ShareFragment,
  type SharedNote,
  ShareDecryptError,
  ShareFormatError,
  ShareLinkError,
  openSharedNote,
  parseShareFragment,
  parseSharedNote,
  sharedNoteMaxJsonBytes,
} from "../src/lib/share-note.ts";

interface Vector {
  readonly shareId: string;
  readonly key: string;
  readonly link: string;
  readonly blobBase64: string;
  readonly payload: SharedNote;
}

const vectorUrl: URL = new URL("../../Packages/AINotepadCore/Tests/AINotepadCoreTests/Fixtures/NoteShareVector.json", import.meta.url);
const vector: Vector = JSON.parse(await readFile(vectorUrl, "utf8")) as Vector;
const blob: Uint8Array<ArrayBuffer> = Uint8Array.from(Buffer.from(vector.blobBase64, "base64"));
const fragment: ShareFragment = parseShareFragment(new URL(vector.link).hash);

/** Swift'in yazmadığı (nil) alanlar web tarafında null'dır. */
function normalized(payload: SharedNote): SharedNote {
  return {
    ...payload,
    tasks: payload.tasks.map((task) => ({ ...task, due: task.due ?? null })),
    transcript: payload.transcript ?? null,
  };
}

/** Bağlantının anahtarıyla, verilen JSON'u Swift'in biçiminde mühürler (Node WebCrypto + zlib). */
async function seal(json: Uint8Array, shareId: string, key: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
  const cryptoKey: CryptoKey = await crypto.subtle.importKey("raw", key, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv: Uint8Array<ArrayBuffer> = crypto.getRandomValues(new Uint8Array(12));
  const sealed: ArrayBuffer = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(`GSS1${shareId}`) },
    cryptoKey,
    new Uint8Array(deflateRawSync(json)),
  );
  return Uint8Array.from([...new TextEncoder().encode("GSS1"), ...iv, ...new Uint8Array(sealed)]);
}

test("the Swift test vector opens to its payload", async () => {
  assert.equal(fragment.shareId, vector.shareId);
  assert.deepEqual(await openSharedNote(blob, fragment), normalized(vector.payload));
});

test("a wrong key, another share id or a changed byte does not open", async () => {
  const otherKey: ShareFragment = { shareId: fragment.shareId, key: crypto.getRandomValues(new Uint8Array(32)) };
  await assert.rejects(openSharedNote(blob, otherKey), ShareDecryptError);
  await assert.rejects(openSharedNote(blob, { shareId: "BBBBBBBBBBBBBBBBBBBBBB", key: fragment.key }), ShareDecryptError);
  const flipped: Uint8Array<ArrayBuffer> = blob.slice();
  flipped[flipped.length - 20] = (flipped[flipped.length - 20] ?? 0) ^ 1;
  await assert.rejects(openSharedNote(flipped, fragment), ShareDecryptError);
  await assert.rejects(openSharedNote(new TextEncoder().encode("GSY1-not-a-share-blob-000000000000"), fragment), ShareFormatError);
});

test("incomplete or malformed links are refused before any request", () => {
  for (const hash of ["", "#", "#abc", `#${vector.shareId}`, `#${vector.shareId}.`, `#${vector.shareId}.${vector.key}.x`, `#${vector.shareId}.${vector.key.slice(1)}`]) {
    assert.throws(() => parseShareFragment(hash), ShareLinkError, hash);
  }
});

test("unknown fields, wrong types and unknown versions are refused", async () => {
  const base: SharedNote = normalized(vector.payload);
  assert.throws(() => parseSharedNote({ ...base, html: "<b>x</b>" }), ShareFormatError);
  assert.throws(() => parseSharedNote({ ...base, v: 2 }), ShareFormatError);
  assert.throws(() => parseSharedNote({ ...base, title: 5 }), ShareFormatError);
  assert.throws(() => parseSharedNote({ ...base, lang: "en\" onload=\"x" }), ShareFormatError);
  assert.throws(() => parseSharedNote({ ...base, tasks: [{ owner: "a", description: "b", due: 3 }] }), ShareFormatError);
  const sealed: Uint8Array<ArrayBuffer> = await seal(new TextEncoder().encode(JSON.stringify({ ...base, v: 2 })), fragment.shareId, fragment.key);
  await assert.rejects(openSharedNote(sealed, fragment), ShareFormatError);
});

test("a decompression bomb is cut at the size cap", async () => {
  const bomb: Uint8Array = new Uint8Array(sharedNoteMaxJsonBytes + 1024).fill(0x20);
  const sealed: Uint8Array<ArrayBuffer> = await seal(bomb, fragment.shareId, fragment.key);
  assert.ok(sealed.byteLength < 64 * 1024, `bomb blob is ${sealed.byteLength} bytes`);
  await assert.rejects(openSharedNote(sealed, fragment), ShareFormatError);
});
