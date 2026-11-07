import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { expect } from "vitest";
import { appleIssuer } from "../src/auth/apple";
import { base64UrlEncode, randomId, randomToken, sha256, sha256Hex, utf8 } from "../src/crypto";
import { mcpResource } from "../src/mcp/config";
import type { McpEnv } from "../src/mcp/env";
import { createMcpWorker } from "../src/mcp/index";
import { allowingLimiter } from "./assistantHelpers";
import { type Harness, type Session, appleIdentityToken, googleClientId, req } from "./helpers";

/**
 * Test harness of the `gistsmith-mcp` Worker: the real Worker (OAuth provider, pages, MCP handler) against this test
 * runtime's D1, R2 and KV, with the API harness's outbound fetch (fake Apple and Google keys) and clock. A small cookie
 * jar stands in for the browser; `TestClient` is a fake MCP client doing registration, PKCE and the token requests.
 */

export const mcpBase: string = "https://mcp.gistsmith.com";
/** The Apple Services ID the site signs in with (`APPLE_SIGNIN_CLIENT_ID`). */
export const webAppleClientId: string = "com.senoldogan.AINotepad.web";

export function mcpEnvWith(overrides: Partial<McpEnv>): McpEnv {
  return {
    DB: env.DB,
    ASSISTANT_DB: env.ASSISTANT_DB,
    ASSISTANT_BUCKET: env.ASSISTANT_BUCKET,
    OAUTH_KV: env.OAUTH_KV,
    MCP_GRANT_LIMITER: allowingLimiter,
    MCP_IP_LIMITER: allowingLimiter,
    MCP_REVIEWER_LIMITER: allowingLimiter,
    ENVIRONMENT: "production",
    APPLE_SIGNIN_CLIENT_ID: webAppleClientId,
    GOOGLE_SIGNIN_CLIENT_ID: googleClientId,
    TRIAL_MEETINGS: "3",
    TRIAL_DAYS: "7",
    PAST_DUE_GRACE_DAYS: "7",
    REVENUECAT_ACCEPT_SANDBOX: "true",
    DEVICECHECK_POLICY: "off",
    ...(env.ASSISTANT_DATA_KEY === undefined ? {} : { ASSISTANT_DATA_KEY: env.ASSISTANT_DATA_KEY }),
    ...overrides,
  };
}

/** Cookie jar of one browser. */
export class CookieJar {
  private readonly cookies: Map<string, string> = new Map();

  take(response: Response): void {
    for (const line of response.headers.getSetCookie()) {
      const [pair] = line.split(";");
      const index: number = pair?.indexOf("=") ?? -1;
      if (pair === undefined || index < 0) {
        continue;
      }
      const name: string = pair.slice(0, index).trim();
      const value: string = pair.slice(index + 1).trim();
      if (value.length === 0 || /max-age=0/i.test(line)) {
        this.cookies.delete(name);
      } else {
        this.cookies.set(name, value);
      }
    }
  }

  header(): string {
    return [...this.cookies].map(([name, value]): string => `${name}=${value}`).join("; ");
  }
}

/** The Worker under test. */
export interface McpTest {
  readonly harness: Harness;
  readonly env: McpEnv;
  readonly fetch: (request: Request) => Promise<Response>;
  /** Runs the Worker's daily cron at `scheduledTimeMs`. */
  readonly scheduled: (scheduledTimeMs: number) => Promise<void>;
}

export function mcpTest(harness: Harness, overrides: Partial<McpEnv>): McpTest {
  const worker = createMcpWorker(() => harness.platform);
  const testEnv: McpEnv = mcpEnvWith(overrides);
  return {
    harness,
    env: testEnv,
    fetch: async (request: Request): Promise<Response> => {
      const ctx: ExecutionContext = createExecutionContext();
      const response: Response = await worker.fetch(request, testEnv, ctx);
      await waitOnExecutionContext(ctx);
      return response;
    },
    scheduled: (scheduledTimeMs: number): Promise<void> => worker.scheduled(createScheduledController({ scheduledTime: scheduledTimeMs, cron: "41 3 * * *" }), testEnv),
  };
}

/** A page request from the browser. */
export async function browse(test: McpTest, jar: CookieJar, method: string, pathOrUrl: string, form: Record<string, string> | null): Promise<Response> {
  const headers: Headers = new Headers({ "cf-connecting-ip": "203.0.113.7" });
  const cookie: string = jar.header();
  if (cookie.length > 0) {
    headers.set("cookie", cookie);
  }
  let body: string | null = null;
  if (form !== null) {
    headers.set("content-type", "application/x-www-form-urlencoded");
    body = new URLSearchParams(form).toString();
  }
  const url: string = pathOrUrl.startsWith("http") ? pathOrUrl : `${mcpBase}${pathOrUrl}`;
  const response: Response = await test.fetch(new Request(url, { method, headers, body, redirect: "manual" }));
  jar.take(response);
  return response;
}

/** HTML entity decoding of the pages' escaping. */
export function unescapeHtml(value: string): string {
  return value.replace(/&#(\d+);/g, (_match: string, code: string): string => String.fromCharCode(Number(code)));
}

/** Hidden inputs of the page's first form, and its action. */
export function formOf(html: string): { readonly action: string; readonly fields: Record<string, string> } {
  const action: string = unescapeHtml(/<form[^>]*action="([^"]*)"/.exec(html)?.[1] ?? "");
  const fields: Record<string, string> = {};
  for (const match of html.matchAll(/<input type="hidden" name="([^"]*)" value="([^"]*)">/g)) {
    fields[unescapeHtml(match[1] ?? "")] = unescapeHtml(match[2] ?? "");
  }
  return { action, fields };
}

/** The first link whose URL starts with `prefix`. */
export function linkOf(html: string, prefix: string): URL {
  for (const match of html.matchAll(/href="([^"]*)"/g)) {
    const href: string = unescapeHtml(match[1] ?? "");
    if (href.startsWith(prefix)) {
      return new URL(href, mcpBase);
    }
  }
  throw new Error(`No link starting with ${prefix}`);
}

/** Signs in to the API with a known Apple subject (so the MCP sign-in can use the same identity). */
export async function appleSession(harness: Harness, subject: string): Promise<Session> {
  const nonce: string = randomToken(24);
  const identityToken: string = await appleIdentityToken({
    subject,
    nonceClaim: await sha256Hex(nonce),
    audience: "com.senoldogan.AINotepad.hosted",
    issuer: appleIssuer,
    expiresInSeconds: 600,
    nowMs: harness.clock.nowMs,
  });
  const response: Response = await harness.call(req("POST", "/v1/auth/apple", { json: { identityToken, nonce } }));
  expect(response.status).toBe(200);
  return response.json<Session>();
}

/** A fake MCP client. */
export interface TestClient {
  readonly clientId: string;
  readonly redirectUri: string;
}

/** Dynamic client registration (public client, PKCE). */
export async function registerClient(test: McpTest, redirectUri: string, name: string): Promise<TestClient> {
  const response: Response = await test.fetch(
    new Request(`${mcpBase}/oauth/register`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": `198.51.100.${Math.floor(Math.random() * 250)}` },
      body: JSON.stringify({
        redirect_uris: [redirectUri],
        client_name: name,
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
      }),
    }),
  );
  expect(response.status).toBe(201);
  const body: { client_id: string } = await response.json<{ client_id: string }>();
  return { clientId: body.client_id, redirectUri };
}

/** PKCE verifier and S256 challenge. */
export async function pkce(): Promise<{ readonly verifier: string; readonly challenge: string }> {
  const verifier: string = randomToken(48);
  return { verifier, challenge: base64UrlEncode(await sha256(utf8(verifier))) };
}

/** `GET /authorize` URL. */
export function authorizeUrl(client: TestClient, challenge: string, state: string, resource: string): string {
  const params: URLSearchParams = new URLSearchParams({
    response_type: "code",
    client_id: client.clientId,
    redirect_uri: client.redirectUri,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    scope: "notes:read",
    resource,
  });
  return `/authorize?${params.toString()}`;
}

/** The consent page of a sign-in with Apple as `subject`; returns the page and the jar. */
export async function consentPageFor(test: McpTest, client: TestClient, subject: string, challenge: string): Promise<{ readonly html: string; readonly jar: CookieJar }> {
  const jar: CookieJar = new CookieJar();
  const signIn: Response = await browse(test, jar, "GET", authorizeUrl(client, challenge, "client-state-1", mcpResource), null);
  expect(signIn.status).toBe(200);
  const signInHtml: string = await signIn.text();
  const apple: URL = linkOf(signInHtml, "https://appleid.apple.com/");
  const state: string = apple.searchParams.get("state") ?? "";
  const idToken: string = await appleIdentityToken({
    subject,
    nonceClaim: apple.searchParams.get("nonce") ?? "",
    audience: webAppleClientId,
    issuer: appleIssuer,
    expiresInSeconds: 600,
    nowMs: test.harness.clock.nowMs,
  });
  // Apple's cross-site form post carries no cookie.
  const callback: Response = await browse(test, new CookieJar(), "POST", "/signin/apple/callback", { state, code: "c1", id_token: idToken });
  expect(callback.status).toBe(200);
  const relay = formOf(await callback.text());
  const finish: Response = await browse(test, jar, "POST", relay.action, relay.fields);
  return { html: await finish.text(), jar };
}

/** Token response. */
export interface Tokens {
  readonly access_token: string;
  readonly refresh_token: string;
  readonly expires_in: number;
  readonly scope: string;
}

export async function tokenRequest(test: McpTest, form: Record<string, string>): Promise<Response> {
  return test.fetch(
    new Request(`${mcpBase}/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form).toString(),
    }),
  );
}

/** An allowed authorization: the code and its PKCE verifier, not yet exchanged. */
export interface ApprovedCode {
  readonly code: string;
  readonly verifier: string;
}

/** Where the consent decision's return page sends the browser (`returnPage`: 200 with a link, never a redirect). */
export async function returnLocation(response: Response): Promise<URL> {
  expect(response.status).toBe(200);
  expect(response.headers.get("location")).toBeNull();
  const html: string = await response.text();
  return new URL(unescapeHtml(/id="return" href="([^"]*)"/.exec(html)?.[1] ?? ""));
}

/** Sign in and allow; returns the code the client receives. */
export async function approvedCode(test: McpTest, client: TestClient, subject: string): Promise<ApprovedCode> {
  const { verifier, challenge } = await pkce();
  const { html, jar } = await consentPageFor(test, client, subject, challenge);
  const consent = formOf(html);
  const decided: Response = await browse(test, jar, "POST", "/authorize", { ...consent.fields, decision: "approve" });
  const location: URL = await returnLocation(decided);
  expect(`${location.origin}${location.pathname}`).toBe(client.redirectUri);
  expect(location.searchParams.get("state")).toBe("client-state-1");
  return { code: location.searchParams.get("code") ?? "", verifier };
}

/** Exchanges an allowed code at the token endpoint. */
export async function exchangeCode(test: McpTest, client: TestClient, approved: ApprovedCode): Promise<Response> {
  return tokenRequest(test, {
    grant_type: "authorization_code",
    code: approved.code,
    redirect_uri: client.redirectUri,
    client_id: client.clientId,
    code_verifier: approved.verifier,
    resource: mcpResource,
  });
}

/** The whole connection: sign in, allow, exchange the code. */
export async function connect(test: McpTest, client: TestClient, subject: string): Promise<Tokens> {
  const token: Response = await exchangeCode(test, client, await approvedCode(test, client, subject));
  expect(token.status).toBe(200);
  return token.json<Tokens>();
}

/** JSON-RPC response of an MCP request. */
export interface RpcResponse {
  readonly result?: {
    readonly isError?: boolean;
    readonly content?: ReadonlyArray<{ readonly type: string; readonly text: string }>;
    readonly structuredContent?: Record<string, unknown>;
    readonly tools?: ReadonlyArray<Record<string, unknown>>;
    readonly serverInfo?: Record<string, unknown>;
    readonly instructions?: string;
  };
  readonly error?: { readonly code: number; readonly message: string };
}

/** One MCP request (Streamable HTTP, stateless); answers in JSON or one SSE event. */
export async function mcpRequest(test: McpTest, accessToken: string, method: string, params: Record<string, unknown>): Promise<{ readonly status: number; readonly body: RpcResponse | null }> {
  const response: Response = await test.fetch(
    new Request(`${mcpBase}/mcp`, {
      method: "POST",
      headers: {
        // Cloudflare always sends Host; the MCP handler validates it (DNS rebinding protection).
        host: "mcp.gistsmith.com",
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "mcp-protocol-version": "2025-06-18",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: randomId(), method, params }),
    }),
  );
  const text: string = await response.text();
  if (response.status !== 200) {
    return { status: response.status, body: null };
  }
  const json: string = (response.headers.get("content-type") ?? "").includes("text/event-stream")
    ? (text.split("\n").find((line: string): boolean => line.startsWith("data: "))?.slice(6) ?? "null")
    : text;
  return { status: response.status, body: JSON.parse(json) as RpcResponse };
}

/** Calls a tool; returns the result. */
export async function callTool(test: McpTest, accessToken: string, name: string, args: Record<string, unknown>): Promise<NonNullable<RpcResponse["result"]>> {
  const { status, body } = await mcpRequest(test, accessToken, "tools/call", { name, arguments: args });
  expect(status).toBe(200);
  expect(body?.error).toBeUndefined();
  const result = body?.result;
  if (result === undefined) {
    throw new Error("tools/call returned no result");
  }
  return result;
}

/** The error text of a failed tool call. */
export function toolErrorText(result: NonNullable<RpcResponse["result"]>): string {
  expect(result.isError).toBe(true);
  return result.content?.[0]?.text ?? "";
}
