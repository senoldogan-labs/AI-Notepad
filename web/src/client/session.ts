// Oturum: jetonlar bellekte ve sekmeye özgü sessionStorage'da tutulur (localStorage yok; sekme kapanınca biter).
// Erişim jetonu süresi dolmadan ve sunucu 401 döndüğünde bir kez `/v1/auth/refresh` ile yenilenir; yenileme jetonu
// her yenilemede döner (eski jeton yeniden kullanılırsa sunucu tüm oturum ailesini düşürür). Kopyalanan sekme
// sessionStorage'ı da kopyalar; iki sekme aynı yenileme jetonunu kullanınca sunucu bunu çalıntı sayıp ikisini de
// düşürürdü. Bu yüzden her sekmenin kimliği vardır ve kopya, sahibi açıkken kopyalanmış oturumu kullanmadan siler
// (`claimTabSession`). Oturumun durumu ve kuşağı src/lib/session-state.ts'teki saf geçişlerle değişir: çıkıştan ya da
// yeni girişten sonra gelen yenileme yanıtı atılır, yenileme tek uçuşludur.
import { type ApiCall, ApiRequestError, type RawResponse, type SessionTokens, parseSession, send } from "./api";
import {
  type SessionEvent,
  type SessionState,
  type SessionTokenAction,
  type StoredSession,
  freshTokenAction,
  initialSessionState,
  isSignedIn,
  persistedTokens,
  sessionTransition,
  unauthorizedTokenAction,
} from "../lib/session-state";

const storageKey: string = "gistsmith.session";
/** Sekmenin kimliği (sessionStorage; kopyalanan sekmeye de kopyalanır). */
const tabKey: string = "gistsmith.tab";
/** Sekmeler arası soru ve cevap kanalı. */
const tabChannelName: string = "gistsmith.tabs";
/** Sahip sekmenin cevabı için beklenen süre. */
const tabClaimWaitMs: number = 150;

/** Sekmeler arası ileti: "bu kimlik kimin?" ve "benim". */
interface TabMessage {
  readonly type: "who" | "mine";
  readonly tabId: string;
}

/** İletinin biçimi doğru mu. Saf fonksiyondur. */
function isTabMessage(value: unknown): value is TabMessage {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const candidate: { type?: unknown; tabId?: unknown } = value as { type?: unknown; tabId?: unknown };
  return (candidate.type === "who" || candidate.type === "mine") && typeof candidate.tabId === "string";
}

/** Oturum yok ya da yenilenemedi: kullanıcı yeniden giriş yapmalı. */
export class SignedOutError extends Error {
  override readonly name: string = "SignedOutError";
}

/** Oturumun durumu; sayfada ilk kullanımda sessionStorage'dan okunur. */
let state: SessionState | null = null;
let claiming: Promise<void> | null = null;
/** Yoldaki yenileme ve başladığı kuşak (tek uçuş: aynı kuşaktaki çağrılar bu sözü paylaşır). */
let inflightRefresh: { readonly generation: number; readonly promise: Promise<void> } | null = null;
/** Bir isteğin önünde en çok kaç kez yenilenir (her yenilemeden sonra durum yeniden değerlendirilir). */
const maxRefreshRounds: number = 3;

/** Sunucu oturumunu saklanacak biçime çevirir. Saf fonksiyondur. */
function toStored(tokens: SessionTokens, nowMs: number): StoredSession {
  return { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, accessExpiresAt: nowMs + tokens.expiresIn * 1000 };
}

/** sessionStorage'daki oturumu okur; bozuksa siler ve null döner. */
function readStored(): StoredSession | null {
  const raw: string | null = sessionStorage.getItem(storageKey);
  if (raw === null) {
    return null;
  }
  try {
    const parsed: { accessToken?: string; refreshToken?: string; accessExpiresAt?: number } = JSON.parse(raw) as {
      accessToken?: string;
      refreshToken?: string;
      accessExpiresAt?: number;
    };
    if (typeof parsed.accessToken === "string" && typeof parsed.refreshToken === "string" && typeof parsed.accessExpiresAt === "number") {
      return { accessToken: parsed.accessToken, refreshToken: parsed.refreshToken, accessExpiresAt: parsed.accessExpiresAt };
    }
  } catch (error: unknown) {
    console.warn("session_corrupt", { error: error instanceof Error ? error.message : String(error) });
  }
  sessionStorage.removeItem(storageKey);
  return null;
}

/** Geçerli durum (ilk çağrıda sessionStorage'dan okunur). */
function currentState(): SessionState {
  if (state === null) {
    state = initialSessionState(readStored());
  }
  return state;
}

/**
 * Olayı uygular ve sessionStorage'ı yeni duruma eşitler. Olay bu durumda geçersizse ya da eski bir kuşağa aitse hiçbir
 * şey değişmez ve false döner (eski isteğin sonucu atılır).
 */
function apply(event: SessionEvent): boolean {
  const previous: SessionState = currentState();
  const next: SessionState | null = sessionTransition(previous, event);
  if (next === null) {
    console.warn("session_event_dropped", { event: event.type, state: previous.kind, generation: previous.generation });
    return false;
  }
  state = next;
  const tokens: StoredSession | null = persistedTokens(next);
  if (tokens === null) {
    sessionStorage.removeItem(storageKey);
  } else {
    sessionStorage.setItem(storageKey, JSON.stringify(tokens));
  }
  return true;
}

/** Girişten dönen oturumu saklar (yeni kuşak). */
export function saveSession(tokens: SessionTokens): void {
  apply({ type: "signedIn", tokens: toStored(tokens, Date.now()) });
}

/** Oturumu siler (hesap silme, kopyalanmış sekme); yoldaki yenilemenin sonucu artık yazılmaz. */
export function clearSession(): void {
  apply({ type: "cleared" });
}

/** Bu sekmede oturum var mı. */
export function hasSession(): boolean {
  return isSignedIn(currentState());
}

/** Yeni sekme kimliği yazar ve döner. */
function newTabId(): string {
  const tabId: string = crypto.randomUUID();
  sessionStorage.setItem(tabKey, tabId);
  return tabId;
}

/**
 * Oturumu kullanmadan önce çağrılır: bu sekme kopyaysa (aynı kimliğin sahibi açık bir sekmede cevap verir) kopyalanmış
 * oturum silinir ve sekme yeni kimlik alır; kullanıcı bu sekmede yeniden giriş yapar. Sonra sekme kendi kimliği
 * soruldukça "benim" diye cevap verir. BroadcastChannel yoksa (çok eski tarayıcı) kopya algılanamaz ve uyarı loglanır.
 */
export function claimTabSession(): Promise<void> {
  if (claiming === null) {
    claiming = claimOnce();
  }
  return claiming;
}

/** Sayfada bir kez çalışan sahiplik denetimi (üst çubuk ve sayfa betiği aynı sözü paylaşır; ikinci kanal kendi
 * sorusuna cevap vermez). */
async function claimOnce(): Promise<void> {
  if (typeof BroadcastChannel === "undefined") {
    console.warn("tab_claim_unavailable", { reason: "BroadcastChannel yok" });
    return;
  }
  const channel: BroadcastChannel = new BroadcastChannel(tabChannelName);
  let tabId: string = sessionStorage.getItem(tabKey) ?? newTabId();
  const duplicate: boolean = await new Promise((resolve: (found: boolean) => void): void => {
    const onAnswer = (event: MessageEvent): void => {
      if (isTabMessage(event.data) && event.data.type === "mine" && event.data.tabId === tabId) {
        channel.removeEventListener("message", onAnswer);
        resolve(true);
      }
    };
    channel.addEventListener("message", onAnswer);
    channel.postMessage({ type: "who", tabId } satisfies TabMessage);
    setTimeout((): void => {
      channel.removeEventListener("message", onAnswer);
      resolve(false);
    }, tabClaimWaitMs);
  });
  if (duplicate) {
    console.warn("tab_session_duplicate", { action: "kopyalanan oturum silindi" });
    clearSession();
    tabId = newTabId();
  }
  channel.addEventListener("message", (event: MessageEvent): void => {
    if (isTabMessage(event.data) && event.data.type === "who" && event.data.tabId === sessionStorage.getItem(tabKey)) {
      channel.postMessage({ type: "mine", tabId: event.data.tabId } satisfies TabMessage);
    }
  });
}

/**
 * `generation` kuşağının oturumunu yeniler; aynı kuşakta yoldaki yenileme varsa ona katılır. Sonuç yalnızca kuşak hâlâ
 * geçerliyse yazılır (çıkış ya da yeni girişten sonra gelen yanıt atılır). Sunucu jetonu reddederse oturum biter ve
 * `SignedOutError`; ağ hatasında eski jetonlar kalır ve hata fırlatılır.
 */
function refresh(generation: number): Promise<void> {
  if (inflightRefresh !== null && inflightRefresh.generation === generation) {
    return inflightRefresh.promise;
  }
  const current: SessionState = currentState();
  if (current.kind !== "signedIn" || current.generation !== generation) {
    return Promise.reject(new Error(`Yenileme başlatılamadı: durum ${current.kind}, kuşak ${current.generation}, istenen kuşak ${generation}.`));
  }
  apply({ type: "refreshStarted", generation });
  const promise: Promise<void> = (async (): Promise<void> => {
    const path: string = "/v1/auth/refresh";
    try {
      const response: RawResponse = await send({ method: "POST", path, body: { refreshToken: current.tokens.refreshToken }, accessToken: null, attempts: 1 });
      apply({ type: "refreshSucceeded", generation, tokens: toStored(parseSession(response, path), Date.now()) });
    } catch (error: unknown) {
      if (error instanceof ApiRequestError && (error.status === 401 || error.status === 400)) {
        if (apply({ type: "refreshRejected", generation })) {
          throw new SignedOutError(`Oturum yenilenemedi (${error.code}).`);
        }
        // Bu arada çıkış ya da yeni giriş oldu: eski ailenin reddi geçerli oturumu bitirmez, çağıran durumu yeniden okur.
        return;
      }
      apply({ type: "refreshFailed", generation });
      throw error;
    } finally {
      if (inflightRefresh !== null && inflightRefresh.generation === generation) {
        inflightRefresh = null;
      }
    }
  })();
  inflightRefresh = { generation, promise };
  return promise;
}

/**
 * `decide`'ın seçtiği adımı yürütür: jetonu kullanır ya da yeniler; her yenilemeden sonra durum yeniden değerlendirilir
 * (bu arada çıkış ya da yeni giriş olmuş olabilir). Oturum yoksa `SignedOutError`.
 */
async function resolveTokens(decide: (current: SessionState) => SessionTokenAction): Promise<StoredSession> {
  for (let round: number = 0; round <= maxRefreshRounds; round += 1) {
    const action: SessionTokenAction = decide(currentState());
    if (action.kind === "use") {
      return action.tokens;
    }
    if (action.kind === "signedOut") {
      throw new SignedOutError("Bu sekmede oturum yok.");
    }
    await refresh(action.generation);
  }
  throw new Error(`Oturum ${maxRefreshRounds} yenilemeden sonra da kullanılabilir jeton vermedi.`);
}

/** Kullanıma hazır oturum: süresi dolmak üzereyse önce yenilenir. Oturum yoksa `SignedOutError`. */
function freshSession(): Promise<StoredSession> {
  return resolveTokens((current: SessionState): SessionTokenAction => freshTokenAction(current, Date.now()));
}

/** Kimlikli istek tanımı (jeton oturumdan eklenir). */
export type AuthorizedCall = Omit<ApiCall, "accessToken">;

/**
 * Kimlikli istek: erişim jetonu eklenir; sunucu 401 dönerse istek bir kez tekrarlanır. Jeton o arada başka bir istekle
 * yenilendiyse güncel jeton kullanılır; değilse önce yenilenir (kullanılmış yenileme jetonu yeniden sunulmaz).
 */
export async function authorizedSend(call: AuthorizedCall): Promise<RawResponse> {
  const session: StoredSession = await freshSession();
  try {
    return await send({ ...call, accessToken: session.accessToken });
  } catch (error: unknown) {
    if (!(error instanceof ApiRequestError) || error.status !== 401) {
      throw error;
    }
  }
  const renewed: StoredSession = await resolveTokens((current: SessionState): SessionTokenAction => unauthorizedTokenAction(current, session.accessToken));
  return send({ ...call, accessToken: renewed.accessToken });
}

/**
 * Çıkış: yerel oturum hemen silinir (yoldaki yenilemenin sonucu artık yazılmaz), sonra sunucuda oturum ailesi
 * düşürülür. Sunucu hatası fırlatılır ama yerel çıkışı geri almaz. Oturum yoksa hiçbir şey yapılmaz.
 */
export async function signOut(): Promise<void> {
  const tokens: StoredSession | null = persistedTokens(currentState());
  if (tokens === null || !apply({ type: "signOutStarted" })) {
    return;
  }
  const generation: number = currentState().generation;
  try {
    await send({ method: "POST", path: "/v1/auth/logout", body: { refreshToken: tokens.refreshToken }, accessToken: null, attempts: 2 });
  } finally {
    apply({ type: "signOutFinished", generation });
  }
}
