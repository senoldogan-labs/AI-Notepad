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
    // Assistants such as ChatGPT run sign-in in a popup and read the result through window.opener once the popup
    // reaches their redirect page. COOP same-origin would sever that link as soon as the popup loads this page, so
    // the authorization could never complete. Framing stays blocked by frame-ancestors and X-Frame-Options.
    "cross-origin-opener-policy": "unsafe-none",
    "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
  });
}

const style: string = `
:root{color-scheme:light dark;--bg:#fff;--card:#faf8f4;--soft:#f4f1eb;--line:#e5e2dc;--ink:#0a0a0a;--muted:#575757;
--primary:#0a0a0a;--on-primary:#fff;--ok:#2f7a55;--warn:#9a5b00;--danger:#b42318;--focus:#2f5f8a;--shadow:0 1px 2px rgb(0 0 0/.04),0 8px 24px rgb(0 0 0/.06)}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#0e0e0e;--soft:#151515;--line:#262626;--ink:#f2f2f2;--muted:#a6a6a6;
--primary:#f2f2f2;--on-primary:#000;--ok:#7fcfa3;--warn:#f2b863;--danger:#ff8a7a;--focus:#8fb5d8;--shadow:0 1px 2px rgb(0 0 0/.55),0 8px 24px rgb(0 0 0/.5)}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
-webkit-font-smoothing:antialiased;display:flex;flex-direction:column;align-items:center;padding:clamp(24px,8vh,72px) 16px 40px}
main{width:100%;max-width:440px}
.brand{display:flex;align-items:center;gap:10px;font-weight:650;font-size:17px;letter-spacing:-.01em;margin:0 0 20px;padding:0 4px}
.brand svg{width:28px;height:28px;border-radius:7px;box-shadow:0 0 0 1px var(--line)}
.panel{background:var(--card);border:1px solid var(--line);border-radius:24px;padding:28px 24px;box-shadow:var(--shadow)}
.eyebrow{font-size:13px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--muted);margin:0 0 8px}
h1{font-size:24px;line-height:1.25;letter-spacing:-.02em;margin:0 0 8px;font-weight:650}
p{margin:0 0 16px;color:var(--muted)}
.badge{display:inline-flex;align-items:center;gap:4px;font-size:13px;font-weight:600;color:var(--ok);margin:0 0 16px}
.badge svg{width:15px;height:15px}
.callout{display:flex;gap:10px;align-items:flex-start;background:var(--soft);border:1px solid var(--line);border-radius:14px;padding:12px 14px;margin:0 0 20px;font-size:14px;color:var(--ink)}
.callout svg{flex:none;width:18px;height:18px;margin-top:1px;color:var(--warn)}
.callout p{margin:0;color:inherit}
.section-title{font-size:14px;font-weight:600;color:var(--ink);margin:0 0 10px}
.scope{list-style:none;margin:0 0 24px;padding:0;border-top:1px solid var(--line)}
.scope li{display:flex;gap:10px;align-items:center;padding:10px 0;border-bottom:1px solid var(--line);font-size:15px}
.scope svg{flex:none;width:18px;height:18px}.scope .yes svg{color:var(--ok)}.scope .no{color:var(--muted)}.scope .no svg{color:var(--muted)}
.account{display:flex;gap:12px;align-items:center;background:var(--bg);border:1px solid var(--line);border-radius:14px;padding:12px 14px;margin:0 0 20px}
.account svg{flex:none;width:22px;height:22px}.account strong{display:block;font-size:15px}.account span{display:block;font-size:13px;color:var(--muted)}
.button{display:flex;align-items:center;justify-content:center;gap:10px;width:100%;min-height:48px;padding:12px 16px;border-radius:999px;
border:1px solid var(--line);background:var(--bg);color:var(--ink);font:inherit;font-weight:600;text-decoration:none;cursor:pointer;margin:0 0 10px}
.button svg{width:18px;height:18px;flex:none}
.button:hover{border-color:var(--muted)}.button:focus-visible{outline:2px solid var(--focus);outline-offset:2px}
.primary{background:var(--primary);border-color:var(--primary);color:var(--on-primary)}.primary:hover{opacity:.9;border-color:var(--primary)}
.actions{display:flex;gap:10px;margin-top:4px}.actions .button{margin:0}
label{display:block;font-size:14px;color:var(--muted);margin:0 0 4px}
input[type=email],input[type=password]{width:100%;min-height:44px;padding:10px 14px;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--ink);font:inherit;margin:0 0 14px}
.error{color:var(--danger)}
.small{font-size:14px}a{color:inherit}
footer{max-width:440px;width:100%;margin-top:20px;padding:0 4px;font-size:13px;color:var(--muted);display:flex;gap:14px;flex-wrap:wrap}
footer a{color:var(--muted);text-decoration:none}footer a:hover{color:var(--ink);text-decoration:underline}`;

/** The Gistsmith mark (the site's favicon), inline: the pages load no images. */
const logo: string = `<svg viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" fill="#0a0a0a"/><g fill="#fafafa"><rect x="7.4" y="12" width="2.6" height="8" rx="1.3"/><rect x="11.4" y="8.2" width="2.6" height="15.6" rx="1.3"/><rect x="15.4" y="10.6" width="2.6" height="10.8" rx="1.3"/><rect x="19.6" y="14.7" width="5.6" height="2.6" rx="1.3"/></g></svg>`;

const appleIcon: string = `<svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor"><path d="M16.37 12.6c-.02-2.2 1.8-3.26 1.88-3.31-1.03-1.5-2.62-1.7-3.18-1.73-1.35-.14-2.64.8-3.33.8-.69 0-1.74-.78-2.87-.76-1.47.02-2.83.86-3.6 2.18-1.53 2.66-.39 6.6 1.1 8.76.73 1.06 1.6 2.24 2.73 2.2 1.1-.04 1.51-.71 2.84-.71 1.32 0 1.7.71 2.86.69 1.18-.02 1.93-1.08 2.65-2.14.84-1.22 1.18-2.41 1.2-2.47-.03-.01-2.3-.88-2.28-3.5ZM14.18 6.13c.6-.73 1.01-1.75.9-2.76-.87.04-1.92.58-2.54 1.31-.56.65-1.05 1.68-.92 2.67.97.08 1.96-.49 2.56-1.22Z"/></svg>`;

const googleIcon: string = `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09Z"/><path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23Z"/><path fill="#FBBC05" d="M5.84 14.1c-.22-.66-.35-1.36-.35-2.1s.13-1.44.35-2.1V7.06H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.94l3.66-2.84Z"/><path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84c.87-2.6 3.3-4.52 6.16-4.52Z"/></svg>`;

const checkIcon: string = `<svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m4.5 10.5 3.5 3.5 7.5-8"/></svg>`;
const crossIcon: string = `<svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="m5.5 5.5 9 9m0-9-9 9"/></svg>`;
const shieldIcon: string = `<svg viewBox="0 0 20 20" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2.5 3.5 5v4.5c0 4 2.8 6.9 6.5 8 3.7-1.1 6.5-4 6.5-8V5L10 2.5Z"/><path d="M10 7v3.5M10 13.2v.1"/></svg>`;
const verifiedIcon: string = `<svg viewBox="0 0 20 20" aria-hidden="true" fill="currentColor"><path d="M10 1.5 12.2 3l2.6-.1.9 2.5 2.2 1.4-.8 2.5.8 2.5-2.2 1.4-.9 2.5-2.6-.1L10 18.5 7.8 17l-2.6.1-.9-2.5-2.2-1.4.8-2.5-.8-2.5 2.2-1.4.9-2.5L7.8 3 10 1.5Zm3.4 5.8-4.4 4.6-2.3-2.3-1.1 1.1 3.4 3.4 5.5-5.7-1.1-1.1Z"/></svg>`;

function document(title: string, body: string, nonce: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title><style nonce="${nonce}">${style}</style></head><body><main><div class="brand">${logo}<span>Gistsmith</span></div><div class="panel">${body}</div></main>
<footer><a href="https://gistsmith.com/mcp">About AI assistant access</a><a href="https://gistsmith.com/privacy">Privacy</a><a href="https://gistsmith.com/terms">Terms</a></footer></body></html>`;
}

/** Heading and description of a client. Pure function. */
function clientBlock(client: ClientPresentation): string {
  if (client.kind === "verified") {
    return `<p class="eyebrow">Connection request</p><h1>Connect ${escapeHtml(client.name)} to Gistsmith</h1><div class="badge">${verifiedIcon}Verified app</div>
<div class="callout">${shieldIcon}<p>Continue only if you just started connecting Gistsmith from ${escapeHtml(client.name)} yourself. If someone sent you this link, close this page.</p></div>`;
  }
  if (client.kind === "local") {
    return `<p class="eyebrow">Connection request</p><h1>An app on this computer</h1><p>Unverified app: ${escapeHtml(client.name)}</p>
<div class="callout">${shieldIcon}<p>Access goes to ${escapeHtml(client.redirectHost)}, a program running on this computer. Continue only if you just started connecting from it.</p></div>`;
  }
  return `<p class="eyebrow">Connection request</p><h1>${escapeHtml(client.redirectHost)}</h1><p>Unverified app: ${escapeHtml(client.name)}</p>
<div class="callout">${shieldIcon}<p>Gistsmith can't confirm who runs this app. Access goes to ${escapeHtml(client.redirectHost)}.</p></div>`;
}

const scopeBlock: string = `<p class="section-title">Read your meeting notes</p><ul class="scope">
<li class="yes">${checkIcon}Titles, dates and summaries</li>
<li class="yes">${checkIcon}Decisions, tasks and outlines</li>
<li class="yes">${checkIcon}Your own notes</li>
<li class="no">${crossIcon}Never audio or transcripts</li>
<li class="no">${crossIcon}Read only: it can't change or delete anything</li></ul>`;

/** A fresh CSP nonce. */
export function newNonce(): string {
  return randomToken(16);
}

/** Sign-in page: who is asking, then Apple / Google links (and the reviewer link when reviewer accounts exist). */
export function signInPage(client: ClientPresentation, appleUrl: string, googleUrl: string, reviewerUrl: string | null, nonce: string): Page {
  const reviewer: string = reviewerUrl === null ? "" : `<p class="small"><a href="${escapeHtml(reviewerUrl)}">App reviewer sign-in</a></p>`;
  const body: string = `${clientBlock(client)}${scopeBlock}<p class="small">Sign in with the account you use in the Gistsmith app.</p>
<a class="button primary" href="${escapeHtml(appleUrl)}">${appleIcon}Continue with Apple</a><a class="button" href="${escapeHtml(googleUrl)}">${googleIcon}Continue with Google</a>${reviewer}`;
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
  const providerIcon: string = account.provider === "apple" ? appleIcon : account.provider === "google" ? googleIcon : logo;
  const accountBlock: string = `<div class="account">${providerIcon}<div><strong>Signed in with ${providerLabel(account.provider)}</strong><span>Gistsmith account created ${escapeHtml(created)}</span></div></div>`;
  const hidden: string = `<input type="hidden" name="handle" value="${escapeHtml(form.handle)}"><input type="hidden" name="user" value="${escapeHtml(form.user)}"><input type="hidden" name="signature" value="${escapeHtml(form.signature)}">`;
  const explanation: string =
    state === "disabled"
      ? `<div class="callout">${shieldIcon}<p><strong>Turn on AI assistant access in the Gistsmith app first.</strong><br>On your Mac or iPhone: Settings › Connections › “Let AI assistants read my meeting notes”. Then connect again from your assistant.</p></div>`
      : state === "no_access"
        ? `<div class="callout">${shieldIcon}<p><strong>AI assistant access isn't available on this account right now.</strong><br>Check your account in the Gistsmith app, then connect again from your assistant.</p></div>`
        : scopeBlock;
  const allow: string = state === "ready" ? `<button class="button primary" name="decision" value="approve">Allow</button>` : "";
  const body: string = `${clientBlock(client)}${accountBlock}${explanation}<form method="post" action="/authorize">${hidden}<div class="actions"><button class="button" name="decision" value="deny">Cancel</button>${allow}</div></form>`;
  return { status: 200, html: document("Allow access to your meeting notes", body, nonce), nonce, formTargets: [redirectOrigin] };
}

/**
 * The way back to the assistant after Allow or Cancel. A form post that answers with a redirect is checked against
 * form-action along the whole redirect chain, and some assistants bounce their callback on to another host (ChatGPT's
 * callback continues to platform.openai.com), which the browser then blocks. A page that navigates with a script is
 * not a form submission, so the chain is free; the link is the fallback without scripts.
 */
export function returnPage(location: string, nonce: string): Page {
  const body: string = `<h1>Returning to your assistant…</h1><p>If nothing happens, continue below.</p><a class="button primary" id="return" href="${escapeHtml(location)}">Continue</a>
<script nonce="${nonce}">location.replace(document.getElementById("return").href);</script>`;
  return { status: 200, html: document("Returning to your assistant", body, nonce), nonce, formTargets: [] };
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
  const error: string = failed ? `<p class="error">That email and password don't match a reviewer account.</p>` : "";
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
