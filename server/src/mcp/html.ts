import { randomToken } from "../crypto";
import type { ClientPresentation } from "./clients";

/**
 * Server-rendered pages of mcp.gistsmith.com (sign-in, consent, errors). No third-party script, image, font or
 * analytics: sign-in with Apple and Google are plain links (redirect flows). Every value that came from a client or a
 * request is escaped with `escapeHtml`. Each response carries a fresh CSP nonce for its one inline style (and, on the
 * relay page, its one inline script).
 */

/** A rendered page and the CSP it needs. */
export interface Page {
  readonly status: number;
  readonly html: string;
  readonly nonce: string;
  /** Extra `form-action` sources (the client's redirect origin on the consent page). */
  readonly formTargets: readonly string[];
}

/** HTML escaping for text and attribute values. Pure function. */
export function escapeHtml(value: string): string {
  return value.replace(/[&<>"'`=/]/g, (char: string): string => `&#${char.charCodeAt(0)};`);
}

/** Response headers of a page: strict CSP, no framing, no referrer, no caching. Pure function. */
export function pageHeaders(page: Page): Headers {
  const formAction: string = ["'self'", ...page.formTargets].join(" ");
  return new Headers({
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": `default-src 'none'; style-src 'nonce-${page.nonce}'; script-src 'nonce-${page.nonce}'; form-action ${formAction}; frame-ancestors 'none'; base-uri 'none'`,
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "cache-control": "no-store",
    "cross-origin-opener-policy": "same-origin",
    "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  });
}

const style: string = `
:root{--ink:#16181d;--muted:#5b6170;--line:#e4e6eb;--accent:#4f46e5;--warn:#9a3412;--bg:#fff}
@media (prefers-color-scheme:dark){:root{--ink:#eceef3;--muted:#a3a9b8;--line:#2c3039;--accent:#8b85ff;--warn:#fdba74;--bg:#111317}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:440px;margin:0 auto;padding:48px 16px}h1{font-size:22px;line-height:1.3;margin:0 0 8px}
p{margin:0 0 16px;color:var(--muted)}.brand{font-weight:600;color:var(--accent);margin-bottom:24px}
.card{border:1px solid var(--line);border-radius:12px;padding:16px;margin:0 0 20px}.card p{margin:0}.card p+p{margin-top:8px}
.warn{color:var(--warn)}.button{display:block;width:100%;text-align:center;padding:12px 16px;border-radius:10px;border:1px solid var(--line);
background:transparent;color:var(--ink);font:inherit;font-weight:600;text-decoration:none;cursor:pointer;margin:0 0 12px}
.primary{background:var(--accent);border-color:var(--accent);color:#fff}label{display:block;font-size:14px;color:var(--muted);margin:0 0 4px}
input[type=email],input[type=password]{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--ink);font:inherit;margin:0 0 12px}
.small{font-size:14px}`;

function document(title: string, body: string, nonce: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title><style nonce="${nonce}">${style}</style></head><body><main><div class="brand">Gistsmith</div>${body}</main></body></html>`;
}

/** Heading and description of a client. Pure function. */
function clientBlock(client: ClientPresentation): string {
  if (client.kind === "verified") {
    return `<h1>${escapeHtml(client.name)} (verified)</h1><p>wants to read your Gistsmith meeting notes.</p>
<p class="warn">Continue only if you just started connecting Gistsmith from ${escapeHtml(client.name)} yourself. If someone sent you this link, close this page.</p>`;
  }
  if (client.kind === "local") {
    return `<h1>An app on this computer</h1><p>Unverified app: ${escapeHtml(client.name)}</p>
<p class="warn">Access goes to ${escapeHtml(client.redirectHost)}, a program running on this computer. Continue only if you just started connecting from it.</p>`;
  }
  return `<h1>${escapeHtml(client.redirectHost)}</h1><p>Unverified app: ${escapeHtml(client.name)}</p>
<p class="warn">Gistsmith can't confirm who runs this app. Access goes to ${escapeHtml(client.redirectHost)}.</p>`;
}

const scopeBlock: string = `<div class="card"><p><strong>Read your meeting notes</strong></p><p class="small">Titles, dates, summaries, decisions, tasks, outlines and your own notes. Never audio or transcripts. Read only.</p></div>`;

/** A fresh CSP nonce. */
export function newNonce(): string {
  return randomToken(16);
}

/** Sign-in page: who is asking, then Apple / Google links (and the reviewer link when reviewer accounts exist). */
export function signInPage(client: ClientPresentation, appleUrl: string, googleUrl: string, reviewerUrl: string | null, nonce: string): Page {
  const reviewer: string = reviewerUrl === null ? "" : `<p class="small"><a href="${escapeHtml(reviewerUrl)}">App reviewer sign-in</a></p>`;
  const body: string = `${clientBlock(client)}${scopeBlock}<p>Sign in with the account you use in the Gistsmith app.</p>
<a class="button" href="${escapeHtml(appleUrl)}">Continue with Apple</a><a class="button" href="${escapeHtml(googleUrl)}">Continue with Google</a>${reviewer}`;
  return { status: 200, html: document("Connect to Gistsmith", body, nonce), nonce, formTargets: [] };
}

/** Signed-in account as shown on the consent page (no email: the server stores none). */
export interface AccountSummary {
  readonly provider: "apple" | "google" | "reviewer";
  readonly createdAt: Date;
}

/** What the consent page offers. */
export type ConsentState = "ready" | "disabled" | "no_access";

/** Hidden fields of the consent form. */
export interface ConsentForm {
  readonly handle: string;
  readonly user: string;
  readonly signature: string;
}

function providerLabel(provider: AccountSummary["provider"]): string {
  return provider === "apple" ? "Apple" : provider === "google" ? "Google" : "a reviewer account";
}

/** Consent page. Only `ready` offers Allow; otherwise it explains what to do in the app and offers Cancel only. */
export function consentPage(client: ClientPresentation, account: AccountSummary, state: ConsentState, form: ConsentForm, redirectOrigin: string, nonce: string): Page {
  const created: string = account.createdAt.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
  const accountBlock: string = `<p class="small">Signed in with ${providerLabel(account.provider)} · Gistsmith account created ${escapeHtml(created)}</p>`;
  const hidden: string = `<input type="hidden" name="handle" value="${escapeHtml(form.handle)}"><input type="hidden" name="user" value="${escapeHtml(form.user)}"><input type="hidden" name="signature" value="${escapeHtml(form.signature)}">`;
  const explanation: string =
    state === "disabled"
      ? `<div class="card"><p><strong>Turn on AI assistant access in the Gistsmith app first.</strong></p><p class="small">On your Mac or iPhone: Settings › Connections › Online assistants. Then connect again from your assistant.</p></div>`
      : state === "no_access"
        ? `<div class="card"><p><strong>AI assistant access isn't available on this account right now.</strong></p><p class="small">Check your account in the Gistsmith app, then connect again from your assistant.</p></div>`
        : scopeBlock;
  const allow: string = state === "ready" ? `<button class="button primary" name="decision" value="approve">Allow</button>` : "";
  const body: string = `${clientBlock(client)}${accountBlock}${explanation}<form method="post" action="/authorize">${hidden}${allow}<button class="button" name="decision" value="deny">Cancel</button></form>`;
  return { status: 200, html: document("Allow access to your meeting notes", body, nonce), nonce, formTargets: [redirectOrigin] };
}

/**
 * Relay after the provider's cross-site form post: the binding cookie (SameSite=Lax) is not sent on that post, so this
 * page posts the fields again from our own origin, where it is.
 */
export function relayPage(action: string, fields: Readonly<Record<string, string>>, nonce: string): Page {
  const inputs: string = Object.entries(fields)
    .map(([name, value]: [string, string]): string => `<input type="hidden" name="${escapeHtml(name)}" value="${escapeHtml(value)}">`)
    .join("");
  const body: string = `<h1>Signing you in…</h1><form id="relay" method="post" action="${escapeHtml(action)}">${inputs}<button class="button primary">Continue</button></form>
<script nonce="${nonce}">document.getElementById("relay").submit();</script>`;
  return { status: 200, html: document("Signing you in", body, nonce), nonce, formTargets: [] };
}

/** Reviewer sign-in form (email + password; only accounts listed in `REVIEWER_LOGINS`). */
export function reviewerPage(action: string, failed: boolean, nonce: string): Page {
  const error: string = failed ? `<p class="warn">That email and password don't match a reviewer account.</p>` : "";
  const body: string = `<h1>App reviewer sign-in</h1><p>For app directory reviewers with a Gistsmith reviewer account.</p>${error}
<form method="post" action="${escapeHtml(action)}"><label for="email">Email</label><input id="email" type="email" name="email" autocomplete="username" required>
<label for="password">Password</label><input id="password" type="password" name="password" autocomplete="current-password" required>
<button class="button primary">Sign in</button></form>`;
  return { status: failed ? 401 : 200, html: document("Reviewer sign-in", body, nonce), nonce, formTargets: [] };
}

/** The user canceled at Apple or Google: a link back to the app (an error redirect after a form post would be blocked by `form-action`). */
export function canceledPage(returnUrl: string, nonce: string): Page {
  const body: string = `<h1>Sign-in canceled</h1><p>Nothing was shared.</p><a class="button" href="${escapeHtml(returnUrl)}">Return to the app</a>`;
  return { status: 200, html: document("Sign-in canceled", body, nonce), nonce, formTargets: [] };
}

/** Error page; never redirects. */
export function errorPage(status: number, title: string, message: string, nonce: string): Page {
  const body: string = `<h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p>`;
  return { status, html: document(title, body, nonce), nonce, formTargets: [] };
}

/** The page as a response. Pure function. */
export function pageResponse(page: Page, extraHeaders: Headers | null): Response {
  const headers: Headers = pageHeaders(page);
  if (extraHeaders !== null) {
    for (const cookie of extraHeaders.getSetCookie()) {
      headers.append("set-cookie", cookie);
    }
    for (const [name, value] of extraHeaders) {
      if (name.toLowerCase() !== "set-cookie" && !headers.has(name)) {
        headers.set(name, value);
      }
    }
  }
  return new Response(page.html, { status: page.status, headers });
}
