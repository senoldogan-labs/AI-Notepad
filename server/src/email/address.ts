/**
 * The address a user types for lifecycle email (we never read one from a sign-in token). Accepted: one `@`, an ASCII
 * local part of the usual unquoted characters (no leading, trailing or double dots, at most 64), and a domain of ASCII
 * labels (punycode for international domains) with a letter top-level label; 254 characters at most (RFC 5321). The
 * domain is lower-cased; the local part keeps its case. Pure module.
 */

const localPartPattern: RegExp = /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*$/;
const domainPattern: RegExp = /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+(xn--[a-z0-9-]{2,59}|[a-z]{2,63})$/;

/** The normalized address, or null when it isn't one we accept. Pure function. */
export function normalizedEmailAddress(raw: string): string | null {
  const trimmed: string = raw.trim();
  if (trimmed.length > 254) {
    return null;
  }
  const at: number = trimmed.lastIndexOf("@");
  if (at <= 0 || trimmed.indexOf("@") !== at) {
    return null;
  }
  const local: string = trimmed.slice(0, at);
  const domain: string = trimmed.slice(at + 1).toLowerCase();
  if (local.length > 64 || !localPartPattern.test(local) || !domainPattern.test(domain)) {
    return null;
  }
  return `${local}@${domain}`;
}

/** Whether two addresses are the same mailbox for our purposes (case-insensitive). Pure function. */
export function sameEmailAddress(left: string, right: string): boolean {
  return left.toLowerCase() === right.toLowerCase();
}
