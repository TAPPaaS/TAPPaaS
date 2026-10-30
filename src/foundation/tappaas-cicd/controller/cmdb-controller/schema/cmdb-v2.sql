-- cmdb schema version 2 — recorded facts (ADR-040 D7).
--
-- What no machine can see is recorded by an operator through asset-manager,
-- and reported marked recorded. The mark stays on the object and the relation:
-- a source that later sees the same thing does not make it less recorded.
-- Brings a v1 store to v2 at the service's start, in one transaction.

ALTER TABLE object ADD COLUMN IF NOT EXISTS recorded boolean NOT NULL DEFAULT false;
ALTER TABLE relation ADD COLUMN IF NOT EXISTS recorded boolean NOT NULL DEFAULT false;

COMMENT ON TABLE object IS 'cmdb schema 2';
