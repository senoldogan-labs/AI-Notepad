import {
  type AuthRequest,
  AuthorizationError,
  CimdFetchError,
  type ClientInfo,
  type OAuthHelpers,
  authorizationErrorRedirect,
} from "@cloudflare/workers-oauth-provider";
import { z } from "zod";
import { appleIssuer, appleJwksUrl } from "../auth/apple";
import { googleIssuers, googleJwksUrl } from "../auth/google";
import { type IdentityTokenIssuer, type VerifiedIdentityToken, verifyIdentityToken } from "../auth/identityToken";
import { type IdentityProvider, findUserId } from "../auth/users";
import { constantTimeEqualText, randomToken, sha256Hex } from "../crypto";
import { ApiError, ProviderApiError, UpstreamError } from "../errors";
import { clientIpKey } from "../ip";
import { errorName, log } from "../log";
import type { OutboundPlatform } from "../platform";
import { type ClientPresentation, connectionLabel, isVerifiedRedirect, presentClient } from "./clients";
import { type McpConfig, type ReviewerLogin, notesReadScope } from "./config";
import type { McpEnv } from "./env";
import { type UserGate, gateMessage, hmacHex, purposeKey, userGate } from "./gate";
import { type ConsentProps, markClientUsed } from "./grants";
import {
  type AccountSummary,
  type ConsentState,
  type Page,
  canceledPage,
  consentPage,
  errorPage,
  newNonce,
  pageResponse,
  relayPage,
  reviewerPage,
  signInPage,
} from "./html";

/**
 * The authorization pages on mcp.gistsmith.com (the library owns metadata, token, registration and revocation):
 *
 * 1. `GET /authorize`: the library validates the client, redirect URI, resource and PKCE (`parseAuthRequest`); S256 is
 *    required of every client. An invalid client or redirect URI renders an error page and never redirects. The page
 *    shows who is asking and offers Apple / Google sign-in (redirect flows, `response_mode=form_post`), with a
 *    browser-bound, single-use, 10-minute transaction (`beginUpstream`) whose state goes to the provider and whose
 *    data holds the raw nonce (the provider gets its SHA-256).
 * 2. `POST /signin/{apple,google}/callback`: the provider's cross-site form post. The transaction cookie is
 *    SameSite=Lax and not sent on it, so the page posts the same fields again from this origin (`relayPage`).
 * 3. `POST /signin/finish?state=…`: opens the transaction (cookie required), verifies the identity token (signature,
 *    issuer, audience, expiry, single-use nonce), finds the existing Gistsmith account (none is created here) and
 *    renders the consent page (`beginConsent`, browser-bound handle). The user id travels in the form, signed with a
 *    key derived from `ASSISTANT_DATA_KEY` and bound to the handle.
 * 4. `POST /authorize`: Allow (only when the feature is on and the account has access) completes the authorization;
 *    Cancel redirects back with `access_denied`.
 *
 * The consent page shows the sign-in provider and the account's creation date, never an email (the server stores
 * none). Reviewer accounts (`REVIEWER_LOGINS`) sign in with email and password at `/signin/reviewer`, rate limited.
 */

/** Data kept in the upstream transaction. */
const upstreamDataSchema = z.strictObject({ rawNonce: z.string().min(32).max(128) });
const callbackSchema = z.object({
  state: z.string().min(16).max(200),
  id_token: z.string().min(20).max(8192).optional(),
  error: z.string().min(1).max(200).optional(),
});
const finishSchema = z.object({
  provider: z.enum(["apple", "google"]),
  id_token: z.string().min(20).max(8192).optional(),
  error: z.string().min(1).max(200).optional(),
});
const consentFormSchema = z.object({
  handle: z.string().min(16).max(200),
  decision: z.enum(["approve", "deny"]),
  user: z.uuid(),
  signature: z.string().regex(/^[0-9a-f]{64}$/),
});
const reviewerFormSchema = z.object({ email: z.string().min(3).max(200), password: z.string().min(1).max(200) });
/** Form bodies on these pages are small. */
const formMaxBytes: number = 16 * 1024;

/** A page-level failure: rendered, never redirected. */
class PageError extends Error {
  override readonly name: string = "PageError";
  readonly status: number;
  readonly title: string;

  constructor(status: number, title: string, message: string) {
    super(message);
    this.status = status;
    this.title = title;
  }
}

/** What the pages need besides the request. */
export interface AuthorizeContext {
  readonly env: McpEnv;
  readonly oauth: OAuthHelpers;
  readonly config: McpConfig;
  readonly platform: OutboundPlatform;
}

/** The identity token issuer of a provider for this Worker's client ids. Pure function. */
export function signInIssuer(provider: "apple" | "google", config: McpConfig): IdentityTokenIssuer {
  return provider === "apple"
    ? { displayName: "Apple", jwksService: "apple_jwks", jwksUrl: appleJwksUrl, issuers: [appleIssuer], audiences: [config.appleClientId] }
    : { displayName: "Google", jwksService: "google_jwks", jwksUrl: googleJwksUrl, issuers: googleIssuers, audiences: [config.googleClientId] };
}

/** Apple's authorize URL (form post, no name or email requested). Pure function. */
export function appleAuthorizeUrl(clientId: string, origin: string, state: string, nonceHash: string): string {
  const url: URL = new URL("https://appleid.apple.com/auth/authorize");
  url.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: `${origin}/signin/apple/callback`,
    response_type: "code id_token",
    response_mode: "form_post",
    state,
    nonce: nonceHash,
  }).toString();
  return url.toString();
}

/** Google's authorize URL (OpenID Connect implicit id_token with form post). Pure function. */
export function googleAuthorizeUrl(clientId: string, origin: string, state: string, nonceHash: string): string {
  const url: URL = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: `${origin}/signin/google/callback`,
    response_type: "id_token",
    response_mode: "form_post",
    scope: "openid",
    prompt: "select_account",
    state,
    nonce: nonceHash,
  }).toString();
  return url.toString();
}

async function formOf<Schema extends z.ZodType>(request: Request, schema: Schema): Promise<z.output<Schema>> {
  const declared: string | null = request.headers.get("content-length");
  if (declared !== null && Number(declared) > formMaxBytes) {
    throw new PageError(413, "Request too large", "Start again from your assistant.");
  }
  const contentType: string = request.headers.get("content-type") ?? "";
  if (!contentType.startsWith("application/x-www-form-urlencoded") && !contentType.startsWith("multipart/form-data")) {
    throw new PageError(415, "Unexpected request", "Start again from your assistant.");
  }
  const form: FormData = await request.formData();
  const fields: Record<string, string> = {};
  for (const [name, value] of form) {
    if (typeof value === "string") {
      fields[name] = value;
    }
  }
  const parsed = schema.safeParse(fields);
  if (!parsed.success) {
    throw new PageError(400, "Something is missing", "This page was sent incompletely. Start again from your assistant.");
  }
  return parsed.data;
}

async function presentationOf(oauth: OAuthHelpers, auth: AuthRequest): Promise<ClientPresentation> {
  const client: ClientInfo | null = await oauth.lookupClient(auth.clientId);
  return presentClient(auth.redirectUri, client?.clientName ?? null);
}

/** User-facing text of an invalid authorization request (the code is the library's, never client-supplied). Pure function. */
export function authorizationRefusalMessage(code: string): string {
  if (code === "invalid_target") {
    return "The app asked for access to a different server than Gistsmith's. Check the connector URL (https://mcp.gistsmith.com/mcp) or contact the app's developer.";
  }
  if (code === "invalid_scope") {
    return "The app asked for access Gistsmith doesn't offer. Contact the app's developer.";
  }
  return "The app's sign-in request is incomplete or not supported (it must use PKCE with S256). Update the app or contact its developer.";
}

/** `GET /authorize`. */
async function startAuthorization(request: Request, context: AuthorizeContext): Promise<Response> {
  let auth: AuthRequest;
  try {
    auth = await context.oauth.parseAuthRequest(request);
  } catch (error: unknown) {
    // Only a verified product's callback gets the standard OAuth error redirect (and only one the library validated).
    // Any client can register through DCR, so redirecting its invalid requests would make this origin an open redirector
    // (RFC 9700 §4.11.2): those get an error page instead.
    if (error instanceof AuthorizationError && error.redirectTo !== undefined && isVerifiedRedirect(error.redirectTo)) {
      return new Response(null, { status: 302, headers: { location: error.redirectTo, "cache-control": "no-store", "referrer-policy": "no-referrer" } });
    }
    if (error instanceof AuthorizationError && error.redirectTo !== undefined) {
      log("info", "assistant_authorize_refused", { path: "/authorize", code: error.code });
      throw new PageError(400, "This app's request can't be used", authorizationRefusalMessage(error.code));
    }
    throw error;
  }
  if (auth.codeChallenge === undefined || auth.codeChallengeMethod !== "S256") {
    throw new PageError(400, "This app can't connect", "It must sign in with PKCE (S256). Update the app or contact its developer.");
  }
  const presentation: ClientPresentation = await presentationOf(context.oauth, auth);
  const rawNonce: string = randomToken(32);
  const upstream = await context.oauth.beginUpstream(auth, { data: { rawNonce } });
  const origin: string = new URL(request.url).origin;
  const nonceHash: string = await sha256Hex(rawNonce);
  const reviewerUrl: string | null = context.config.reviewers.length === 0 ? null : `/signin/reviewer?state=${encodeURIComponent(upstream.state)}`;
  const page: Page = signInPage(
    presentation,
    appleAuthorizeUrl(context.config.appleClientId, origin, upstream.state, nonceHash),
    googleAuthorizeUrl(context.config.googleClientId, origin, upstream.state, nonceHash),
    reviewerUrl,
    newNonce(),
  );
  return pageResponse(page, upstream.headers);
}

/** `POST /signin/{provider}/callback`: re-post from this origin. */
async function relayCallback(request: Request, provider: "apple" | "google"): Promise<Response> {
  const body = await formOf(request, callbackSchema);
  const fields: Record<string, string> = { provider };
  if (body.id_token !== undefined) {
    fields["id_token"] = body.id_token;
  }
  if (body.error !== undefined || body.id_token === undefined) {
    fields["error"] = body.error ?? "missing_id_token";
  }
  return pageResponse(relayPage(`/signin/finish?state=${encodeURIComponent(body.state)}`, fields, newNonce()), null);
}

/** The consent page for a signed-in account. */
async function consentResponse(
  context: AuthorizeContext,
  auth: AuthRequest,
  userId: string,
  provider: AccountSummary["provider"],
  headers: Headers,
): Promise<Response> {
  const now: Date = context.platform.now();
  const gate: UserGate = await userGate(context.env.DB, context.env.ASSISTANT_DB, context.config.access, userId, now);
  if (gate.kind === "missing") {
    throw new PageError(403, "No Gistsmith account", gateMessage(gate));
  }
  const user: { created_at: number } | null = await context.env.DB.prepare("SELECT created_at FROM users WHERE id = ?").bind(userId).first<{ created_at: number }>();
  if (user === null) {
    throw new PageError(403, "No Gistsmith account", "This Gistsmith account no longer exists.");
  }
  const state: ConsentState = gate.kind === "ready" ? "ready" : gate.kind;
  const presentation: ClientPresentation = await presentationOf(context.oauth, auth);
  const consent = await context.oauth.beginConsent(auth);
  const signature: string = await hmacHex(await purposeKey(context.config.keyring, "consent"), `${consent.handle}|${userId}`);
  for (const cookie of consent.headers.getSetCookie()) {
    headers.append("set-cookie", cookie);
  }
  const page: Page = consentPage(
    presentation,
    { provider, createdAt: new Date(user.created_at) },
    state,
    { handle: consent.handle, user: userId, signature },
    new URL(auth.redirectUri).origin,
    newNonce(),
  );
  return pageResponse(page, headers);
}

/** `POST /signin/finish?state=…`. */
async function finishSignIn(request: Request, context: AuthorizeContext): Promise<Response> {
  const body = await formOf(request, finishSchema);
  const upstream = await context.oauth.finishUpstream(request);
  const data = upstreamDataSchema.parse(upstream.data);
  if (body.error !== undefined || body.id_token === undefined) {
    return pageResponse(canceledPage(authorizationErrorRedirect(upstream.request, "access_denied"), newNonce()), upstream.headers);
  }
  const provider: IdentityProvider = body.provider;
  const identity: VerifiedIdentityToken = await verifyIdentityToken(context.env.ASSISTANT_DB, context.platform, signInIssuer(provider, context.config), body.id_token, data.rawNonce);
  const userId: string | null = await findUserId(context.env.DB, provider, identity.subject);
  if (userId === null) {
    const name: string = provider === "apple" ? "Apple ID" : "Google account";
    throw new PageError(403, "No Gistsmith account", `No Gistsmith account uses this ${name}. Sign in to the Gistsmith app with it first, then connect again.`);
  }
  log("info", "assistant_signin", { provider, userId });
  return consentResponse(context, upstream.request, userId, provider, upstream.headers);
}

/** The reviewer whose email and password match, compared in constant time against every entry. */
async function matchingReviewer(reviewers: readonly ReviewerLogin[], email: string, password: string): Promise<ReviewerLogin | null> {
  let match: ReviewerLogin | null = null;
  for (const reviewer of reviewers) {
    const [emailOk, passwordOk]: [boolean, boolean] = await Promise.all([
      constantTimeEqualText(reviewer.email, email.trim().toLowerCase()),
      constantTimeEqualText(reviewer.password, password),
    ]);
    if (emailOk && passwordOk) {
      match = reviewer;
    }
  }
  return match;
}

/** `GET`/`POST /signin/reviewer?state=…`. */
async function reviewerSignIn(request: Request, context: AuthorizeContext, ipKey: string): Promise<Response> {
  if (context.config.reviewers.length === 0) {
    throw new PageError(404, "Not found", "There is no such page.");
  }
  const state: string | null = new URL(request.url).searchParams.get("state");
  if (state === null || state.length < 16 || state.length > 200) {
    throw new PageError(400, "Something is missing", "Start again from your assistant.");
  }
  const action: string = `/signin/reviewer?state=${encodeURIComponent(state)}`;
  if (request.method === "GET") {
    return pageResponse(reviewerPage(action, false, newNonce()), null);
  }
  const outcome: RateLimitOutcome = await context.env.MCP_REVIEWER_LIMITER.limit({ key: `ip:${ipKey}` });
  if (!outcome.success) {
    throw new PageError(429, "Too many attempts", "Wait a minute and try again.");
  }
  const body = await formOf(request, reviewerFormSchema);
  const reviewer: ReviewerLogin | null = await matchingReviewer(context.config.reviewers, body.email, body.password);
  if (reviewer === null) {
    log("warn", "assistant_reviewer_signin_failed", {});
    return pageResponse(reviewerPage(action, true, newNonce()), null);
  }
  const upstream = await context.oauth.finishUpstream(request);
  log("info", "assistant_signin", { provider: "reviewer", userId: reviewer.userId });
  return consentResponse(context, upstream.request, reviewer.userId, "reviewer", upstream.headers);
}

/** `POST /authorize`: the consent decision. */
async function decideConsent(request: Request, context: AuthorizeContext): Promise<Response> {
  const body = await formOf(request, consentFormSchema);
  if (body.decision === "deny") {
    const denied = await context.oauth.denyConsent(request, body.handle);
    return new Response(null, { status: 302, headers: denied.headers });
  }
  const expected: string = await hmacHex(await purposeKey(context.config.keyring, "consent"), `${body.handle}|${body.user}`);
  if (!(await constantTimeEqualText(expected, body.signature))) {
    throw new PageError(400, "This page has expired", "Start again from your assistant.");
  }
  const gate: UserGate = await userGate(context.env.DB, context.env.ASSISTANT_DB, context.config.access, body.user, context.platform.now());
  if (gate.kind !== "ready") {
    throw new PageError(403, "Can't connect", gateMessage(gate));
  }
  const approved = await context.oauth.approveConsent(request, body.handle, { scope: [notesReadScope] });
  await markClientUsed(context.env.ASSISTANT_DB, approved.request.clientId, context.platform.now());
  const presentation: ClientPresentation = await presentationOf(context.oauth, approved.request);
  const props: ConsentProps = {
    userId: body.user,
    epoch: gate.epoch,
    clientName: connectionLabel(presentation),
    redirectHost: presentation.redirectHost,
    verified: presentation.kind === "verified",
  };
  const { redirectTo } = await context.oauth.completeAuthorization({
    request: approved.request,
    userId: body.user,
    metadata: {},
    scope: [notesReadScope],
    props,
  });
  log("info", "assistant_consent_approved", { userId: body.user, verified: props.verified });
  approved.headers.set("location", redirectTo);
  approved.headers.set("referrer-policy", "no-referrer");
  return new Response(null, { status: 302, headers: approved.headers });
}

/** Renders any failure of these pages; nothing here redirects. */
function failureResponse(error: unknown, path: string): Response {
  const nonce: string = newNonce();
  if (error instanceof PageError) {
    return pageResponse(errorPage(error.status, error.title, error.message, nonce), null);
  }
  if (error instanceof AuthorizationError) {
    log("info", "assistant_authorize_refused", { path, code: error.code });
    return pageResponse(errorPage(400, "Can't continue", "This sign-in expired, was already used or was opened in another browser. Start again from your assistant.", nonce), null);
  }
  if (error instanceof CimdFetchError) {
    log("warn", "assistant_cimd_failed", { path, reason: error.reason });
    return pageResponse(errorPage(400, "This app could not be verified", "Gistsmith couldn't read this app's details. Try again later or contact the app's developer.", nonce), null);
  }
  if (error instanceof ApiError && error.code === "invalid_token") {
    log("info", "assistant_signin_rejected", { path });
    return pageResponse(errorPage(400, "Sign-in failed", "The sign-in couldn't be confirmed. Start again from your assistant.", nonce), null);
  }
  if (error instanceof UpstreamError || error instanceof ProviderApiError) {
    log("error", "assistant_signin_upstream_failed", { path, error: errorName(error) });
    return pageResponse(errorPage(502, "Sign-in is unavailable", "Apple or Google didn't respond. Try again in a moment.", nonce), null);
  }
  log("error", "assistant_authorize_failed", { path, error: errorName(error) });
  return pageResponse(errorPage(500, "Something went wrong", "Try again in a moment.", nonce), null);
}

/** The Worker's non-OAuth routes (the provider's `defaultHandler`). */
export async function handleAuthorizePages(request: Request, context: AuthorizeContext, clientIp: string): Promise<Response> {
  const path: string = new URL(request.url).pathname;
  const method: string = request.method;
  const ipKey: string = clientIpKey(clientIp);
  try {
    if (path === "/" && method === "GET") {
      return new Response("Gistsmith MCP server. Add https://mcp.gistsmith.com/mcp as a connector in your AI assistant.\n", {
        headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "public, max-age=3600" },
      });
    }
    const outcome: RateLimitOutcome = await context.env.MCP_IP_LIMITER.limit({ key: `ip:${ipKey}` });
    if (!outcome.success) {
      throw new PageError(429, "Too many requests", "Wait a minute and try again.");
    }
    if (path === "/authorize" && method === "GET") {
      return await startAuthorization(request, context);
    }
    if (path === "/authorize" && method === "POST") {
      return await decideConsent(request, context);
    }
    if (path === "/signin/apple/callback" && method === "POST") {
      return await relayCallback(request, "apple");
    }
    if (path === "/signin/google/callback" && method === "POST") {
      return await relayCallback(request, "google");
    }
    if (path === "/signin/finish" && method === "POST") {
      return await finishSignIn(request, context);
    }
    if (path === "/signin/reviewer" && (method === "GET" || method === "POST")) {
      return await reviewerSignIn(request, context, ipKey);
    }
    throw new PageError(404, "Not found", "There is no such page.");
  } catch (error: unknown) {
    return failureResponse(error, path);
  }
}
