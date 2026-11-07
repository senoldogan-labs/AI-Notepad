import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { projectionUploadSchema } from "../src/assistant/projection";
import { type DemoMeeting, reviewerDemoMeetings, reviewerUserId } from "../src/assistant/reviewer";
import { mcpResource } from "../src/mcp/config";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, req, signInWithGoogle } from "./helpers";
import { allowingLimiter, assistantRows } from "./assistantHelpers";
import { type McpTest, type TestClient, type Tokens, CookieJar, authorizeUrl, browse, callTool, formOf, linkOf, mcpTest, pkce, registerClient, tokenRequest, toolErrorText } from "./mcpHarness";

const adminSubject: string = "reviewer-admin-sub";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}`, ASSISTANT_USER_LIMITER: allowingLimiter });
const reviewerEmail: string = "reviewer@example.com";
const reviewerPassword: string = "directory-review-password-0001";

interface SeedBody {
  readonly userId: string;
  readonly epoch: number;
  readonly meetingIds: readonly string[];
}

async function seed(harness: Harness, admin: Session): Promise<SeedBody> {
  const response: Response = await harness.call(req("POST", "/v1/admin/assistant/reviewer", { token: admin.accessToken, env: adminEnv }));
  expect(response.status).toBe(200);
  return response.json<SeedBody>();
}

/** Signs in on the reviewer form, allows the connection and exchanges the code. */
async function reviewerTokens(test: McpTest, client: TestClient): Promise<Tokens> {
  const { verifier, challenge } = await pkce();
  const jar: CookieJar = new CookieJar();
  const signIn: Response = await browse(test, jar, "GET", authorizeUrl(client, challenge, "client-state-1", mcpResource), null);
  const reviewer: URL = linkOf(await signIn.text(), "/signin/reviewer");
  const consentPage: Response = await browse(test, jar, "POST", `${reviewer.pathname}${reviewer.search}`, { email: reviewerEmail, password: reviewerPassword });
  expect(consentPage.status).toBe(200);
  const consent = formOf(await consentPage.text());
  const decided: Response = await browse(test, jar, "POST", "/authorize", { ...consent.fields, decision: "approve" });
  expect(decided.status).toBe(302);
  const code: string = new URL(decided.headers.get("location") ?? "").searchParams.get("code") ?? "";
  const token: Response = await tokenRequest(test, {
    grant_type: "authorization_code",
    code,
    redirect_uri: client.redirectUri,
    client_id: client.clientId,
    code_verifier: verifier,
    resource: mcpResource,
  });
  expect(token.status).toBe(200);
  return token.json<Tokens>();
}

describe("Reviewer account seed", () => {
  it("builds six valid demo meetings with app-format ids over the last two weeks", () => {
    const now: Date = new Date("2026-11-07T12:00:00Z");
    const meetings: DemoMeeting[] = reviewerDemoMeetings(1, now);
    expect(meetings).toHaveLength(6);
    for (const meeting of meetings) {
      expect(meeting.meetingId).toMatch(/^\d{8}-\d{6}$/);
      expect(projectionUploadSchema.parse(meeting.upload)).toEqual(meeting.upload);
      const ageMs: number = now.getTime() - Date.parse(meeting.upload.startedAt);
      expect(ageMs).toBeGreaterThan(0);
      expect(ageMs).toBeLessThan(14 * 86_400_000);
    }
    expect(meetings[0]?.meetingId).toBe("20261025-093000");
  });

  it("seeds one account idempotently, serves it to a reviewer sign-in and removes access", async () => {
    const harness: Harness = await defaultHarness();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const someone: Session = await signInWithGoogle(harness, "not-an-admin");
    expect((await harness.call(req("POST", "/v1/admin/assistant/reviewer", { token: someone.accessToken, env: adminEnv }))).status).toBe(403);

    const first: SeedBody = await seed(harness, admin);
    const second: SeedBody = await seed(harness, admin);
    expect(first.userId).toBe(reviewerUserId);
    expect(second).toEqual(first);
    expect(first.meetingIds).toHaveLength(6);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM users WHERE id = ?").bind(reviewerUserId).first()).toEqual({ count: 1 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM auth_identities WHERE user_id = ?").bind(reviewerUserId).first()).toEqual({ count: 0 });
    expect(await assistantRows("assistant_meetings", reviewerUserId)).toBe(6);
    expect(await env.DB.prepare("SELECT complimentary, status FROM subscriptions WHERE user_id = ?").bind(reviewerUserId).first()).toEqual({ complimentary: 1, status: "active" });

    // A later seed moves the dates; the copy still holds exactly the current six.
    harness.clock.nowMs += 3 * 86_400_000;
    const laterAdmin: Session = await signInWithGoogle(harness, adminSubject);
    const later: SeedBody = await seed(harness, laterAdmin);
    expect(later.meetingIds).not.toEqual(first.meetingIds);
    expect(await assistantRows("assistant_meetings", reviewerUserId)).toBe(6);

    const test: McpTest = mcpTest(harness, { REVIEWER_LOGINS: JSON.stringify([{ email: reviewerEmail, password: reviewerPassword, userId: reviewerUserId }]) });
    const client: TestClient = await registerClient(test, "https://client.example/callback", "Directory Review");
    const tokens: Tokens = await reviewerTokens(test, client);
    const listed = (await callTool(test, tokens.access_token, "list_meetings", {})).structuredContent as { meetings: Array<{ id: string; title: string }> };
    expect(listed.meetings.map((meeting) => meeting.title)).toEqual([
      "Weekly product stand-up",
      "Q1 budget review",
      "1:1 with Priya",
      "Hiring debrief: Senior Robotics Engineer",
      "Brightwater Logistics pilot review",
      "Q1 product planning",
    ]);
    const open = (await callTool(test, tokens.access_token, "list_my_tasks", {})).structuredContent as { tasks: unknown[] };
    const all = (await callTool(test, tokens.access_token, "list_my_tasks", { include_done: true })).structuredContent as { tasks: unknown[] };
    expect([open.tasks.length, all.tasks.length]).toEqual([5, 8]);
    const search = (await callTool(test, tokens.access_token, "search", { query: "Brightwater" })).structuredContent as { results: unknown[] };
    expect(search.results.length).toBeGreaterThan(0);
    const fetched = await callTool(test, tokens.access_token, "fetch", { id: listed.meetings[1]?.id ?? "" });
    expect(String(fetched.structuredContent?.["text"])).toContain("Raw sensor data retention goes from 90 to 30 days.");

    const removed: Response = await harness.call(req("DELETE", "/v1/admin/assistant/reviewer", { token: laterAdmin.accessToken, env: adminEnv }));
    expect(await removed.json()).toEqual({ userId: reviewerUserId, assistantEnabled: false, complimentaryRevoked: true });
    expect(await assistantRows("assistant_meetings", reviewerUserId)).toBe(0);
    expect(await assistantRows("assistant_grants", reviewerUserId)).toBe(0);
    expect(toolErrorText(await callTool(test, tokens.access_token, "list_meetings", {}))).toContain("AI assistant access is off");
    const again: Response = await harness.call(req("DELETE", "/v1/admin/assistant/reviewer", { token: laterAdmin.accessToken, env: adminEnv }));
    expect(await again.json()).toEqual({ userId: reviewerUserId, assistantEnabled: false, complimentaryRevoked: false });
    await expectError(await harness.call(req("DELETE", "/v1/admin/assistant/reviewer", { token: (await signInWithGoogle(harness, "not-an-admin")).accessToken, env: adminEnv })), 403, "forbidden");
  });
});
