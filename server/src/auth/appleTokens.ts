import { type CryptoKey as JoseKey, type JWTPayload, SignJWT, decodeJwt, importPKCS8 } from "jose";
import { z } from "zod";
import { type AppleSignInConfig, type AppleSignInCredentials, ConfigError } from "../config";
import { Base64Error, base64Decode, base64Encode, concatBytes, decodeUtf8Strict, utf8 } from "../crypto";
import { ApiError, ProviderApiError, UpstreamError, isRetryableStatus } from "../errors";
import { errorName, log } from "../log";
import { type OpsEvent, recordOpsEvents } from "../opsEvents";
import type { Platform } from "../platform";
import { withRetries } from "../retry";
import { isRetryableUpstreamError } from "../upstream";
import { appleIssuer } from "./apple";

/**
 * Apple ile girişin yenileme jetonu: yalnızca hesap silinince Apple'da yetkiyi geri almak için saklanır (Apple, "Offering
 * account deletion in your app": "Apps that support Sign in with Apple should use the Sign in with Apple REST API to
 * revoke user tokens"; TN3194). Akış:
 * 1. Site, Apple'ın yanıtındaki tek kullanımlık yetkilendirme kodunu (5 dakika geçerli) `POST /v1/auth/apple/authorization-code`
 *    ile gönderir (sitenin kendi girişinde de uygulama adına girişte de; uygulamalar değişmez).
 * 2. Sunucu kodu `POST https://appleid.apple.com/auth/token` ile takas eder (`client_id` = Services ID, istemci sırrı
 *    ES256 JWT, `redirect_uri` = sitenin dönüş adresi). Yanıttaki kimlik jetonu Apple'dan doğrudan TLS ile geldiği için
 *    imzası yeniden doğrulanmaz (OpenID Connect Core 3.1.3.7); `iss`, `aud` ve `sub` denetlenir.
 * 3. Yenileme jetonu AES-256-GCM ile şifrelenip Apple kimliğine (`sub`) bağlı saklanır (`apple_sign_in_tokens`).
 * 4. Hesap silinince jeton `POST https://appleid.apple.com/auth/revoke` ile (`token_type_hint=refresh_token`) iptal edilir.
 * Jeton, kod ve istemci sırrı hiçbir zaman loglanmaz; Apple'ın hata gövdesinden yalnızca `error` kodu loglanır.
 */

/** Apple'ın jeton ve iptal uçları. */
export const appleTokenUrl: string = "https://appleid.apple.com/auth/token";
export const appleRevokeUrl: string = "https://appleid.apple.com/auth/revoke";

/** Yeniden deneme dahil en çok deneme (5xx, 429, ağ hatası, zaman aşımı). */
const appleTokenAttempts: number = 3;
/** Deneme başına zaman aşımı. */
const appleTokenTimeoutMs: number = 10_000;
/** İstemci sırrının ömrü: her çağrıda yeniden üretilir, kısa tutulur (Apple'ın üst sınırı altı ay). */
const clientSecretLifetimeSeconds: number = 300;
/** AES-GCM IV uzunluğu (bayt). */
const ivBytes: number = 12;

/** Yapılandırılmış (anahtarları girilmiş) Apple ile giriş. */
export interface ActiveAppleSignIn {
  readonly teamId: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly credentials: AppleSignInCredentials;
}

/** Kod takasının sonucu: Apple kimliği ve yenileme jetonu (düz; yalnızca bellekte). */
export interface AppleTokenGrant {
  readonly subject: string;
  readonly refreshToken: string;
}

/** Saklanan jeton satırı. */
interface StoredAppleTokenRow {
  readonly subject: string;
  readonly client_id: string;
  readonly refresh_token_ciphertext: string;
}

/** Hesap silmede jeton iptalinin sonucu (log ve "Sorunlar" sayacı için). */
export type AppleRevocationOutcome = "revoked" | "no_token" | "failed";

/** Şifreli jeton çözülemedi (anahtar değişti ya da satır bozuk). Ayrıntı taşımaz. */
export class AppleTokenDecryptError extends Error {
  override readonly name: string = "AppleTokenDecryptError";
}

const tokenResponseSchema = z.object({
  refresh_token: z.string().min(1),
  id_token: z.string().min(1),
});
const tokenClaimsSchema = z.object({ iss: z.string(), sub: z.string().min(1), aud: z.union([z.string(), z.array(z.string())]) });
const errorResponseSchema = z.object({ error: z.string().max(64) });

/** Anahtarları girilmişse etkin yapılandırma; değilse `503 apple_tokens_unavailable`. */
export function requireAppleSignIn(config: AppleSignInConfig): ActiveAppleSignIn {
  if (config.credentials === null) {
    throw new ApiError("apple_tokens_unavailable", "Sign in with Apple token storage isn't configured on the server.");
  }
  return { teamId: config.teamId, clientId: config.clientId, redirectUri: config.redirectUri, credentials: config.credentials };
}

/**
 * Apple'ın istemci sırrı (Apple, "Creating a client secret"): ES256, başlık `{alg, kid}`, iddialar `iss` = ekip,
 * `sub` = istemci (`client_id` ile aynı), `aud` = `https://appleid.apple.com`, `iat`, `exp` (5 dakika). Anahtar
 * okunamazsa `ConfigError`.
 */
export async function appleClientSecret(apple: ActiveAppleSignIn, clientId: string, now: Date): Promise<string> {
  let key: JoseKey;
  try {
    key = await importPKCS8(apple.credentials.privateKeyPem, "ES256");
  } catch (error: unknown) {
    log("error", "apple_signin_key_invalid", { error: errorName(error) });
    throw new ConfigError(["APPLE_SIGNIN_PRIVATE_KEY"]);
  }
  const issuedAt: number = Math.floor(now.getTime() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: apple.credentials.keyId })
    .setIssuer(apple.teamId)
    .setSubject(clientId)
    .setAudience(appleIssuer)
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + clientSecretLifetimeSeconds)
    .sign(key);
}

/** AES-256-GCM anahtarı. */
async function encryptionKey(keyBytes: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

/**
 * Yenileme jetonunu şifreler: base64(12 baytlık rastgele IV || şifreli metin ve etiket); ek doğrulanmış veri Apple
 * kimliğidir (şifreli değer başka bir satıra taşınırsa çözülmez).
 */
export async function encryptAppleRefreshToken(keyBytes: Uint8Array, subject: string, refreshToken: string): Promise<string> {
  const iv: Uint8Array = crypto.getRandomValues(new Uint8Array(ivBytes));
  const sealed: ArrayBuffer = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: utf8(subject) }, await encryptionKey(keyBytes), utf8(refreshToken));
  return base64Encode(concatBytes([iv, new Uint8Array(sealed)]));
}

/** `encryptAppleRefreshToken`'ın tersi; anahtar, kimlik ya da değer uymazsa `AppleTokenDecryptError`. */
export async function decryptAppleRefreshToken(keyBytes: Uint8Array, subject: string, ciphertext: string): Promise<string> {
  let bytes: Uint8Array;
  try {
    bytes = base64Decode(ciphertext);
  } catch (error: unknown) {
    if (error instanceof Base64Error) {
      throw new AppleTokenDecryptError("şifreli jeton base64 değil");
    }
    throw error;
  }
  if (bytes.byteLength <= ivBytes) {
    throw new AppleTokenDecryptError("şifreli jeton çok kısa");
  }
  let opened: ArrayBuffer;
  try {
    opened = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.slice(0, ivBytes), additionalData: utf8(subject) },
      await encryptionKey(keyBytes),
      bytes.slice(ivBytes),
    );
  } catch (error: unknown) {
    // WebCrypto, anahtar ya da ek veri uymazsa `OperationError` adlı DOMException fırlatır.
    if (error instanceof DOMException) {
      throw new AppleTokenDecryptError(`jeton çözülemedi: ${error.name}`);
    }
    throw error;
  }
  return decodeUtf8Strict(new Uint8Array(opened));
}

/** Apple'ın hata gövdesindeki `error` kodu (`invalid_grant`, `invalid_client`…); okunamazsa `unknown`. Saf fonksiyondur. */
export function appleErrorCode(body: string): string {
  try {
    const parsed = errorResponseSchema.safeParse(JSON.parse(body));
    return parsed.success ? parsed.data.error : "unknown";
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      return "unknown";
    }
    throw error;
  }
}

/**
 * Apple'ın form gövdeli ucuna POST atar ve başarılı yanıtın gövdesini döndürür. 5xx, 429 ve ağ hataları uyarıyla
 * yeniden denenir; 400 (`invalid_grant`, `invalid_client`…) denenmez. Hata `UpstreamError`'dur ve yalnızca Apple'ın
 * `error` kodunu taşır. `form` her denemede yeniden kurulur.
 */
async function postAppleForm(platform: Platform, service: "apple_token" | "apple_revoke", url: string, form: () => URLSearchParams): Promise<string> {
  return withRetries(
    { service, attempts: appleTokenAttempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError, recordRetry: platform.recordRetry },
    async (): Promise<string> => {
      const response: Response = await platform.fetch(url, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
        body: form(),
        signal: AbortSignal.timeout(appleTokenTimeoutMs),
      });
      const body: string = await response.text();
      if (response.ok) {
        return body;
      }
      const code: string = appleErrorCode(body);
      log("warn", "apple_token_request_failed", { service, status: response.status, appleError: code });
      throw new UpstreamError(service, response.status, isRetryableStatus(response.status), `apple error ${code}`);
    },
  );
}

/** Kimlik jetonunun `aud`'u istemciyi içeriyor mu. Saf fonksiyondur. */
function audienceIncludes(audience: string | readonly string[], clientId: string): boolean {
  return typeof audience === "string" ? audience === clientId : audience.includes(clientId);
}

/**
 * Yetkilendirme kodunu Apple'da yenileme jetonuna çevirir (Apple, "Generate and validate tokens":
 * `grant_type=authorization_code`, `redirect_uri` yetkilendirme isteğindekiyle aynı). Yanıt beklenen biçimde değilse ya da
 * kimlik jetonu başka bir istemcinin ya da yayıncının ise `UpstreamError` (yeniden denenmez).
 */
export async function exchangeAppleAuthorizationCode(platform: Platform, apple: ActiveAppleSignIn, code: string, now: Date): Promise<AppleTokenGrant> {
  const clientSecret: string = await appleClientSecret(apple, apple.clientId, now);
  const body: string = await postAppleForm(
    platform,
    "apple_token",
    appleTokenUrl,
    (): URLSearchParams =>
      new URLSearchParams({
        client_id: apple.clientId,
        client_secret: clientSecret,
        code,
        grant_type: "authorization_code",
        redirect_uri: apple.redirectUri,
      }),
  );
  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      throw new UpstreamError("apple_token", 200, false, "jeton yanıtı JSON değil");
    }
    throw error;
  }
  const parsed = tokenResponseSchema.safeParse(json);
  if (!parsed.success) {
    throw new UpstreamError("apple_token", 200, false, "jeton yanıtında refresh_token ya da id_token yok");
  }
  let payload: JWTPayload;
  try {
    payload = decodeJwt(parsed.data.id_token);
  } catch (error: unknown) {
    throw new UpstreamError("apple_token", 200, false, `id_token çözülemedi: ${errorName(error)}`);
  }
  const claims = tokenClaimsSchema.safeParse(payload);
  if (!claims.success || claims.data.iss !== appleIssuer || !audienceIncludes(claims.data.aud, apple.clientId)) {
    throw new UpstreamError("apple_token", 200, false, "id_token beklenen yayıncı ya da istemci için değil");
  }
  return { subject: claims.data.sub, refreshToken: parsed.data.refresh_token };
}

/** Yenileme jetonunu Apple'da iptal eder (Apple, "Revoke tokens"; zaten geçersiz jetonda da 200 döner). */
export async function revokeAppleRefreshToken(platform: Platform, apple: ActiveAppleSignIn, clientId: string, refreshToken: string, now: Date): Promise<void> {
  const clientSecret: string = await appleClientSecret(apple, clientId, now);
  await postAppleForm(
    platform,
    "apple_revoke",
    appleRevokeUrl,
    (): URLSearchParams => new URLSearchParams({ client_id: clientId, client_secret: clientSecret, token: refreshToken, token_type_hint: "refresh_token" }),
  );
}

/** Jetonu Apple kimliğine bağlı saklar; aynı kimliğin eski jetonunun yerine geçer. */
async function storeAppleRefreshToken(db: D1Database, apple: ActiveAppleSignIn, grant: AppleTokenGrant, now: Date): Promise<void> {
  const ciphertext: string = await encryptAppleRefreshToken(apple.credentials.tokenEncryptionKey, grant.subject, grant.refreshToken);
  await db
    .prepare(
      `INSERT INTO apple_sign_in_tokens (subject, client_id, refresh_token_ciphertext, stored_at) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(subject) DO UPDATE SET client_id = ?2, refresh_token_ciphertext = ?3, stored_at = ?4`,
    )
    .bind(grant.subject, apple.clientId, ciphertext, now.getTime())
    .run();
}

/**
 * `POST /v1/auth/apple/authorization-code`: kodu takas eder ve yenileme jetonunu saklar. Giriş bundan bağımsızdır (site
 * hatayı konsola yazar ve girişi sürdürür). Takas başarısız olursa `ProviderApiError` (`apple_token`): genel hata yolu
 * "Sorunlar"a `provider_error`/`apple_token` sayar; o kimliğin hesabı silinince iptal edilecek jeton olmaz (silme yine
 * yapılır ve `apple_revoke_no_token` sayılır). Anahtarlar girilmemişse `503 apple_tokens_unavailable` (5xx olarak sayılır).
 */
export async function storeAppleAuthorizationCode(db: D1Database, platform: Platform, config: AppleSignInConfig, code: string, now: Date): Promise<void> {
  const apple: ActiveAppleSignIn = requireAppleSignIn(config);
  let grant: AppleTokenGrant;
  try {
    grant = await exchangeAppleAuthorizationCode(platform, apple, code, now);
  } catch (error: unknown) {
    // Apple'ın hata yanıtı ya da yeniden denemelerden sonra da süren ağ hatası / zaman aşımı.
    if (error instanceof UpstreamError || isRetryableUpstreamError(error)) {
      log("error", "apple_token_exchange_failed", { error: errorName(error), status: error instanceof UpstreamError ? error.status : null });
      throw new ProviderApiError("apple_token", error instanceof UpstreamError && !error.retryable ? "upstream_rejected" : "upstream_unavailable", "Apple didn't accept the authorization code.");
    }
    throw error;
  }
  await storeAppleRefreshToken(db, apple, grant, now);
  log("info", "apple_token_stored", { clientId: apple.clientId });
}

/** Hesabın Apple kimliklerine bağlı saklanan jetonlar. */
async function storedTokensOf(db: D1Database, userId: string): Promise<StoredAppleTokenRow[]> {
  const rows: D1Result<StoredAppleTokenRow> = await db
    .prepare(
      `SELECT t.subject, t.client_id, t.refresh_token_ciphertext FROM apple_sign_in_tokens t
       JOIN auth_identities i ON i.provider = 'apple' AND i.subject = t.subject WHERE i.user_id = ?`,
    )
    .bind(userId)
    .all<StoredAppleTokenRow>();
  return rows.results;
}

/** Hesabın Apple kimliği var mı. */
async function hasAppleIdentity(db: D1Database, userId: string): Promise<boolean> {
  const row: { found: number } | null = await db
    .prepare("SELECT 1 AS found FROM auth_identities WHERE user_id = ? AND provider = 'apple' LIMIT 1")
    .bind(userId)
    .first<{ found: number }>();
  return row !== null;
}

/** Tek jetonu çözer ve iptal eder; başarısızsa hata adıyla loglar ve false döner (silme sürer). */
async function revokeStoredToken(platform: Platform, apple: ActiveAppleSignIn, userId: string, row: StoredAppleTokenRow, now: Date): Promise<boolean> {
  try {
    const refreshToken: string = await decryptAppleRefreshToken(apple.credentials.tokenEncryptionKey, row.subject, row.refresh_token_ciphertext);
    await revokeAppleRefreshToken(platform, apple, row.client_id, refreshToken, now);
    return true;
  } catch (error: unknown) {
    if (error instanceof AppleTokenDecryptError || error instanceof UpstreamError || error instanceof ConfigError || isRetryableUpstreamError(error)) {
      log("alert", "apple_token_revoke_failed", { userId, clientId: row.client_id, error: errorName(error), status: error instanceof UpstreamError ? error.status : null });
      return false;
    }
    throw error;
  }
}

/**
 * Hesap silinmeden önce hesabın Apple jetonlarını iptal eder. Silme hakkı iptale bağlı değildir: iptal başarısız
 * olursa (anahtarlar girilmemiş, jeton çözülemiyor, Apple yeniden denemelerden sonra da yanıt vermiyor) `alert` loglanır,
 * "Sorunlar"a `provider_error`/`apple_revoke` sayılır ve silme sürer; elle takip gerekir (kullanıcı Apple Kimliği
 * ayarlarından "Apple ile giriş"i kendisi de durdurabilir). Apple kimliği olan ama jetonu saklanmamış hesap (bu sürümden
 * önce giriş yapmış ve o zamandan beri yeniden girmemiş, ya da takas başarısız olmuş) `apple_revoke_no_token` sayılır.
 * Saklanan satırlar silme toplu işleminde silinir (`appleTokenDeletionStatement`).
 */
export async function revokeAppleTokensForDeletion(db: D1Database, platform: Platform, config: AppleSignInConfig, userId: string, now: Date): Promise<AppleRevocationOutcome> {
  const rows: StoredAppleTokenRow[] = await storedTokensOf(db, userId);
  if (rows.length === 0) {
    if (!(await hasAppleIdentity(db, userId))) {
      return "no_token";
    }
    await recordOpsEvents(db, [{ kind: "provider_error", detail: "apple_revoke_no_token" }], now);
    log("warn", "apple_token_missing_on_deletion", { userId });
    return "no_token";
  }
  if (config.credentials === null) {
    log("alert", "apple_token_revoke_failed", { userId, clientId: null, error: "apple_tokens_unavailable", status: null });
    await recordOpsEvents(db, [{ kind: "provider_error", detail: "apple_revoke" }], now);
    return "failed";
  }
  const apple: ActiveAppleSignIn = requireAppleSignIn(config);
  const results: boolean[] = [];
  for (const row of rows) {
    results.push(await revokeStoredToken(platform, apple, userId, row, now));
  }
  const failures: OpsEvent[] = results.filter((revoked: boolean): boolean => !revoked).map((): OpsEvent => ({ kind: "provider_error", detail: "apple_revoke" }));
  await recordOpsEvents(db, failures, now);
  return failures.length === 0 ? "revoked" : "failed";
}

/** Hesabın Apple kimliklerine bağlı jeton satırlarını silen ifade (kimlikler silinmeden önce, aynı toplu işlemde). */
export function appleTokenDeletionStatement(db: D1Database, userId: string): D1PreparedStatement {
  return db
    .prepare("DELETE FROM apple_sign_in_tokens WHERE subject IN (SELECT subject FROM auth_identities WHERE user_id = ? AND provider = 'apple')")
    .bind(userId);
}
