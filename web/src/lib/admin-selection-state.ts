// Which report or account an admin view shows, and which detail response may draw it (src/client/admin.ts inbox,
// src/client/admin-users.ts). Every selection, clearing and reload takes a new generation: a detail response draws only
// when it belongs to the current generation and target, so an older response for the same target (A -> B -> A, or a
// read started before a status change) never overwrites a newer one, and an open requested before the list finished
// loading does not reopen its target after the admin chose another one. Pure; no DOM (scripts/admin-selection-state.test.ts).

/** The shown target and the generation of its latest detail request (0 before any). */
export interface SelectionState {
  readonly targetId: string | null;
  readonly generation: number;
}

export type SelectionEvent =
  /** The admin chose a target: its detail is requested. */
  | { readonly kind: "select"; readonly targetId: string }
  /** A target chosen earlier, applied only if nothing changed the selection since `expectedGeneration`. */
  | { readonly kind: "deferredSelect"; readonly targetId: string; readonly expectedGeneration: number }
  /** `targetId`'s detail is requested again (refresh, or after an action on it); nothing if it is no longer shown. */
  | { readonly kind: "reload"; readonly targetId: string }
  /**
   * An action on `targetId` answered with its newest detail: it takes a new generation and is drawn without another
   * request, so every read started before it is dropped. Nothing if the target is no longer shown.
   */
  | { readonly kind: "actionAnswered"; readonly targetId: string }
  /** The selection ends (filter changed, back to the list). */
  | { readonly kind: "clear" }
  /** A detail response arrived for the request of `generation`. */
  | { readonly kind: "detailArrived"; readonly targetId: string; readonly generation: number };

export type SelectionEffect =
  /** Request the detail of `targetId`; its response comes back as `detailArrived` with this generation. */
  | { readonly kind: "requestDetail"; readonly targetId: string; readonly generation: number }
  /** Draw the response that arrived: it is the current one. */
  | { readonly kind: "renderDetail"; readonly targetId: string; readonly generation: number };

export interface SelectionTransition {
  readonly state: SelectionState;
  readonly effects: readonly SelectionEffect[];
}

/** Nothing selected yet. */
export const initialSelection: SelectionState = { targetId: null, generation: 0 };

function requesting(state: SelectionState, targetId: string): SelectionTransition {
  const next: SelectionState = { targetId, generation: state.generation + 1 };
  return { state: next, effects: [{ kind: "requestDetail", targetId, generation: next.generation }] };
}

/** The next selection state and what the view must do. Pure function. */
export function selectionTransition(state: SelectionState, event: SelectionEvent): SelectionTransition {
  switch (event.kind) {
    case "select":
      return requesting(state, event.targetId);
    case "deferredSelect":
      return state.generation === event.expectedGeneration ? requesting(state, event.targetId) : { state, effects: [] };
    case "reload":
      return state.targetId === event.targetId ? requesting(state, event.targetId) : { state, effects: [] };
    case "actionAnswered": {
      if (state.targetId !== event.targetId) {
        return { state, effects: [] };
      }
      const next: SelectionState = { targetId: event.targetId, generation: state.generation + 1 };
      return { state: next, effects: [{ kind: "renderDetail", targetId: event.targetId, generation: next.generation }] };
    }
    case "clear":
      return { state: { targetId: null, generation: state.generation + 1 }, effects: [] };
    case "detailArrived":
      return state.targetId === event.targetId && state.generation === event.generation
        ? { state, effects: [{ kind: "renderDetail", targetId: event.targetId, generation: event.generation }] }
        : { state, effects: [] };
  }
}

/** Whether a transition says to draw the response that arrived. Pure function. */
export function shouldRender(transition: SelectionTransition): boolean {
  return transition.effects.some((effect: SelectionEffect): boolean => effect.kind === "renderDetail");
}

/** The detail request a transition asks for, if any. Pure function. */
export function requestedDetail(transition: SelectionTransition): { readonly targetId: string; readonly generation: number } | null {
  for (const effect of transition.effects) {
    if (effect.kind === "requestDetail") {
      return { targetId: effect.targetId, generation: effect.generation };
    }
  }
  return null;
}
