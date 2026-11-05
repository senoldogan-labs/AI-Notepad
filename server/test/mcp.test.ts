import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { randomId } from "../src/crypto";
import { getOAuthApi } from "@cloudflare/workers-oauth-provider";
import { mcpResource } from "../src/mcp/config";
import { mcpProviderOptions } from "../src/mcp/index";
import { type Harness, type Session, blockingLimiter, defaultHarness, expectError, req } from "./helpers";
import { assistantEnv, dayMs, fieldsFor, putMeeting, setAssistant, subscriber } from "./assistantHelpers";
import {
  type McpTest,
  type TestClient,
  type Tokens,
  CookieJar,
  appleSession,
  authorizeUrl,
  browse,
  callTool,
  connect,
  consentPageFor,
  formOf,
  linkOf,
  mcpBase,
  mcpRequest,
  mcpTest,
  pkce,
  registerClient,
  tokenRequest,
  toolErrorText,
  unescapeHtml,
} from "./mcpHarness";

afterEach(() => {
  vi.restoreAllMocks();
});

/** A subscriber with assistant access on, its Apple subject and its settings epoch. */
interface Owner {
  readonly session: Session;
  readonly subject: string;
  readonly epoch: number;
}

async function owner(harness: Harness): Promise<Owner> {
  const subject: string = `apple-${randomId()}`;
  const session: Session = await subscriber(harness, await appleSession(harness, subject));
  const settings = await setAssistant(harness, session, true);
  return { session, subject, epoch: settings.epoch };
}

async function setup(): Promise<{ readonly harness: Harness; readonly test: McpTest; readonly client: TestClient }> {
  const harness: Harness = await defaultHarness();
  const test: McpTest = mcpTest(harness, {});
  const client: TestClient = await registerClient(test, "https://client.example/callback", "Example Client");
  return { harness, test, client };
}

describe("MCP OAuth", () => {
  it("advertises the authorization server and the protected resource", async () => {
    const { test } = await setup();
    const metadata = await (await test.fetch(new Request(`${mcpBase}/.well-known/oauth-authorization-server`))).json<Record<string, unknown>>();
    expect(metadata).toMatchObject({
      issuer: mcpBase,
      authorization_endpoint: `${mcpBase}/authorize`,
      token_endpoint: `${mcpBase}/oauth/token`,
      registration_endpoint: `${mcpBase}/oauth/register`,
      code_challenge_methods_supported: ["S256"],
      client_id_metadata_document_supported: true,
      authorization_response_iss_parameter_supported: true,
    });
    expect(metadata["token_endpoint_auth_methods_supported"]).toContain("none");
    const resource = await (await test.fetch(new Request(`${mcpBase}/.well-known/oauth-protected-resource/mcp`))).json<Record<string, unknown>>();
    expect(resource).toMatchObject({ resource: mcpResource, authorization_servers: [mcpBase], scopes_supported: ["notes:read"] });
    const unauthenticated: Response = await test.fetch(new Request(`${mcpBase}/mcp`, { method: "POST", body: "{}" }));
    expect(unauthenticated.status).toBe(401);
    expect(unauthenticated.headers.get("www-authenticate")).toContain("resource_metadata");
  });

  it("connects a client end to end (DCR, PKCE, resource) and serves the tools", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const meetingId: string = randomId();
    await putMeeting(harness, user.session, meetingId, { ...fieldsFor(user.epoch, "Quarterly budget"), folder: "Finance" });
    const tokens: Tokens = await connect(test, client, user.subject);
    expect(tokens.expires_in).toBe(3600);
    expect(tokens.scope).toBe("notes:read");
    const listed = await mcpRequest(test, tokens.access_token, "tools/list", {});
    const tools = listed.body?.result?.tools ?? [];
    expect(tools.map((tool) => tool["name"])).toEqual(["search", "fetch", "list_meetings", "list_my_tasks"]);
    for (const tool of tools) {
      expect(tool["annotations"]).toMatchObject({ readOnlyHint: true, destructiveHint: false, openWorldHint: false });
      expect(tool["outputSchema"]).toBeDefined();
      expect(tool["_meta"]).toEqual({ securitySchemes: [{ type: "oauth2", scopes: ["notes:read"] }] });
    }
    const search = await callTool(test, tokens.access_token, "search", { query: "budget" });
    expect(search.structuredContent).toEqual({ results: [{ id: meetingId, title: "Quarterly budget", url: `https://gistsmith.com/m/${meetingId}` }] });
    expect(JSON.parse(search.content?.[0]?.text ?? "")).toEqual(search.structuredContent);
    const fetched = await callTool(test, tokens.access_token, "fetch", { id: meetingId });
    expect(fetched.structuredContent).toMatchObject({
      id: meetingId,
      title: "Quarterly budget",
      url: `https://gistsmith.com/m/${meetingId}`,
      metadata: { startedAt: "2026-10-14T09:00:00+02:00", durationSec: 1800, folder: "Finance", attendees: ["Ada Lovelace"], language: "en" },
    });
    expect(String(fetched.structuredContent?.["text"])).toContain("Quarterly budget summary text");
    const connection = await env.ASSISTANT_DB.prepare("SELECT client_name, verified, calls_day, last_used_at FROM assistant_grants WHERE user_id = ?").bind(user.session.userId).first();
    expect(connection).toEqual({ client_name: "Example Client (client.example)", verified: 0, calls_day: 1, last_used_at: harness.clock.nowMs });
  });

  it("supports Client ID Metadata Documents and shows allowlisted callbacks as verified", async () => {
    const { harness, test } = await setup();
    const user: Owner = await owner(harness);
    const clientId: string = "https://claude.ai/oauth/mcp-client-metadata";
    const redirectUri: string = "https://claude.ai/api/mcp/auth_callback";
    const realFetch: typeof fetch = globalThis.fetch;
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const url: string = input instanceof Request ? input.url : String(input);
      if (url === clientId) {
        return Response.json(
          { client_id: clientId, client_name: "Claude", redirect_uris: [redirectUri], token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] },
          { headers: { "cache-control": "no-store" } },
        );
      }
      return realFetch(input, init);
    });
    const client: TestClient = { clientId, redirectUri };
    const { challenge } = await pkce();
    const { html } = await consentPageFor(test, client, user.subject, challenge);
    expect(html).toContain("<h1>Claude (verified)</h1>");
    expect(html).toContain("Signed in with Apple");
    expect(html).toContain("Gistsmith account created 15 October 2026");
    expect(html).not.toMatch(/[\w.+-]+@[\w-]+\.[\w.]+/);
    expect(html).not.toMatch(/<img/);
    const tokens: Tokens = await connect(test, client, user.subject);
    expect((await callTool(test, tokens.access_token, "list_meetings", {})).structuredContent).toEqual({ meetings: [], nextCursor: null });
    const connection = await env.ASSISTANT_DB.prepare("SELECT client_name, redirect_host, verified FROM assistant_grants WHERE user_id = ?").bind(user.session.userId).first();
    expect(connection).toEqual({ client_name: "Claude", redirect_host: "claude.ai", verified: 1 });
  });

  it("renders unverified clients by redirect host with a sanitised name and never redirects to an unregistered URI", async () => {
    const { harness, test } = await setup();
    const user: Owner = await owner(harness);
    const evil: TestClient = await registerClient(test, "https://evil.example/cb", 'Cl‮aude <script>alert(1)</script> Official Assistant Extra Long Name');
    const { challenge } = await pkce();
    const { html } = await consentPageFor(test, evil, user.subject, challenge);
    expect(html).toContain("<h1>evil.example</h1>");
    expect(unescapeHtml(html)).toContain("Unverified app: Cl aude script alert(1) /script Official</p>");
    expect(html).not.toContain("‮");
    expect(html).not.toContain("<script>alert");
    // A redirect URI the client never registered: an error page, no Location.
    const jar: CookieJar = new CookieJar();
    const bad: Response = await browse(test, jar, "GET", authorizeUrl({ ...evil, redirectUri: "https://attacker.example/cb" }, challenge, "s", mcpResource), null);
    expect(bad.status).toBe(400);
    expect(bad.headers.get("location")).toBeNull();
    expect(bad.headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
    expect(bad.headers.get("referrer-policy")).toBe("no-referrer");
    const unknown: Response = await browse(test, jar, "GET", authorizeUrl({ clientId: "no-such-client", redirectUri: evil.redirectUri }, challenge, "s", mcpResource), null);
    expect(unknown.status).toBe(400);
    expect(unknown.headers.get("location")).toBeNull();
  });

  it("refuses a wrong resource, a missing PKCE challenge and bad registrations", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const jar: CookieJar = new CookieJar();
    const { verifier, challenge } = await pkce();
    const wrong: Response = await browse(test, jar, "GET", authorizeUrl(client, challenge, "s", "https://other.example/mcp"), null);
    // An unverified (dynamically registered) client never gets a redirect for an invalid request: an error page.
    expect(wrong.status).toBe(400);
    expect(wrong.headers.get("location")).toBeNull();
    expect(await wrong.text()).toContain("a different server");
    // A public client without PKCE, or with the plain method: an error page too.
    for (const variant of ["", "&code_challenge=abc&code_challenge_method=plain"]) {
      const url: string = authorizeUrl(client, challenge, "s", mcpResource).replace(/&code_challenge=[^&]*&code_challenge_method=S256/, variant);
      const refused: Response = await browse(test, jar, "GET", url, null);
      expect(refused.status).toBe(400);
      expect(refused.headers.get("location")).toBeNull();
    }
    // A confidential client may skip PKCE in OAuth, but not here: an error page, no code.
    const registered: Response = await test.fetch(
      new Request(`${mcpBase}/oauth/register`, {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.77" },
        body: JSON.stringify({ redirect_uris: ["https://secret.example/cb"], client_name: "Confidential", token_endpoint_auth_method: "client_secret_basic" }),
      }),
    );
    const confidential: TestClient = { clientId: (await registered.json<{ client_id: string }>()).client_id, redirectUri: "https://secret.example/cb" };
    const withoutPkce: Response = await browse(test, jar, "GET", authorizeUrl(confidential, challenge, "s", mcpResource).replace(/&code_challenge=[^&]*&code_challenge_method=S256/, ""), null);
    expect(withoutPkce.status).toBe(400);
    expect(withoutPkce.headers.get("location")).toBeNull();
    expect(await withoutPkce.text()).toContain("PKCE (S256)");
    // A code exchanged for another resource is refused.
    const { html, jar: consentJar } = await consentPageFor(test, client, user.subject, challenge);
    const decided: Response = await browse(test, consentJar, "POST", "/authorize", { ...formOf(html).fields, decision: "approve" });
    const code: string = new URL(decided.headers.get("location") ?? "").searchParams.get("code") ?? "";
    const exchanged: Response = await tokenRequest(test, { grant_type: "authorization_code", code, redirect_uri: client.redirectUri, client_id: client.clientId, code_verifier: verifier, resource: "https://other.example/mcp" });
    expect(exchanged.status).toBe(400);
    expect(await exchanged.json()).toMatchObject({ error: "invalid_target" });
    // Registration policy.
    const register = (body: object): Promise<Response> =>
      test.fetch(new Request(`${mcpBase}/oauth/register`, { method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.50" }, body: JSON.stringify(body) }));
    expect((await register({ redirect_uris: ["http://remote.example/cb"], token_endpoint_auth_method: "none" })).status).toBe(400);
    expect((await register({ redirect_uris: ["https://a.example/1", "https://a.example/2", "https://a.example/3", "https://a.example/4", "https://a.example/5", "https://a.example/6"] })).status).toBe(400);
    const statuses: number[] = [];
    for (let index: number = 0; index < 11; index += 1) {
      statuses.push((await register({ redirect_uris: ["https://a.example/cb"], token_endpoint_auth_method: "none", client_name: "Spam" })).status);
    }
    expect(statuses.filter((status: number): boolean => status === 201)).toHaveLength(10);
    expect(statuses.at(-1)).toBe(429);
  });

  it("consent is single use, bound to the signed user and offers no Allow when the feature is off", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const { challenge } = await pkce();
    const { html, jar } = await consentPageFor(test, client, user.subject, challenge);
    const fields = formOf(html).fields;
    // A forged user id fails the signature.
    const forged: Response = await browse(test, jar, "POST", "/authorize", { ...fields, user: randomId(), decision: "approve" });
    expect(forged.status).toBe(400);
    const first: Response = await browse(test, jar, "POST", "/authorize", { ...fields, decision: "approve" });
    expect(first.status).toBe(302);
    const replay: Response = await browse(test, jar, "POST", "/authorize", { ...fields, decision: "approve" });
    expect(replay.status).toBe(400);
    expect(replay.headers.get("location")).toBeNull();
    // Another browser cannot use a handle it did not open.
    const second = await consentPageFor(test, client, user.subject, challenge);
    const stolen: Response = await browse(test, new CookieJar(), "POST", "/authorize", { ...formOf(second.html).fields, decision: "approve" });
    expect(stolen.status).toBe(400);
    // Feature off: the page explains and only offers Cancel; Cancel returns access_denied.
    await setAssistant(harness, user.session, false);
    const off = await consentPageFor(test, client, user.subject, challenge);
    expect(off.html).toContain("Turn on AI assistant access in the Gistsmith app first.");
    expect(off.html).not.toContain('value="approve"');
    const forcedAllow: Response = await browse(test, off.jar, "POST", "/authorize", { ...formOf(off.html).fields, decision: "approve" });
    expect(forcedAllow.status).toBe(403);
    const canceled: Response = await browse(test, off.jar, "POST", "/authorize", { ...formOf(off.html).fields, decision: "deny" });
    expect(canceled.status).toBe(302);
    expect(new URL(canceled.headers.get("location") ?? "").searchParams.get("error")).toBe("access_denied");
  });

  it("does not create accounts and rejects replayed or foreign identity tokens", async () => {
    const { test, client } = await setup();
    const { challenge } = await pkce();
    const { html } = await consentPageFor(test, client, `apple-${randomId()}`, challenge);
    expect(html).toContain("No Gistsmith account uses this Apple ID.");
    // The callback relayed without the browser's cookie is refused.
    const jar: CookieJar = new CookieJar();
    const signIn: Response = await browse(test, jar, "GET", authorizeUrl(client, challenge, "s", mcpResource), null);
    const state: string = linkOf(await signIn.text(), "https://appleid.apple.com/").searchParams.get("state") ?? "";
    const noCookie: Response = await browse(test, new CookieJar(), "POST", `/signin/finish?state=${state}`, { provider: "apple", id_token: "x".repeat(40) });
    expect(noCookie.status).toBe(400);
    // A canceled sign-in shows a way back to the app with access_denied.
    const canceled: Response = await browse(test, jar, "POST", `/signin/finish?state=${state}`, { provider: "apple", error: "user_cancelled_authorize" });
    expect(canceled.status).toBe(200);
    expect(linkOf(await canceled.text(), client.redirectUri).searchParams.get("error")).toBe("access_denied");
  });

  it("rotates refresh tokens, stops at once when the connection is removed and after 180 days", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const tokens: Tokens = await connect(test, client, user.subject);
    const refresh = (token: string): Promise<Response> => tokenRequest(test, { grant_type: "refresh_token", refresh_token: token, client_id: client.clientId });
    const second: Tokens = await (await refresh(tokens.refresh_token)).json<Tokens>();
    expect(second.refresh_token).not.toBe(tokens.refresh_token);
    const third: Response = await refresh(second.refresh_token);
    expect(third.status).toBe(200);
    // The first token's successor was used: the first is dead.
    expect((await refresh(tokens.refresh_token)).status).toBe(400);
    const thirdTokens: Tokens = await third.json<Tokens>();
    // Past the maximum age the grant is refused (and revoked).
    await env.ASSISTANT_DB.prepare("UPDATE assistant_grants SET created_at = ? WHERE user_id = ?").bind(harness.clock.nowMs - 181 * dayMs, user.session.userId).run();
    expect(await (await refresh(thirdTokens.refresh_token)).json()).toMatchObject({ error: "invalid_grant" });
    // A new connection; the app disconnects it: the very next call fails, refresh fails.
    const fresh: Tokens = await connect(test, client, user.subject);
    expect((await callTool(test, fresh.access_token, "list_my_tasks", {})).isError).toBeUndefined();
    const grants = await (await harness.call(req("GET", "/v1/assistant/grants", { token: user.session.accessToken, env: assistantEnv }))).json<{ grants: Array<{ grantId: string }> }>();
    expect(grants.grants).toHaveLength(1);
    const grantId: string = grants.grants[0]?.grantId ?? "";
    expect((await harness.call(req("DELETE", `/v1/assistant/grants/${grantId}`, { token: user.session.accessToken, env: assistantEnv }))).status).toBe(200);
    expect(toolErrorText(await callTool(test, fresh.access_token, "search", { query: "x" }))).toContain("This connection was removed");
    expect(await (await refresh(fresh.refresh_token)).json()).toMatchObject({ error: "invalid_grant" });
  });

  it("never accepts tokens of the other system", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const tokens: Tokens = await connect(test, client, user.subject);
    const appToken: Response = await test.fetch(new Request(`${mcpBase}/mcp`, { method: "POST", headers: { authorization: `Bearer ${user.session.accessToken}`, "content-type": "application/json" }, body: "{}" }));
    expect(appToken.status).toBe(401);
    // The library's tokens are not app JWTs: refused as malformed (`unauthorized`) or invalid, never accepted.
    expect((await harness.call(req("GET", "/v1/me", { token: tokens.access_token }))).status).toBe(401);
    expect((await harness.call(req("GET", "/v1/assistant/settings", { token: tokens.access_token, env: assistantEnv }))).status).toBe(401);
    const asBearer: Response = await harness.call(req("GET", "/v1/me", { headers: { authorization: `Bearer ${tokens.access_token.replaceAll(":", ".")}` } }));
    await expectError(asBearer, 401, "invalid_token");
  });

  it("signs reviewers in with email and password only when listed", async () => {
    const harness: Harness = await defaultHarness();
    const user: Owner = await owner(harness);
    const test: McpTest = mcpTest(harness, { REVIEWER_LOGINS: JSON.stringify([{ email: "Reviewer@Example.com", password: "correct horse battery staple", userId: user.session.userId }]) });
    const client: TestClient = await registerClient(test, "https://client.example/callback", "Reviewer Client");
    const { challenge } = await pkce();
    const jar: CookieJar = new CookieJar();
    const signIn: Response = await browse(test, jar, "GET", authorizeUrl(client, challenge, "s", mcpResource), null);
    const reviewer: URL = linkOf(await signIn.text(), "/signin/reviewer");
    const path: string = `${reviewer.pathname}${reviewer.search}`;
    expect((await browse(test, jar, "GET", path, null)).status).toBe(200);
    const wrong: Response = await browse(test, jar, "POST", path, { email: "reviewer@example.com", password: "wrong password here" });
    expect(wrong.status).toBe(401);
    const right: Response = await browse(test, jar, "POST", path, { email: "reviewer@example.com", password: "correct horse battery staple" });
    expect(right.status).toBe(200);
    expect(await right.text()).toContain("Signed in with a reviewer account");
    // Without reviewer accounts there is no link and no page.
    const plain: McpTest = mcpTest(harness, {});
    const plainSignIn: Response = await browse(plain, new CookieJar(), "GET", authorizeUrl(client, challenge, "s", mcpResource), null);
    expect(await plainSignIn.text()).not.toContain("/signin/reviewer");
    expect((await browse(plain, jar, "GET", path, null)).status).toBe(404);
  });
});

describe("MCP cron", () => {
  it("revokes disconnected grants in KV and deletes unused registrations", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const unused: TestClient = await registerClient(test, "https://unused.example/cb", "Unused");
    await connect(test, client, user.subject);
    const oauth = getOAuthApi(mcpProviderOptions(() => harness.platform), test.env);
    expect((await oauth.listUserGrants(user.session.userId)).items).toHaveLength(1);
    await setAssistant(harness, user.session, false);
    await test.scheduled(Date.now() + 2 * dayMs);
    expect((await oauth.listUserGrants(user.session.userId)).items).toEqual([]);
    expect(await env.ASSISTANT_DB.prepare("SELECT COUNT(*) AS count FROM assistant_revocations WHERE user_id = ?").bind(user.session.userId).first()).toEqual({ count: 0 });
    expect(await oauth.lookupClient(unused.clientId)).toBeNull();
  });
});

describe("MCP tools", () => {
  it("pages, filters and lists tasks; two accounts with the same meeting id never cross", async () => {
    const { harness, test, client } = await setup();
    const first: Owner = await owner(harness);
    const second: Owner = await owner(harness);
    const shared: string = randomId();
    await putMeeting(harness, first.session, shared, { ...fieldsFor(first.epoch, "Alpha strategy"), startedAt: "2026-10-01T10:00:00+00:00", folder: "Work" });
    await putMeeting(harness, second.session, shared, { ...fieldsFor(second.epoch, "Beta secret"), startedAt: "2026-10-01T10:00:00+00:00" });
    for (let day: number = 2; day <= 4; day += 1) {
      await putMeeting(harness, first.session, randomId(), { ...fieldsFor(first.epoch, `Daily ${day}`), startedAt: `2026-10-0${day}T10:00:00+00:00`, folder: day === 3 ? "Work" : null });
    }
    const firstTokens: Tokens = await connect(test, client, first.subject);
    const secondTokens: Tokens = await connect(test, client, second.subject);
    const page1 = (await callTool(test, firstTokens.access_token, "list_meetings", { limit: 2 })).structuredContent as { meetings: Array<{ title: string }>; nextCursor: string };
    expect(page1.meetings.map((meeting) => meeting.title)).toEqual(["Daily 4", "Daily 3"]);
    const page2 = (await callTool(test, firstTokens.access_token, "list_meetings", { limit: 2, cursor: page1.nextCursor })).structuredContent as { meetings: Array<{ title: string }>; nextCursor: string | null };
    expect(page2.meetings.map((meeting) => meeting.title)).toEqual(["Daily 2", "Alpha strategy"]);
    expect(page2.nextCursor).toBeNull();
    const work = (await callTool(test, firstTokens.access_token, "list_meetings", { folder: "work" })).structuredContent as { meetings: Array<{ title: string }> };
    expect(work.meetings.map((meeting) => meeting.title)).toEqual(["Daily 3", "Alpha strategy"]);
    const ranged = (await callTool(test, firstTokens.access_token, "list_meetings", { since: "2026-10-02T00:00:00+00:00", until: "2026-10-04T00:00:00Z" })).structuredContent as { meetings: Array<{ title: string }> };
    expect(ranged.meetings.map((meeting) => meeting.title)).toEqual(["Daily 3", "Daily 2"]);
    expect(toolErrorText(await callTool(test, firstTokens.access_token, "list_meetings", { since: "yesterday" }))).toContain("ISO 8601");
    expect(toolErrorText(await callTool(test, firstTokens.access_token, "list_meetings", { cursor: "forged" }))).toContain("cursor is not valid");
    const tasks = (await callTool(test, firstTokens.access_token, "list_my_tasks", {})).structuredContent as { tasks: Array<{ description: string; done: boolean }> };
    expect(tasks.tasks.map((task) => task.description)).toEqual(["Follow up on Daily 4", "Follow up on Daily 3", "Follow up on Daily 2", "Follow up on Alpha strategy"]);
    const withDone = (await callTool(test, firstTokens.access_token, "list_my_tasks", { include_done: true })).structuredContent as { tasks: unknown[] };
    expect(withDone.tasks).toHaveLength(8);
    // Same meeting id, different accounts.
    expect((await callTool(test, secondTokens.access_token, "fetch", { id: shared })).structuredContent?.["title"]).toBe("Beta secret");
    expect((await callTool(test, firstTokens.access_token, "fetch", { id: shared })).structuredContent?.["title"]).toBe("Alpha strategy");
    expect((await callTool(test, secondTokens.access_token, "search", { query: "alpha strategy" })).structuredContent).toEqual({ results: [] });
    expect(toolErrorText(await callTool(test, firstTokens.access_token, "fetch", { id: "not-an-id" }))).toContain("No meeting has this id");
    expect(toolErrorText(await callTool(test, firstTokens.access_token, "search", { query: "!!!" }))).toContain("at least one word");
  });

  it("checks the feature, access, limits and heavy reading on every call", async () => {
    const { harness, test, client } = await setup();
    const user: Owner = await owner(harness);
    const meetingId: string = randomId();
    await putMeeting(harness, user.session, meetingId, fieldsFor(user.epoch, "Limits"));
    const tokens: Tokens = await connect(test, client, user.subject);
    // Per-connection rate limit.
    const limited: McpTest = { ...test, fetch: mcpTest(harness, { MCP_GRANT_LIMITER: blockingLimiter }).fetch };
    expect(toolErrorText(await callTool(limited, tokens.access_token, "search", { query: "limits" }))).toContain("Too many requests");
    // Daily fetch limit.
    await env.ASSISTANT_DB.prepare("UPDATE assistant_grants SET calls_day = 300, calls_day_date = '2026-10-15' WHERE user_id = ?").bind(user.session.userId).run();
    expect(toolErrorText(await callTool(test, tokens.access_token, "fetch", { id: meetingId }))).toContain("daily limit");
    expect((await callTool(test, tokens.access_token, "search", { query: "limits" })).isError).toBeUndefined();
    // Heavy reading: more than 100 meetings returned within an hour marks the connection once.
    await env.ASSISTANT_DB.prepare("UPDATE assistant_grants SET reads_hour = 100, reads_hour_start = ? WHERE user_id = ?").bind(harness.clock.nowMs, user.session.userId).run();
    await callTool(test, tokens.access_token, "search", { query: "limits" });
    const marked = await env.ASSISTANT_DB.prepare("SELECT heavy_read_at FROM assistant_grants WHERE user_id = ?").bind(user.session.userId).first<{ heavy_read_at: number | null }>();
    expect(marked?.heavy_read_at).toBe(harness.clock.nowMs);
    const events = await env.ASSISTANT_DB.prepare("SELECT count FROM assistant_ops_events WHERE kind = 'heavy_reader'").first<{ count: number }>();
    expect(events?.count).toBeGreaterThanOrEqual(1);
    // Access ended: refused at once, no upsell.
    harness.clock.nowMs += 70 * dayMs;
    const ended: string = toolErrorText(await callTool(test, tokens.access_token, "search", { query: "limits" }));
    expect(ended).toContain("isn't available on this Gistsmith account");
    expect(ended).not.toMatch(/subscribe|checkout|upgrade|http/i);
    harness.clock.nowMs -= 70 * dayMs;
    // Feature off: refused at once (the copy is gone too).
    await setAssistant(harness, user.session, false);
    expect(toolErrorText(await callTool(test, tokens.access_token, "search", { query: "limits" }))).toContain("AI assistant access is off");
  });

  it("logs no note text, titles, queries, tokens or reviewer credentials", async () => {
    const lines: string[] = [];
    for (const method of ["log", "info", "warn", "error", "debug"] as const) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]): void => {
        lines.push(args.map((arg: unknown): string => (typeof arg === "string" ? arg : JSON.stringify(arg) ?? String(arg))).join(" "));
      });
    }
    const harness: Harness = await defaultHarness();
    const user: Owner = await owner(harness);
    const test: McpTest = mcpTest(harness, { REVIEWER_LOGINS: JSON.stringify([{ email: "rev@example.com", password: "reviewer-password-0001", userId: user.session.userId }]) });
    const client: TestClient = await registerClient(test, "https://client.example/callback", "Logger Client");
    const meetingId: string = randomId();
    await putMeeting(harness, user.session, meetingId, { ...fieldsFor(user.epoch, "Zebracorn merger"), summary: "Confidential zebracorn numbers" });
    const tokens: Tokens = await connect(test, client, user.subject);
    await callTool(test, tokens.access_token, "search", { query: "zebracorn quokka" });
    await callTool(test, tokens.access_token, "fetch", { id: meetingId });
    await callTool(test, tokens.access_token, "fetch", { id: "zebracorn-not-an-id" });
    await tokenRequest(test, { grant_type: "refresh_token", refresh_token: tokens.refresh_token, client_id: client.clientId });
    await tokenRequest(test, { grant_type: "refresh_token", refresh_token: "zebracorn-bad-token", client_id: client.clientId });
    const { challenge } = await pkce();
    const jar: CookieJar = new CookieJar();
    const signIn: Response = await browse(test, jar, "GET", authorizeUrl(client, challenge, "s", mcpResource), null);
    const reviewer: URL = linkOf(await signIn.text(), "/signin/reviewer");
    await browse(test, jar, "POST", `${reviewer.pathname}${reviewer.search}`, { email: "rev@example.com", password: "zebracorn-wrong" });
    const joined: string = lines.join("\n");
    expect(lines.length).toBeGreaterThan(0);
    for (const secret of ["zebracorn", "Zebracorn", "quokka", tokens.access_token, tokens.refresh_token, "reviewer-password", "rev@example.com", "Ada Lovelace"]) {
      expect(joined).not.toContain(secret);
    }
  });
});
