import { base64UrlEncode, constantTimeEqualText, hexEncode, utf8 } from "../crypto";

/**
 * Keys derived from `TRIAL_HASH_SECRET` (no new secret binding; see the 128-binding limit in `wranglerConfig.test.ts`),
 * each under its own label so the email keys never produce a trial ledger hash or each other's values:
 * - the unsubscribe key signs a subscription's random `id` (links in every lifecycle email);
 * - the limits key turns an address or an account id into the opaque key of `email_recipient_limits`.
 */
const unsubscribeKeyLabel: string = "gistsmith/email-unsubscribe-key/v1";
const limitsKeyLabel: string = "gistsmith/email-limits-key/v1";

async function hmacBytes(key: Uint8Array, message: string): Promise<Uint8Array> {
  const cryptoKey: CryptoKey = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, utf8(message)));
}

async function derivedKey(secret: string, label: string): Promise<Uint8Array> {
  return hmacBytes(utf8(secret), label);
}

async function unsubscribeSignature(secret: string, id: string): Promise<string> {
  return base64UrlEncode(await hmacBytes(await derivedKey(secret, unsubscribeKeyLabel), `email-unsubscribe:v1:${id}`));
}

/** The `s` value of a subscription's unsubscribe links: `<id>.<signature>` (URL-safe). */
export async function unsubscribeToken(secret: string, id: string): Promise<string> {
  return `${id}.${await unsubscribeSignature(secret, id)}`;
}

/** The subscription id a well-formed, correctly signed `s` value names; null otherwise (constant-time check). */
export async function verifiedUnsubscribeId(secret: string, token: string): Promise<string | null> {
  const match: RegExpExecArray | null = /^([0-9a-f-]{36})\.([A-Za-z0-9_-]{43})$/.exec(token);
  if (match === null || match[1] === undefined || match[2] === undefined) {
    return null;
  }
  const expected: string = await unsubscribeSignature(secret, match[1]);
  return (await constantTimeEqualText(expected, match[2])) ? match[1] : null;
}

/** The opaque `email_recipient_limits` key of a recipient (lower-cased address). */
export async function recipientLimitKey(secret: string, address: string): Promise<string> {
  return hexEncode(await hmacBytes(await derivedKey(secret, limitsKeyLabel), `recipient:${address.toLowerCase()}`));
}

/** The opaque `email_recipient_limits` key of an account (confirmation emails one account may ask for). */
export async function accountLimitKey(secret: string, userId: string): Promise<string> {
  return hexEncode(await hmacBytes(await derivedKey(secret, limitsKeyLabel), `account:${userId}`));
}
