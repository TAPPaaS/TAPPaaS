-- cmdb schema version 4 — the sweep record (ADR-040 D15).
--
-- A sweep is one change row, verb sweep: its time, its counts and its
-- differences, kept as the row's body.

ALTER TABLE change ADD COLUMN IF NOT EXISTS body jsonb;
CREATE INDEX IF NOT EXISTS change_by_verb ON change (verb, time);

COMMENT ON TABLE object IS 'cmdb schema 4';
