-- cmdb schema version 3 — volatile attributes (ADR-040 D6).
--
-- A value that changes by itself (a pool's used, a lease) has history like any
-- other, and never counts as drift. Brings a v2 store to v3 at the service's
-- start; the metamodel load fills the column.

ALTER TABLE attribute_def ADD COLUMN IF NOT EXISTS volatile boolean NOT NULL DEFAULT false;

COMMENT ON TABLE object IS 'cmdb schema 3';
