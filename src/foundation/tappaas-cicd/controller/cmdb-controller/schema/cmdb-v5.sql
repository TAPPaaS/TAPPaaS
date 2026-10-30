-- cmdb schema version 5 — health as conditions (ADR-041 D1, D3).
--
-- A relation type says which end depends on the other and whether it needs it;
-- the metamodel load fills the columns. `conditions` replaces ADR-040 D11's
-- `health`: the open rows close, their history stays, and the next assess
-- writes the conditions.

ALTER TABLE relation_type ADD COLUMN IF NOT EXISTS dependant text;
ALTER TABLE relation_type ADD COLUMN IF NOT EXISTS required boolean NOT NULL DEFAULT false;

UPDATE attribute SET validity = tstzrange(lower(validity), GREATEST(lower(validity), now()))
 WHERE name = 'health' AND upper_inf(validity);

COMMENT ON TABLE object IS 'cmdb schema 5';
