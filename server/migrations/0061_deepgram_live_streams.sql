-- Deepgram streams a meeting declared at its first grant (src/deepgram.ts `x-live-streams`): with the on-device live
-- preview a Mac meeting streams only "Sen" to Deepgram. The budget estimate charges and settles this many streams instead
-- of a fixed two. Older rows and older apps (no header) count two.
ALTER TABLE deepgram_live_meetings ADD COLUMN streams INTEGER NOT NULL DEFAULT 2;
