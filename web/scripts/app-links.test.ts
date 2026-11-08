// Toplantı bağlantısı sayfasının uygulama adresi (src/lib/app-links.ts): geçerli kimlik `gistsmith://meeting/<kimlik>`
// olur; kimliksiz, fazla parçalı ya da kurala uymayan adres düğmeyi açmaz. Kural uygulamadaki ayrıştırıcıyla
// (`AppLinksTests`) aynı. Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { appMeetingLink } from "../src/lib/app-links.ts";

test("a meeting page address becomes the app's meeting link", () => {
  assert.equal(appMeetingLink("/m/20261105-103000"), "gistsmith://meeting/20261105-103000");
  assert.equal(appMeetingLink("/m/0a4f2c1e-7b7d-4c33-9e55-2f3b6a1c9d10/"), "gistsmith://meeting/0a4f2c1e-7b7d-4c33-9e55-2f3b6a1c9d10");
  assert.equal(appMeetingLink(`/m/${"a".repeat(64)}`), `gistsmith://meeting/${"a".repeat(64)}`);
});

test("addresses without a valid meeting id give no app link", () => {
  for (const pathname of ["/meeting", "/m/", "/m", "/m/a/b", "/m/-abc", "/m/a%2Fb", "/m/a%20b", "/m/%C3%A7", "/m/..", `/m/${"a".repeat(65)}`, "/x/m/abc"]) {
    assert.equal(appMeetingLink(pathname), null, pathname);
  }
});
