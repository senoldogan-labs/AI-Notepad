/**
 * The two state machines of a dialer call (`phone_calls`), as pure functions. Every UPDATE that moves a call or its
 * recording takes its source-state condition from here and checks the changed row count, so a webhook that arrives
 * late, twice or out of order can never move a row backwards.
 *
 * Call: `reserved` → (connect) `dialing` → (end) `completed` | `failed`; `reserved` | `dialing` → (expire) `expired`.
 * The three end states are settled (`settled_at` set) and final.
 *
 * Recording (independent of the call's status): `pending` → `ready` (sid known) | `absent`; `absent` → `ready` (a
 * recording that came after all); `ready` → `deleted` (deleted at the provider). A known recording sid is never
 * replaced or cleared: any other sid the provider reports is queued for deletion at the provider instead, so every
 * recording is deleted there.
 */

export type PhoneCallStatus = "reserved" | "dialing" | "completed" | "failed" | "expired";

/** What happens to a call: the voice webhook bridged it, it ended (answered or not), or its reservation ran out. */
export type PhoneCallEvent = "connect" | "end_answered" | "end_unanswered" | "expire";

interface CallTransition {
  readonly from: readonly PhoneCallStatus[];
  readonly to: PhoneCallStatus;
}

const callTransitions: Readonly<Record<PhoneCallEvent, CallTransition>> = {
  connect: { from: ["reserved"], to: "dialing" },
  end_answered: { from: ["dialing"], to: "completed" },
  end_unanswered: { from: ["dialing"], to: "failed" },
  expire: { from: ["reserved", "dialing"], to: "expired" },
};

/** The status after `event`, or `null` when the event doesn't apply to a call in `status`. Pure function. */
export function nextCallStatus(status: PhoneCallStatus, event: PhoneCallEvent): PhoneCallStatus | null {
  const transition: CallTransition = callTransitions[event];
  return transition.from.includes(status) ? transition.to : null;
}

/** The status `event` moves a call to. Pure function. */
export function callStatusAfter(event: PhoneCallEvent): PhoneCallStatus {
  return callTransitions[event].to;
}

/**
 * The SQL condition that a `phone_calls` row is in a source state of `event` (statuses are a closed set of literals,
 * so they are inlined). Pure function.
 */
export function callSourceSql(event: PhoneCallEvent): string {
  const from: string = callTransitions[event].from.map((status: PhoneCallStatus): string => `'${status}'`).join(", ");
  return `(status IN (${from}) AND settled_at IS NULL)`;
}

/** A call's recording as stored. */
export type RecordingState =
  | { readonly kind: "pending" }
  | { readonly kind: "absent" }
  | { readonly kind: "ready"; readonly sid: string }
  | { readonly kind: "deleted"; readonly sid: string };

/** What the provider's recording callback reports: a finished recording, or none (possibly with a sid that exists). */
export type RecordingEvent = { readonly kind: "ready"; readonly sid: string } | { readonly kind: "absent"; readonly sid: string | null };

/** What to do with a recording callback: the state to store (from a source state, see `recordingSourceSql`) and a sid to delete at the provider. */
export interface RecordingDecision {
  readonly store: "ready" | "absent" | null;
  readonly purge: string | null;
}

/** The recording columns of a `phone_calls` row. */
export interface RecordingColumns {
  readonly recording_status: "ready" | "absent" | null;
  readonly recording_sid: string | null;
  readonly recording_deleted_at: number | null;
}

/** Thrown for a row whose recording columns contradict each other. */
export class RecordingStateError extends Error {
  constructor(columns: RecordingColumns) {
    super(`Contradictory phone recording columns: status=${columns.recording_status} sid=${columns.recording_sid === null ? "null" : "set"} deleted_at=${columns.recording_deleted_at}`);
    this.name = "RecordingStateError";
  }
}

/** Decodes the recording columns; contradictory rows throw `RecordingStateError`. Pure function. */
export function recordingStateOf(columns: RecordingColumns): RecordingState {
  if (columns.recording_sid !== null) {
    if (columns.recording_status !== "ready") {
      throw new RecordingStateError(columns);
    }
    return columns.recording_deleted_at === null ? { kind: "ready", sid: columns.recording_sid } : { kind: "deleted", sid: columns.recording_sid };
  }
  if (columns.recording_deleted_at !== null || columns.recording_status === "ready") {
    throw new RecordingStateError(columns);
  }
  return columns.recording_status === "absent" ? { kind: "absent" } : { kind: "pending" };
}

/**
 * The recording transition for a callback. A call without a recording sid takes a ready recording; a pending one also
 * takes "none". Every reported sid that is not the stored one is purged at the provider; the stored one is kept (its
 * own deletion is the app's or the cleanup's). Pure function.
 */
export function recordingTransition(state: RecordingState, event: RecordingEvent): RecordingDecision {
  switch (state.kind) {
    case "pending":
      return event.kind === "ready" ? { store: "ready", purge: null } : { store: "absent", purge: event.sid };
    case "absent":
      return event.kind === "ready" ? { store: "ready", purge: null } : { store: null, purge: event.sid };
    case "ready":
    case "deleted":
      return { store: null, purge: event.sid === state.sid ? null : event.sid };
  }
}

/** The decision for a callback whose call no longer exists (deleted account, retention): the recording is purged. Pure function. */
export function orphanRecordingDecision(event: RecordingEvent): RecordingDecision {
  return { store: null, purge: event.sid };
}

/** The SQL condition that a row is in a state that may store `store` (no recording sid yet; "absent" only from pending). Pure function. */
export function recordingSourceSql(store: "ready" | "absent"): string {
  return store === "ready"
    ? "(recording_sid IS NULL AND recording_deleted_at IS NULL)"
    : "(recording_sid IS NULL AND recording_deleted_at IS NULL AND recording_status IS NULL)";
}
