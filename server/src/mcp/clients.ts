/**
 * How an OAuth client is presented on the sign-in and consent pages. A client is "verified" only when the redirect URI
 * of the request is exactly one of the allowlisted callbacks below: the authorization code then goes to that product
 * and nowhere else, whatever name the client registered. Every other client is shown by its redirect host, with its
 * self-chosen name marked unverified, sanitised and cut to 40 characters; logos are never shown.
 *
 * Loopback callbacks (Claude Code, Cursor, other local apps) cannot be verified: any program on the computer can
 * listen on a local port, so they are shown as "an app on this computer" with a warning.
 */

/** A verified product and its exact callback. */
export interface VerifiedRedirect {
  readonly redirectUri: string;
  readonly name: string;
}

export const verifiedRedirects: readonly VerifiedRedirect[] = [
  { redirectUri: "https://claude.ai/api/mcp/auth_callback", name: "Claude" },
  { redirectUri: "https://claude.com/api/mcp/auth_callback", name: "Claude" },
  { redirectUri: "https://chatgpt.com/connector_platform_oauth_redirect", name: "ChatGPT" },
];

/** Longest shown client name. */
export const clientNameMaxChars: number = 40;
/** Most redirect URIs a dynamically registered client may list. */
export const maxRegisteredRedirectUris: number = 5;

/** The page's view of a client. */
export type ClientPresentation =
  | { readonly kind: "verified"; readonly name: string; readonly redirectHost: string }
  | { readonly kind: "local"; readonly name: string; readonly redirectHost: string }
  | { readonly kind: "unverified"; readonly name: string; readonly redirectHost: string };

/** Whether a host is a loopback address. Pure function. */
export function isLoopbackHost(host: string): boolean {
  return host === "localhost" || host === "[::1]" || host === "::1" || /^127(?:\.\d{1,3}){3}$/.test(host);
}

/**
 * A client-chosen name made safe to show: compatibility-normalised, marks removed, then only printable ASCII letters,
 * digits, spaces and a few punctuation marks kept (this drops bidi controls, invisible characters and look-alike
 * letters from other scripts), whitespace collapsed, cut to `clientNameMaxChars`. Empty: "Unnamed app". Pure function.
 */
export function sanitizeClientName(raw: string): string {
  const cleaned: string = raw
    .normalize("NFKD")
    .replace(/\p{M}+/gu, "")
    .replace(/[^A-Za-z0-9 .,:_()&+'/-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, clientNameMaxChars)
    .trim();
  return cleaned.length > 0 ? cleaned : "Unnamed app";
}

/** Presentation of a request's client from its redirect URI and registered (or metadata) name. Pure function. */
export function presentClient(redirectUri: string, clientName: string | null): ClientPresentation {
  const url: URL = new URL(redirectUri);
  // Host name without the port: a local app's loopback port changes between sign-ins.
  const redirectHost: string = url.hostname;
  const verified: VerifiedRedirect | undefined = verifiedRedirects.find((entry: VerifiedRedirect): boolean => entry.redirectUri === redirectUri);
  if (verified !== undefined) {
    return { kind: "verified", name: verified.name, redirectHost };
  }
  const name: string = sanitizeClientName(clientName ?? "");
  return isLoopbackHost(url.hostname) ? { kind: "local", name, redirectHost } : { kind: "unverified", name, redirectHost };
}

/** The label the apps list a connection under. Pure function. */
export function connectionLabel(presentation: ClientPresentation): string {
  return presentation.kind === "verified" ? presentation.name : `${presentation.name} (${presentation.redirectHost})`.slice(0, 120);
}

/**
 * Whether a registration's redirect URI is acceptable: https, or http on a loopback host. A native app's private-use
 * scheme (Cursor registers `cursor://…` next to its loopback callback) is stored but the library refuses every
 * authorization request that uses it (`allowPrivateUseRedirectUris` stays off). Remote http is refused. Pure function.
 */
export function isAllowedRegistrationRedirect(uri: string): boolean {
  let url: URL;
  try {
    url = new URL(uri);
  } catch (error: unknown) {
    if (error instanceof TypeError) {
      return false;
    }
    throw error;
  }
  if (url.protocol === "http:") {
    return isLoopbackHost(url.hostname);
  }
  return url.protocol !== "javascript:" && url.protocol !== "data:" && url.protocol !== "file:";
}
