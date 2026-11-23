// public/.well-known/security.txt (RFC 9116): the contact is the operator's address, and `Expires` is still at least 30
// days away, so the file never goes stale unnoticed. Renew `Expires` in the file when this fails.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { operator } from "../src/legal/operator.ts";

const minimumDaysLeft: number = 30;

/** The value of a `Field: value` line of security.txt; throws when the field is missing. */
function field(text: string, name: string): string {
  const line: string | undefined = text.split("\n").find((candidate: string): boolean => candidate.startsWith(`${name}:`));
  if (line === undefined) {
    throw new Error(`security.txt has no ${name} field`);
  }
  return line.slice(name.length + 1).trim();
}

test("security.txt names the operator's address and does not expire soon", async () => {
  const text: string = await readFile(new URL("../public/.well-known/security.txt", import.meta.url), "utf8");
  assert.equal(field(text, "Contact"), `mailto:${operator.email}`);
  const expires: number = Date.parse(field(text, "Expires"));
  assert.ok(Number.isFinite(expires), "Expires is not a valid date");
  const daysLeft: number = (expires - Date.now()) / 86_400_000;
  assert.ok(daysLeft >= minimumDaysLeft, `security.txt expires in ${Math.floor(daysLeft)} days: renew Expires`);
});
