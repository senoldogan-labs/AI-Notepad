// Blog editor work ownership (src/lib/blog-editor-state.ts). No build needed.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { type BlogWorkOwner, ownsBlogWork } from "../src/lib/blog-editor-state.ts";

const started: BlogWorkOwner = { session: 3, imageAttempt: 5 };

test("an answer acts on the editor only within the session it started in", () => {
  assert.equal(ownsBlogWork({ session: 3, imageAttempt: 5 }, started, "session"), true);
  assert.equal(ownsBlogWork({ session: 4, imageAttempt: 5 }, started, "session"), false);
  // An image upload stays the post's even if the image section was reset meanwhile.
  assert.equal(ownsBlogWork({ session: 3, imageAttempt: 6 }, started, "session"), true);
});

test("a prepared preview belongs to its image attempt as well", () => {
  assert.equal(ownsBlogWork({ session: 3, imageAttempt: 5 }, started, "image"), true);
  assert.equal(ownsBlogWork({ session: 3, imageAttempt: 6 }, started, "image"), false);
  assert.equal(ownsBlogWork({ session: 4, imageAttempt: 5 }, started, "image"), false);
});
