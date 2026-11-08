-- Paused time is excluded from a meeting's time limit and from monthly usage (src/meetingPause.ts). Additive only: new
-- columns with defaults on meeting_sessions; existing rows read as never paused.

-- Credited time of the meeting's closed pauses (ms, server clock).
ALTER TABLE meeting_sessions ADD COLUMN paused_ms INTEGER NOT NULL DEFAULT 0;
-- Start of the open pause (ms, server clock); NULL while recording.
ALTER TABLE meeting_sessions ADD COLUMN paused_at INTEGER;
-- How far max_ends_at lies beyond the meeting's base end (ms); equals paused_ms whenever no pause is open.
ALTER TABLE meeting_sessions ADD COLUMN pause_extension_ms INTEGER NOT NULL DEFAULT 0;
-- Pauses so far (capped per meeting).
ALTER TABLE meeting_sessions ADD COLUMN pause_count INTEGER NOT NULL DEFAULT 0;
