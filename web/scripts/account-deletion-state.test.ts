// Account deletion on the account page (src/lib/account-deletion-state.ts). No build needed.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  type AccountDeletionEvent,
  type AccountDeletionState,
  type AccountDeletionTransition,
  accountDeletionTransition,
  canCloseDeletion,
  canConfirmDeletion,
  initialAccountDeletion,
} from "../src/lib/account-deletion-state.ts";

function run(events: readonly AccountDeletionEvent[]): AccountDeletionState {
  return events.reduce((state: AccountDeletionState, event: AccountDeletionEvent): AccountDeletionState => accountDeletionTransition(state, event).state, initialAccountDeletion);
}

const confirmed: readonly AccountDeletionEvent[] = [{ kind: "opened" }, { kind: "typed", wordMatches: true }, { kind: "confirmed" }];

test("the confirmation word enables exactly one deletion", () => {
  assert.equal(canConfirmDeletion(run([{ kind: "opened" }])), false);
  assert.equal(canConfirmDeletion(run([{ kind: "opened" }, { kind: "typed", wordMatches: true }])), true);
  assert.deepEqual(accountDeletionTransition(run([{ kind: "opened" }]), { kind: "confirmed" }).effects, []);
  const sending: AccountDeletionTransition = accountDeletionTransition(run([{ kind: "opened" }, { kind: "typed", wordMatches: true }]), { kind: "confirmed" });
  assert.deepEqual(sending, { state: { kind: "deleting" }, effects: [{ kind: "sendDeletion" }] });
});

test("while the deletion runs, typing, confirming, reopening or closing changes nothing", () => {
  const deleting: AccountDeletionState = run(confirmed);
  for (const event of [{ kind: "typed", wordMatches: true }, { kind: "confirmed" }, { kind: "opened" }, { kind: "cancelled" }] as const) {
    assert.deepEqual(accountDeletionTransition(deleting, event), { state: deleting, effects: [] }, event.kind);
  }
  assert.equal(canConfirmDeletion(deleting), false);
  assert.equal(canCloseDeletion(deleting), false);
});

test("a failure offers the deletion again only with the word typed; success finishes once", () => {
  assert.equal(canConfirmDeletion(run([...confirmed, { kind: "failed", wordMatches: true }])), true);
  assert.equal(canConfirmDeletion(run([...confirmed, { kind: "failed", wordMatches: false }])), false);
  const done: AccountDeletionTransition = accountDeletionTransition(run(confirmed), { kind: "succeeded" });
  assert.deepEqual(done, { state: { kind: "deleted" }, effects: [{ kind: "finish" }] });
  assert.deepEqual(accountDeletionTransition(done.state, { kind: "succeeded" }).effects, []);
  assert.deepEqual(accountDeletionTransition(done.state, { kind: "opened" }).state, done.state);
  assert.equal(canConfirmDeletion(done.state), false);
});

test("cancelling before confirming closes; the dialog can be opened again", () => {
  const closed: AccountDeletionState = run([{ kind: "opened" }, { kind: "typed", wordMatches: true }, { kind: "cancelled" }]);
  assert.deepEqual(closed, initialAccountDeletion);
  assert.deepEqual(run([{ kind: "opened" }, { kind: "cancelled" }, { kind: "opened" }]), { kind: "confirming", wordMatches: false });
});
