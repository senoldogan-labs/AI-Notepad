import { env } from "cloudflare:workers";
import { type CryptoKey as JoseKey, SignJWT, decodeProtectedHeader, exportPKCS8, exportSPKI, generateKeyPair, importSPKI, jwtVerify } from "jose";
import { describe, expect, it } from "vitest";
import { appleIssuer } from "../src/auth/apple";
import {
  type ActiveAppleSignIn,
  AppleTokenDecryptError,
  appleClientSecret,
  appleErrorCode,
  appleRevokeUrl,
  appleTokenUrl,
  decryptAppleRefreshToken,
  encryptAppleRefreshToken,
} from "../src/auth/appleTokens";
import { cleanupExpiredRows } from "../src/cleanup";
import { base64Encode, randomId, randomToken, sha256Hex } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, appleIdentityToken, defaultHarness, envWith, expectError, req } from "./helpers";

/** Sitenin Services ID'si (`wrangler.jsonc` → `APPLE_SIGNIN_CLIENT_ID`). */
const servicesId: string = "com.senoldogan.AINotepad.web";
/** Yerel `SITE_ORIGIN`'in dönüş adresi. */
const redirectUri: string = "http://localhost:8788/sign-in";

/** Testin "Sign in with Apple" anahtarı: dosya başına bir kez üretilir, gerçek anahtar değildir. */
interface TestSigningKey {
  readonly pkcs8Pem: string;
  readonly publicKey: JoseKey;
}

let signingKeyPromise: Promise<TestSigningKey> | null = null;

async function signingKey(): Promise<TestSigningKey> {
  signingKeyPromise ??= (async (): Promise<TestSigningKey> => {
    const pair = await generateKeyPair("ES256", { extractable: true });
    const publicKey: JoseKey = await importSPKI(await exportSPKI(pair.publicKey), "ES256");
    return { pkcs8Pem: await exportPKCS8(pair.privateKey), publicKey };
  })();
  return signingKeyPromise;
}

/** Testin şifreleme anahtarı (32 bayt). */
const encryptionKeyBytes: Uint8Array = crypto.getRandomValues(new Uint8Array(32));

/** Apple anahtarları girilmiş ortam. */
async function appleEnv(): Promise<Env> {
  const key: TestSigningKey = await signingKey();
  return envWith({ APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: key.pkcs8Pem, APPLE_TOKEN_ENC_KEY: base64Encode(encryptionKeyBytes) });
}

/** Doğrudan modül çağrıları için etkin yapılandırma. */
async function activeApple(): Promise<ActiveAppleSignIn> {
  const key: TestSigningKey = await signingKey();
  return { teamId: "79DZ4AA4DW", clientId: servicesId, redirectUri, credentials: { keyId: "TESTKEY123", privateKeyPem: key.pkcs8Pem, tokenEncryptionKey: encryptionKeyBytes } };
}

/** Apple'ın `/auth/token` yanıtındaki kimlik jetonu (imzası sunucuda denetlenmez; rastgele anahtarla imzalı). */
async function tokenResponseIdToken(subject: string, audience: string): Promise<string> {
  const pair = await generateKeyPair("RS256");
  const now: number = Math.floor(Date.now() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "RS256", kid: "apple" })
    .setIssuer(appleIssuer)
    .setAudience(audience)
    .setSubject(subject)
    .setIssuedAt(now)
    .setExpirationTime(now + 600)
    .sign(pair.privateKey);
}

/** Sahte Apple `/auth/token`: kodu verilen kimliğe bağlı yenileme jetonuna çevirir; alınan formlar kaydedilir. */
function stubTokenEndpoint(harness: Harness, subject: string, refreshToken: string): URLSearchParams[] {
  const forms: URLSearchParams[] = [];
  harness.stub(appleTokenUrl, async (request: Request): Promise<Response> => {
    forms.push(new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer())));
    return Response.json({
      access_token: `access-${randomToken(8)}`,
      token_type: "Bearer",
      expires_in: 3600,
      refresh_token: refreshToken,
      id_token: await tokenResponseIdToken(subject, servicesId),
    });
  });
  return forms;
}

/** Sahte Apple `/auth/revoke`: `status` ile yanıt verir; alınan formlar kaydedilir. */
function stubRevokeEndpoint(harness: Harness, status: number): URLSearchParams[] {
  const forms: URLSearchParams[] = [];
  harness.stub(appleRevokeUrl, async (request: Request): Promise<Response> => {
    forms.push(new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer())));
    return status === 200 ? new Response(null, { status: 200 }) : Response.json({ error: "server_error" }, { status });
  });
  return forms;
}

/** Verilen Apple kimliğiyle giriş. */
async function signInAs(harness: Harness, subject: string, testEnv: Env): Promise<Session> {
  const nonce: string = randomToken(24);
  const identityToken: string = await appleIdentityToken({
    subject,
    nonceClaim: await sha256Hex(nonce),
    audience: servicesId,
    issuer: appleIssuer,
    expiresInSeconds: 600,
    nowMs: harness.clock.nowMs,
  });
  const response: Response = await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce }, env: testEnv }));
  expect(response.status).toBe(200);
  return response.json<Session>();
}

function postCode(harness: Harness, code: string, testEnv: Env): Promise<Response> {
  return harness.call(req("POST", "/v1/auth/apple/authorization-code", { json: { code }, env: testEnv }));
}

async function storedRow(subject: string): Promise<{ client_id: string; refresh_token_ciphertext: string } | null> {
  return env.DB.prepare("SELECT client_id, refresh_token_ciphertext FROM apple_sign_in_tokens WHERE subject = ?")
    .bind(subject)
    .first<{ client_id: string; refresh_token_ciphertext: string }>();
}

async function opsCount(detail: string): Promise<number> {
  const row = await env.DB.prepare("SELECT COALESCE(SUM(count), 0) AS count FROM ops_events WHERE kind = 'provider_error' AND detail = ?")
    .bind(detail)
    .first<{ count: number }>();
  return row?.count ?? 0;
}

describe("Apple istemci sırrı ve jeton şifrelemesi", () => {
  it("istemci sırrı ES256 imzalı ve Apple'ın istediği başlık ve iddiaları taşır", async () => {
    const now: Date = new Date();
    const secret: string = await appleClientSecret(await activeApple(), servicesId, now);
    expect(decodeProtectedHeader(secret)).toEqual({ alg: "ES256", kid: "TESTKEY123" });
    const { payload } = await jwtVerify(secret, (await signingKey()).publicKey, { issuer: "79DZ4AA4DW", audience: appleIssuer, subject: servicesId, currentDate: now });
    const issuedAt: number = Math.floor(now.getTime() / 1000);
    expect({ iat: payload.iat, exp: payload.exp }).toEqual({ iat: issuedAt, exp: issuedAt + 300 });
  });

  it("şifreleme gidiş-dönüşü çalışır; başka kimlik ya da anahtarla çözülmez, şifreli metin jetonu içermez", async () => {
    const token: string = `r.${randomToken(32)}`;
    const sealed: string = await encryptAppleRefreshToken(encryptionKeyBytes, "subject-a", token);
    expect(sealed).not.toContain(token);
    expect(await decryptAppleRefreshToken(encryptionKeyBytes, "subject-a", sealed)).toBe(token);
    await expect(decryptAppleRefreshToken(encryptionKeyBytes, "subject-b", sealed)).rejects.toBeInstanceOf(AppleTokenDecryptError);
    await expect(decryptAppleRefreshToken(crypto.getRandomValues(new Uint8Array(32)), "subject-a", sealed)).rejects.toBeInstanceOf(AppleTokenDecryptError);
    await expect(decryptAppleRefreshToken(encryptionKeyBytes, "subject-a", "kısa")).rejects.toBeInstanceOf(AppleTokenDecryptError);
    // Aynı jeton her seferinde farklı şifrelenir (rastgele IV).
    expect(await encryptAppleRefreshToken(encryptionKeyBytes, "subject-a", token)).not.toBe(sealed);
  });

  it("Apple hata gövdesinden yalnızca hata kodunu okur", () => {
    expect(appleErrorCode('{"error":"invalid_grant"}')).toBe("invalid_grant");
    expect(appleErrorCode("<html>")).toBe("unknown");
    expect(appleErrorCode('{"message":"x"}')).toBe("unknown");
  });
});

describe("POST /v1/auth/apple/authorization-code", () => {
  it("kodu Services ID ve dönüş adresiyle takas eder, yenileme jetonunu şifreli saklar; yeni giriş jetonu değiştirir", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const subject: string = `apple-${randomId()}`;
    const forms: URLSearchParams[] = stubTokenEndpoint(harness, subject, "refresh-one");

    const response: Response = await postCode(harness, "c0de.0.test.authorization", testEnv);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ stored: true });
    expect(forms).toHaveLength(1);
    const form: URLSearchParams = forms[0] ?? new URLSearchParams();
    expect({
      client_id: form.get("client_id"),
      code: form.get("code"),
      grant_type: form.get("grant_type"),
      redirect_uri: form.get("redirect_uri"),
    }).toEqual({ client_id: servicesId, code: "c0de.0.test.authorization", grant_type: "authorization_code", redirect_uri: redirectUri });
    await jwtVerify(form.get("client_secret") ?? "", (await signingKey()).publicKey, { issuer: "79DZ4AA4DW", audience: appleIssuer, subject: servicesId, currentDate: new Date(harness.clock.nowMs) });

    const row = await storedRow(subject);
    expect(row?.client_id).toBe(servicesId);
    expect(row?.refresh_token_ciphertext).not.toContain("refresh-one");
    expect(await decryptAppleRefreshToken(encryptionKeyBytes, subject, row?.refresh_token_ciphertext ?? "")).toBe("refresh-one");

    stubTokenEndpoint(harness, subject, "refresh-two");
    expect((await postCode(harness, "c0de.0.test.second", testEnv)).status).toBe(200);
    expect(await decryptAppleRefreshToken(encryptionKeyBytes, subject, (await storedRow(subject))?.refresh_token_ciphertext ?? "")).toBe("refresh-two");
  });

  it("anahtarlar girilmemişse 503 apple_tokens_unavailable; Apple çağrılmaz", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(await postCode(harness, "c0de.0.test.unconfigured", env), 503, "apple_tokens_unavailable");
    expect(harness.outbound.filter((request: Request): boolean => request.url.startsWith("https://appleid.apple.com/auth/"))).toHaveLength(0);
  });

  it("Apple kodu reddederse (invalid_grant) yeniden denemez, 502 döner ve Sorunlar'a sayılır; giriş yine çalışır", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    let calls: number = 0;
    harness.stub(appleTokenUrl, async (): Promise<Response> => {
      calls += 1;
      return Response.json({ error: "invalid_grant" }, { status: 400 });
    });
    const before: number = await opsCount("apple_token");
    await expectError(await postCode(harness, "c0de.0.test.rejected", testEnv), 502, "upstream_rejected");
    expect(calls).toBe(1);
    expect(await opsCount("apple_token")).toBe(before + 1);
    const subject: string = `apple-${randomId()}`;
    await signInAs(harness, subject, testEnv);
    expect(await storedRow(subject)).toBeNull();
  });

  it("Apple 5xx verirse 3 kez dener, sonra 502 upstream_unavailable", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    let calls: number = 0;
    harness.stub(appleTokenUrl, async (): Promise<Response> => {
      calls += 1;
      return new Response("unavailable", { status: 503 });
    });
    await expectError(await postCode(harness, "c0de.0.test.unavailable", testEnv), 502, "upstream_unavailable");
    expect(calls).toBe(3);
  });

  it("yanıttaki kimlik jetonu başka istemcinin ise saklamaz", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const subject: string = `apple-${randomId()}`;
    harness.stub(appleTokenUrl, async (): Promise<Response> =>
      Response.json({ refresh_token: "refresh-x", id_token: await tokenResponseIdToken(subject, "com.example.other") }),
    );
    await expectError(await postCode(harness, "c0de.0.test.audience", testEnv), 502, "upstream_rejected");
    expect(await storedRow(subject)).toBeNull();
  });

  it("bozuk kod biçimi 400", async () => {
    const harness: Harness = await defaultHarness();
    await expectError(await postCode(harness, "has space in it", await appleEnv()), 400, "invalid_body");
  });
});

describe("DELETE /v1/me: Apple jetonunun iptali", () => {
  it("saklanan yenileme jetonunu Apple'da iptal eder, sonra hesabı ve jeton satırını siler", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const subject: string = `apple-${randomId()}`;
    stubTokenEndpoint(harness, subject, "refresh-to-revoke");
    expect((await postCode(harness, "c0de.0.test.delete", testEnv)).status).toBe(200);
    const session: Session = await signInAs(harness, subject, testEnv);
    const revokes: URLSearchParams[] = stubRevokeEndpoint(harness, 200);

    const response: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: testEnv }));
    expect(response.status).toBe(200);
    expect(revokes).toHaveLength(1);
    const form: URLSearchParams = revokes[0] ?? new URLSearchParams();
    expect({ client_id: form.get("client_id"), token: form.get("token"), token_type_hint: form.get("token_type_hint") }).toEqual({
      client_id: servicesId,
      token: "refresh-to-revoke",
      token_type_hint: "refresh_token",
    });
    await jwtVerify(form.get("client_secret") ?? "", (await signingKey()).publicKey, { issuer: "79DZ4AA4DW", audience: appleIssuer, subject: servicesId, currentDate: new Date(harness.clock.nowMs) });
    expect(await storedRow(subject)).toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM users WHERE id = ?").bind(session.userId).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("iptal yeniden denemelerden sonra da başarısızsa hesap yine silinir ve Sorunlar'a sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const subject: string = `apple-${randomId()}`;
    stubTokenEndpoint(harness, subject, "refresh-stuck");
    expect((await postCode(harness, "c0de.0.test.stuck", testEnv)).status).toBe(200);
    const session: Session = await signInAs(harness, subject, testEnv);
    const revokes: URLSearchParams[] = stubRevokeEndpoint(harness, 503);
    const before: number = await opsCount("apple_revoke");

    const response: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: testEnv }));
    expect(response.status).toBe(200);
    expect(revokes).toHaveLength(3);
    expect(await opsCount("apple_revoke")).toBe(before + 1);
    expect(await storedRow(subject)).toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM users WHERE id = ?").bind(session.userId).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("anahtarlar sonradan kaldırıldıysa iptal edilemez: hesap silinir, Sorunlar'a sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const subject: string = `apple-${randomId()}`;
    stubTokenEndpoint(harness, subject, "refresh-unconfigured");
    expect((await postCode(harness, "c0de.0.test.removed", testEnv)).status).toBe(200);
    const session: Session = await signInAs(harness, subject, env);
    const before: number = await opsCount("apple_revoke");
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env }))).status).toBe(200);
    expect(await opsCount("apple_revoke")).toBe(before + 1);
    expect(await storedRow(subject)).toBeNull();
  });

  it("jetonu saklanmamış Apple hesabı (bu sürümden önceki giriş) silinir ve apple_revoke_no_token sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const session: Session = await signInAs(harness, `apple-${randomId()}`, testEnv);
    const before: number = await opsCount("apple_revoke_no_token");
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: testEnv }))).status).toBe(200);
    expect(await opsCount("apple_revoke_no_token")).toBe(before + 1);
    expect(harness.outbound.filter((request: Request): boolean => request.url.startsWith(appleRevokeUrl))).toHaveLength(0);
  });
});

describe("temizlik: hesaba bağlanmamış Apple jetonu", () => {
  it("bir günden eski ve kimliği olmayan satırı siler; hesaba bağlı ya da yeni satırı tutar", async () => {
    const harness: Harness = await defaultHarness();
    const testEnv: Env = await appleEnv();
    const now: number = harness.clock.nowMs;
    const linked: string = `apple-${randomId()}`;
    await signInAs(harness, linked, testEnv);
    const orphanOld: string = `apple-${randomId()}`;
    const orphanNew: string = `apple-${randomId()}`;
    const insert = (subject: string, storedAt: number): D1PreparedStatement =>
      env.DB.prepare("INSERT INTO apple_sign_in_tokens (subject, client_id, refresh_token_ciphertext, stored_at) VALUES (?, ?, 'x', ?)").bind(subject, servicesId, storedAt);
    await env.DB.batch([insert(linked, now - 10 * 86_400_000), insert(orphanOld, now - 2 * 86_400_000), insert(orphanNew, now - 3_600_000)]);

    await cleanupExpiredRows(env.DB, new Date(now), { batchSize: 100, maxBatchesPerTable: 2 });
    expect(await storedRow(linked)).not.toBeNull();
    expect(await storedRow(orphanOld)).toBeNull();
    expect(await storedRow(orphanNew)).not.toBeNull();
  });
});
