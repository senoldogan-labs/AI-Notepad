-- Meeting session lifecycle guards (src/meetingLifecycle.ts). The code applies every transition with an UPDATE that is
-- conditional on the source phase; these triggers make the irreversible rules hold in the database too. Additive only:
-- no table rebuild, no existing row is read or changed. They fire only on the transitions they forbid, so legacy rows
-- (ended before 0012 with a NULL end_reason) keep working.

-- Ended is final: once ended_at is set it and end_reason never change.
CREATE TRIGGER meeting_sessions_end_is_final BEFORE UPDATE OF ended_at, end_reason ON meeting_sessions
WHEN OLD.ended_at IS NOT NULL AND (NEW.ended_at IS NOT OLD.ended_at OR NEW.end_reason IS NOT OLD.end_reason)
BEGIN
  SELECT RAISE(ABORT, 'meeting_sessions: an ended meeting cannot be ended again or reopened');
END;

-- Ending records why and closes an open pause in the same statement (src/meetingPause.ts endMeetingSetSql).
CREATE TRIGGER meeting_sessions_end_is_complete BEFORE UPDATE OF ended_at ON meeting_sessions
WHEN OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL AND (NEW.end_reason IS NULL OR NEW.paused_at IS NOT NULL)
BEGIN
  SELECT RAISE(ABORT, 'meeting_sessions: ending a meeting must set end_reason and close its pause');
END;

-- Only a meeting that has not ended can be paused (deferred recordings are inserted ended).
CREATE TRIGGER meeting_sessions_pause_needs_open_meeting BEFORE UPDATE OF paused_at ON meeting_sessions
WHEN NEW.paused_at IS NOT NULL AND OLD.paused_at IS NULL AND (OLD.ended_at IS NOT NULL OR OLD.deferred = 1)
BEGIN
  SELECT RAISE(ABORT, 'meeting_sessions: an ended meeting cannot be paused');
END;

-- A settled Deepgram estimate takes no new grants (src/deepgram.ts incrementGrant).
CREATE TRIGGER deepgram_live_meetings_no_grant_after_settle BEFORE UPDATE OF grants ON deepgram_live_meetings
WHEN OLD.settled_at IS NOT NULL AND NEW.grants > OLD.grants
BEGIN
  SELECT RAISE(ABORT, 'deepgram_live_meetings: a settled meeting cannot take new grants');
END;
