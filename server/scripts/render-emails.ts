// Renders every email in every language to HTML and text files for a visual check (no sending, no network):
//   npx esbuild scripts/render-emails.ts --bundle --platform=node --format=esm --outfile=<tmp>/render-emails.mjs
//   node <tmp>/render-emails.mjs <output folder>
// Then open <output folder>/index.html. The logo loads from https://gistsmith.com (the production site origin).
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { emailLocales } from "../src/email/copy";
import {
  type ComposedEmail,
  type EmailFacts,
  type UnsubscribeLinks,
  activationEmail,
  confirmationEmail,
  freePlanEmail,
  trialEndingEmail,
  welcomeEmail,
} from "../src/email/messages";

const outDir: string | undefined = process.argv[2];
if (outDir === undefined) {
  throw new Error("Usage: node render-emails.mjs <output folder>");
}
const facts: EmailFacts = {
  siteOrigin: "https://gistsmith.com",
  privacyContact: "privacy@gistsmith.com",
  trial: { meetings: 3, days: 7 },
  free: { notesPerMonth: 4, maxMeetingMinutes: 45, asksPerMonth: 5 },
};
const token: string = "EXAMPLE_TOKEN_0123456789abcdefghijklmnopqrs";
const links: UnsubscribeLinks = {
  oneClickUrl: `https://api.gistsmith.com/v1/email/unsubscribe?s=00000000-0000-4000-8000-000000000000.${token}`,
  pageUrl: `https://gistsmith.com/email/unsubscribe#00000000-0000-4000-8000-000000000000.${token}`,
};
mkdirSync(outDir, { recursive: true });
const rows: string[] = [];
for (const locale of emailLocales) {
  const emails: ReadonlyArray<readonly [string, ComposedEmail]> = [
    ["confirm", confirmationEmail(locale, facts, token)],
    ["welcome", welcomeEmail(locale, facts, links)],
    ["activation", activationEmail(locale, facts, links)],
    ["trial-ending-free", trialEndingEmail(locale, facts, links, { reason: "one_meeting_left", next: "free" })],
    ["trial-ending-subscribe", trialEndingEmail(locale, facts, links, { reason: "ends_within_day", next: "subscribe" })],
    ["free-plan", freePlanEmail(locale, facts, links)],
  ];
  for (const [kind, email] of emails) {
    const name: string = `${locale}-${kind}`;
    writeFileSync(join(outDir, `${name}.html`), email.html);
    writeFileSync(join(outDir, `${name}.txt`), `Subject: ${email.subject}\n${Object.entries(email.headers).map(([key, value]) => `${key}: ${value}`).join("\n")}\n\n${email.text}`);
    rows.push(`<li><a href="${name}.html">${name}</a> · <a href="${name}.txt">text</a> · ${email.subject} · ${email.html.length} bytes</li>`);
  }
}
writeFileSync(join(outDir, "index.html"), `<!doctype html><meta charset="utf-8"><title>Gistsmith emails</title><ul>${rows.join("")}</ul>`);
console.log(`${rows.length} emails written to ${outDir}`);
