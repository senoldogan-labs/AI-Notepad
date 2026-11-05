import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { ApiError } from "../errors";
import { monthKey } from "../usage";
import type { LLMPurpose } from "./purpose";

// Sor'da web araması (Anthropic'in sunucu tarafı `web_search` aracı). İstemci aracı yalnız Sor cevabında
// (`x-llm-purpose: ask_answer`) ve "Sor'da web aramasına izin ver" açıkken ister; sunucu cevap başına arama sayısını
// (`webSearchMaxUsesPerAnswer`) ve kullanıcının aylık arama sınırını (`MONTHLY_WEB_SEARCH_CAP`) kendisi uygular.
// Aramayı Anthropic yapar: modelin sorudan türettiği arama sorgusu Anthropic'in arama sağlayıcısına gider (gizlilik
// politikası, bölüm 3 ve 8). Sunucu sorguyu ya da sonuçları saklamaz ve loglamaz; yalnızca arama sayısını sayar.

/** Aracın sürümü: dinamik süzmeli sürüm; Haiku 5.5 dahil güncel modellerde. */
export const webSearchToolType = "web_search_20260209" as const;

/** Cevap başına en çok arama (istemci de bunu ister; fazlası 400). */
export const webSearchMaxUsesPerAnswer: number = 3;

/** Arama başına ücret (Anthropic: 1000 aramada 10 $), mikro dolar. */
export const webSearchMicroUsd: number = 10_000;

/**
 * Arama başına önceden ayrılan girdi tokenı: sonuçlar sonraki örneklemede girdi olarak sayılır (doğrudan aramada
 * sonuç sayfalarının özetleri; ölçülen tipik değer 5–15 K). Bütçe denetimi için üstten tahmindir; kesinleştirme gerçek
 * `input_tokens`'ı yazar.
 */
export const webSearchReservedInputTokens: number = 20_000;

/** İstemcinin istediği web araması aracı: yalnızca tür, ad ve 1–3 arama. */
export const webSearchToolSchema = z.strictObject({
  type: z.literal(webSearchToolType),
  name: z.literal("web_search"),
  max_uses: z.number().int().min(1).max(webSearchMaxUsesPerAnswer),
});

export type WebSearchToolRequest = z.output<typeof webSearchToolSchema>;

/**
 * İsteğin istediği arama sayısı: araç yoksa 0. Araç yalnız Sor cevabında kabul edilir; başka amaçta `invalid_body`
 * (dışarı istek gitmez). Saf fonksiyondur.
 */
export function requestedWebSearches(tools: readonly WebSearchToolRequest[] | undefined, purpose: LLMPurpose): number {
  const tool: WebSearchToolRequest | undefined = tools?.[0];
  if (tool === undefined) {
    return 0;
  }
  if (purpose !== "ask_answer") {
    throw new ApiError("invalid_body", "Web search is only available for Ask answers (x-llm-purpose: ask_answer).");
  }
  return tool.max_uses;
}

/** Bu ay kalan arama hakkına göre verilecek arama sayısı: istenenden ve kalandan küçüğü. Saf fonksiyondur. */
export function webSearchGrant(requested: number, usedThisMonth: number, monthlyCap: number): number {
  return Math.max(0, Math.min(requested, monthlyCap - usedThisMonth));
}

/**
 * Kullanıcının bu ayki arama hakkından `requested` kadarını (kalan daha azsa kalan kadarını) önceden düşer ve verilen
 * sayıyı döndürür; hak yoksa 0 (araç sunulmaz). Düşme tek koşullu ifadedir: eşzamanlı cevaplar sınırı aşamaz (yarışı
 * kaybeden 0 alır). Kullanılmayan pay kesinleştirmede geri verilir (`webSearchRefundStatement`).
 */
export async function reserveWebSearches(db: D1Database, userId: string, requested: number, monthlyCap: number, now: Date): Promise<number> {
  if (requested === 0) {
    return 0;
  }
  const month: string = monthKey(now);
  const row: { web_searches: number } | null = await db
    .prepare("SELECT web_searches FROM monthly_usage WHERE user_id = ? AND month = ?")
    .bind(userId, month)
    .first<{ web_searches: number }>();
  const grant: number = webSearchGrant(requested, row?.web_searches ?? 0, monthlyCap);
  if (grant === 0) {
    return 0;
  }
  const result: D1Result = await db
    .prepare(
      `INSERT INTO monthly_usage (user_id, month, web_searches) VALUES (?1, ?2, ?3)
       ON CONFLICT(user_id, month) DO UPDATE SET web_searches = web_searches + excluded.web_searches
       WHERE web_searches + excluded.web_searches <= ?4`,
    )
    .bind(userId, month, grant, monthlyCap)
    .run();
  return result.meta.changes > 0 ? grant : 0;
}

/**
 * Kesinleşen çağrıda verilen paydan kullanılmayanı (`granted - used`) aylık arama sayacına geri verir; geri verilecek
 * yoksa ifade yok. Ay, ayırmanın ayıdır. Saf fonksiyondur.
 */
export function webSearchRefundStatement(db: D1Database, userId: string, month: string, granted: number, used: number): D1PreparedStatement[] {
  const refund: number = granted - Math.min(used, granted);
  if (refund <= 0) {
    return [];
  }
  return [db.prepare("UPDATE monthly_usage SET web_searches = MAX(0, web_searches - ?) WHERE user_id = ? AND month = ?").bind(refund, userId, month)];
}

/** Anthropic'e giden araç: doğrudan çağrı (kod yürütme yok; sunucu döngüsü en çok `grant + 1` adım). Saf fonksiyondur. */
export function upstreamWebSearchTool(grant: number): Anthropic.WebSearchTool20260209 {
  return { type: webSearchToolType, name: "web_search", max_uses: grant, allowed_callers: ["direct"] };
}

/** Kullanımın yaptığı arama sayısı (`usage.server_tool_use.web_search_requests`); alan yoksa 0. Saf fonksiyondur. */
export function webSearchesOf(usage: { server_tool_use?: { web_search_requests?: number | null } | null } | null | undefined): number {
  return usage?.server_tool_use?.web_search_requests ?? 0;
}

/**
 * İstemciye arama durumunu bildiren yanıt başlığı (`x-web-search`): araç istenmediyse yok; verildiyse `on`, aylık hak
 * bittiği için sunulmadıysa `cap_reached` (Sor bunu cevabın altında yazar). Saf fonksiyondur.
 */
export function webSearchStatusHeader(requested: number, granted: number): Record<string, string> {
  if (requested === 0) {
    return {};
  }
  return { "x-web-search": granted > 0 ? "on" : "cap_reached" };
}

/** Web araması sunulamadı (politika kapalı ya da Anthropic kuruluşta aramayı reddetti): Sor bunu cevabın altında yazar. */
export const webSearchUnavailableHeader: Readonly<Record<string, string>> = { "x-web-search": "unavailable" };

/** Anthropic hata gövdesinin okunan kısmı (`{"type":"error","error":{"type":…,"message":…}}`). */
const anthropicErrorBodySchema = z.object({ error: z.object({ type: z.string(), message: z.string() }) });

/**
 * Anthropic'in "web araması bu kuruluşta kapalı" reddi mi: belgeye göre (Web search tool › "How to use web search")
 * yönetici Console'da aramayı kapattıysa araçlı istek, sonuç bloğundaki hata kodu yerine 400 `invalid_request_error`
 * ile döner ve mesajı web aramasının etkin olmadığını söyler. Mesaj sabit bir sözleşme olmadığı için hem "web search"
 * hem "not enabled"/"disabled" aranır; başka 400'ler (ör. bozuk istek) bu değildir. Saf fonksiyondur.
 */
export function isWebSearchDisabledError(status: number | undefined, body: unknown): boolean {
  if (status !== 400) {
    return false;
  }
  const parsed = anthropicErrorBodySchema.safeParse(body);
  if (!parsed.success || parsed.data.error.type !== "invalid_request_error") {
    return false;
  }
  const message: string = parsed.data.error.message.toLowerCase();
  return /web[ _-]?search/.test(message) && /(not enabled|disabled)/.test(message);
}

/** Araçsız istek: web araması aracı çıkarılır (başka araç kalmazsa `tools` alanı da). Saf fonksiyondur. */
export function withoutWebSearchTool(params: Anthropic.MessageCreateParamsNonStreaming): Anthropic.MessageCreateParamsNonStreaming {
  const { tools, ...rest } = params;
  const others: Anthropic.ToolUnion[] = (tools ?? []).filter((tool: Anthropic.ToolUnion): boolean => !("type" in tool && tool.type === webSearchToolType));
  return others.length === 0 ? rest : { ...rest, tools: others };
}

/** "Web araması kapalı" alarmının en sık yazılma aralığı. */
export const webSearchDisabledAlertIntervalMs: number = 60 * 60 * 1000;

/** Alarm yazılmalı mı: hiç yazılmadıysa ya da son yazılıştan `intervalMs` geçtiyse. Saf fonksiyondur. */
export function isAlertDue(lastAlertAt: number | null, now: number, intervalMs: number): boolean {
  return lastAlertAt === null || now - lastAlertAt >= intervalMs;
}

/**
 * Arama sonucu bloklarındaki hata kodları (`web_search_tool_result_error`: `max_uses_exceeded`, `unavailable`,
 * `too_many_requests`…). Hatalı arama 200 yanıtın içinde gelir ve ücretlendirilmez; model cevabı yine yazar. Saf
 * fonksiyondur.
 */
export function webSearchErrorCodes(blocks: readonly Anthropic.ContentBlock[]): string[] {
  return blocks.flatMap((block: Anthropic.ContentBlock): string[] =>
    block.type === "web_search_tool_result" && !Array.isArray(block.content) ? [block.content.error_code] : [],
  );
}
