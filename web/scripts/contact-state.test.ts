// Contact form submission and its single-use Turnstile token (src/lib/contact-state.ts). No build needed.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { type ContactState, type ContactTransition, canSubmit, contactTransition, initialContact } from "../src/lib/contact-state.ts";

function ready(token: string): ContactState {
  return contactTransition(initialContact, { kind: "tokenIssued", token }).state;
}

test("a submission consumes its token once; a repeated submit sends nothing", () => {
  const sending: ContactTransition = contactTransition(ready("t1"), { kind: "submitRequested" });
  assert.deepEqual(sending.effects, [{ kind: "send", token: "t1" }]);
  assert.deepEqual(sending.state, { token: null, submitting: true });
  assert.deepEqual(contactTransition(sending.state, { kind: "submitRequested" }).effects, []);
  assert.deepEqual(contactTransition(initialContact, { kind: "submitRequested" }), { state: initialContact, effects: [] });
});

test("a token issued while a submission runs does not enable a second one and is dropped when it finishes", () => {
  const sending: ContactState = contactTransition(ready("t1"), { kind: "submitRequested" }).state;
  const redrawn: ContactState = contactTransition(contactTransition(sending, { kind: "tokenLost" }).state, { kind: "tokenIssued", token: "t2" }).state;
  assert.equal(canSubmit(redrawn), false);
  assert.deepEqual(contactTransition(redrawn, { kind: "submitRequested" }).effects, []);
  const finished: ContactTransition = contactTransition(redrawn, { kind: "submitFinished" });
  assert.deepEqual(finished, { state: { token: null, submitting: false }, effects: [{ kind: "resetWidget" }] });
  assert.equal(canSubmit(finished.state), false);
  assert.equal(canSubmit(contactTransition(finished.state, { kind: "tokenIssued", token: "t3" }).state), true);
});

test("an expired or failed token disables submission until a new one arrives", () => {
  const lost: ContactState = contactTransition(ready("t1"), { kind: "tokenLost" }).state;
  assert.equal(canSubmit(lost), false);
  assert.deepEqual(contactTransition(lost, { kind: "submitRequested" }).effects, []);
});
