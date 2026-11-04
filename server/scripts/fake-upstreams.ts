// Yerel uçtan uca denemelerin sahte Anthropic ve ElevenLabs servisi (ücretli çağrı yapılmaz). Kullanım:
//   node scripts/fake-upstreams.ts 8798
//   npx wrangler dev --port 8797 --var UPSTREAM_STUB_URL:http://127.0.0.1:8798
// Sunucu yalnızca geliştirme ortamında ve geri döngü adresinde bu adrese yönlendirir (bkz. src/upstreamStub.ts).
// - POST /v1/messages: isteğin JSON şemasına (output_config.format.schema) uyan en küçük yanıt; şema yoksa kısa metin.
//   `stream: true` ise Anthropic SSE olayları. Kullanım: 120 girdi, 30 çıktı token. İstek web araması aracını taşıyorsa
//   (Sor cevabı) akış bir arama yapar: `server_tool_use`, `web_search_tool_result`, alıntılı (`citations_delta`) metin
//   ve `usage.server_tool_use.web_search_requests: 1`.
// - POST /v1/speech-to-text: kısa bir Fince yazıya dökme (1 sn).
import { type IncomingMessage, type ServerResponse, createServer } from "node:http";

/** JSON şemasının kullanılan alt kümesi. */
interface JsonSchema {
  readonly type?: string;
  readonly properties?: Readonly<Record<string, JsonSchema>>;
  readonly required?: readonly string[];
}

/** Şemaya uyan değer. */
type JsonValue = string | number | boolean | readonly JsonValue[] | { readonly [key: string]: JsonValue };

/** Sahte servisin okuduğu Anthropic istek alanları. */
interface MessagesRequest {
  readonly stream?: boolean;
  readonly tools?: readonly { readonly type: string; readonly max_uses?: number }[];
  readonly output_config?: { readonly format?: { readonly schema?: JsonSchema } };
}

const port: number = Number(process.argv[2]);
if (!Number.isInteger(port) || port <= 0) {
  console.error("Kullanım: node scripts/fake-upstreams.ts <port>");
  process.exit(2);
}

/** Şemaya uyan en küçük değer (zorunlu alanlar dolu, diziler boş). Saf fonksiyondur. */
function sample(schema: JsonSchema | undefined): JsonValue {
  switch (schema?.type) {
    case "object": {
      const value: Record<string, JsonValue> = {};
      for (const name of schema.required ?? Object.keys(schema.properties ?? {})) {
        value[name] = sample(schema.properties?.[name]);
      }
      return value;
    }
    case "array":
      return [];
    case "integer":
    case "number":
      return 1;
    case "boolean":
      return false;
    default:
      return "Uçtan uca deneme";
  }
}

function readBody(request: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve: (body: Buffer) => void, reject: (error: Error) => void): void => {
    const parts: Buffer[] = [];
    request.on("data", (part: Buffer): void => {
      parts.push(part);
    });
    request.on("end", (): void => resolve(Buffer.concat(parts)));
    request.on("error", reject);
  });
}

const usage = { input_tokens: 120, output_tokens: 30, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } as const;

function message(text: string): object {
  return {
    id: "msg_fake",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage,
  };
}

/** Sahte arama sonucu (gerçek bir sayfa değildir). */
const searchResult = { type: "web_search_result", url: "https://example.com/haiku-pricing", title: "Example pricing page", encrypted_content: "ZmFrZQ==", page_age: null } as const;

/** Web aramalı akış: kısa ön söz, arama, sonuç, alıntılı cümle ve alıntısız son. */
function searchSse(text: string): string {
  const citation = {
    type: "web_search_result_location",
    url: searchResult.url,
    title: searchResult.title,
    encrypted_index: "ZmFrZQ==",
    cited_text: "Example pricing",
  };
  const events: ReadonlyArray<readonly [string, object]> = [
    ["message_start", { type: "message_start", message: { ...message(""), content: [], stop_reason: null, usage: { ...usage, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Searching the web." } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["content_block_start", { type: "content_block_start", index: 1, content_block: { type: "server_tool_use", id: "srvtoolu_fake", name: "web_search", input: {} } }],
    ["content_block_delta", { type: "content_block_delta", index: 1, delta: { type: "input_json_delta", partial_json: '{"query":"uçtan uca deneme"}' } }],
    ["content_block_stop", { type: "content_block_stop", index: 1 }],
    ["content_block_start", { type: "content_block_start", index: 2, content_block: { type: "web_search_tool_result", tool_use_id: "srvtoolu_fake", content: [searchResult] } }],
    ["content_block_stop", { type: "content_block_stop", index: 2 }],
    ["content_block_start", { type: "content_block_start", index: 3, content_block: { type: "text", text: "", citations: [] } }],
    ["content_block_delta", { type: "content_block_delta", index: 3, delta: { type: "citations_delta", citation } }],
    ["content_block_delta", { type: "content_block_delta", index: 3, delta: { type: "text_delta", text } }],
    ["content_block_stop", { type: "content_block_stop", index: 3 }],
    [
      "message_delta",
      {
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { output_tokens: usage.output_tokens, server_tool_use: { web_search_requests: 1, web_fetch_requests: 0 } },
      },
    ],
    ["message_stop", { type: "message_stop" }],
  ];
  return events.map(([type, data]: readonly [string, object]): string => `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`).join("");
}

function sse(text: string): string {
  const events: ReadonlyArray<readonly [string, object]> = [
    ["message_start", { type: "message_start", message: { ...message(""), content: [], stop_reason: null, usage: { ...usage, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: usage.output_tokens } }],
    ["message_stop", { type: "message_stop" }],
  ];
  return events.map(([type, data]: readonly [string, object]): string => `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`).join("");
}

const transcription = {
  language_code: "fin",
  language_probability: 0.98,
  text: "Hyvää huomenta",
  words: [
    { text: "Hyvää", type: "word", start: 0.1, end: 0.4, speaker_id: "speaker_0", logprob: -0.1 },
    { text: " ", type: "spacing", start: 0.4, end: 0.45, speaker_id: "speaker_0", logprob: 0 },
    { text: "huomenta", type: "word", start: 0.45, end: 0.9, speaker_id: "speaker_0", logprob: -0.1 },
  ],
  audio_duration_secs: 1,
} as const;

async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const path: string = (request.url ?? "").split("?")[0] ?? "";
  const body: Buffer = await readBody(request);
  if (request.method === "POST" && path === "/v1/messages") {
    const json: MessagesRequest = JSON.parse(body.toString("utf8")) as MessagesRequest;
    const schema: JsonSchema | undefined = json.output_config?.format?.schema;
    const text: string = schema === undefined ? "Uçtan uca deneme" : JSON.stringify(sample(schema));
    const searches: boolean = (json.tools ?? []).some((tool): boolean => tool.type.startsWith("web_search"));
    console.log(`messages stream=${json.stream === true} schema=${schema !== undefined} webSearch=${searches}`);
    if (json.stream === true && searches) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(searchSse(text));
    } else if (json.stream === true) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(sse(text));
    } else {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(message(text)));
    }
    return;
  }
  if (request.method === "POST" && path === "/v1/speech-to-text") {
    console.log(`speech-to-text bytes=${body.length}`);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(transcription));
    return;
  }
  console.log(`unknown ${request.method ?? ""} ${path}`);
  response.writeHead(404, { "content-type": "application/json" });
  response.end(JSON.stringify({ error: "not_found" }));
}

createServer((request: IncomingMessage, response: ServerResponse): void => {
  handle(request, response).catch((error: unknown): void => {
    console.error(`fake upstream failed: ${String(error)}`);
    response.writeHead(500, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "fake_upstream_failed" }));
  });
}).listen(port, "127.0.0.1", (): void => {
  console.log(`fake upstreams listening on http://127.0.0.1:${port}`);
});
