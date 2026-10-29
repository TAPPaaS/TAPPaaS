-- cmdb schema version 1 — the eight tables of ADR-040 D13.
--
-- Applied by cmdb-controller at every start, in one transaction; every
-- statement is idempotent. The version is kept as the comment on table
-- object ('cmdb schema 1'): a controller older than the store refuses to
-- start. A change to these tables is an ADR-025 migration and a new file
-- (cmdb-v2.sql) that brings a v1 store to v2, never an edit of this one.
--
-- The metamodel (class, class_ancestor, attribute_def, relation_type) is
-- data, rewritten from metamodel/*.json at every start; the store (object,
-- attribute, relation, change) is never deleted from. Validity is a tstzrange:
-- the current row is the one whose range is open at the upper end, the row
-- on a date the one whose range contains it.

-- gist on uuid/text equality, for the exclusion constraints. A trusted
-- extension: the database owner may create it (cmdb-db.service does, as postgres).
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ── the metamodel ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS class (
    name        text PRIMARY KEY,
    parent      text REFERENCES class (name) DEFERRABLE INITIALLY DEFERRED,
    abstract    boolean NOT NULL DEFAULT false,
    physical    boolean NOT NULL DEFAULT false,  -- inherited: true when the class or an ancestor declares it
    description text NOT NULL DEFAULT ''
);

-- The transitive closure, rebuilt when the metamodel loads: every class is
-- its own ancestor at depth 0. "Every asset" is a join on ancestor = 'asset'.
CREATE TABLE IF NOT EXISTS class_ancestor (
    class    text NOT NULL REFERENCES class (name) DEFERRABLE INITIALLY DEFERRED,
    ancestor text NOT NULL REFERENCES class (name) DEFERRABLE INITIALLY DEFERRED,
    depth    integer NOT NULL,
    PRIMARY KEY (class, ancestor)
);
CREATE INDEX IF NOT EXISTS class_ancestor_by_ancestor ON class_ancestor (ancestor);

-- A field declared as ADR-020's fields.json declares one. key: the rank of
-- the identity key the field is part of (D5), null when none. spec: the rest
-- of the declaration (enum, items, properties, relation, direction, otel,
-- allowedBy, derived) as the metamodel file has it.
CREATE TABLE IF NOT EXISTS attribute_def (
    class       text NOT NULL REFERENCES class (name) DEFERRABLE INITIALLY DEFERRED,
    name        text NOT NULL,
    type        text NOT NULL CHECK (type IN ('string', 'integer', 'number', 'boolean', 'array', 'object', 'relation')),
    required    boolean NOT NULL DEFAULT false,
    immutable   boolean NOT NULL DEFAULT false,
    key         smallint,
    identifying boolean NOT NULL DEFAULT false,
    description text NOT NULL DEFAULT '',
    spec        jsonb NOT NULL DEFAULT '{}',
    PRIMARY KEY (class, name)
);

-- One row per pair of classes a relation may join; a subclass of either end
-- may stand in it.
CREATE TABLE IF NOT EXISTS relation_type (
    name        text NOT NULL,
    parent      text,
    from_class  text NOT NULL REFERENCES class (name) DEFERRABLE INITIALLY DEFERRED,
    to_class    text NOT NULL REFERENCES class (name) DEFERRABLE INITIALLY DEFERRED,
    cardinality text NOT NULL CHECK (cardinality IN ('1:1', 'n:1', '1:n', 'n:m')),
    description text NOT NULL DEFAULT '',
    PRIMARY KEY (name, from_class, to_class)
);

-- ── the store ────────────────────────────────────────────────────────────

-- Every report that wrote something: an observation (a manager looked) or a
-- change (a verb changed it: job, verb, actor). The rows it wrote name it.
CREATE TABLE IF NOT EXISTS change (
    id        bigserial PRIMARY KEY,
    kind      text NOT NULL CHECK (kind IN ('observation', 'change')),
    source    text NOT NULL,
    job       text,
    verb      text,
    actor     text,
    time      timestamptz NOT NULL,
    objects   uuid[] NOT NULL DEFAULT '{}',
    relations bigint[] NOT NULL DEFAULT '{}',
    drift     boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS change_by_time ON change (time);
CREATE INDEX IF NOT EXISTS change_by_objects ON change USING gin (objects);

-- The core every object has. ended: retired (a CI) or disposed (an asset) —
-- the row stays, with its history, and no longer takes part in key matching
-- (D5, D7). seen: the last time each source reported it.
CREATE TABLE IF NOT EXISTS object (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    class        text NOT NULL REFERENCES class (name),
    name         text NOT NULL,
    display_name text,
    created      timestamptz NOT NULL,
    ended        timestamptz,
    last_seen    timestamptz,
    seen         jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS object_by_class ON object (class);
CREATE INDEX IF NOT EXISTS object_by_name ON object (name);

-- One row per value per period. No two periods of one object's attribute
-- overlap: the exclusion constraint is the history's invariant.
CREATE TABLE IF NOT EXISTS attribute (
    id       bigserial PRIMARY KEY,
    object   uuid NOT NULL REFERENCES object (id),
    name     text NOT NULL,
    value    jsonb NOT NULL,
    source   text NOT NULL,
    change   bigint REFERENCES change (id),
    validity tstzrange NOT NULL,
    CONSTRAINT attribute_no_overlap EXCLUDE USING gist (object WITH =, name WITH =, validity WITH &&)
);
CREATE INDEX IF NOT EXISTS attribute_by_name ON attribute (name);
CREATE INDEX IF NOT EXISTS attribute_by_value ON attribute USING gin (value jsonb_path_ops);
CREATE INDEX IF NOT EXISTS attribute_current ON attribute (object, name) WHERE upper_inf(validity);

CREATE TABLE IF NOT EXISTS relation (
    id          bigserial PRIMARY KEY,
    type        text NOT NULL,
    from_object uuid NOT NULL REFERENCES object (id),
    to_object   uuid NOT NULL REFERENCES object (id),
    attributes  jsonb NOT NULL DEFAULT '{}',
    source      text NOT NULL,
    change      bigint REFERENCES change (id),
    validity    tstzrange NOT NULL,
    CONSTRAINT relation_no_overlap EXCLUDE USING gist (type WITH =, from_object WITH =, to_object WITH =, validity WITH &&)
);
CREATE INDEX IF NOT EXISTS relation_by_from ON relation (from_object);
CREATE INDEX IF NOT EXISTS relation_by_to ON relation (to_object);

COMMENT ON TABLE object IS 'cmdb schema 1';
