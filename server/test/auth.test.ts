import { env } from "cloudflare:workers";
import { type JWK, SignJWT, exportJWK, generateKeyPair } from "jose";
import { describe, expect, it, vi } from "vitest";
import { appleIssuer, appleJwksUrl } from "../src/auth/apple";
import { googleJwksUrl } from "../src/auth/google";
import { jwksCacheTtlMs, jwksStaleMaxMs } from "../src/auth/identityToken";
import { refreshRetryWindowMs } from "../src/auth/tokens";
import { cleanupExpiredRows, scheduledCleanupLimits } from "../src/cleanup";
import { randomId, randomToken, sha256Hex } from "../src/crypto";
import {
  type AppleTokenFields,
  type Harness,
  type Session,
  appleIdentityToken,
  blockingLimiter,
  defaultHarness,
  envWith,
  expectError,
  googleClientId,
  googleIdentityToken,
  req,
  signIn,
  signInWithGoogle,
} from "./helpers";

const clientId: string = "com.senoldogan.AINotepad.hosted";

/** Kimlik jetonu girişinin değiştirilebilir alanları. */
interface LoginOverrides {
  readonly audience: string;
  readonly issuer: string;
  readonly nonceClaimFor: string;
  readonly nonce: string;
  readonly expiresInSeconds: number;
}

async function appleLogin(harness: Harness, overrides: LoginOverrides): Promise<Response> {
  const identityToken: string = await appleIdentityToken({
    subject: `apple-${randomId()}`,
    nonceClaim: await sha256Hex(overrides.nonceClaimFor),
    audience: overrides.audience,
    issuer: overrides.issuer,
    expiresInSeconds: overrides.expiresInSeconds,
    nowMs: harness.clock.nowMs,
  });
  return harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce: overrides.nonce } }));
}

async function googleLogin(harness: Harness, subject: string, overrides: LoginOverrides): Promise<Response> {
  const fields: AppleTokenFields = {
    subject,
    nonceClaim: await sha256Hex(overrides.nonceClaimFor),
    audience: overrides.audience,
    issuer: overrides.issuer,
    expiresInSeconds: overrides.expiresInSeconds,
    nowMs: harness.clock.nowMs,
  };
  const identityToken: string = await googleIdentityToken(fields);
  return harness.call(req("POST", "/v1/auth/google", { json: { identityToken, nonce: overrides.nonce } }));
}

describe("Apple ile giriş", () => {
  it("geçerli jetonla kullanıcı ve oturum oluşturur; aynı Apple kimliği aynı kullanıcıdır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect(session.accessToken.split(".")).toHaveLength(3);
    const me: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
    expect(me.status).toBe(200);
    expect((await me.json<{ userId: string }>()).userId).toBe(session.userId);
    // Jetondaki doğrulanmış e-posta saklanmaz.
    const identity = await env.DB.prepare("SELECT provider, email FROM auth_identities WHERE user_id = ?").bind(session.userId).first<{ provider: string; email: string | null }>();
    expect(identity).toEqual({ provider: "apple", email: null });
  });

  it("yanlış aud, yanlış iss, süresi dolmuş jeton ve yanlış nonce reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base = { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 };
    await expectError(await appleLogin(harness, { ...base, audience: "com.baskasi.app" }), 401, "invalid_token");
    await expectError(await appleLogin(harness, { ...base, issuer: "https://evil.example" }), 401, "invalid_token");
    await expectError(await appleLogin(harness, { ...base, expiresInSeconds: -60 }), 401, "invalid_token");
    await expectError(await appleLogin(harness, { ...base, nonce: randomToken(24) }), 401, "invalid_token");
  });

  it("aynı nonce ikinci kez kullanılamaz", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base = { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 };
    expect((await appleLogin(harness, base)).status).toBe(200);
    await expectError(await appleLogin(harness, base), 401, "invalid_token");
  });

  it("Apple JWKS geçici hatası yeniden denenir", async () => {
    const harness: Harness = await defaultHarness();
    let calls: number = 0;
    const original = harness.outbound.length;
    harness.stub("https://appleid.apple.com/auth/keys", async (): Promise<Response> => {
      calls += 1;
      return new Response("geçici", { status: 503 });
    });
    const nonce: string = randomToken(24);
    const response: Response = await appleLogin(harness, { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 });
    await expectError(response, 502, "upstream_unavailable");
    expect(calls).toBe(3);
    expect(harness.outbound.length - original).toBe(3);
  });

  it("Apple anahtarları önbellekte tutulur; bilinmeyen kid (anahtar dönüşü) ve süresi dolan önbellek yeniden alınır", async () => {
    const harness: Harness = await defaultHarness();
    const jwksCalls = (): number => harness.outbound.filter((request: Request): boolean => request.url === appleJwksUrl).length;
    await signIn(harness);
    await signIn(harness);
    expect(jwksCalls()).toBe(1);

    // Apple yeni bir anahtara geçti: jetonun kid'i önbellekte yok.
    const { privateKey, publicKey } = await generateKeyPair("RS256", { extractable: true });
    const rotated: JWK = { ...(await exportJWK(publicKey)), kid: "test-apple-key-2", alg: "RS256", use: "sig" };
    const original: JWK[] = harness.platform.jwksCache.get(appleJwksUrl)?.keys.keys ?? [];
    harness.stub(appleJwksUrl, async (): Promise<Response> => Response.json({ keys: [...original, rotated] }));
    const nonce: string = randomToken(24);
    const issuedAt: number = Math.floor(harness.clock.nowMs / 1000);
    const identityToken: string = await new SignJWT({ nonce: await sha256Hex(nonce) })
      .setProtectedHeader({ alg: "RS256", kid: "test-apple-key-2" })
      .setIssuer(appleIssuer)
      .setAudience(clientId)
      .setSubject(`apple-${randomId()}`)
      .setIssuedAt(issuedAt)
      .setExpirationTime(issuedAt + 600)
      .sign(privateKey);
    expect((await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce } }))).status).toBe(200);
    expect(jwksCalls()).toBe(2);
    await signIn(harness);
    expect(jwksCalls()).toBe(2);

    harness.clock.nowMs += jwksCacheTtlMs;
    await signIn(harness);
    expect(jwksCalls()).toBe(3);
  });

  it("anahtarlar Worker örnekleri arasında D1'de kalır; Apple yanıt vermezse en çok bir hafta eski anahtarla giriş sürer", async () => {
    const harness: Harness = await defaultHarness();
    const jwksCalls = (): number => harness.outbound.filter((request: Request): boolean => request.url === appleJwksUrl).length;
    await signIn(harness);
    expect(jwksCalls()).toBe(1);
    // Yeni Worker örneği: bellek boş, anahtarlar D1'den okunur (Apple'a gidilmez).
    harness.platform.jwksCache.clear();
    await signIn(harness);
    expect(jwksCalls()).toBe(1);

    // Önbellek eskidi ve Apple yanıt vermiyor: tek kısa deneme, sonra kayıtlı anahtarlarla giriş.
    harness.clock.nowMs += jwksCacheTtlMs + 1_000;
    harness.platform.jwksCache.clear();
    harness.stub(appleJwksUrl, async (): Promise<Response> => new Response("geçici", { status: 503 }));
    await signIn(harness);
    expect(jwksCalls()).toBe(2);

    // Bir haftadan eski kayıt kullanılmaz: Apple'a tam yeniden denemeyle gidilir, yanıt yoksa giriş hata verir.
    harness.clock.nowMs += jwksStaleMaxMs;
    harness.platform.jwksCache.clear();
    const nonce: string = randomToken(24);
    await expectError(
      await appleLogin(harness, { audience: clientId, issuer: appleIssuer, nonceClaimFor: nonce, nonce, expiresInSeconds: 600 }),
      502,
      "upstream_unavailable",
    );
    expect(jwksCalls()).toBe(5);
  });

  it("giriş uçları IP başına hız sınırlıdır", async () => {
    const harness: Harness = await defaultHarness();
    const limited = envWith({ AUTH_IP_LIMITER: blockingLimiter });
    await expectError(
      await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken: "x".repeat(30), nonce: randomToken(24) }, env: limited })),
      429,
      "rate_limited",
    );
  });
});

describe("Google ile giriş", () => {
  it("geçerli jetonla kullanıcı ve oturum oluşturur; aynı Google kimliği aynı kullanıcıdır, e-posta saklanmaz", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-${randomId()}`;
    const first: Session = await signInWithGoogle(harness, subject);
    const me: Response = await harness.call(req("GET", "/v1/me", { token: first.accessToken }));
    expect(me.status).toBe(200);
    // Kısa `iss` biçimi de geçerlidir; aynı `sub` aynı kullanıcıya düşer.
    const nonce: string = randomToken(24);
    const second: Response = await googleLogin(harness, subject, {
      audience: googleClientId,
      issuer: "accounts.google.com",
      nonceClaimFor: nonce,
      nonce,
      expiresInSeconds: 3600,
    });
    expect(second.status).toBe(200);
    expect((await second.json<Session>()).userId).toBe(first.userId);
    const identity = await env.DB.prepare("SELECT provider, subject, email FROM auth_identities WHERE user_id = ?")
      .bind(first.userId)
      .first<{ provider: string; subject: string; email: string | null }>();
    expect(identity).toEqual({ provider: "google", subject, email: null });
  });

  it("Apple ve Google'daki aynı `sub` ayrı kullanıcılardır (otomatik bağlama yok)", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `ortak-${randomId()}`;
    const google: Session = await signInWithGoogle(harness, subject);
    const nonce: string = randomToken(24);
    const appleToken: string = await appleIdentityToken({
      subject,
      nonceClaim: await sha256Hex(nonce),
      audience: clientId,
      issuer: appleIssuer,
      expiresInSeconds: 600,
      nowMs: harness.clock.nowMs,
    });
    const apple: Response = await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken: appleToken, nonce } }));
    expect(apple.status).toBe(200);
    expect((await apple.json<Session>()).userId).not.toBe(google.userId);
  });

  it("yanlış aud, yanlış iss, Apple iss'i, süresi dolmuş jeton ve yanlış nonce reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base: LoginOverrides = { audience: googleClientId, issuer: "https://accounts.google.com", nonceClaimFor: nonce, nonce, expiresInSeconds: 3600 };
    const subject: string = `google-${randomId()}`;
    await expectError(await googleLogin(harness, subject, { ...base, audience: "baska.apps.googleusercontent.com" }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, audience: clientId }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, issuer: "https://evil.example" }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, issuer: appleIssuer }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, expiresInSeconds: -60 }), 401, "invalid_token");
    await expectError(await googleLogin(harness, subject, { ...base, nonce: randomToken(24) }), 401, "invalid_token");
    // Ham nonce'un kendisi (özeti değil) jetonda: reddedilir.
    const raw: string = randomToken(24);
    const fields: AppleTokenFields = { subject, nonceClaim: raw, audience: googleClientId, issuer: base.issuer, expiresInSeconds: 3600, nowMs: harness.clock.nowMs };
    const rawToken: string = await googleIdentityToken(fields);
    await expectError(await harness.call(req("POST", "/v1/auth/google", { json: { identityToken: rawToken, nonce: raw } })), 401, "invalid_token");
  });

  it("Apple anahtarıyla imzalanmış jeton Google ucunda reddedilir", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const identityToken: string = await appleIdentityToken({
      subject: `google-${randomId()}`,
      nonceClaim: await sha256Hex(nonce),
      audience: googleClientId,
      issuer: "https://accounts.google.com",
      expiresInSeconds: 600,
      nowMs: harness.clock.nowMs,
    });
    await expectError(await harness.call(req("POST", "/v1/auth/google", { json: { identityToken, nonce } })), 401, "invalid_token");
  });

  it("aynı nonce ikinci kez kullanılamaz", async () => {
    const harness: Harness = await defaultHarness();
    const nonce: string = randomToken(24);
    const base: LoginOverrides = { audience: googleClientId, issuer: "https://accounts.google.com", nonceClaimFor: nonce, nonce, expiresInSeconds: 3600 };
    const subject: string = `google-${randomId()}`;
    expect((await googleLogin(harness, subject, base)).status).toBe(200);
    await expectError(await googleLogin(harness, subject, base), 401, "invalid_token");
  });

  it("Google JWKS geçici hatası yeniden denenir", async () => {
    const harness: Harness = await defaultHarness();
    let calls: number = 0;
    harness.stub(googleJwksUrl, async (): Promise<Response> => {
      calls += 1;
      return new Response("geçici", { status: 503 });
    });
    const nonce: string = randomToken(24);
    const response: Response = await googleLogin(harness, `google-${randomId()}`, {
      audience: googleClientId,
      issuer: "https://accounts.google.com",
      nonceClaimFor: nonce,
      nonce,
      expiresInSeconds: 3600,
    });
    await expectError(response, 502, "upstream_unavailable");
    expect(calls).toBe(3);
  });

  it("Google girişi de IP başına hız sınırlıdır; e-posta uçları kaldırıldı", async () => {
    const harness: Harness = await defaultHarness();
    const limited = envWith({ AUTH_IP_LIMITER: blockingLimiter });
    await expectError(
      await harness.call(req("POST", "/v1/auth/google", { json: { identityToken: "x".repeat(30), nonce: randomToken(24) }, env: limited })),
      429,
      "rate_limited",
    );
    await expectError(
      await harness.call(req("POST", "/v1/auth/email/start", { json: { email: "kisi@ornek.test", turnstileToken: "tt" } })),
      404,
      "not_found",
    );
  });
});

describe("yenileme jetonu ve çıkış", () => {
  it("yenileme jetonu döner; yerine geçen jeton kullanıldıktan sonra eski jeton gelirse tüm aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const rotated: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    expect(rotated.status).toBe(200);
    const second: Session = await rotated.json<Session>();
    expect(second.refreshToken).not.toBe(first.refreshToken);
    const third: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } }))).json<Session>();
    expect((await harness.call(req("GET", "/v1/me", { token: third.accessToken }))).status).toBe(200);

    // Çalınmış eski jeton (halefi zaten kullanıldı, süre içinde bile olsa): yeniden kullanım tespit edilir.
    harness.clock.nowMs += 5_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    // Meşru yeni jeton ve erişim jetonu da artık geçersiz.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: third.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: third.accessToken })), 401, "invalid_token");
  });

  it("halefi kullanılmamış eski jeton yeniden deneme süresi (10 dk) geçince yeniden kullanımdır: aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const second: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += refreshRetryWindowMs + 1_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } })), 401, "invalid_token");
  });

  it("yanıtı kaybolan yenileme (istemci zaman aşımı) dakikalar sonra aynı jetonla yeniden denenebilir; kaybolan jeton geçersizleşir, aile düşmez", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const lost: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    // İstemcinin 30 sn'lik zaman aşımından ve sonraki isteğe dek geçen süreden uzun.
    harness.clock.nowMs += 4 * 60_000;
    const retried: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    expect(retried.status).toBe(200);
    const second: Session = await retried.json<Session>();
    expect(second.refreshToken).not.toBe(lost.refreshToken);
    expect((await harness.call(req("GET", "/v1/me", { token: second.accessToken }))).status).toBe(200);
    // Kaybolan jeton istemciye hiç ulaşmadı; yeni jeton dönmeye devam eder.
    const third: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } }))).json<Session>();
    expect((await harness.call(req("GET", "/v1/me", { token: third.accessToken }))).status).toBe(200);
    // Süre geçtikten sonra hemen önceki jeton yeniden kullanımdır: aile düşer.
    harness.clock.nowMs += refreshRetryWindowMs + 1_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: second.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: third.accessToken })), 401, "invalid_token");
  });

  it("eski jeton süre içinde başka elden yeniden denenirse gerçek istemcinin tuttuğu halef gelince tüm aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    // Gerçek istemci dönüşü aldı ve halefi tutuyor.
    const legit: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += 5 * 60_000;
    // Çalınan eski jeton süre içinde sunuluyor: yeniden deneme sanılır, yeni çift verilir.
    const stolen: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    expect(stolen.status).toBe(200);
    const attacker: Session = await stolen.json<Session>();
    harness.clock.nowMs += 10 * 60_000;
    // Gerçek istemci halefini sunar: sessizce reddedilmez, tüm aile düşer (saldırganın oturumu dahil).
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: legit.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: attacker.refreshToken } })), 401, "invalid_token");
  });

  it("günlük temizlik geçersiz yazılmış halefi silmez: saldırgan yeni jetonu kullandıktan sonra gelen gerçek halef aileyi düşürür", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    const legit: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += 5 * 60_000;
    // Çalınan eski jeton süre içinde sunulur: gerçek halef geçersiz yazılır, saldırgan yeni çift alır ve onu kullanır.
    const attacker: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += 60_000;
    const attackerNext: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: attacker.refreshToken } }))).json<Session>();
    // Gece temizliği (Mac uykudayken).
    harness.clock.nowMs += 6 * 3_600_000;
    await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs), scheduledCleanupLimits);
    // Gerçek istemci halefini sunar: sessiz geçersiz jeton değil, tüm aile düşer ve neden yazılır.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: legit.refreshToken } })), 401, "invalid_token");
    const family = await env.DB.prepare("SELECT revoked_at, revoke_reason FROM refresh_families WHERE user_id = ?")
      .bind(first.userId)
      .first<{ revoked_at: number | null; revoke_reason: string | null }>();
    expect(family).toEqual({ revoked_at: harness.clock.nowMs, revoke_reason: "refresh_superseded_reuse" });
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: attackerNext.refreshToken } })), 401, "invalid_token");
  });

  it("yeniden denemede verilen halef kullanıldıktan sonra ilk jeton süre içinde yeniden gelirse aile düşer", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }));
    harness.clock.nowMs += 60_000;
    const retried: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += 60_000;
    const newest: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: retried.refreshToken } }))).json<Session>();
    harness.clock.nowMs += 60_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: newest.accessToken })), 401, "invalid_token");
  });

  it("kullanılmış yazılıp halefi eklenmemiş jeton (yarıda kalmış dönüş) aileyi düşürmez, yeniden sunulunca yeni çift verir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    // Eski sürümde jetonu kullanılmış yapan ifade işlendi, halefi ekleyen ifadeden önce istek düştü.
    await env.DB.prepare("UPDATE refresh_tokens SET used_at = ?, replaced_by = ? WHERE token_hash = ?")
      .bind(harness.clock.nowMs, await sha256Hex(randomToken(32)), await sha256Hex(session.refreshToken))
      .run();
    harness.clock.nowMs += 2 * 60_000;
    const retried: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }));
    expect(retried.status).toBe(200);
    expect((await harness.call(req("GET", "/v1/me", { token: (await retried.json<Session>()).accessToken }))).status).toBe(200);
  });

  it("çalınan, henüz kullanılmamış jeton art arda döndürülse de gerçek istemci onu sununca tüm aile düşer ve alarm yazılır", async () => {
    const harness: Harness = await defaultHarness();
    const stolen: Session = await signIn(harness);
    // Saldırgan çalınan jetonu (gerçek istemci de tutuyor) üç kez döndürür: ilk jeton artık iki kuşaktan daha eskidir.
    let attacker: Session = stolen;
    for (let index: number = 0; index < 3; index += 1) {
      harness.clock.nowMs += 60_000;
      attacker = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: attacker.refreshToken } }))).json<Session>();
    }
    // Mac uykudan uyanır; arada gece temizliği çalışır.
    harness.clock.nowMs += 6 * 3_600_000;
    await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs), scheduledCleanupLimits);
    const alerts = vi.spyOn(console, "error");
    try {
      await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: stolen.refreshToken } })), 401, "invalid_token");
      const family = await env.DB.prepare("SELECT revoked_at, revoke_reason FROM refresh_families WHERE user_id = ?")
        .bind(stolen.userId)
        .first<{ revoked_at: number | null; revoke_reason: string | null }>();
      expect(family).toEqual({ revoked_at: harness.clock.nowMs, revoke_reason: "refresh_reuse" });
      expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"refresh_token_reuse"'))).toBe(true);
    } finally {
      alerts.mockRestore();
    }
    // Saldırganın oturumu da düşer.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: attacker.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: attacker.accessToken })), 401, "invalid_token");
  });

  it("kullanılmış jetonlar süreleri dolana dek kalır, günlük temizlik onları süresi dolunca siler", async () => {
    const harness: Harness = await defaultHarness();
    let session: Session = await signIn(harness);
    for (let index: number = 0; index < 5; index += 1) {
      session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }))).json<Session>();
    }
    const family = await env.DB.prepare("SELECT id FROM refresh_families WHERE user_id = ?").bind(session.userId).first<{ id: string }>();
    const usedCount = async (): Promise<Array<{ used: number; count: number }>> =>
      (
        await env.DB.prepare("SELECT used_at IS NOT NULL AS used, COUNT(*) AS count FROM refresh_tokens WHERE family_id = ? GROUP BY used ORDER BY used")
          .bind(family?.id ?? "")
          .all<{ used: number; count: number }>()
      ).results;
    expect(await usedCount()).toEqual([
      { used: 0, count: 1 },
      { used: 1, count: 5 },
    ]);
    // Jeton ömrü (60 gün) geçince kullanılmışlar silinir; son jeton da dolduysa aile de silinir.
    harness.clock.nowMs += 61 * 86_400_000;
    await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs), scheduledCleanupLimits);
    expect(await usedCount()).toEqual([]);
  });

  it("süresi dolmuş erişim jetonu reddedilir, yenileme yeni jeton verir", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    harness.clock.nowMs += 16 * 60_000;
    await expectError(await harness.call(req("GET", "/v1/me", { token: session.accessToken })), 401, "invalid_token");
    const refreshed: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }))).json<Session>();
    expect((await harness.call(req("GET", "/v1/me", { token: refreshed.accessToken }))).status).toBe(200);
  });

  it("çıkış oturum ailesini düşürür", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const out: Response = await harness.call(req("POST", "/v1/auth/logout", { json: { refreshToken: session.refreshToken } }));
    expect(out.status).toBe(200);
    await expectError(await harness.call(req("GET", "/v1/me", { token: session.accessToken })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } })), 401, "invalid_token");
  });

  it("a revoked family is final: a retry within the window, the unused successor and every access token stay refused", async () => {
    const harness: Harness = await defaultHarness();
    const first: Session = await signIn(harness);
    // The rotation's answer is lost; the client still holds the first token and signs out with it.
    const lost: Session = await (await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } }))).json<Session>();
    harness.clock.nowMs += 60_000;
    expect((await harness.call(req("POST", "/v1/auth/logout", { json: { refreshToken: first.refreshToken } }))).status).toBe(200);
    const revokedAt: number = harness.clock.nowMs;
    const tokenCount = async (): Promise<unknown> =>
      env.DB.prepare("SELECT COUNT(*) AS count FROM refresh_tokens t JOIN refresh_families f ON f.id = t.family_id WHERE f.user_id = ?").bind(first.userId).first();
    const before: unknown = await tokenCount();
    harness.clock.nowMs += 60_000;
    // Within the retry window, the lost-answer retry would otherwise be honoured.
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: first.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: lost.refreshToken } })), 401, "invalid_token");
    await expectError(await harness.call(req("GET", "/v1/me", { token: lost.accessToken })), 401, "invalid_token");
    expect(await tokenCount()).toEqual(before);
    const family = await env.DB.prepare("SELECT revoked_at, revoke_reason FROM refresh_families WHERE user_id = ?").bind(first.userId).first();
    expect(family).toEqual({ revoked_at: revokedAt, revoke_reason: "logout" });
  });

  it("a new sign-in is its own family: the old family's retry answers only for the old family, and its revocation leaves the new one alive", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `apple-${randomId()}`;
    const signInAs = async (): Promise<Session> => {
      const nonce: string = randomToken(24);
      const identityToken: string = await appleIdentityToken({
        subject,
        nonceClaim: await sha256Hex(nonce),
        audience: clientId,
        issuer: appleIssuer,
        expiresInSeconds: 600,
        nowMs: harness.clock.nowMs,
      });
      const response: Response = await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce } }));
      expect(response.status).toBe(200);
      return response.json<Session>();
    };
    const old: Session = await signInAs();
    await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: old.refreshToken } }));
    harness.clock.nowMs += 60_000;
    const current: Session = await signInAs();
    expect(current.userId).toBe(old.userId);
    // The old family's lost-answer retry still answers, inside the old family.
    harness.clock.nowMs += 60_000;
    const retried: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: old.refreshToken } }));
    expect(retried.status).toBe(200);
    const oldRetry: Session = await retried.json<Session>();
    const families = async (): Promise<Array<{ id: string; revoked: number }>> =>
      (
        await env.DB.prepare("SELECT id, revoked_at IS NOT NULL AS revoked FROM refresh_families WHERE user_id = ? ORDER BY created_at")
          .bind(old.userId)
          .all<{ id: string; revoked: number }>()
      ).results;
    const [oldFamily, newFamily] = await families();
    const familyOf = async (token: string): Promise<unknown> =>
      env.DB.prepare("SELECT family_id FROM refresh_tokens WHERE token_hash = ?").bind(await sha256Hex(token)).first();
    expect(await familyOf(oldRetry.refreshToken)).toEqual({ family_id: oldFamily?.id });
    expect(await familyOf(current.refreshToken)).toEqual({ family_id: newFamily?.id });
    // Reuse in the old family signs out only the old family.
    harness.clock.nowMs += refreshRetryWindowMs + 1_000;
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: old.refreshToken } })), 401, "invalid_token");
    expect(await families()).toEqual([
      { id: oldFamily?.id, revoked: 1 },
      { id: newFamily?.id, revoked: 0 },
    ]);
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: oldRetry.refreshToken } })), 401, "invalid_token");
    const renewed: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: current.refreshToken } }));
    expect(renewed.status).toBe(200);
    expect((await harness.call(req("GET", "/v1/me", { token: (await renewed.json<Session>()).accessToken }))).status).toBe(200);
  });

  it("bilinmeyen yenileme jetonu reddedilir ve hiçbir jeton açık metin saklanmaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: randomToken(32) } })), 401, "invalid_token");
    const plain = await env.DB.prepare("SELECT COUNT(*) AS count FROM refresh_tokens WHERE token_hash = ?").bind(session.refreshToken).first<{ count: number }>();
    expect(plain?.count).toBe(0);
  });
});
