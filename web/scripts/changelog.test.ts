// Sürüm geçmişinin saf yardımcıları (src/lib/changelog.ts): sürüm sırası, notların HTML'i ve notlarla yayın günlerinin
// eşleşmesi. Derleme gerektirmez; depodaki gerçek notlar ve günler de birlikte denetlenir.
import { strict as assert } from "node:assert";
import { readdir, readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { type ChangelogEntry, changelogEntries, releaseNotesHtml, releaseVersionOf } from "../src/lib/changelog.ts";

const notesDir: URL = new URL("../../docs/release-notes/", import.meta.url);

test("only Gistsmith notes are releases, newest first by number, not by text", () => {
  const entries: ChangelogEntry[] = changelogEntries(
    { "x/gistsmith-0.1.9.md": "Nine.", "x/gistsmith-0.1.10.md": "Ten.", "x/gistsmith-0.2.0.md": "Two.", "x/0.1.3.md": "Old app." },
    { "0.1.9": "2026-10-30", "0.1.10": "2026-10-31", "0.2.0": "2026-11-06" },
  );
  assert.deepEqual(
    entries.map((entry: ChangelogEntry): string => entry.version),
    ["0.2.0", "0.1.10", "0.1.9"],
  );
  assert.equal(entries[0]?.anchor, "v0-2-0");
  assert.equal(releaseVersionOf("docs/release-notes/0.1.3.md"), null);
});

test("a release without a date, or a date without notes, stops the build", () => {
  assert.throws(() => changelogEntries({ "gistsmith-0.3.0.md": "New." }, {}), /0\.3\.0/);
  assert.throws(() => changelogEntries({ "gistsmith-0.3.0.md": "New." }, { "0.3.0": "3 Nov" }), /0\.3\.0/);
  assert.throws(() => changelogEntries({}, { "0.3.0": "2026-11-11" }), /0\.3\.0/);
});

test("the notes keep their text; their headings move one level down under the version", () => {
  const html: string = releaseNotesHtml("Summary.\n\n## New\n- **Bold lead.** Text.\n\nRequires macOS 15.");
  assert.match(html, /<h3[^>]*>New<\/h3>/);
  assert.match(html, /<li><strong>Bold lead\.<\/strong> Text\.<\/li>/);
  assert.match(html, /<p>Requires macOS 15\.<\/p>/);
});

test("every release note in the repository has a release date", async () => {
  const names: string[] = await readdir(fileURLToPath(notesDir));
  const notes: Record<string, string> = Object.fromEntries(
    await Promise.all(names.filter((name: string): boolean => name.endsWith(".md")).map(async (name: string): Promise<[string, string]> => [name, await readFile(new URL(name, notesDir), "utf8")])),
  );
  const dates: Record<string, string> = JSON.parse(await readFile(new URL("release-dates.json", notesDir), "utf8")) as Record<string, string>;
  assert.ok(changelogEntries(notes, dates).length > 0);
});
