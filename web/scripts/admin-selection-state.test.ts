// Admin selection ownership (src/lib/admin-selection-state.ts): a detail response draws only for the current target and
// request generation, and an open requested before a list load finished does not override a newer choice. No build needed.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  type SelectionState,
  type SelectionTransition,
  initialSelection,
  requestedDetail,
  selectionTransition,
  shouldRender,
} from "../src/lib/admin-selection-state.ts";

/** The request generation a transition asked for; fails the test when it asked for none. */
function requested(transition: SelectionTransition): number {
  const request: { readonly targetId: string; readonly generation: number } | null = requestedDetail(transition);
  assert.ok(request !== null, "expected a detail request");
  return request.generation;
}

test("selecting a target requests its detail and draws only that response", () => {
  const selected: SelectionTransition = selectionTransition(initialSelection, { kind: "select", targetId: "a" });
  assert.deepEqual(selected.state, { targetId: "a", generation: 1 });
  assert.deepEqual(selected.effects, [{ kind: "requestDetail", targetId: "a", generation: 1 }]);
  assert.equal(shouldRender(selectionTransition(selected.state, { kind: "detailArrived", targetId: "a", generation: 1 })), true);
  assert.equal(shouldRender(selectionTransition(selected.state, { kind: "detailArrived", targetId: "b", generation: 1 })), false);
});

test("A -> B -> A: the first A response arriving last is not drawn", () => {
  const firstA: SelectionTransition = selectionTransition(initialSelection, { kind: "select", targetId: "a" });
  const b: SelectionTransition = selectionTransition(firstA.state, { kind: "select", targetId: "b" });
  const secondA: SelectionTransition = selectionTransition(b.state, { kind: "select", targetId: "a" });
  assert.equal(shouldRender(selectionTransition(secondA.state, { kind: "detailArrived", targetId: "a", generation: requested(secondA) })), true);
  assert.equal(shouldRender(selectionTransition(secondA.state, { kind: "detailArrived", targetId: "a", generation: requested(firstA) })), false);
  assert.equal(shouldRender(selectionTransition(secondA.state, { kind: "detailArrived", targetId: "b", generation: requested(b) })), false);
});

test("a reload after an action supersedes a read started before it", () => {
  const selected: SelectionTransition = selectionTransition(initialSelection, { kind: "select", targetId: "a" });
  const reloaded: SelectionTransition = selectionTransition(selected.state, { kind: "reload", targetId: "a" });
  assert.deepEqual(reloaded.effects, [{ kind: "requestDetail", targetId: "a", generation: 2 }]);
  assert.equal(shouldRender(selectionTransition(reloaded.state, { kind: "detailArrived", targetId: "a", generation: requested(selected) })), false);
  assert.equal(shouldRender(selectionTransition(reloaded.state, { kind: "detailArrived", targetId: "a", generation: requested(reloaded) })), true);
});

test("reload of a target no longer shown and clear request nothing; clear rejects the pending response", () => {
  assert.deepEqual(selectionTransition(initialSelection, { kind: "reload", targetId: "a" }), { state: initialSelection, effects: [] });
  const selected: SelectionTransition = selectionTransition(initialSelection, { kind: "select", targetId: "a" });
  const otherShown: SelectionState = selectionTransition(selected.state, { kind: "select", targetId: "b" }).state;
  assert.deepEqual(selectionTransition(otherShown, { kind: "reload", targetId: "a" }), { state: otherShown, effects: [] });
  const cleared: SelectionTransition = selectionTransition(selected.state, { kind: "clear" });
  assert.deepEqual(cleared, { state: { targetId: null, generation: 2 }, effects: [] });
  assert.equal(shouldRender(selectionTransition(cleared.state, { kind: "detailArrived", targetId: "a", generation: requested(selected) })), false);
});

test("a deferred open applies only when nothing changed the selection since it began", () => {
  const cleared: SelectionState = selectionTransition(initialSelection, { kind: "clear" }).state;
  const expectedGeneration: number = cleared.generation;
  const applied: SelectionTransition = selectionTransition(cleared, { kind: "deferredSelect", targetId: "r", expectedGeneration });
  assert.deepEqual(applied.effects, [{ kind: "requestDetail", targetId: "r", generation: expectedGeneration + 1 }]);

  // The admin switched tabs (clear) or picked another report while the list loaded: the open is dropped.
  const switched: SelectionState = selectionTransition(cleared, { kind: "clear" }).state;
  assert.deepEqual(selectionTransition(switched, { kind: "deferredSelect", targetId: "r", expectedGeneration }), { state: switched, effects: [] });
  const picked: SelectionState = selectionTransition(cleared, { kind: "select", targetId: "other" }).state;
  assert.deepEqual(selectionTransition(picked, { kind: "deferredSelect", targetId: "r", expectedGeneration }), { state: picked, effects: [] });
});

test("an action's answer is drawn as a new generation and drops every read started before it", () => {
  const selected: SelectionTransition = selectionTransition(initialSelection, { kind: "select", targetId: "a" });
  const refreshed: SelectionTransition = selectionTransition(selected.state, { kind: "reload", targetId: "a" });
  const answered: SelectionTransition = selectionTransition(refreshed.state, { kind: "actionAnswered", targetId: "a" });
  assert.deepEqual(answered.effects, [{ kind: "renderDetail", targetId: "a", generation: 3 }]);
  assert.equal(shouldRender(selectionTransition(answered.state, { kind: "detailArrived", targetId: "a", generation: requested(refreshed) })), false);
  assert.equal(shouldRender(selectionTransition(answered.state, { kind: "detailArrived", targetId: "a", generation: requested(selected) })), false);
  // The admin left the account before the action answered: nothing is drawn.
  const left: SelectionState = selectionTransition(selected.state, { kind: "clear" }).state;
  assert.deepEqual(selectionTransition(left, { kind: "actionAnswered", targetId: "a" }), { state: left, effects: [] });
});

test("a deferred open is dropped after a clear followed by a select", () => {
  const cleared: SelectionState = selectionTransition(initialSelection, { kind: "clear" }).state;
  const expectedGeneration: number = cleared.generation;
  const later: SelectionState = selectionTransition(selectionTransition(cleared, { kind: "clear" }).state, { kind: "select", targetId: "x" }).state;
  assert.deepEqual(selectionTransition(later, { kind: "deferredSelect", targetId: "r", expectedGeneration }), { state: later, effects: [] });
});
