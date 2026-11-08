-- State guards for the dialer calls, refresh tokens, the trial columns of `users`, sync key envelopes and App Store
-- rows. The code already moves each of these with UPDATEs conditional on the source state (src/phone/lifecycle.ts,
-- src/auth/refreshState.ts, src/trialState.ts, src/sync.ts, src/appStore.ts); these triggers make the same rules hold
-- in the database, so a missed condition in a future code path fails loudly instead of writing a contradictory row.
--
-- Additive only: no table rebuild, no existing row is read or changed. Every trigger fires on a write that changes the
-- guarded columns, so rows written before this migration stay readable and every write the running code does passes.

-- Dialer calls (`phone_calls`): reserved → dialing → completed | failed; reserved | dialing → expired. A call is settled
-- (`settled_at` set) exactly when it is in an end state, and a settled call never changes its outcome.
CREATE TRIGGER phone_calls_insert_reserved BEFORE INSERT ON phone_calls
WHEN NEW.status <> 'reserved' OR NEW.settled_at IS NOT NULL OR NEW.recording_status IS NOT NULL OR NEW.recording_sid IS NOT NULL
  OR NEW.recording_deleted_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'phone_calls: a call starts reserved, unsettled and without a recording');
END;

CREATE TRIGGER phone_calls_status_transition BEFORE UPDATE OF status ON phone_calls
WHEN OLD.status <> NEW.status AND NOT (
  (OLD.status = 'reserved' AND NEW.status IN ('dialing', 'expired'))
  OR (OLD.status = 'dialing' AND NEW.status IN ('completed', 'failed', 'expired'))
)
BEGIN
  SELECT RAISE(ABORT, 'phone_calls: status transition not allowed');
END;

CREATE TRIGGER phone_calls_settled_iff_ended BEFORE UPDATE OF status, settled_at ON phone_calls
WHEN (NEW.status IN ('completed', 'failed', 'expired')) <> (NEW.settled_at IS NOT NULL)
BEGIN
  SELECT RAISE(ABORT, 'phone_calls: a call is settled exactly when it has ended');
END;

CREATE TRIGGER phone_calls_settlement_is_final BEFORE UPDATE OF status, settled_at, billed_seconds, cost_micro_usd ON phone_calls
WHEN OLD.settled_at IS NOT NULL AND (NEW.settled_at IS NOT OLD.settled_at OR NEW.status IS NOT OLD.status
  OR NEW.billed_seconds IS NOT OLD.billed_seconds OR NEW.cost_micro_usd IS NOT OLD.cost_micro_usd)
BEGIN
  SELECT RAISE(ABORT, 'phone_calls: a settled call cannot change');
END;

-- Recording: a stored recording sid never changes and is never cleared (any other sid is queued for deletion at the
-- provider), `recording_status` is 'ready' exactly when a sid is stored, and the deletion mark needs the sid and stays.
CREATE TRIGGER phone_calls_recording_sid_kept BEFORE UPDATE OF recording_sid ON phone_calls
WHEN OLD.recording_sid IS NOT NULL AND NEW.recording_sid IS NOT OLD.recording_sid
BEGIN
  SELECT RAISE(ABORT, 'phone_calls: a stored recording sid cannot change');
END;

CREATE TRIGGER phone_calls_recording_consistent BEFORE UPDATE OF recording_status, recording_sid, recording_deleted_at ON phone_calls
WHEN (NEW.recording_sid IS NOT NULL) <> (NEW.recording_status IS 'ready')
  OR (NEW.recording_deleted_at IS NOT NULL AND NEW.recording_sid IS NULL)
  OR (OLD.recording_deleted_at IS NOT NULL AND NEW.recording_deleted_at IS NOT OLD.recording_deleted_at)
BEGIN
  SELECT RAISE(ABORT, 'phone_calls: contradictory recording columns');
END;

-- Refresh tokens (src/auth/refreshState.ts): unused → rotated (used_at and the successor's hash) → superseded (a
-- retry replaced the unused successor; `replaced_by` = 'superseded'). Use is final, a successor is only recorded for a
-- used token and is never cleared, 'superseded' is final. A signed-out family stays signed out.
CREATE TRIGGER refresh_tokens_successor_needs_use BEFORE INSERT ON refresh_tokens
WHEN NEW.replaced_by IS NOT NULL AND NEW.used_at IS NULL
BEGIN
  SELECT RAISE(ABORT, 'refresh_tokens: a successor needs used_at');
END;

CREATE TRIGGER refresh_tokens_rotation BEFORE UPDATE OF used_at, replaced_by ON refresh_tokens
WHEN (NEW.replaced_by IS NOT NULL AND NEW.used_at IS NULL)
  OR (OLD.used_at IS NOT NULL AND NEW.used_at IS NOT OLD.used_at)
  OR (OLD.replaced_by IS NOT NULL AND NEW.replaced_by IS NULL)
  OR (OLD.replaced_by = 'superseded' AND NEW.replaced_by IS NOT 'superseded')
BEGIN
  SELECT RAISE(ABORT, 'refresh_tokens: rotation can only move forward');
END;

CREATE TRIGGER refresh_families_revocation_is_final BEFORE UPDATE OF revoked_at ON refresh_families
WHEN OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS NOT OLD.revoked_at
BEGIN
  SELECT RAISE(ABORT, 'refresh_families: a revoked family stays revoked');
END;

-- Trial (src/trialState.ts): the trial start is never cleared or moved later (that would hand out a new trial), used
-- trial meetings carried over from deleted accounts never shrink, and a trial bound to a Mac stays bound. A pending
-- Mac claim and a finished binding never coexist.
CREATE TRIGGER users_trial_start_kept BEFORE UPDATE OF trial_started_at ON users
WHEN OLD.trial_started_at IS NOT NULL AND (NEW.trial_started_at IS NULL OR NEW.trial_started_at > OLD.trial_started_at)
BEGIN
  SELECT RAISE(ABORT, 'users: the trial start cannot be cleared or moved later');
END;

CREATE TRIGGER users_carried_trial_meetings_grow BEFORE UPDATE OF carried_trial_meetings ON users
WHEN NEW.carried_trial_meetings < OLD.carried_trial_meetings
BEGIN
  SELECT RAISE(ABORT, 'users: carried trial meetings cannot shrink');
END;

CREATE TRIGGER users_trial_device_binding BEFORE UPDATE OF trial_device_verified_at, trial_device_claim_started_at ON users
WHEN (OLD.trial_device_verified_at IS NOT NULL AND NEW.trial_device_verified_at IS NOT OLD.trial_device_verified_at)
  OR (NEW.trial_device_verified_at IS NOT NULL AND NEW.trial_device_claim_started_at IS NOT NULL)
BEGIN
  SELECT RAISE(ABORT, 'users: a Mac-bound trial stays bound and has no pending claim');
END;

-- Sync key envelopes (src/sync.ts `syncEnvelopeKinds`): the recovery envelope never expires, a pairing message always
-- does.
CREATE TRIGGER sync_key_envelopes_kind_insert BEFORE INSERT ON sync_key_envelopes
WHEN NOT ((NEW.kind = 'recovery' AND NEW.expires_at IS NULL) OR (NEW.kind = 'pairing' AND NEW.expires_at IS NOT NULL))
BEGIN
  SELECT RAISE(ABORT, 'sync_key_envelopes: recovery never expires, pairing always does');
END;

CREATE TRIGGER sync_key_envelopes_kind_update BEFORE UPDATE OF kind, expires_at ON sync_key_envelopes
WHEN NOT ((NEW.kind = 'recovery' AND NEW.expires_at IS NULL) OR (NEW.kind = 'pairing' AND NEW.expires_at IS NOT NULL))
BEGIN
  SELECT RAISE(ABORT, 'sync_key_envelopes: recovery never expires, pairing always does');
END;

-- App Store rows come only from the App Store or the Mac App Store (src/appStore.ts `appStoreStores`).
CREATE TRIGGER app_store_subscriptions_store_insert BEFORE INSERT ON app_store_subscriptions
WHEN NEW.store NOT IN ('app_store', 'mac_app_store')
BEGIN
  SELECT RAISE(ABORT, 'app_store_subscriptions: unknown store');
END;

CREATE TRIGGER app_store_subscriptions_store_update BEFORE UPDATE OF store ON app_store_subscriptions
WHEN NEW.store NOT IN ('app_store', 'mac_app_store')
BEGIN
  SELECT RAISE(ABORT, 'app_store_subscriptions: unknown store');
END;
