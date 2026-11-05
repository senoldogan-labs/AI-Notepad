import { Base64Error, base64Decode, concatBytes, utf8 } from "../crypto";

/**
 * Encryption of the AI assistant copy (design: docs/superpowers/specs/2026-11-05-remote-mcp.md, "Storage (EU)").
 *
 * Every stored field (the R2 note object, the D1 index) is sealed on its own with AES-256-GCM under a per-user subkey:
 * HKDF-SHA256 over one master key of `ASSISTANT_DATA_KEY` with the user id in `info`. The additional data binds the
 * ciphertext to `user|meeting|field|version`, so a blob copied to another account, meeting or field fails to open.
 *
 * Sealed layout: magic `GSA1` (4 bytes), format version (1 byte), key id (1 byte), 12-byte nonce, ciphertext + 16-byte
 * tag. The key id names the master key, so keys rotate by adding a new one in front of the keyring: new writes use it,
 * old objects still open with theirs until they are rewritten.
 *
 * The server can read this copy (it is encrypted at rest, not end to end); the design and privacy copy say so.
 */

/** Keyring parsed from `ASSISTANT_DATA_KEY`: `"<id>:<base64 of 32 bytes>"` entries separated by commas, newest first. */
export interface AssistantKeyring {
  /** Key id new objects are sealed with (the first entry). */
  readonly currentKeyId: number;
  readonly keys: ReadonlyMap<number, Uint8Array>;
}

/** Fields that are sealed separately (part of the additional data). */
export type SealedField = "note" | "index";

/** The sealed format version written today. */
export const sealedFormatVersion: number = 1;
const magic: Uint8Array = utf8("GSA1");
const headerBytes: number = magic.byteLength + 1 + 1;
const nonceBytes: number = 12;
const tagBytes: number = 16;
const hkdfSalt: Uint8Array = utf8("gistsmith-assistant-v1");

/** `ASSISTANT_DATA_KEY` is missing or malformed; carries no key material. */
export class AssistantKeyringError extends Error {
  override readonly name: string = "AssistantKeyringError";
}

/** A sealed field could not be opened (tampered, other user, meeting or field, unknown key id, wrong format). */
export class AssistantCryptoError extends Error {
  override readonly name: string = "AssistantCryptoError";
}

/** Parses the keyring secret; throws `AssistantKeyringError` naming the problem (never the key). Pure function. */
export function parseAssistantKeyring(secret: string | undefined): AssistantKeyring {
  if (secret === undefined || secret.trim().length === 0) {
    throw new AssistantKeyringError("ASSISTANT_DATA_KEY is not set.");
  }
  const keys: Map<number, Uint8Array> = new Map();
  let currentKeyId: number | null = null;
  for (const entry of secret.split(",")) {
    const match: RegExpExecArray | null = /^\s*(\d{1,3}):([A-Za-z0-9+/=_-]+)\s*$/.exec(entry);
    if (match === null || match[1] === undefined || match[2] === undefined) {
      throw new AssistantKeyringError("ASSISTANT_DATA_KEY entries must look like <id>:<base64 key>.");
    }
    const id: number = Number(match[1]);
    if (id < 1 || id > 255 || keys.has(id)) {
      throw new AssistantKeyringError("ASSISTANT_DATA_KEY key ids must be unique and between 1 and 255.");
    }
    let key: Uint8Array;
    try {
      key = base64Decode(match[2]);
    } catch (error: unknown) {
      if (error instanceof Base64Error) {
        throw new AssistantKeyringError("ASSISTANT_DATA_KEY keys must be base64.");
      }
      throw error;
    }
    if (key.byteLength !== 32) {
      throw new AssistantKeyringError("ASSISTANT_DATA_KEY keys must be 32 bytes.");
    }
    keys.set(id, key);
    currentKeyId ??= id;
  }
  if (currentKeyId === null) {
    throw new AssistantKeyringError("ASSISTANT_DATA_KEY has no key.");
  }
  return { currentKeyId, keys };
}

/** Additional data of a sealed field. Pure function. */
export function sealedAdditionalData(userId: string, meetingId: string, field: SealedField, version: number): Uint8Array {
  return utf8(`${userId}|${meetingId}|${field}|${version}`);
}

/** The user's AES-256-GCM subkey under one master key (HKDF-SHA256, user id in `info`). */
async function userSubkey(masterKey: Uint8Array, userId: string): Promise<CryptoKey> {
  const ikm: CryptoKey = await crypto.subtle.importKey("raw", masterKey, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: hkdfSalt, info: utf8(`user:${userId}`) },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

function masterKeyOf(keyring: AssistantKeyring, keyId: number): Uint8Array {
  const key: Uint8Array | undefined = keyring.keys.get(keyId);
  if (key === undefined) {
    throw new AssistantCryptoError(`No assistant data key with id ${keyId}.`);
  }
  return key;
}

/** Seals one field with the current key and a random nonce. */
export async function sealField(keyring: AssistantKeyring, userId: string, meetingId: string, field: SealedField, plaintext: Uint8Array): Promise<Uint8Array> {
  const keyId: number = keyring.currentKeyId;
  const nonce: Uint8Array = crypto.getRandomValues(new Uint8Array(nonceBytes));
  const key: CryptoKey = await userSubkey(masterKeyOf(keyring, keyId), userId);
  const ciphertext: ArrayBuffer = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: sealedAdditionalData(userId, meetingId, field, sealedFormatVersion) },
    key,
    plaintext,
  );
  return concatBytes([magic, Uint8Array.of(sealedFormatVersion, keyId), nonce, new Uint8Array(ciphertext)]);
}

/** Key id a sealed field names (for rotation reports); `AssistantCryptoError` when it is not a sealed field. Pure function. */
export function sealedKeyId(sealed: Uint8Array): number {
  if (sealed.byteLength < headerBytes + nonceBytes + tagBytes || !magic.every((byte: number, index: number): boolean => sealed[index] === byte)) {
    throw new AssistantCryptoError("Not a sealed assistant field.");
  }
  const keyId: number | undefined = sealed[magic.byteLength + 1];
  if (keyId === undefined) {
    throw new AssistantCryptoError("Not a sealed assistant field.");
  }
  return keyId;
}

/** Opens a sealed field with an already derived subkey (see `openField`). */
async function openWithKey(key: CryptoKey, userId: string, meetingId: string, field: SealedField, sealed: Uint8Array): Promise<Uint8Array> {
  const version: number | undefined = sealed[magic.byteLength];
  if (version !== sealedFormatVersion) {
    throw new AssistantCryptoError("Unknown sealed format version.");
  }
  try {
    const plaintext: ArrayBuffer = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: sealed.subarray(headerBytes, headerBytes + nonceBytes), additionalData: sealedAdditionalData(userId, meetingId, field, version) },
      key,
      sealed.subarray(headerBytes + nonceBytes),
    );
    return new Uint8Array(plaintext);
  } catch (error: unknown) {
    if (error instanceof DOMException && error.name === "OperationError") {
      throw new AssistantCryptoError("The sealed field failed authentication.");
    }
    throw error;
  }
}

/** Opens a sealed field; `AssistantCryptoError` when anything does not match. */
export async function openField(keyring: AssistantKeyring, userId: string, meetingId: string, field: SealedField, sealed: Uint8Array): Promise<Uint8Array> {
  const keyId: number = sealedKeyId(sealed);
  return openWithKey(await userSubkey(masterKeyOf(keyring, keyId), userId), userId, meetingId, field, sealed);
}

/** One sealed field of one meeting. */
export interface SealedMeetingField {
  readonly meetingId: string;
  readonly sealed: Uint8Array;
}

/**
 * Opens many fields of one user, deriving the subkey once per key id (a search opens up to 2,000 indexes). Results are
 * in input order; the first failure rejects.
 */
export async function openUserFields(keyring: AssistantKeyring, userId: string, field: SealedField, items: readonly SealedMeetingField[]): Promise<Uint8Array[]> {
  const keys: Map<number, Promise<CryptoKey>> = new Map();
  return Promise.all(
    items.map(async (item: SealedMeetingField): Promise<Uint8Array> => {
      const keyId: number = sealedKeyId(item.sealed);
      let key: Promise<CryptoKey> | undefined = keys.get(keyId);
      if (key === undefined) {
        key = userSubkey(masterKeyOf(keyring, keyId), userId);
        keys.set(keyId, key);
      }
      return openWithKey(await key, userId, item.meetingId, field, item.sealed);
    }),
  );
}
