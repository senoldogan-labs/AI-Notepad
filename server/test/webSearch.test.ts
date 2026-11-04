import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { webSearchGrant, webSearchMicroUsd } from "../src/llm/webSearch";
import { llmCostMicroUsd } from "../src/usage";
import { type Harness, type Session, defaultHarness, envWith, expectError, req, signIn, startMeeting } from "./helpers";

const anthropicUrl: string = "https://api.anthropic.com/v1/messages";

/** Sor cevabının web araması aracı (istemcinin gönderdiği biçim). */
const searchTool = { type: "web_search_20260209", name: "web_search", max_uses: 3 } as const;

const askBody = { effort: "medium", max_tokens: 16_000, messages: [{ role: "user", content: "Haiku 5.5 ne kadar?" }], tools: [searchTool] };

/** Anthropic'in web aramalı yanıtı: bir arama, alıntılı metin. */
function searchMessage(inputTokens: number, outputTokens: number, searches: number): object {
  return {
    id: "msg_search",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [
      { type: "server_tool_use", id: "srvtoolu_1", name: "web_search", input: { query: "haiku pricing" }, caller: { type: "direct" } },
      { type: "web_search_tool_result", tool_use_id: "srvtoolu_1", content: [{ type: "web_search_result", url: "https://example.com", title: "Example", encrypted_content: "e", page_age: null }] },
      { type: "text", text: "0,10 $", citations: [{ type: "web_search_result_location", url: "https://example.com", title: "Example", encrypted_index: "i", cited_text: "0.10" }] },
    ],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: {
      input_tokens: inputTokens,
      output_tokens: outputTokens,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      server_tool_use: { web_search_requests: searches, web_fetch_requests: 0 },
    },
  };
}

function sse(events: ReadonlyArray<readonly [string, object]>): string {
  return events.map(([type, data]): string => `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`).join("");
}

/** Denemesi başlamış hesap (ilk toplantı açıldı). */
async function trialAccount(): Promise<{ harness: Harness; session: Session }> {
  const harness: Harness = await defaultHarness();
  const session: Session = await signIn(harness);
  expect((await startMeeting(harness, session)).status).toBe(201);
  return { harness, session };
}

function accountLLM(harness: Harness, session: Session, purpose: string, json: object, environment: Env | null): Promise<Response> {
  return harness.call(req("POST", "/v1/llm/messages", { token: session.accessToken, headers: { "x-llm-purpose": purpose }, json, env: environment }));
}

async function monthlySearches(userId: string): Promise<number> {
  const row = await env.DB.prepare("SELECT web_searches FROM monthly_usage WHERE user_id = ?").bind(userId).first<{ web_searches: number }>();
  return row?.web_searches ?? 0;
}

async function purposeSearches(purpose: string): Promise<number> {
  const row = await env.DB.prepare("SELECT SUM(web_searches) AS searches FROM llm_purpose_usage WHERE purpose = ?").bind(purpose).first<{ searches: number | null }>();
  return row?.searches ?? 0;
}

async function todaySpend(): Promise<number> {
  const row = await env.DB.prepare("SELECT COALESCE(SUM(llm_micro_usd), 0) AS spend FROM daily_spend").first<{ spend: number }>();
  return row?.spend ?? 0;
}

describe("web araması: hak hesabı", () => {
  it("verilen arama istenenden ve kalandan küçüğüdür", () => {
    expect(webSearchGrant(3, 0, 100)).toBe(3);
    expect(webSearchGrant(3, 98, 100)).toBe(2);
    expect(webSearchGrant(3, 100, 100)).toBe(0);
    expect(webSearchGrant(3, 120, 100)).toBe(0);
  });
});

describe("web araması: yalnız Sor cevabında", () => {
  it.each([
    ["başka amaç", "note_edit", askBody],
    ["amaç başlığı yok", null, askBody],
    ["4 arama", "ask_answer", { ...askBody, tools: [{ ...searchTool, max_uses: 4 }] }],
    ["eski araç türü", "ask_answer", { ...askBody, tools: [{ ...searchTool, type: "web_search_20250305" }] }],
    ["web getirme", "ask_answer", { ...askBody, tools: [{ type: "web_fetch_20260209", name: "web_fetch", max_uses: 1 }] }],
    ["iki araç", "ask_answer", { ...askBody, tools: [searchTool, searchTool] }],
    ["alan adı listesi", "ask_answer", { ...askBody, tools: [{ ...searchTool, allowed_domains: ["evil.example"] }] }],
  ])("%s reddedilir, dışarı istek gitmez", async (_name: string, purpose: string | null, body: object) => {
    const { harness, session } = await trialAccount();
    const before: number = harness.outbound.length;
    const headers: Record<string, string> = purpose === null ? {} : { "x-llm-purpose": purpose };
    await expectError(await harness.call(req("POST", "/v1/llm/messages", { token: session.accessToken, headers, json: body })), 400, "invalid_body");
    expect(harness.outbound.length).toBe(before);
    expect(await monthlySearches(session.userId)).toBe(0);
  });
});

describe("web araması: Sor cevabı", () => {
  it("araç doğrudan çağrıyla ve en çok 3 aramayla gider; yapılan arama sayılır, kalan hak geri verilir, maliyete eklenir", async () => {
    const { harness, session } = await trialAccount();
    let upstream: { max_tokens: number; tools?: unknown } = { max_tokens: 0 };
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      upstream = await request.json<{ max_tokens: number; tools?: unknown }>();
      return Response.json(searchMessage(5000, 200, 1));
    });
    const spendBefore: number = await todaySpend();
    const response: Response = await accountLLM(harness, session, "ask_answer", askBody, null);
    expect(response.status).toBe(200);
    expect(response.headers.get("x-web-search")).toBe("on");
    expect(upstream.tools).toEqual([{ type: "web_search_20260209", name: "web_search", max_uses: 3, allowed_callers: ["direct"] }]);
    // Sor cevabının çağrı başı sınırı hesap çağrısınınkinden büyük.
    expect(upstream.max_tokens).toBe(Number(env.LLM_ASK_MAX_TOKENS));
    expect(upstream.max_tokens).toBeGreaterThan(Number(env.LLM_ACCOUNT_MAX_TOKENS));
    expect(await monthlySearches(session.userId)).toBe(1);
    expect(await purposeSearches("ask_answer")).toBeGreaterThanOrEqual(1);
    expect((await todaySpend()) - spendBefore).toBe(llmCostMicroUsd(5000, 200) + webSearchMicroUsd);
  });

  it("aracı istemeyen Sor cevabı araçsız gider, başlık ve arama sayısı yok", async () => {
    const { harness, session } = await trialAccount();
    let tools: unknown = "yok";
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      tools = (await request.json<{ tools?: unknown }>()).tools;
      return Response.json(searchMessage(100, 20, 0));
    });
    const response: Response = await accountLLM(harness, session, "ask_answer", { ...askBody, tools: undefined }, null);
    expect(response.status).toBe(200);
    expect(response.headers.get("x-web-search")).toBeNull();
    expect(tools).toBeUndefined();
    expect(await monthlySearches(session.userId)).toBe(0);
  });

  it("aylık hak bitince araç sunulmaz ve istemciye cap_reached denir; son hak kısmen verilir", async () => {
    const { harness, session } = await trialAccount();
    const capped: Env = envWith({ MONTHLY_WEB_SEARCH_CAP: "2" });
    const seen: unknown[] = [];
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      seen.push((await request.json<{ tools?: unknown }>()).tools);
      return Response.json(searchMessage(100, 20, 2));
    });
    const first: Response = await accountLLM(harness, session, "ask_answer", askBody, capped);
    expect(first.headers.get("x-web-search")).toBe("on");
    expect(seen[0]).toEqual([{ type: "web_search_20260209", name: "web_search", max_uses: 2, allowed_callers: ["direct"] }]);
    expect(await monthlySearches(session.userId)).toBe(2);
    const second: Response = await accountLLM(harness, session, "ask_answer", askBody, capped);
    expect(second.status).toBe(200);
    expect(second.headers.get("x-web-search")).toBe("cap_reached");
    expect(seen[1]).toBeUndefined();
    expect(await monthlySearches(session.userId)).toBe(2);
  });

  it("WEB_SEARCH_POLICY off iken araç sunulmaz, hak düşülmez ve istemciye unavailable denir", async () => {
    const { harness, session } = await trialAccount();
    const disabled: Env = envWith({ WEB_SEARCH_POLICY: "off" });
    let tools: unknown = "yok";
    harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      tools = (await request.json<{ tools?: unknown }>()).tools;
      return Response.json(searchMessage(100, 20, 0));
    });
    const spendBefore: number = await todaySpend();
    const response: Response = await accountLLM(harness, session, "ask_answer", askBody, disabled);
    expect(response.status).toBe(200);
    expect(response.headers.get("x-web-search")).toBe("unavailable");
    expect(tools).toBeUndefined();
    expect(await monthlySearches(session.userId)).toBe(0);
    expect((await todaySpend()) - spendBefore).toBe(llmCostMicroUsd(100, 20));
  });

  it("üst çağrı başarısızsa verilen hak geri verilir", async () => {
    const { harness, session } = await trialAccount();
    harness.stub(anthropicUrl, async (): Promise<Response> => Response.json({ type: "error", error: { type: "invalid_request_error", message: "x" } }, { status: 400 }));
    await expectError(await accountLLM(harness, session, "ask_answer", askBody, null), 502, "upstream_rejected");
    expect(await monthlySearches(session.userId)).toBe(0);
  });

  it("akışta arama sayısı message_delta'dan okunur", async () => {
    const { harness, session } = await trialAccount();
    const events: ReadonlyArray<readonly [string, object]> = [
      ["message_start", { type: "message_start", message: { ...searchMessage(300, 1, 0), content: [], stop_reason: null } }],
      ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "", citations: [] } }],
      ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Tamam" } }],
      ["content_block_stop", { type: "content_block_stop", index: 0 }],
      [
        "message_delta",
        { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 40, server_tool_use: { web_search_requests: 2, web_fetch_requests: 0 } } },
      ],
      ["message_stop", { type: "message_stop" }],
    ];
    harness.stub(anthropicUrl, async (): Promise<Response> => new Response(sse(events), { headers: { "content-type": "text/event-stream" } }));
    const response: Response = await accountLLM(harness, session, "ask_answer", { ...askBody, stream: true }, null);
    expect(response.status).toBe(200);
    expect(response.headers.get("x-web-search")).toBe("on");
    expect(await response.text()).toContain("event: message_stop");
    await harness.drain();
    expect(await monthlySearches(session.userId)).toBe(2);
  });
});
