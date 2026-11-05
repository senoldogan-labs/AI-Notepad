import Anthropic from "@anthropic-ai/sdk";
import { continueAfterDisconnect, runAfterResponse } from "../background";
import type { Config } from "../config";
import { ApiError, ProviderApiError, isRetryableStatus } from "../errors";
import { jsonResponse } from "../http";
import { type LogFields, errorName, log } from "../log";
import type { MeetingRow } from "../meetings";
import type { AccountLLMAccess } from "../entitlements";
import type { RequestContext } from "../platform";
import { type RetryOptions, withRetries } from "../retry";
import {
  type ReservationCheck,
  type ReservationLimit,
  type TokenUsage,
  type UsageReservation,
  dailyTokenLimit,
  llmReservation,
  llmStreamDeadlineMs,
  meetingLiveTokenLimit,
  meetingTokenLimit,
  monthlyTokenLimit,
  remainingOf,
  reserveUsage,
  settleLLMStatements,
  subscriberAccountTokenLimit,
  tightestLimit,
  trialAccountTokenLimit,
} from "../reservations";
import { recordMeetingFailure, recordOpsEvents } from "../opsEvents";
import { llmCostMicroUsd } from "../usage";
import { type LLMPurpose, liveLLMPurposes, purposeUsageStatement } from "./purpose";
import { type ScreenImageUsage, screenImageUsage } from "./images";
import { type LLMRequest, clampMaxTokens, estimateInputTokens, requestImages, requestTextBytes, upstreamParams } from "./request";
import { type LLMUsageTag, llmUsageStatement, llmUsageTagOf } from "./usageBuckets";
import {
  isAlertDue,
  isWebSearchDisabledError,
  requestedWebSearches,
  reserveWebSearches,
  webSearchDisabledAlertIntervalMs,
  webSearchErrorCodes,
  webSearchMicroUsd,
  webSearchRefundStatement,
  webSearchReservedInputTokens,
  webSearchStatusHeader,
  webSearchUnavailableHeader,
  webSearchesOf,
  withoutWebSearchTool,
} from "./webSearch";

/** Akışsız çağrının zaman aşımı: yanıt başlığı ancak üretim bitince gelir, bu yüzden toplam süredir. */
const messageTimeoutMs: number = 120_000;
/** Akışlı çağrının ilk bayt (yanıt başlığı) zaman aşımı; akışın toplam süresi `llmStreamDeadlineMs` ile sınırlıdır. */
const streamFirstByteTimeoutMs: number = 30_000;

/**
 * Akışın kalan süresi (ms): ayırma anından `llmStreamDeadlineMs` sonrasına dek, en az 0. Akışın açılması (ilk bayt
 * beklemesi ve yeniden denemeler) da bu süreden düşer. Saf fonksiyondur.
 */
export function streamTimeLeftMs(reservedAtMs: number, nowMs: number): number {
  return Math.max(0, reservedAtMs + llmStreamDeadlineMs - nowMs);
}

/**
 * Bu Worker örneğinin son "web araması kapalı" alarmının anı. Alarm örnek başına saatte en çok bir kez yazılır (yeni
 * tablo gerektirmeyen en hafif sınır); sorunun gün içindeki toplam sayısı yönetim panelinin "Sorunlar" sayacındadır
 * (`provider_error` / `anthropic_web_search_disabled`).
 */
let lastWebSearchDisabledAlertAt: number | null = null;

/** Çağrının sonucu ve web aramasının bu çağrıda geri çekilip çekilmediği (`withdrawWebSearch`). */
interface CallResult<T> {
  readonly value: T;
  /** Anthropic aramayı reddetti; istek araçsız yinelendi ve istemciye `x-web-search: unavailable` denir. */
  readonly webSearchWithdrawn: boolean;
}

/** Çağrıya verilen web araması hakkı (`granted`) ve çağrının yaptığı arama sayısı (`used`). */
interface WebSearchCount {
  readonly granted: number;
  readonly used: number;
}

/** Çağrının gerçek maliyeti: tokenlar ve yapılan aramalar (mikro dolar). Saf fonksiyondur. */
export function callCostMicroUsd(usage: TokenUsage, webSearches: number): number {
  return llmCostMicroUsd(usage.inputTokens, usage.outputTokens) + webSearches * webSearchMicroUsd;
}

/** Üst servis çağrısının sonucu: değer ya da istemciye dönecek hata (kesinleştirme her iki durumda yapılmıştır). */
type CallOutcome<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: ApiError };

/**
 * Çağrının bağlı olduğu bütçe: açık bir toplantı (kayıt sırasında ve ek sürede; toplantı bütçesi de düşer) ya da
 * yalnızca hesap (Sor, notu yeniden yazma, düzenleme, görev aracı; kullanıcının günlük ve aylık sınırı ve daha küçük
 * çağrı başı `max_tokens`). `purpose`: çağrının amacı (`x-llm-purpose`); yalnızca amaç başına token toplamına yazılır
 * (bkz. `purposeUsageStatement`), bütçeyi etkilemez.
 */
export type LLMScope =
  | { readonly kind: "meeting"; readonly userId: string; readonly meeting: MeetingRow; readonly purpose: LLMPurpose }
  | { readonly kind: "account"; readonly userId: string; readonly access: AccountLLMAccess; readonly purpose: LLMPurpose };

/**
 * Çağrı başı `max_tokens` sınırı: toplantıda `LLM_MAX_TOKENS`, hesap çağrısında `LLM_ACCOUNT_MAX_TOKENS`; Sor cevabı
 * (`ask_answer`) uzun yapılandırılmış cevap yazabilsin diye `LLM_ASK_MAX_TOKENS`. Saf fonksiyondur.
 */
export function callMaxTokens(config: Config, scope: LLMScope): number {
  if (scope.kind === "meeting") {
    return config.llm.maxTokens;
  }
  return scope.purpose === "ask_answer" ? config.llm.askMaxTokens : config.llm.accountMaxTokens;
}

/** Deneme kullanıcısının toplantısız çağrısı mı (ayrıca küçük günlük sınır). Saf fonksiyondur. */
function isTrialAccountCall(scope: LLMScope): boolean {
  return scope.kind === "account" && scope.access === "trial";
}

/** Abonenin toplantısız çağrısı mı (ayrıca aylık `MONTHLY_ACCOUNT_TOKEN_CAP`). Saf fonksiyondur. */
function isSubscriberAccountCall(scope: LLMScope): boolean {
  return scope.kind === "account" && scope.access === "subscription";
}

/**
 * Çağrının sınırları: toplantı bütçesi (toplantıda; canlı amaçlarda nota ayrılan pay düşülmüş) ya da denemenin günlük /
 * abonenin aylık hesap çağrısı sınırı, sonra kullanıcının aylık ve günlük token sınırı.
 */
function llmLimits(config: Config, scope: LLMScope, now: Date): ReservationLimit[] {
  const scoped: ReservationLimit =
    scope.kind === "meeting"
      ? liveLLMPurposes.includes(scope.purpose)
        ? meetingLiveTokenLimit(scope.meeting.id, now)
        : meetingTokenLimit(scope.meeting.id, now)
      : scope.access === "trial"
        ? trialAccountTokenLimit(config, scope.userId, now)
        : subscriberAccountTokenLimit(config, scope.userId, now);
  return [scoped, monthlyTokenLimit(config, scope.userId, now), dailyTokenLimit(config, scope.userId, now)];
}

/** Çağrının harcaması deneme tavanına da sayılır mı: deneme toplantısı ya da denemedeki hesap çağrısı. Saf fonksiyondur. */
function isTrialSpend(scope: LLMScope): boolean {
  return scope.kind === "meeting" ? scope.meeting.kind === "trial" : scope.access === "trial";
}

/** Log alanı: toplantı kimliği ya da hesap çağrısında null. Saf fonksiyondur. */
function scopeMeetingId(scope: LLMScope): string | null {
  return scope.kind === "meeting" ? scope.meeting.id : null;
}

/**
 * Anthropic istemcisi (dış sistem bağlantısı): yeniden denemeyi SDK değil `withRetries` yapar (uyarı loglanır). Zaman
 * aşımı çağrı başına verilir (`messageTimeoutMs`, `streamFirstByteTimeoutMs`); SDK onu yanıt başlığı gelene dek uygular.
 */
function anthropicClient(context: RequestContext, config: Config): Anthropic {
  return new Anthropic({ apiKey: config.secrets.anthropic, fetch: context.platform.fetch, maxRetries: 0, timeout: messageTimeoutMs });
}

/** Bağlantı hatası ve geçici durumlar (408, 409, 429, 5xx, 529) yeniden denenir. Saf fonksiyondur. */
export function isRetryableAnthropicError(error: unknown): boolean {
  if (error instanceof Anthropic.APIUserAbortError) {
    return false;
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return true;
  }
  return error instanceof Anthropic.APIError && error.status !== undefined && isRetryableStatus(error.status);
}

/** SDK hatasını istemci hatasına çevirir; üst servis mesajı (içerik yankılayabilir) taşınmaz, yalnızca durum loglanır. */
function mapAnthropicError(error: unknown, userId: string, meetingId: string | null): ApiError {
  if (error instanceof Anthropic.APIError) {
    log("error", "anthropic_failed", { userId, meetingId, status: error.status ?? null, requestId: error.requestID ?? null });
    if (error.status !== undefined && !isRetryableStatus(error.status)) {
      return new ProviderApiError("anthropic", "upstream_rejected", `The AI request was rejected (status ${error.status}).`);
    }
    return new ProviderApiError("anthropic", "upstream_unavailable", "The AI service is not responding right now; try again shortly.");
  }
  log("error", "anthropic_failed", { userId, meetingId, error: errorName(error) });
  return new ProviderApiError("anthropic", "upstream_unavailable", "The AI service is not responding right now; try again shortly.");
}

/** Toplam girdi tokenı (önbellek okuma/yazma dahil). Saf fonksiyondur. */
function totalInputTokens(usage: { input_tokens: number | null; cache_creation_input_tokens: number | null; cache_read_input_tokens: number | null }): number {
  return (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0);
}

/**
 * Başarıyla biterse toplantıya ilk not anını (`meeting_sessions.first_note_at`) yazacak çağrının toplantısı: not
 * yazma ve düzenleme istemcide `effort: medium` ile gelir (canlı çeviri ve hızlı özellikler `low`); hesap çağrısında
 * ve `low`'da null. Saf fonksiyondur.
 */
export function noteMeetingIdOf(scope: LLMScope, request: LLMRequest): string | null {
  return scope.kind === "meeting" && request.effort === "medium" ? scope.meeting.id : null;
}

/**
 * Ayırmayı gerçek kullanımla kesinleştirir ve gerçek maliyeti günlük harcamaya ekler (denemedeyse deneme payına da);
 * kullanım aynı işlemde çağrının günlük token kovasına (`usageTag`) ve amaç başına günlük token toplamına da yazılır.
 * `noteMeetingId` verildiyse (başarılı not çağrısı) aynı işlemde toplantının ilk not anı yazılır (yalnızca boşsa).
 * Web aramaları maliyete ve amaç satırına eklenir; verilip kullanılmayan arama hakkı aylık sayaca geri verilir.
 */
async function chargeUsage(
  db: D1Database,
  scope: LLMScope,
  reservation: UsageReservation,
  usage: TokenUsage,
  webSearches: WebSearchCount,
  usageTag: LLMUsageTag,
  noteMeetingId: string | null,
  now: Date,
): Promise<void> {
  const noteStatements: D1PreparedStatement[] =
    noteMeetingId === null
      ? []
      : [db.prepare("UPDATE meeting_sessions SET first_note_at = ? WHERE id = ? AND first_note_at IS NULL").bind(now.getTime(), noteMeetingId)];
  await db.batch([
    llmUsageStatement(db, reservation.day, usageTag, usage),
    ...settleLLMStatements(db, reservation, usage, callCostMicroUsd(usage, webSearches.used), now),
    ...noteStatements,
    ...webSearchRefundStatement(db, scope.userId, reservation.month, webSearches.granted, webSearches.used),
    purposeUsageStatement(db, scope.purpose, usage, webSearches.used, now),
  ]);
  log("info", "llm_usage", {
    userId: scope.userId,
    meetingId: scopeMeetingId(scope),
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    webSearches: webSearches.used,
  });
}

/**
 * İstek gönderildikten sonra başarısız olan çağrı: kullanıcının sayaçlarına bir şey yazılmaz, ayırma kapanır; Anthropic
 * girdiyi işlemiş olabileceği için tahmini girdi maliyeti günlük harcamaya sayılır. Verilen web araması hakkı geri verilir
 * (Anthropic hatalı çağrının aramalarını ücretlendirmez).
 */
async function chargeFailure(db: D1Database, reservation: UsageReservation, estimatedInput: number, grantedWebSearches: number, now: Date): Promise<void> {
  await db.batch([
    ...webSearchRefundStatement(db, reservation.userId, reservation.month, grantedWebSearches, 0),
    ...settleLLMStatements(db, reservation, { inputTokens: 0, outputTokens: 0 }, llmCostMicroUsd(estimatedInput, 0), now),
  ]);
}

/** Anthropic'in hatası "web araması bu kuruluşta kapalı" reddi mi (`isWebSearchDisabledError`). */
function isAnthropicWebSearchDisabled(error: unknown): boolean {
  return error instanceof Anthropic.APIError && isWebSearchDisabledError(error.status, error.error);
}

/**
 * Bilinçli erişilebilirlik güvencesi: Anthropic kuruluşta web aramasını reddettiyse (Console'da kapalı; 400
 * `invalid_request_error`) kullanıcı cevapsız kalmasın diye aynı istek bir kez araçsız yinelenir. Önce bu çağrıya
 * verilen arama hakkı aylık sayaca geri verilir (hiç arama yapılmadı), sorun "Sorunlar" sayacına yazılır ve alarm logu bu
 * Worker örneğinde saatte en çok bir kez yazılır (`lastWebSearchDisabledAlertAt`); istemciye `x-web-search: unavailable`
 * denir ve Sor cevabın altında bunu yazar. Ayırma (bütçe) aynı kalır; kesinleştirme yinelenen çağrının gerçek
 * kullanımıyla yapılır. Reddedilen 400 isteği ücretlendirilmez.
 */
async function withdrawWebSearch(db: D1Database, scope: LLMScope, reservation: UsageReservation, grantedWebSearches: number, now: Date): Promise<void> {
  await db.batch(webSearchRefundStatement(db, scope.userId, reservation.month, grantedWebSearches, 0));
  await recordOpsEvents(db, [{ kind: "provider_error", detail: "anthropic_web_search_disabled" }], now);
  if (isAlertDue(lastWebSearchDisabledAlertAt, now.getTime(), webSearchDisabledAlertIntervalMs)) {
    lastWebSearchDisabledAlertAt = now.getTime();
    log("alert", "anthropic_web_search_disabled", { userId: scope.userId, refundedWebSearches: grantedWebSearches });
  }
}

/**
 * Akışsız çağrı ve kesinleştirmesi (başarıda gerçek kullanım, hatada `chargeFailure`). Anthropic web aramasını
 * kuruluşta reddederse istek bir kez araçsız yinelenir (`withdrawWebSearch`).
 */
async function callMessage(
  db: D1Database,
  client: Anthropic,
  retry: RetryOptions,
  params: Anthropic.MessageCreateParamsNonStreaming,
  scope: LLMScope,
  reservation: UsageReservation,
  estimatedInput: number,
  grantedWebSearches: number,
  usageTag: LLMUsageTag,
  noteMeetingId: string | null,
  now: Date,
): Promise<CallOutcome<CallResult<Anthropic.Message>>> {
  let message: Anthropic.Message;
  try {
    message = await withRetries(retry, (): Promise<Anthropic.Message> => client.messages.create(params, { timeout: messageTimeoutMs }));
  } catch (error: unknown) {
    if (grantedWebSearches > 0 && isAnthropicWebSearchDisabled(error)) {
      await withdrawWebSearch(db, scope, reservation, grantedWebSearches, now);
      const retried: CallOutcome<CallResult<Anthropic.Message>> = await callMessage(
        db, client, retry, withoutWebSearchTool(params), scope, reservation, estimatedInput, 0, usageTag, noteMeetingId, now,
      );
      return retried.ok ? { ok: true, value: { value: retried.value.value, webSearchWithdrawn: true } } : retried;
    }
    await chargeFailure(db, reservation, estimatedInput, grantedWebSearches, now);
    return { ok: false, error: mapAnthropicError(error, scope.userId, scopeMeetingId(scope)) };
  }
  logWebSearchErrors(scope, webSearchErrorCodes(message.content));
  const usage: TokenUsage = { inputTokens: totalInputTokens(message.usage), outputTokens: message.usage.output_tokens };
  const webSearches: WebSearchCount = { granted: grantedWebSearches, used: webSearchesOf(message.usage) };
  await chargeUsage(db, scope, reservation, usage, webSearches, usageTag, noteMeetingId, now);
  return { ok: true, value: { value: message, webSearchWithdrawn: false } };
}

/**
 * Hatalı web aramaları (`web_search_tool_result_error`) yalnız kodlarıyla loglanır: yanıt 200'dür, model cevabı yine yazar
 * ve hatalı arama ücretlendirilmez (kullanım `web_search_requests`'ten sayılır). Sorgu ve içerik yazılmaz.
 */
function logWebSearchErrors(scope: LLMScope, codes: readonly string[]): void {
  if (codes.length > 0) {
    log("warn", "web_search_tool_errors", { userId: scope.userId, meetingId: scopeMeetingId(scope), codes: codes.join(",") });
  }
}

/** Anthropic akışı. */
type MessageStream = AsyncIterable<Anthropic.RawMessageStreamEvent> & { controller: AbortController };

/** İstemciye giden akış: yanıt gövdesi (`readable`), vekilin yazdığı uç (`writable`) ve akışı hatayla kesme (`cut`). */
interface ClientStream {
  readonly readable: ReadableStream<Uint8Array>;
  readonly writable: WritableStream<Uint8Array>;
  /**
   * Akışı hatayla keser: istemci okumadığı için bekleyen yazım da reddedilir (`writer.abort` süren yazımı bekler,
   * okumayan istemcide hiç bitmez).
   */
  readonly cut: (reason: Error) => void;
}

/** Yeni istemci akışı (kimlik dönüşümü; geri basınç istemcinin okumasıyla). */
function clientStream(): ClientStream {
  const holder: { controller: TransformStreamDefaultController<Uint8Array> | null } = { controller: null };
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>({
    start(controller: TransformStreamDefaultController<Uint8Array>): void {
      holder.controller = controller;
    },
  });
  const controller: TransformStreamDefaultController<Uint8Array> | null = holder.controller;
  if (controller === null) {
    throw new Error("TransformStream start did not run synchronously.");
  }
  return { readable, writable, cut: (reason: Error): void => controller.error(reason) };
}

/**
 * Akışı açar (ilk bayt zaman aşımıyla); açılamazsa `chargeFailure` ile kesinleştirir. Anthropic web aramasını kuruluşta
 * reddederse (yanıt başlığından önce gelir) akış bir kez araçsız açılır (`withdrawWebSearch`).
 */
async function openStream(
  db: D1Database,
  client: Anthropic,
  retry: RetryOptions,
  params: Anthropic.MessageCreateParamsNonStreaming,
  scope: LLMScope,
  reservation: UsageReservation,
  estimatedInput: number,
  grantedWebSearches: number,
  now: Date,
): Promise<CallOutcome<CallResult<MessageStream>>> {
  try {
    const stream: MessageStream = await withRetries(retry, () => client.messages.create({ ...params, stream: true }, { timeout: streamFirstByteTimeoutMs }));
    return { ok: true, value: { value: stream, webSearchWithdrawn: false } };
  } catch (error: unknown) {
    if (grantedWebSearches > 0 && isAnthropicWebSearchDisabled(error)) {
      await withdrawWebSearch(db, scope, reservation, grantedWebSearches, now);
      const retried: CallOutcome<CallResult<MessageStream>> = await openStream(db, client, retry, withoutWebSearchTool(params), scope, reservation, estimatedInput, 0, now);
      return retried.ok ? { ok: true, value: { value: retried.value.value, webSearchWithdrawn: true } } : retried;
    }
    await chargeFailure(db, reservation, estimatedInput, grantedWebSearches, now);
    return { ok: false, error: mapAnthropicError(error, scope.userId, scopeMeetingId(scope)) };
  }
}

/**
 * Haiku vekili. Girdi tahmini sınırı aşarsa 413. `max_tokens` çağrı başı sınırla (toplantıda `LLM_MAX_TOKENS`, hesap
 * çağrısında daha küçük `LLM_ACCOUNT_MAX_TOKENS`) ve en dar kalan sınıra (`llmLimits`) göre kısılır; `tahmin +
 * max_tokens` tek koşullu ifadeyle süreli bir ayırma satırı olarak ayrılır (eşzamanlı çağrılar ve yeniden başlatılan
 * toplantılar sınırları aşamaz). Üst çağrı ve kesinleştirme `continueAfterDisconnect` ile istemci koparsa da tamamlanır:
 * yanıt bitince gerçek kullanım yazılır; üst çağrı başarısızsa tahmini girdi maliyeti harcamaya sayılır; akış kesilirse
 * ayrılan miktar harcanmış sayılır. Worker kesinleştiremeden durursa ayırmanın süresi dolar (bkz. `reservations.ts`).
 */
export async function proxyLLM(db: D1Database, context: RequestContext, config: Config, scope: LLMScope, request: LLMRequest): Promise<Response> {
  // The body of an image-carrying purpose is read with a larger limit (`llmBodyLimitBytes`); its text is not.
  const textBytes: number = requestTextBytes(request);
  if (textBytes > config.llm.maxRequestBytes) {
    throw new ApiError("payload_too_large", `The request text can be at most ${config.llm.maxRequestBytes} bytes (received ${textBytes}).`);
  }
  const images: ScreenImageUsage = screenImageUsage(requestImages(request), scope.purpose);
  const estimatedInput: number = estimateInputTokens(request, images.tokens);
  if (estimatedInput > config.llm.maxInputTokens) {
    throw new ApiError("payload_too_large", `Input is too long (an estimated ${estimatedInput} tokens; the limit is ${config.llm.maxInputTokens}).`);
  }
  // Web araması yalnız Sor cevabında (başka amaçta 400, dışarı istek gitmez); arama sonuçları girdi tokenı olur.
  // Amaç denetimi politika kapalıyken de yapılır (Sor dışında araç istemek yine `invalid_body`).
  const askedSearches: number = requestedWebSearches(request.tools, scope.purpose);
  const requestedSearches: number = config.llm.webSearchPolicy === "on" ? askedSearches : 0;
  const searchInput: number = requestedSearches * webSearchReservedInputTokens;
  const now: Date = context.platform.now();
  const limits: ReservationLimit[] = llmLimits(config, scope, now);
  const tightest: { readonly remaining: number; readonly error: ApiError } = tightestLimit(limits, await remainingOf(db, limits));
  const callMax: number = callMaxTokens(config, scope);
  const maxTokens: number = clampMaxTokens(request.max_tokens, callMax, tightest.remaining, estimatedInput + searchInput, tightest.error);
  const reservedTokens: number = estimatedInput + searchInput + maxTokens;
  const reservation: UsageReservation = llmReservation(
    {
      userId: scope.userId,
      meetingId: scopeMeetingId(scope),
      tokens: reservedTokens,
      trialAccountCall: isTrialAccountCall(scope),
      subscriberAccountCall: isSubscriberAccountCall(scope),
      estimatedMicroUsd: llmCostMicroUsd(estimatedInput + searchInput, maxTokens) + requestedSearches * webSearchMicroUsd,
      trialSpend: isTrialSpend(scope),
    },
    now,
  );
  await reserveUsage(
    db,
    reservation,
    limits.map((limit: ReservationLimit): ReservationCheck => ({ limit, amount: reservedTokens })),
  );
  // Aylık arama hakkı ayırmadan sonra düşülür (ayırma reddedilirse hak harcanmaz); hak bittiyse araç sunulmaz ve
  // istemci `x-web-search: cap_reached` ile bunu söyler.
  const grantedSearches: number = await reserveWebSearches(db, scope.userId, requestedSearches, config.llm.monthlyWebSearchCap, now);
  const searchHeaders: Readonly<Record<string, string>> =
    config.llm.webSearchPolicy === "on" || askedSearches === 0 ? webSearchStatusHeader(requestedSearches, grantedSearches) : webSearchUnavailableHeader;
  const client: Anthropic = anthropicClient(context, config);
  const params: Anthropic.MessageCreateParamsNonStreaming = upstreamParams(request, maxTokens, grantedSearches);
  const retry: RetryOptions = {
    service: "anthropic",
    attempts: 3,
    baseDelayMs: context.platform.retryBaseDelayMs,
    isRetryable: isRetryableAnthropicError,
    recordRetry: context.platform.recordRetry,
  };
  const logFields: LogFields = { userId: scope.userId, meetingId: scopeMeetingId(scope), reservationId: reservation.id };
  if (images.count > 0) {
    // Only the count, size and estimated tokens: the images themselves are never logged or stored. Their real tokens
    // are part of the call's `input_tokens` and count against the meeting, daily and monthly budgets like any input.
    log("info", "llm_screen_images", { ...logFields, purpose: scope.purpose, images: images.count, imageBytes: images.bytes, estimatedImageTokens: images.tokens });
  }

  const noteMeetingId: string | null = noteMeetingIdOf(scope, request);
  const usageTag: LLMUsageTag = llmUsageTagOf(scope.kind, request);

  if (request.stream !== true) {
    const outcome: CallOutcome<CallResult<Anthropic.Message>> = await continueAfterDisconnect(
      context,
      callMessage(db, client, retry, params, scope, reservation, estimatedInput, grantedSearches, usageTag, noteMeetingId, now),
      "llm_settle_failed",
      logFields,
    );
    if (!outcome.ok) {
      throw outcome.error;
    }
    const response: Response = jsonResponse(200, outcome.value.value);
    for (const [name, value] of Object.entries(outcome.value.webSearchWithdrawn ? webSearchUnavailableHeader : searchHeaders)) {
      response.headers.set(name, value);
    }
    return response;
  }

  const opened: CallOutcome<CallResult<MessageStream>> = await continueAfterDisconnect(
    context,
    openStream(db, client, retry, params, scope, reservation, estimatedInput, grantedSearches, now),
    "llm_settle_failed",
    logFields,
  );
  if (!opened.ok) {
    throw opened.error;
  }
  const toClient: ClientStream = clientStream();
  runAfterResponse(
    context,
    pumpStream(
      db,
      opened.value.value,
      toClient,
      streamTimeLeftMs(reservation.createdAt, context.platform.now().getTime()),
      scope,
      reservation,
      estimatedInput,
      maxTokens,
      opened.value.webSearchWithdrawn ? 0 : grantedSearches,
      usageTag,
      noteMeetingId,
      now,
    ),
    "llm_settle_failed",
    logFields,
  );
  return new Response(toClient.readable, {
    status: 200,
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-store",
      ...(opened.value.webSearchWithdrawn ? webSearchUnavailableHeader : searchHeaders),
    },
  });
}

/** SSE olayı satırları. Saf fonksiyondur. */
export function sseEvent(type: string, data: object): string {
  return `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
}

/**
 * Anthropic akışını olay olay istemciye aktarır ve kullanımı sayar (`message_start` girdi, `message_delta` çıktı).
 * Akış ortasında hata olursa istemciye `error` olayı gider (üst servis mesajı olmadan); hata servis sayacına ve
 * (toplantıdaysa) toplantıya yazılır. İstemci koparsa üst akış iptal edilir. Akış `timeLeftMs` içinde bitmezse
 * (`llmStreamDeadlineMs`; ör. okumayan istemci akışı bekletiyor) üst akış iptal edilir, istemciye giden akış kesilir.
 * Akış tamamlanmadıysa ayrılan bütçenin tamamı harcanmış sayılır; yalnızca tamamlanan akış toplantının ilk not anını
 * yazar (`noteMeetingId`).
 */
async function pumpStream(
  db: D1Database,
  stream: MessageStream,
  client: ClientStream,
  timeLeftMs: number,
  scope: LLMScope,
  reservation: UsageReservation,
  estimatedInput: number,
  maxTokens: number,
  grantedWebSearches: number,
  usageTag: LLMUsageTag,
  noteMeetingId: string | null,
  now: Date,
): Promise<void> {
  const writer: WritableStreamDefaultWriter<Uint8Array> = client.writable.getWriter();
  const encoder: TextEncoder = new TextEncoder();
  let inputTokens: number | null = null;
  let outputTokens: number | null = null;
  let webSearches: number = 0;
  /** Akıştaki hatalı web aramalarının kodları (`logWebSearchErrors`). */
  const searchErrors: string[] = [];
  let completed: boolean = false;
  let clientGone: boolean = false;
  let deadlineHit: boolean = false;
  /** İstemciye yazar; istemci koptuysa (ya da süre dolup akış kesildiyse) üst akışı iptal eder ve false döndürür. */
  const forward = async (text: string): Promise<boolean> => {
    try {
      await writer.write(encoder.encode(text));
      return true;
    } catch {
      stream.controller.abort();
      if (!deadlineHit) {
        clientGone = true;
        log("info", "llm_client_disconnected", { userId: scope.userId, meetingId: scopeMeetingId(scope) });
      }
      return false;
    }
  };
  // Süre dolunca üst akış iptal edilir ve istemciye giden akış kesilir: okumayan istemcinin bekleyen yazımı da biter.
  const deadline: ReturnType<typeof setTimeout> = setTimeout((): void => {
    deadlineHit = true;
    log("warn", "llm_stream_deadline_exceeded", { userId: scope.userId, meetingId: scopeMeetingId(scope), deadlineMs: llmStreamDeadlineMs });
    stream.controller.abort();
    client.cut(new Error("LLM stream deadline exceeded"));
  }, timeLeftMs);
  try {
    for await (const event of stream) {
      if (event.type === "message_start") {
        inputTokens = totalInputTokens(event.message.usage);
      } else if (event.type === "message_delta") {
        outputTokens = event.usage.output_tokens;
        webSearches = Math.max(webSearches, webSearchesOf(event.usage));
        if (typeof event.usage.input_tokens === "number") {
          inputTokens = Math.max(inputTokens ?? 0, totalInputTokens(event.usage));
        }
      } else if (event.type === "message_stop") {
        completed = true;
        logWebSearchErrors(scope, searchErrors);
      } else if (event.type === "content_block_start") {
        searchErrors.push(...webSearchErrorCodes([event.content_block]));
      }
      if (!(await forward(sseEvent(event.type, event)))) {
        break;
      }
    }
  } catch (error: unknown) {
    if (!clientGone && !deadlineHit) {
      stream.controller.abort();
      const retryable: boolean = isRetryableAnthropicError(error);
      log("warn", "anthropic_stream_failed", { userId: scope.userId, meetingId: scopeMeetingId(scope), error: errorName(error), retryable });
      const errorType: string = retryable ? "overloaded_error" : "api_error";
      await forward(sseEvent("error", { type: "error", error: { type: errorType, message: "The AI stream was interrupted." } }));
      await recordOpsEvents(db, [{ kind: "provider_error", detail: "anthropic" }], now);
      if (scope.kind === "meeting") {
        await recordMeetingFailure(db, scope.userId, scope.meeting.id, "upstream_unavailable:anthropic", now);
      }
    }
  } finally {
    clearTimeout(deadline);
    const finished: boolean = completed && outputTokens !== null;
    const usage: TokenUsage = finished
      ? { inputTokens: inputTokens ?? estimatedInput, outputTokens: outputTokens ?? maxTokens }
      : { inputTokens: inputTokens ?? estimatedInput, outputTokens: maxTokens };
    // Tamamlanmayan akışta verilen arama hakkının tamamı yapılmış sayılır (tokenlar gibi üstten).
    const searches: WebSearchCount = { granted: grantedWebSearches, used: finished ? webSearches : grantedWebSearches };
    // Akış kesinleştirmeden önce kapanır: istemci (ör. parça parça yazılan notun sonraki isteği) D1 yazımını beklemez.
    // Kesinleştirme `waitUntil` içinde sürer ve kapatma başarısız olsa da yapılır; o ana dek ayırma açık kalır, yani
    // sonraki çağrının bütçe denetimi bu çağrıyı ayrılan üst sınırla sayar (fazla harcamaya izin vermez).
    try {
      if (!clientGone && !deadlineHit) {
        await writer.close();
      }
    } finally {
      await chargeUsage(db, scope, reservation, usage, searches, usageTag, finished ? noteMeetingId : null, now);
    }
  }
}
