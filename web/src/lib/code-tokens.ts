// Build-time syntax colouring for the site's short code samples (the MCP configuration, the webhook JSON, the connector
// URL). The text is split into tokens that CodeBlock.astro draws as spans with classes; no inline styles (the CSP has no
// 'unsafe-inline' for styles) and no highlighter in the browser.

/** What a piece of code is: a JSON key, a string value, a number or literal, punctuation, or anything else. */
export type CodeTokenKind = "key" | "string" | "literal" | "punctuation" | "plain";

/** A piece of the code and its kind. */
export interface CodeToken {
  readonly kind: CodeTokenKind;
  readonly text: string;
}

/** JSON-like text: strings, numbers and literals, punctuation; whitespace and anything else (such as `…`) stays plain. */
const jsonPattern: RegExp = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\btrue\b|\bfalse\b|\bnull\b)|([{}[\],:])/g;

/**
 * Splits JSON-like text into tokens: a string followed by a colon is a key. Joining the tokens' text gives the input
 * back unchanged. Pure function.
 */
export function jsonTokens(text: string): readonly CodeToken[] {
  const tokens: CodeToken[] = [];
  let last: number = 0;
  for (const match of text.matchAll(jsonPattern)) {
    const index: number = match.index;
    if (index > last) {
      tokens.push({ kind: "plain", text: text.slice(last, index) });
    }
    const [whole, quoted, colon, literal, punctuation] = match;
    if (quoted !== undefined) {
      tokens.push({ kind: colon === undefined ? "string" : "key", text: quoted });
      if (colon !== undefined) {
        tokens.push({ kind: "punctuation", text: colon });
      }
    } else if (literal !== undefined) {
      tokens.push({ kind: "literal", text: literal });
    } else if (punctuation !== undefined) {
      tokens.push({ kind: "punctuation", text: punctuation });
    }
    last = index + whole.length;
  }
  if (last < text.length) {
    tokens.push({ kind: "plain", text: text.slice(last) });
  }
  return tokens;
}

/** Text with no colouring (a URL, a path): one plain token. Pure function. */
export function plainTokens(text: string): readonly CodeToken[] {
  return [{ kind: "plain", text }];
}
