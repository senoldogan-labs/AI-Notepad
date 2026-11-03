import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import {
  askScreenImageMaxCount,
  askScreenImageMaxTotalTokens,
  jpegSize,
  llmBodyLimitBytes,
  screenImageBodyAllowanceBytes,
  screenImageMaxBytes,
  screenImageMaxCount,
  screenImageMaxTotalTokens,
  visualTokens,
} from "../src/llm/images";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, envWith, expectError, req, signIn, startMeeting } from "./helpers";

const anthropicUrl: string = "https://api.anthropic.com/v1/messages";

interface Context {
  readonly harness: Harness;
  readonly session: Session;
  readonly meeting: StartedMeetingBody;
}

async function setup(): Promise<Context> {
  const harness: Harness = await defaultHarness();
  const session: Session = await signIn(harness);
  const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
  return { harness, session, meeting };
}

/** Meeting-scoped LLM call with an `x-llm-purpose`. */
function llm(context: Context, purpose: string, json: object, environment: Env | null): Promise<Response> {
  return context.harness.call(
    req("POST", "/v1/llm/messages", {
      token: context.session.accessToken,
      headers: { "x-meeting-id": context.meeting.meetingId, "x-llm-purpose": purpose },
      json,
      env: environment,
    }),
  );
}

/**
 * Smallest byte layout the server reads a JPEG size from: SOI, an APP0 segment, a baseline SOF0 frame header with the
 * size, optional filler (to reach a byte size) and EOI. Not decodable as pixels; the proxy only reads the header and
 * Anthropic is stubbed.
 */
function fakeJpeg(width: number, height: number, totalBytes: number): Uint8Array {
  const head: number[] = [
    0xff, 0xd8,
    0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, (height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  ];
  const tail: number[] = [0xff, 0xd9];
  const bytes: Uint8Array = new Uint8Array(Math.max(totalBytes, head.length + tail.length));
  bytes.set(head, 0);
  bytes.set(tail, bytes.length - tail.length);
  return bytes;
}

function base64(bytes: Uint8Array): string {
  let binary: string = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function imageBlock(bytes: Uint8Array): object {
  return { type: "image", source: { type: "base64", media_type: "image/jpeg", data: base64(bytes) } };
}

/** Note request whose user message is `label, image` pairs and then the transcript. */
function noteWithImages(images: readonly Uint8Array[]): object {
  return {
    effort: "medium",
    max_tokens: 4000,
    messages: [
      {
        role: "user",
        content: [
          ...images.flatMap((bytes: Uint8Array, index: number): object[] => [{ type: "text", text: `Screen ${index + 1} [00:0${index}]` }, imageBlock(bytes)]),
          { type: "text", text: "<transkript>\n[00:00] Sen: Fiyat sayfasına bakalım.\n</transkript>" },
        ],
      },
    ],
  };
}

function message(inputTokens: number, outputTokens: number): object {
  return {
    id: "msg_test",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text: "{}" }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: inputTokens, output_tokens: outputTokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  };
}

async function meetingTokens(meetingId: string): Promise<number> {
  const row = await env.DB.prepare("SELECT tokens_used FROM meeting_sessions WHERE id = ?").bind(meetingId).first<{ tokens_used: number }>();
  return row?.tokens_used ?? -1;
}

describe("Screen images: pure checks", () => {
  it("reads the JPEG size from the frame header and counts 28 px patches", () => {
    expect(jpegSize(fakeJpeg(812, 448, 0))).toEqual({ width: 812, height: 448 });
    expect(jpegSize(new Uint8Array([0x89, 0x50, 0x4e, 0x47]))).toBeNull();
    expect(jpegSize(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]))).toBeNull();
    expect(visualTokens({ width: 812, height: 448 })).toBe(29 * 16);
    expect(visualTokens({ width: 1, height: 1 })).toBe(1);
    expect(visualTokens({ width: 29, height: 28 })).toBe(2);
  });

  it("raises the body limit only for purposes that may carry images", () => {
    expect(llmBodyLimitBytes(400_000, "note")).toBe(400_000 + screenImageBodyAllowanceBytes);
    expect(llmBodyLimitBytes(400_000, "note_overview")).toBe(400_000 + screenImageBodyAllowanceBytes);
    expect(llmBodyLimitBytes(400_000, "ask_answer")).toBe(400_000 + screenImageBodyAllowanceBytes);
    expect(llmBodyLimitBytes(400_000, "ask_search_terms")).toBe(400_000);
    expect(llmBodyLimitBytes(400_000, "live_translation")).toBe(400_000);
    expect(llmBodyLimitBytes(400_000, "note_chunk")).toBe(400_000);
    expect(llmBodyLimitBytes(400_000, "unattributed")).toBe(400_000);
    // Six images at the byte cap fit (base64 grows 4/3).
    expect(screenImageBodyAllowanceBytes).toBeGreaterThan(screenImageMaxCount * Math.ceil((screenImageMaxBytes * 4) / 3));
  });
});

describe("Screen images: proxy", () => {
  it("passes image blocks through unchanged, counts their tokens in the reservation and charges real usage", async () => {
    const context: Context = await setup();
    const upstream: Array<{ messages: Array<{ content: unknown }> }> = [];
    context.harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      upstream.push(await request.json<{ messages: Array<{ content: unknown }> }>());
      return Response.json(message(1900, 300));
    });
    const images: Uint8Array[] = [fakeJpeg(812, 448, 40_000), fakeJpeg(448, 812, 40_000)];
    const body = noteWithImages(images);
    const response: Response = await llm(context, "note", body, null);
    expect(response.status).toBe(200);
    expect(upstream).toHaveLength(1);
    expect(upstream[0]?.messages[0]?.content).toEqual((body as { messages: Array<{ content: unknown }> }).messages[0]?.content);
    expect(await meetingTokens(context.meeting.meetingId)).toBe(2200);
  });

  it("includes image tokens in the input estimate (a small input cap rejects before any upstream call)", async () => {
    const context: Context = await setup();
    const before: number = context.harness.outbound.length;
    // Text alone is ~40 tokens; two images add 2 × 464.
    const smallCap: Env = envWith({ LLM_MAX_INPUT_TOKENS: "600" });
    await expectError(await llm(context, "note", noteWithImages([fakeJpeg(812, 448, 1000), fakeJpeg(812, 448, 1000)]), smallCap), 413, "payload_too_large");
    expect(context.harness.outbound.length).toBe(before);
  });

  it.each([
    ["too many images", "note", Array.from({ length: screenImageMaxCount + 1 }, (): Uint8Array => fakeJpeg(280, 280, 500))],
    // 6 × 493 tokens = 2,958 > 2,700.
    ["too many tokens", "note", Array.from({ length: 6 }, (): Uint8Array => fakeJpeg(812, 476, 500))],
    ["one huge image", "note", [fakeJpeg(2576, 1449, 500)]],
    ["too many bytes", "note", [fakeJpeg(280, 280, screenImageMaxBytes + 1)]],
    ["not a JPEG", "note", [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])]],
    ["a purpose that may not carry images", "live_translation", [fakeJpeg(280, 280, 500)]],
    ["the chunk of a long note", "note_chunk", [fakeJpeg(280, 280, 500)]],
    ["Ask's search terms", "ask_search_terms", [fakeJpeg(280, 280, 500)]],
    // Ask's own caps are lower than a note's: 4 small images, or 3 × 464 tokens = 1,392 > 1,350.
    ["too many images in Ask", "ask_answer", Array.from({ length: askScreenImageMaxCount + 1 }, (): Uint8Array => fakeJpeg(280, 280, 500))],
    ["too many tokens in Ask", "ask_answer", Array.from({ length: 3 }, (): Uint8Array => fakeJpeg(812, 448, 500))],
  ])("rejects %s with screen_images_over_limit and sends nothing upstream", async (_name: string, purpose: string, images: Uint8Array[]) => {
    const context: Context = await setup();
    const before: number = context.harness.outbound.length;
    await expectError(await llm(context, purpose, noteWithImages(images), null), 413, "screen_images_over_limit");
    expect(context.harness.outbound.length).toBe(before);
  });

  it("accepts exactly the caps: six images totalling the token budget", async () => {
    const context: Context = await setup();
    context.harness.stub(anthropicUrl, async (): Promise<Response> => Response.json(message(3000, 100)));
    // 6 × (16 × 28 px)² … 6 × 450 = 2,700 tokens.
    const images: Uint8Array[] = Array.from({ length: 6 }, (): Uint8Array => fakeJpeg(30 * 28, 15 * 28, screenImageMaxBytes));
    expect(6 * visualTokens({ width: 30 * 28, height: 15 * 28 })).toBe(screenImageMaxTotalTokens);
    const response: Response = await llm(context, "note_overview", noteWithImages(images), null);
    expect(response.status).toBe(200);
  });

  it("accepts Ask's answer at exactly its caps, on an account call (no meeting)", async () => {
    const context: Context = await setup();
    const upstream: Array<{ messages: Array<{ content: unknown }> }> = [];
    context.harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
      upstream.push(await request.json<{ messages: Array<{ content: unknown }> }>());
      return Response.json(message(1500, 200));
    });
    // 3 × 450 = 1,350 tokens.
    const images: Uint8Array[] = Array.from({ length: askScreenImageMaxCount }, (): Uint8Array => fakeJpeg(30 * 28, 15 * 28, 40_000));
    expect(askScreenImageMaxCount * visualTokens({ width: 30 * 28, height: 15 * 28 })).toBe(askScreenImageMaxTotalTokens);
    const body = noteWithImages(images);
    const response: Response = await context.harness.call(
      req("POST", "/v1/llm/messages", { token: context.session.accessToken, headers: { "x-llm-purpose": "ask_answer" }, json: body, env: null }),
    );
    expect(response.status).toBe(200);
    expect(upstream[0]?.messages[0]?.content).toEqual((body as { messages: Array<{ content: unknown }> }).messages[0]?.content);
  });

  it.each([
    ["a PNG media type", { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } }],
    ["a URL source", { type: "image", source: { type: "url", url: "https://example.com/a.jpg" } }],
    ["a cache mark", { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "/9j/" }, cache_control: { type: "ephemeral" } }],
    ["non-base64 data", { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "not base64!" } }],
    // `atob` cannot decode it; caught by the schema, never a 500.
    ["base64 whose length is not a multiple of 4", { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "/9j/4" } }],
  ])("rejects an image block with %s as invalid_body", async (_name: string, block: object) => {
    const context: Context = await setup();
    const before: number = context.harness.outbound.length;
    const body = { effort: "medium", max_tokens: 1000, messages: [{ role: "user", content: [block, { type: "text", text: "x" }] }] };
    await expectError(await llm(context, "note", body, null), 400, "invalid_body");
    expect(context.harness.outbound.length).toBe(before);
  });

  it("keeps the text limit on image purposes and the body limit on the others", async () => {
    const context: Context = await setup();
    const longText = { effort: "medium", max_tokens: 1000, messages: [{ role: "user", content: "a".repeat(400_001) }] };
    await expectError(await llm(context, "note", longText, null), 413, "payload_too_large");
    await expectError(await llm(context, "live_translation", longText, null), 413, "payload_too_large");
    // A text-only purpose cannot use the image allowance even with images inside.
    const big: Uint8Array[] = Array.from({ length: 2 }, (): Uint8Array => fakeJpeg(280, 280, screenImageMaxBytes));
    await expectError(await llm(context, "live_translation", noteWithImages(big), null), 413, "payload_too_large");
  });
});
