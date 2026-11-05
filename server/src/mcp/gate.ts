import { assistantSettings } from "../assistant/store";
import { utf8, hexEncode } from "../crypto";
import type { AssistantKeyring } from "../assistant/crypto";
import type { AccessConfig } from "../entitlements";
import { hasSyncAccess } from "../sync";

/**
 * The checks every connection step makes against strongly consistent D1 (KV, where OAuth tokens live, is eventually
 * consistent): the account exists, AI assistant access is on, and the account has a subscription or a running trial.
 * The consent page, the consent decision, the code exchange and every MCP call run them, so turning the feature off,
 * losing access or deleting the account stops an assistant at once. A refresh does not run them: it only checks that
 * the connection row is live at the current epoch (`grants.ts`), and the next MCP call runs the full gate.
 */
export type UserGate =
  | { readonly kind: "ready"; readonly epoch: number }
  | { readonly kind: "missing" }
  | { readonly kind: "disabled" }
  | { readonly kind: "no_access" };

export async function userGate(db: D1Database, adb: D1Database, access: AccessConfig, userId: string, now: Date): Promise<UserGate> {
  const user: { found: number } | null = await db.prepare("SELECT EXISTS (SELECT 1 FROM users WHERE id = ?) AS found").bind(userId).first<{ found: number }>();
  if (user === null || user.found === 0) {
    return { kind: "missing" };
  }
  const settings = await assistantSettings(adb, userId);
  if (settings === null || settings.enabled === 0) {
    return { kind: "disabled" };
  }
  if (!(await hasSyncAccess(db, access, userId, now))) {
    return { kind: "no_access" };
  }
  return { kind: "ready", epoch: settings.epoch };
}

/** User-facing text of a closed gate (tool errors, token errors). No upsell, no links. Pure function. */
export function gateMessage(gate: Exclude<UserGate, { kind: "ready" }>): string {
  if (gate.kind === "missing") {
    return "This Gistsmith account no longer exists.";
  }
  if (gate.kind === "disabled") {
    return "AI assistant access is off. Turn it on in the Gistsmith app (Settings › Connections).";
  }
  return "AI assistant access isn't available on this Gistsmith account right now. Check your account in the Gistsmith app.";
}

/** HMAC-SHA256 key for one purpose, derived from the current assistant master key (HKDF, separate `info`). */
export async function purposeKey(keyring: AssistantKeyring, purpose: string): Promise<CryptoKey> {
  const master: Uint8Array | undefined = keyring.keys.get(keyring.currentKeyId);
  if (master === undefined) {
    throw new Error("The current assistant key is missing from the keyring.");
  }
  const ikm: CryptoKey = await crypto.subtle.importKey("raw", master, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: utf8("gistsmith-mcp-v1"), info: utf8(`purpose:${purpose}`) },
    ikm,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign", "verify"],
  );
}

/** Hex HMAC of a text. */
export async function hmacHex(key: CryptoKey, text: string): Promise<string> {
  return hexEncode(new Uint8Array(await crypto.subtle.sign("HMAC", key, utf8(text))));
}
