// Web oturumunun durum makinesi (saf; tarayıcı yan etkileri src/client/session.ts'te). Her kimlik değişimi (giriş,
// çıkış, silinen oturum) kuşağı (`generation`) bir artırır; yenileme kuşağı korur (aynı oturum ailesi). Yoldaki bir
// isteğin sonucu, başladığı kuşak hâlâ geçerliyse uygulanır: çıkıştan sonra gelen yenileme yanıtı oturumu geri yazamaz.
// Yenileme tek uçuşludur (`refreshing` durumundayken yeni yenileme başlamaz) ve 401 alan istek, reddedilen erişim
// jetonu artık güncel değilse yenilemez, güncel jetonla yeniden dener: kullanılmış yenileme jetonu sunucuya yeniden
// sunulmaz (sunucu bunu çalıntı sayıp oturum ailesini düşürür).

/** Saklanan jetonlar. */
export interface StoredSession {
  readonly accessToken: string;
  readonly refreshToken: string;
  /** Erişim jetonunun bittiği an (Unix ms). */
  readonly accessExpiresAt: number;
}

/** Oturumun durumu. */
export type SessionState =
  | { readonly kind: "signedOut"; readonly generation: number }
  | { readonly kind: "signedIn"; readonly generation: number; readonly tokens: StoredSession }
  | { readonly kind: "refreshing"; readonly generation: number; readonly tokens: StoredSession }
  /** Çıkış isteği yolda: yerel oturum çoktan silindi. */
  | { readonly kind: "signingOut"; readonly generation: number };

/** Oturumu değiştiren olay. `generation` taşıyan olaylar, başladıkları kuşak geçerliyse uygulanır. */
export type SessionEvent =
  | { readonly type: "signedIn"; readonly tokens: StoredSession }
  | { readonly type: "refreshStarted"; readonly generation: number }
  | { readonly type: "refreshSucceeded"; readonly generation: number; readonly tokens: StoredSession }
  /** Sunucu yenileme jetonunu reddetti (400/401): oturum bitti. */
  | { readonly type: "refreshRejected"; readonly generation: number }
  /** Yenileme ağ ya da sunucu hatasıyla bitti: eski jetonlar kalır, sonraki istek yeniden dener. */
  | { readonly type: "refreshFailed"; readonly generation: number }
  | { readonly type: "signOutStarted" }
  | { readonly type: "signOutFinished"; readonly generation: number }
  /** Oturum yerelde silindi (hesap silindi, kopyalanmış sekme). */
  | { readonly type: "cleared" };

/** Bir isteğin önündeki adım: jetonu kullan, (yoldakine katılarak) yenile ya da oturum yok. */
export type SessionTokenAction =
  | { readonly kind: "use"; readonly tokens: StoredSession }
  | { readonly kind: "refresh"; readonly generation: number }
  | { readonly kind: "signedOut" };

/** Erişim jetonu bu kadar süre kala yenilenir. */
export const refreshMarginMs: number = 30_000;

/** Sayfa açılınca saklanan jetonlardan oturum durumu. Saf fonksiyondur. */
export function initialSessionState(stored: StoredSession | null): SessionState {
  return stored === null ? { kind: "signedOut", generation: 0 } : { kind: "signedIn", generation: 0, tokens: stored };
}

/** Durumda saklanması gereken jetonlar (sessionStorage); yoksa null. Saf fonksiyondur. */
export function persistedTokens(state: SessionState): StoredSession | null {
  return state.kind === "signedIn" || state.kind === "refreshing" ? state.tokens : null;
}

/** Durum bir oturum taşıyor mu (üst çubuk ve sayfalar için "giriş yapılmış"). Saf fonksiyondur. */
export function isSignedIn(state: SessionState): boolean {
  return persistedTokens(state) !== null;
}

/**
 * Olayın durumu nasıl değiştirdiği; olay bu durumda geçersizse ya da başka bir kuşağa aitse null (sonuç atılır). Saf
 * fonksiyondur.
 */
export function sessionTransition(state: SessionState, event: SessionEvent): SessionState | null {
  switch (event.type) {
    case "signedIn":
      return { kind: "signedIn", generation: state.generation + 1, tokens: event.tokens };
    case "cleared":
      return { kind: "signedOut", generation: state.generation + 1 };
    case "signOutStarted":
      return isSignedIn(state) ? { kind: "signingOut", generation: state.generation + 1 } : null;
    case "signOutFinished":
      return state.kind === "signingOut" && state.generation === event.generation ? { kind: "signedOut", generation: state.generation } : null;
    case "refreshStarted":
      return state.kind === "signedIn" && state.generation === event.generation ? { kind: "refreshing", generation: state.generation, tokens: state.tokens } : null;
    case "refreshSucceeded":
      return state.kind === "refreshing" && state.generation === event.generation ? { kind: "signedIn", generation: state.generation, tokens: event.tokens } : null;
    case "refreshFailed":
      return state.kind === "refreshing" && state.generation === event.generation ? { kind: "signedIn", generation: state.generation, tokens: state.tokens } : null;
    case "refreshRejected":
      return state.kind === "refreshing" && state.generation === event.generation ? { kind: "signedOut", generation: state.generation + 1 } : null;
  }
}

/** İstekten önce: erişim jetonu süresi dolmak üzereyse (ya da yenileme yoldaysa) yenile, değilse kullan. Saf fonksiyondur. */
export function freshTokenAction(state: SessionState, nowMs: number): SessionTokenAction {
  switch (state.kind) {
    case "signedOut":
    case "signingOut":
      return { kind: "signedOut" };
    case "refreshing":
      return { kind: "refresh", generation: state.generation };
    case "signedIn":
      return state.tokens.accessExpiresAt - refreshMarginMs > nowMs ? { kind: "use", tokens: state.tokens } : { kind: "refresh", generation: state.generation };
  }
}

/**
 * Sunucu `rejectedAccessToken` ile gönderilen isteğe 401 döndü: jeton o arada yenilendiyse güncel jetonla yeniden
 * dene, yenileme yoldaysa ona katıl, güncel jeton reddedildiyse yenile. Saf fonksiyondur.
 */
export function unauthorizedTokenAction(state: SessionState, rejectedAccessToken: string): SessionTokenAction {
  switch (state.kind) {
    case "signedOut":
    case "signingOut":
      return { kind: "signedOut" };
    case "refreshing":
      return { kind: "refresh", generation: state.generation };
    case "signedIn":
      return state.tokens.accessToken === rejectedAccessToken ? { kind: "refresh", generation: state.generation } : { kind: "use", tokens: state.tokens };
  }
}
