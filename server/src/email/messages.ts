import { type EmailLocale, emailCopies } from "./copy";
import type { EmailCopy, FreePlanFacts, TrialFacts } from "./copy/types";
import { type EmailContent, type FooterLine, renderEmail } from "./layout";

/**
 * What each email says (`copy/`) put into the layout (`layout.ts`), with its links. Pure module: the caller supplies
 * every fact (configuration numbers, links, tokens).
 */

/** Lifecycle emails, each sent at most once per account (`email_sends.kind`). */
export const lifecycleKinds = ["welcome", "activation", "trial_ending", "free_plan"] as const;

export type LifecycleKind = (typeof lifecycleKinds)[number];

/** Every email the server sends. */
export type EmailKind = "confirm" | LifecycleKind;

/** Facts every email may state, from the configuration. */
export interface EmailFacts {
  readonly siteOrigin: string;
  readonly privacyContact: string;
  readonly trial: TrialFacts;
  readonly free: FreePlanFacts;
}

/** The unsubscribe links of one subscription (signed, see `signing.ts`). */
export interface UnsubscribeLinks {
  /** RFC 8058 one-click target (`List-Unsubscribe`): the API's `POST /v1/email/unsubscribe`. */
  readonly oneClickUrl: string;
  /** The visible link: the site's confirmation page. */
  readonly pageUrl: string;
}

/** Why `trial_ending` goes out, and what follows the trial. */
export interface TrialEndingVariant {
  readonly reason: "one_meeting_left" | "ends_within_day";
  readonly next: "free" | "subscribe";
}

/** A rendered email, ready for `send.ts`. */
export interface ComposedEmail {
  readonly subject: string;
  readonly html: string;
  readonly text: string;
  /** Extra headers (`List-Unsubscribe`, `Precedence`, `Auto-Submitted`, `List-Id`). */
  readonly headers: Readonly<Record<string, string>>;
}

/** `List-Id` of the lifecycle emails. */
const lifecycleListId: string = "Gistsmith tips <tips.gistsmith.com>";

function logoUrl(siteOrigin: string): string {
  return `${siteOrigin}/email/logo.png`;
}

/** The footer's identity line (owner decision: no legal name or street address in emails; those are on the privacy page). */
function identityLine(copy: EmailCopy): FooterLine {
  return { link: null, text: `Gistsmith · Oulu, ${copy.footer.country}` };
}

/** The privacy policy link, then where privacy questions go. */
function privacyLines(copy: EmailCopy, facts: EmailFacts): readonly FooterLine[] {
  return [
    { link: { label: copy.footer.privacyPolicy, url: `${facts.siteOrigin}/privacy` }, text: "" },
    { link: null, text: copy.footer.privacy(facts.privacyContact) },
  ];
}

function lifecycleFooter(copy: EmailCopy, facts: EmailFacts, links: UnsubscribeLinks): readonly FooterLine[] {
  return [
    { link: null, text: copy.footer.lifecycleReason },
    { link: { label: copy.footer.unsubscribe, url: links.pageUrl }, text: copy.footer.inApp },
    { link: null, text: copy.footer.reply },
    ...privacyLines(copy, facts),
    identityLine(copy),
  ];
}

/**
 * Lifecycle headers. `List-Unsubscribe` and `List-Unsubscribe-Post` only with an https target: RFC 8058 requires it and
 * Cloudflare Email Service rejects an http one (local development's `apiOrigin` is http and sends nothing). Pure function.
 */
function lifecycleHeaders(links: UnsubscribeLinks): Readonly<Record<string, string>> {
  const base: Record<string, string> = { "List-Id": lifecycleListId, Precedence: "bulk" };
  if (!links.oneClickUrl.startsWith("https://")) {
    return base;
  }
  return { ...base, "List-Unsubscribe": `<${links.oneClickUrl}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" };
}

function compose(content: EmailContent, headers: Readonly<Record<string, string>>): ComposedEmail {
  const bodies = renderEmail(content);
  return { subject: content.subject, html: bodies.html, text: bodies.text, headers };
}

/** The double opt-in email: confirm link and "This wasn't me", both to click-through pages on the site. Pure function. */
export function confirmationEmail(locale: EmailLocale, facts: EmailFacts, token: string): ComposedEmail {
  const copy: EmailCopy = emailCopies[locale];
  const frame = copy.confirm;
  return compose(
    {
      htmlLang: copy.htmlLang,
      subject: frame.subject,
      preheader: frame.preheader,
      heading: frame.heading,
      paragraphs: frame.body,
      items: [],
      closing: [],
      cta: { label: frame.cta, url: `${facts.siteOrigin}/email/confirm#${token}` },
      note: frame.note,
      linkFallback: copy.footer.linkFallback,
      footer: [
        { link: null, text: copy.footer.confirmReason },
        { link: { label: copy.footer.notMe, url: `${facts.siteOrigin}/email/not-me#${token}` }, text: "" },
        ...privacyLines(copy, facts),
        identityLine(copy),
      ],
      logoUrl: logoUrl(facts.siteOrigin),
    },
    { "Auto-Submitted": "auto-generated" },
  );
}

function lifecycleEmail(
  copy: EmailCopy,
  facts: EmailFacts,
  links: UnsubscribeLinks,
  frame: { readonly subject: string; readonly preheader: string; readonly heading: string; readonly cta: string },
  paragraphs: readonly string[],
  items: readonly string[],
  closing: readonly string[],
  ctaUrl: string,
): ComposedEmail {
  return compose(
    {
      htmlLang: copy.htmlLang,
      subject: frame.subject,
      preheader: frame.preheader,
      heading: frame.heading,
      paragraphs,
      items,
      closing,
      cta: { label: frame.cta, url: ctaUrl },
      note: null,
      linkFallback: copy.footer.linkFallback,
      footer: lifecycleFooter(copy, facts, links),
      logoUrl: logoUrl(facts.siteOrigin),
    },
    lifecycleHeaders(links),
  );
}

/** Sent right after confirmation: the first meeting and Gistsmith Keyboard. Pure function. */
export function welcomeEmail(locale: EmailLocale, facts: EmailFacts, links: UnsubscribeLinks): ComposedEmail {
  const copy: EmailCopy = emailCopies[locale];
  return lifecycleEmail(copy, facts, links, copy.welcome, copy.welcome.body, [], [], `${facts.siteOrigin}/open/record`);
}

/** The one reminder for an account without a meeting 48 hours after confirming. Pure function. */
export function activationEmail(locale: EmailLocale, facts: EmailFacts, links: UnsubscribeLinks): ComposedEmail {
  const copy: EmailCopy = emailCopies[locale];
  return lifecycleEmail(copy, facts, links, copy.activation, copy.activation.body(facts.trial), [], [], `${facts.siteOrigin}/open/record`);
}

/** The trial is nearly over: why, what follows, and that meetings and notes stay. Pure function. */
export function trialEndingEmail(locale: EmailLocale, facts: EmailFacts, links: UnsubscribeLinks, variant: TrialEndingVariant): ComposedEmail {
  const copy: EmailCopy = emailCopies[locale];
  const frame = copy.trialEnding;
  const reason: string = variant.reason === "one_meeting_left" ? frame.oneMeetingLeft : frame.endsWithinDay;
  const next: string = variant.next === "free" ? frame.nextFree(facts.free) : frame.nextSubscribe;
  return lifecycleEmail(copy, facts, links, frame, [reason, next, frame.keep], [], [], `${facts.siteOrigin}/pricing`);
}

/** The account moved to the free plan: what it includes. Pure function. */
export function freePlanEmail(locale: EmailLocale, facts: EmailFacts, links: UnsubscribeLinks): ComposedEmail {
  const copy: EmailCopy = emailCopies[locale];
  const frame = copy.freePlan;
  return lifecycleEmail(copy, facts, links, frame, [frame.intro], frame.items(facts.free), [frame.outro], `${facts.siteOrigin}/pricing`);
}
