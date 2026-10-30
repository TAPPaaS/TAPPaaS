// metamodel.ts — the class tree, the fields and the relation types of ADR-040
// D3, read from metamodel/*.json and written into the metamodel tables at
// every start (D13: the metamodel is data). The controller checks every
// report against the same declarations it writes there.
//
// Inheritance: a class has every field of its ancestors; a field a subclass
// declares again with only some properties refines the inherited one (vm
// makes name a key of rank 2), and may not change its type. physical is
// inherited too.

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { Query } from "./pg";
import { HealthRule, checkHealthRules } from "../../../lib/ts/src/health-rules";

export const FIELD_TYPES = ["string", "integer", "number", "boolean", "array", "object", "relation"] as const;
export type FieldType = (typeof FIELD_TYPES)[number];
export type Cardinality = "1:1" | "n:1" | "1:n" | "n:m";
export type Dependant = "from" | "to" | "both";

export interface FieldDef {
  class: string; // the class that declares (or refines) it
  name: string;
  type: FieldType;
  required: boolean;
  immutable: boolean;
  key: number | null; // the rank of the identity key it is part of (D5)
  identifying: boolean; // names the CI in telemetry (D14)
  volatile: boolean; // changes by itself: history, but never drift (D6)
  description: string;
  // The rest of the declaration: enum, values, items, properties, relation,
  // direction, otel, allowedBy, derived.
  spec: Record<string, unknown>;
}

export interface ClassDef {
  name: string;
  parent: string | null;
  abstract: boolean;
  physical: boolean; // effective: declared here or on an ancestor
  description: string;
  declared: Record<string, Partial<FieldDef> & { spec?: Record<string, unknown> }>;
  expiry: string | null; // as declared ("7d"); inherited, see expirySeconds()
  desiredRecord: boolean; // a config/ record can declare it; inherited, see hasDesiredRecord()
  keyVia: KeyVia[]; // as declared; inherited, see keyVia()
}

/** A key that is a field of a related object: an asset is known by any of
 *  its ports' MACs (D5). The related object stands in `relation` to it. */
export interface KeyVia {
  rank: number;
  class: string; // the related object's class (port)
  relation: string; // its relation to the keyed object (part-of)
  field: string; // its field that is the key (mac)
  description?: string;
}

export interface RelationEnd {
  name: string;
  parent: string | null;
  from: string;
  to: string;
  cardinality: Cardinality;
  description: string;
  dependant: Dependant | null; // the end hurt when the other fails (ADR-041 D3); null: carries no health
  required: boolean; // a dependant needs the provider; a relation row may say otherwise
}

export interface Key {
  rank: number;
  components: string[]; // field names; "name" is object.name
}

type Obj = Record<string, unknown>;

const CORE_KEYS = new Set(["type", "required", "immutable", "key", "identifying", "volatile", "description"]);

export const DEFAULT_EXPIRY_SECONDS = 7 * 24 * 3600;

/** "7d", "12h", "30m", "90s" → seconds; null when it is none of those. */
export function parseDuration(s: string): number | null {
  const m = /^(\d+)\s*([smhd])$/.exec(s.trim());
  if (!m) return null;
  return Number(m[1]) * { s: 1, m: 60, h: 3600, d: 86400 }[m[2] as "s" | "m" | "h" | "d"];
}

function isObj(v: unknown): v is Obj {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

export class Metamodel {
  readonly classes = new Map<string, ClassDef>();
  readonly relations: RelationEnd[] = [];
  readonly rules: HealthRule[] = []; // the correlation rules (ADR-041 D3), checked at load
  private fieldCache = new Map<string, Map<string, FieldDef>>();

  // ── reading the files ────────────────────────────────────────────────

  static fromDir(dir: string): Metamodel {
    if (!existsSync(dir)) throw new Error(`no metamodel directory at ${dir}`);
    const mm = new Metamodel();
    const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
    const ruleDocs: [string, Obj][] = [];
    for (const f of files) {
      let doc: unknown;
      try {
        doc = JSON.parse(readFileSync(join(dir, f), "utf8"));
      } catch (e) {
        throw new Error(`metamodel/${f}: ${e instanceof Error ? e.message : String(e)}`);
      }
      if (!isObj(doc)) throw new Error(`metamodel/${f}: expected a JSON object`);
      if (isObj(doc.classes)) mm.addClasses(f, doc.classes);
      if (isObj(doc.relations)) mm.addRelations(f, doc.relations);
      if (Array.isArray(doc.rules)) {
        ruleDocs.push([f, doc]);
        mm.rules.push(...(doc.rules as HealthRule[]));
      }
    }
    mm.check();
    const model = {
      relations: [...new Set(mm.relations.map((r) => r.name))],
      dependants: [...new Set(mm.relations.filter((r) => r.dependant).map((r) => r.name))],
      classes: [...mm.classes.keys()],
    };
    for (const [f, doc] of ruleDocs) {
      const wrong = checkHealthRules(doc, model);
      if (wrong.length) throw new Error(`metamodel/${f}: ${wrong.join("; ")}`);
    }
    return mm;
  }

  private addClasses(file: string, classes: Obj): void {
    for (const [name, raw] of Object.entries(classes)) {
      if (!isObj(raw)) throw new Error(`metamodel/${file}: class ${name} is not an object`);
      if (this.classes.has(name)) throw new Error(`metamodel/${file}: class ${name} is declared twice`);
      const declared: ClassDef["declared"] = {};
      for (const [fname, fraw] of Object.entries(isObj(raw.fields) ? raw.fields : {})) {
        if (!isObj(fraw)) throw new Error(`metamodel/${file}: ${name}.${fname} is not an object`);
        const spec: Obj = {};
        for (const [k, v] of Object.entries(fraw)) if (!CORE_KEYS.has(k)) spec[k] = v;
        const d: Partial<FieldDef> & { spec?: Obj } = { spec };
        if (fraw.type !== undefined) d.type = fraw.type as FieldType;
        if (fraw.required !== undefined) d.required = fraw.required === true;
        if (fraw.immutable !== undefined) d.immutable = fraw.immutable === true;
        if (fraw.key !== undefined) d.key = typeof fraw.key === "number" ? fraw.key : null;
        if (fraw.identifying !== undefined) d.identifying = fraw.identifying === true;
        if (fraw.volatile !== undefined) d.volatile = fraw.volatile === true;
        if (fraw.description !== undefined) d.description = String(fraw.description);
        declared[fname] = d;
      }
      this.classes.set(name, {
        name,
        parent: typeof raw.parent === "string" ? raw.parent : null,
        abstract: raw.abstract === true,
        physical: raw.physical === true,
        description: typeof raw.description === "string" ? raw.description : "",
        declared,
        expiry: typeof raw.expiry === "string" ? raw.expiry : null,
        desiredRecord: raw.desiredRecord === true,
        keyVia: Array.isArray(raw.keyVia)
          ? raw.keyVia.filter(isObj).map((k) => ({
              rank: Number(k.rank),
              class: String(k.class),
              relation: String(k.relation),
              field: String(k.field),
              description: typeof k.description === "string" ? k.description : undefined,
            }))
          : [],
      });
    }
  }

  private addRelations(file: string, relations: Obj): void {
    for (const [name, raw] of Object.entries(relations)) {
      if (!isObj(raw) || !Array.isArray(raw.ends)) throw new Error(`metamodel/${file}: relation ${name} needs ends`);
      const card = String(raw.cardinality ?? "n:m") as Cardinality;
      if (!["1:1", "n:1", "1:n", "n:m"].includes(card)) throw new Error(`metamodel/${file}: relation ${name}: cardinality ${card}`);
      const dependant = raw.dependant === undefined ? null : (String(raw.dependant) as Dependant);
      if (dependant !== null && !["from", "to", "both"].includes(dependant)) throw new Error(`metamodel/${file}: relation ${name}: dependant ${dependant}`);
      for (const end of raw.ends) {
        if (!Array.isArray(end) || end.length !== 2) throw new Error(`metamodel/${file}: relation ${name}: an end is [from, to]`);
        this.relations.push({
          name,
          parent: typeof raw.parent === "string" ? raw.parent : null,
          from: String(end[0]),
          to: String(end[1]),
          cardinality: card,
          description: typeof raw.description === "string" ? raw.description : "",
          dependant,
          required: raw.required === true,
        });
      }
    }
  }

  // The tree has one root, object; no cycles; every field resolves to a type;
  // a relation field names a relation type; every end names a class.
  private check(): void {
    const roots = [...this.classes.values()].filter((c) => c.parent === null);
    if (roots.length !== 1 || roots[0].name !== "object") {
      throw new Error(`the class tree must have one root, object (has: ${roots.map((c) => c.name).join(", ") || "none"})`);
    }
    for (const c of this.classes.values()) {
      if (c.parent !== null && !this.classes.has(c.parent)) throw new Error(`class ${c.name}: parent ${c.parent} is not a class`);
      const seen = new Set<string>();
      for (let p: string | null = c.name; p !== null; p = this.classes.get(p)!.parent) {
        if (seen.has(p)) throw new Error(`class ${c.name}: its parents form a cycle`);
        seen.add(p);
      }
    }
    for (const c of this.classes.values()) {
      c.physical = this.ancestors(c.name).some((a) => this.classes.get(a)!.physical);
      for (const [fname, f] of this.fields(c.name)) {
        if (!FIELD_TYPES.includes(f.type)) throw new Error(`${c.name}.${fname}: type ${String(f.type)} is not one of ${FIELD_TYPES.join(", ")}`);
        if (f.type === "relation" && !this.relations.some((r) => r.name === f.spec.relation)) {
          throw new Error(`${c.name}.${fname}: relation ${String(f.spec.relation)} is not a relation type`);
        }
      }
    }
    for (const r of this.relations) {
      for (const end of [r.from, r.to]) if (!this.classes.has(end)) throw new Error(`relation ${r.name}: ${end} is not a class`);
    }
    for (const c of this.classes.values()) {
      if (c.expiry !== null && parseDuration(c.expiry) === null) throw new Error(`class ${c.name}: expiry ${c.expiry} is not a duration (7d, 12h, 30m, 90s)`);
      for (const k of c.keyVia) {
        if (!Number.isFinite(k.rank)) throw new Error(`class ${c.name}: a keyVia needs a rank`);
        if (!this.classes.has(k.class)) throw new Error(`class ${c.name}: keyVia class ${k.class} is not a class`);
        if (!this.allows(k.relation, k.class, c.name)) throw new Error(`class ${c.name}: ${k.relation} does not join ${k.class} to it`);
        if (!this.fields(k.class).has(k.field)) throw new Error(`class ${c.name}: ${k.class} has no field ${k.field}`);
      }
    }
  }

  /** How long a CI may go unreported before it is unseen (D5): the nearest
   *  declared expiry, else 7 days. Only CIs expire; null for the rest. */
  expirySeconds(name: string): number | null {
    if (!this.isA(name, "ci")) return null;
    for (const a of this.ancestors(name)) {
      const e = this.classes.get(a)!.expiry;
      if (e !== null) return parseDuration(e);
    }
    return DEFAULT_EXPIRY_SECONDS;
  }

  /** Can a config/ record declare this class? What a sweep calls unmanaged
   *  when it has none (D15). A lease or a service never has one of its own. */
  hasDesiredRecord(name: string): boolean {
    return this.ancestors(name).some((a) => this.classes.get(a)!.desiredRecord);
  }

  /** The keys of a class that are fields of related objects, own and inherited. */
  keyVia(name: string): KeyVia[] {
    return this.ancestors(name).flatMap((a) => this.classes.get(a)!.keyVia);
  }

  // ── the tree ─────────────────────────────────────────────────────────

  has(name: string): boolean {
    return this.classes.has(name);
  }

  /** The class and its ancestors, the class first. */
  ancestors(name: string): string[] {
    const out: string[] = [];
    for (let p: string | null = name; p !== null && this.classes.has(p); p = this.classes.get(p)!.parent) out.push(p);
    return out;
  }

  isA(name: string, ancestor: string): boolean {
    return this.ancestors(name).includes(ancestor);
  }

  /** The class and every class under it. */
  descendants(name: string): string[] {
    return [...this.classes.keys()].filter((c) => this.isA(c, name));
  }

  /** Every field a class has, its own and inherited, refinements applied. */
  fields(name: string): Map<string, FieldDef> {
    const cached = this.fieldCache.get(name);
    if (cached) return cached;
    const out = new Map<string, FieldDef>();
    for (const cls of this.ancestors(name).reverse()) {
      for (const [fname, d] of Object.entries(this.classes.get(cls)!.declared)) {
        const base = out.get(fname);
        if (base && d.type !== undefined && d.type !== base.type) {
          throw new Error(`${cls}.${fname}: a refinement may not change the type (${base.type} → ${d.type})`);
        }
        out.set(fname, {
          class: cls,
          name: fname,
          type: (d.type ?? base?.type ?? "string") as FieldType,
          required: d.required ?? base?.required ?? false,
          immutable: d.immutable ?? base?.immutable ?? false,
          key: d.key !== undefined ? d.key : base?.key ?? null,
          identifying: d.identifying ?? base?.identifying ?? false,
          volatile: d.volatile ?? base?.volatile ?? false,
          description: d.description ?? base?.description ?? "",
          spec: { ...(base?.spec ?? {}), ...(d.spec ?? {}) },
        });
      }
    }
    this.fieldCache.set(name, out);
    return out;
  }

  /** The identity keys of a class, strongest (lowest rank) first (D5). A
   *  class that declares none is known by its name within its class. */
  keys(name: string): Key[] {
    const ranks = new Map<number, string[]>();
    for (const f of this.fields(name).values()) {
      if (f.key === null) continue;
      ranks.set(f.key, [...(ranks.get(f.key) ?? []), f.name]);
    }
    return [...ranks.entries()].sort((a, b) => a[0] - b[0]).map(([rank, components]) => ({ rank, components: components.sort() }));
  }

  /** Where a class's keys are unique: its nearest abstract ancestor — a vm's
   *  VMID among every node, an asset's serial among every asset. A class
   *  with no keys of its own is matched within itself. */
  keyScope(name: string): string {
    if (this.keys(name).length === 0) return name;
    return this.ancestors(name).find((a) => this.classes.get(a)!.abstract) ?? name;
  }

  /** The classes an object of class `name` may be matched with by `key`:
   *  in its scope, concrete, holding the same key. */
  keyClasses(name: string, key: Key): string[] {
    if (this.keys(name).length === 0) return [name];
    const sig = key.components.join(",");
    return this.descendants(this.keyScope(name)).filter(
      (c) => !this.classes.get(c)!.abstract && this.keys(c).some((k) => k.components.join(",") === sig),
    );
  }

  /** The classes an object of class `name` may be matched with by a keyVia. */
  keyViaClasses(name: string, kv: KeyVia): string[] {
    const sig = `${kv.class}|${kv.relation}|${kv.field}`;
    return this.descendants(this.keyScope(name)).filter(
      (c) => !this.classes.get(c)!.abstract && this.keyVia(c).some((k) => `${k.class}|${k.relation}|${k.field}` === sig),
    );
  }

  // ── relations ────────────────────────────────────────────────────────

  relationEnds(type: string): RelationEnd[] {
    return this.relations.filter((r) => r.name === type);
  }

  /** May an object of class `from` stand in `type` to one of class `to`? */
  allows(type: string, from: string, to: string): RelationEnd | null {
    return this.relationEnds(type).find((r) => this.isA(from, r.from) && this.isA(to, r.to)) ?? null;
  }

  /** The classes a relation field's target may be. */
  targetClasses(type: string, cls: string, direction: "out" | "in"): string[] {
    const ends = this.relationEnds(type).filter((r) => this.isA(cls, direction === "out" ? r.from : r.to));
    return [...new Set(ends.flatMap((r) => this.descendants(direction === "out" ? r.to : r.from)))];
  }

  // ── into the tables ──────────────────────────────────────────────────

  /** Rewrite the metamodel tables from this model, in the caller's
   *  transaction. A class that has objects is never removed: the load fails
   *  and names it. */
  async store(q: Query): Promise<void> {
    const classes = [...this.classes.values()].map((c) => ({
      name: c.name,
      parent: c.parent,
      abstract: c.abstract,
      physical: c.physical,
      description: c.description,
    }));
    const gone = await q(
      `SELECT c.name, count(o.id) AS n FROM class c LEFT JOIN object o ON o.class = c.name
        WHERE c.name NOT IN (SELECT x.name FROM jsonb_to_recordset($1::jsonb) AS x(name text))
        GROUP BY c.name`,
      [classes],
    );
    const used = gone.rows.filter((r) => Number(r.n) > 0).map((r) => String(r.name));
    if (used.length) throw new Error(`the metamodel drops classes that have objects: ${used.join(", ")}`);
    await q("DELETE FROM class_ancestor");
    await q("DELETE FROM attribute_def");
    await q("DELETE FROM relation_type");
    await q(
      `INSERT INTO class (name, parent, abstract, physical, description)
       SELECT x.name, x.parent, x.abstract, x.physical, x.description
         FROM jsonb_to_recordset($1::jsonb) AS x(name text, parent text, abstract boolean, physical boolean, description text)
       ON CONFLICT (name) DO UPDATE SET parent = EXCLUDED.parent, abstract = EXCLUDED.abstract,
         physical = EXCLUDED.physical, description = EXCLUDED.description`,
      [classes],
    );
    await q(
      `DELETE FROM class WHERE name NOT IN (SELECT x.name FROM jsonb_to_recordset($1::jsonb) AS x(name text))`,
      [classes],
    );
    const closure = [...this.classes.keys()].flatMap((c) =>
      this.ancestors(c).map((a, depth) => ({ class: c, ancestor: a, depth })),
    );
    await q(
      `INSERT INTO class_ancestor (class, ancestor, depth)
       SELECT x.class, x.ancestor, x.depth FROM jsonb_to_recordset($1::jsonb) AS x(class text, ancestor text, depth integer)`,
      [closure],
    );
    // One row per field a class declares, with the refinement resolved: the
    // row says what the field is at that class.
    const defs = [...this.classes.values()].flatMap((c) =>
      Object.keys(c.declared).map((fname) => {
        const f = this.fields(c.name).get(fname)!;
        return {
          class: c.name,
          name: fname,
          type: f.type,
          required: f.required,
          immutable: f.immutable,
          key: f.key,
          identifying: f.identifying,
          volatile: f.volatile,
          description: f.description,
          spec: f.spec,
        };
      }),
    );
    await q(
      `INSERT INTO attribute_def (class, name, type, required, immutable, key, identifying, volatile, description, spec)
       SELECT x.class, x.name, x.type, x.required, x.immutable, x.key, x.identifying, x.volatile, x.description, x.spec
         FROM jsonb_to_recordset($1::jsonb) AS x(class text, name text, type text, required boolean, immutable boolean,
              key smallint, identifying boolean, volatile boolean, description text, spec jsonb)`,
      [defs],
    );
    await q(
      `INSERT INTO relation_type (name, parent, from_class, to_class, cardinality, description, dependant, required)
       SELECT x.name, x.parent, x."from", x."to", x.cardinality, x.description, x.dependant, x.required
         FROM jsonb_to_recordset($1::jsonb) AS x(name text, parent text, "from" text, "to" text, cardinality text, description text, dependant text, required boolean)`,
      [this.relations],
    );
  }
}
