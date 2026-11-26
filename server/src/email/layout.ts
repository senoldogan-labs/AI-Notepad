/**
 * The one email layout every message uses: table-based HTML with inline styles (Gmail, Apple Mail, Outlook), at most
 * 600 px wide, the system font stack and the site's warm palette (`web/src/styles/global.css`), the logo as a hosted PNG
 * with alt text and no text in images, one button that is also a plain link, a hidden preheader, `color-scheme`
 * light/dark with a dark palette for clients that honour `prefers-color-scheme` (Apple Mail, Outlook.com), and a
 * matching plain-text part. Pure module.
 */

/** A line of the footer: optional link first, then text. */
export interface FooterLine {
  readonly link: { readonly label: string; readonly url: string } | null;
  readonly text: string;
}

/** What one email says, independent of how it is laid out. */
export interface EmailContent {
  readonly htmlLang: string;
  readonly subject: string;
  readonly preheader: string;
  readonly heading: string;
  readonly paragraphs: readonly string[];
  /** A bullet list after the paragraphs; may be empty. */
  readonly items: readonly string[];
  /** Paragraphs after the list; may be empty. */
  readonly closing: readonly string[];
  readonly cta: { readonly label: string; readonly url: string };
  /** Small text under the button (e.g. how long a link works); null for none. */
  readonly note: string | null;
  /** The sentence above the button's plain link. */
  readonly linkFallback: string;
  readonly footer: readonly FooterLine[];
  /** The hosted logo (PNG). */
  readonly logoUrl: string;
}

/** The rendered bodies. */
export interface EmailBodies {
  readonly html: string;
  readonly text: string;
}

/** Light palette (the site's light tokens) and the dark one, applied through classes where supported. */
const light = { bg: "#f6f0e7", card: "#fffbf5", line: "#e2d6c4", ink: "#1c1714", muted: "#655848", primary: "#9e4f2e", onPrimary: "#fffbf5" } as const;
const dark = { bg: "#100e0d", card: "#1a1715", line: "#2e2824", ink: "#f5ede4", muted: "#a99e93", primary: "#e39a72", onPrimary: "#141110" } as const;

const fontStack: string = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";

/** Escapes text for HTML element content and attribute values. Pure function. */
export function escapeHtml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

/** Dark mode overrides (Apple Mail, iOS Mail, Outlook.com via `data-ogsc`; Gmail ignores them and keeps light). */
const darkStyles: string = [
  `.bg{background-color:${dark.bg}!important}`,
  `.card{background-color:${dark.card}!important;border-color:${dark.line}!important}`,
  `.ink{color:${dark.ink}!important}`,
  `.muted{color:${dark.muted}!important}`,
  `.link{color:${dark.primary}!important}`,
  `.btn{background-color:${dark.primary}!important}`,
  `.btn-label{color:${dark.onPrimary}!important}`,
].join("");

const headStyles: string =
  `:root{color-scheme:light dark;supported-color-schemes:light dark}` +
  `body{margin:0;padding:0;-webkit-text-size-adjust:100%}` +
  `@media (prefers-color-scheme:dark){${darkStyles}}` +
  darkStyles
    .split("}")
    .filter((rule: string): boolean => rule.length > 0)
    .map((rule: string): string => `[data-ogsc] ${rule}}`)
    .join("") +
  `@media only screen and (max-width:620px){.card-pad{padding:28px 22px!important}}`;

function paragraphHtml(text: string, last: boolean): string {
  return `<p class="ink" style="margin:0 0 ${last ? 0 : 14}px;font-family:${fontStack};font-size:16px;line-height:1.6;color:${light.ink};">${escapeHtml(text)}</p>`;
}

function itemsHtml(items: readonly string[]): string {
  if (items.length === 0) {
    return "";
  }
  const rows: string = items
    .map(
      (item: string): string =>
        `<tr><td class="ink" style="width:18px;vertical-align:top;font-family:${fontStack};font-size:16px;line-height:1.6;color:${light.primary};">&#8226;</td>` +
        `<td class="ink" style="vertical-align:top;padding-bottom:6px;font-family:${fontStack};font-size:16px;line-height:1.6;color:${light.ink};">${escapeHtml(item)}</td></tr>`,
    )
    .join("");
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:4px 0 14px;">${rows}</table>`;
}

function buttonHtml(label: string, url: string): string {
  const href: string = escapeHtml(url);
  return (
    `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0 0;">` +
    `<tr><td class="btn" bgcolor="${light.primary}" style="border-radius:8px;background-color:${light.primary};">` +
    `<a class="btn-label" href="${href}" target="_blank" style="display:inline-block;padding:13px 22px;font-family:${fontStack};font-size:16px;font-weight:600;line-height:1.2;color:${light.onPrimary};text-decoration:none;border-radius:8px;">${escapeHtml(label)}</a>` +
    `</td></tr></table>`
  );
}

function footerLineHtml(line: FooterLine): string {
  const link: string =
    line.link === null
      ? ""
      : `<a class="link" href="${escapeHtml(line.link.url)}" target="_blank" style="color:${light.primary};text-decoration:underline;">${escapeHtml(line.link.label)}</a>${line.text.length > 0 ? " " : ""}`;
  return `<p class="muted" style="margin:0 0 8px;font-family:${fontStack};font-size:13px;line-height:1.5;color:${light.muted};">${link}${escapeHtml(line.text)}</p>`;
}

/** The HTML body. Pure function. */
export function renderEmailHtml(content: EmailContent): string {
  const body: string[] = [];
  content.paragraphs.forEach((text: string, index: number): void => {
    body.push(paragraphHtml(text, index === content.paragraphs.length - 1 && content.items.length === 0 && content.closing.length === 0));
  });
  body.push(itemsHtml(content.items));
  content.closing.forEach((text: string, index: number): void => {
    body.push(paragraphHtml(text, index === content.closing.length - 1));
  });
  body.push(buttonHtml(content.cta.label, content.cta.url));
  if (content.note !== null) {
    body.push(`<p class="muted" style="margin:14px 0 0;font-family:${fontStack};font-size:14px;line-height:1.5;color:${light.muted};">${escapeHtml(content.note)}</p>`);
  }
  body.push(
    `<p class="muted" style="margin:20px 0 0;font-family:${fontStack};font-size:13px;line-height:1.5;color:${light.muted};">${escapeHtml(content.linkFallback)}<br>` +
      `<a class="link" href="${escapeHtml(content.cta.url)}" target="_blank" style="color:${light.primary};word-break:break-all;">${escapeHtml(content.cta.url)}</a></p>`,
  );
  // Invisible spacer after the preheader so clients don't pull body text into the inbox preview.
  const previewSpacer: string = "&#8199;&#847;".repeat(60);
  return (
    `<!doctype html>` +
    `<html lang="${escapeHtml(content.htmlLang)}" dir="ltr">` +
    `<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<meta name="x-apple-disable-message-reformatting"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">` +
    `<title>${escapeHtml(content.subject)}</title><style>${headStyles}</style></head>` +
    `<body class="bg" style="margin:0;padding:0;background-color:${light.bg};">` +
    `<div style="display:none;max-height:0;max-width:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;opacity:0;color:${light.bg};">${escapeHtml(content.preheader)}${previewSpacer}</div>` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="bg" bgcolor="${light.bg}" style="background-color:${light.bg};">` +
    `<tr><td align="center" style="padding:32px 12px;">` +
    `<!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;">` +
    `<tr><td style="padding:0 4px 18px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>` +
    `<td style="vertical-align:middle;"><img src="${escapeHtml(content.logoUrl)}" width="32" height="32" alt="Gistsmith logo" style="display:block;border:0;border-radius:7px;"></td>` +
    `<td class="ink" style="padding-left:10px;vertical-align:middle;font-family:${fontStack};font-size:17px;font-weight:600;color:${light.ink};">Gistsmith</td>` +
    `</tr></table></td></tr>` +
    `<tr><td class="card card-pad" bgcolor="${light.card}" style="background-color:${light.card};border:1px solid ${light.line};border-radius:14px;padding:36px 40px;">` +
    `<h1 class="ink" style="margin:0 0 16px;font-family:${fontStack};font-size:24px;font-weight:600;line-height:1.3;color:${light.ink};">${escapeHtml(content.heading)}</h1>` +
    body.join("") +
    `</td></tr>` +
    `<tr><td style="padding:22px 8px 0;">${content.footer.map(footerLineHtml).join("")}</td></tr>` +
    `</table>` +
    `<!--[if mso]></td></tr></table><![endif]-->` +
    `</td></tr></table></body></html>`
  );
}

/** The plain-text body: the same words, links written out. Pure function. */
export function renderEmailText(content: EmailContent): string {
  const lines: string[] = [content.heading, ""];
  for (const paragraph of content.paragraphs) {
    lines.push(paragraph, "");
  }
  for (const item of content.items) {
    lines.push(`- ${item}`);
  }
  if (content.items.length > 0) {
    lines.push("");
  }
  for (const paragraph of content.closing) {
    lines.push(paragraph, "");
  }
  lines.push(`${content.cta.label}: ${content.cta.url}`, "");
  if (content.note !== null) {
    lines.push(content.note, "");
  }
  lines.push("--");
  for (const line of content.footer) {
    lines.push(line.link === null ? line.text : `${line.link.label}: ${line.link.url}${line.text.length > 0 ? ` (${line.text})` : ""}`);
  }
  return `${lines.join("\n")}\n`;
}

/** Both bodies. Pure function. */
export function renderEmail(content: EmailContent): EmailBodies {
  return { html: renderEmailHtml(content), text: renderEmailText(content) };
}
