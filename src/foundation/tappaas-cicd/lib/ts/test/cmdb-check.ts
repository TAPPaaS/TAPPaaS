// cmdb-check.ts — test support: would cmdb-controller take this report? The
// checks its store makes before it writes anything (ADR-040 D3, D5), without
// a database: every class exists and is concrete, every attribute is a field
// of its class or an ancestor with a value of the field's type, every ref
// names an object earlier in the report (an attribute's) or in it (a
// relation's), every relation joins classes its type allows, and every
// object of a class with keys carries one of them whole.
//
// For the reporters' fast tests; the metamodel is cmdb-controller's own
// (controller/cmdb-controller/metamodel/), read here as its metamodel.ts
// reads it (that class brings the service's PostgreSQL client with it).

import { existsSync, readFileSync, readdirSync } from "fs";
import { dirname, join } from "path";
import { CmdbReport } from "../src/cmdb";

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);

interface Field {
  type: string;
  spec: Obj;
}

/** The metamodel as the store reads it: classes with their parents and
 *  fields (a subclass's partial redeclaration refines the inherited field),
 *  relation types with their ends. */
export class Model {
  parent = new Map<string, string | null>();
  abstract = new Set<string>();
  own = new Map<string, Record<string, Obj>>();
  ends = new Map<string, [string, string][]>();

  constructor(dir: string) {
    for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
      const doc = JSON.parse(readFileSync(join(dir, f), "utf8")) as Obj;
      for (const [name, c] of Object.entries((doc.classes ?? {}) as Record<string, Obj>)) {
        this.parent.set(name, typeof c.parent === "string" ? c.parent : null);
        if (c.abstract === true) this.abstract.add(name);
        this.own.set(name, (c.fields ?? {}) as Record<string, Obj>);
      }
      for (const [name, r] of Object.entries((doc.relations ?? {}) as Record<string, Obj>)) {
        this.ends.set(name, (r.ends ?? []) as [string, string][]);
      }
    }
  }
  has(c: string): boolean {
    return this.parent.has(c);
  }
  ancestors(c: string): string[] {
    const out: string[] = [];
    for (let x: string | null | undefined = c; x; x = this.parent.get(x)) out.push(x);
    return out;
  }
  isA(c: string, a: string): boolean {
    return this.ancestors(c).includes(a);
  }
  fields(c: string): Map<string, Field> {
    const out = new Map<string, Field>();
    for (const cls of this.ancestors(c).reverse()) {
      for (const [k, spec] of Object.entries(this.own.get(cls) ?? {})) {
        const merged = { ...(out.get(k)?.spec ?? {}), ...spec };
        out.set(k, { type: String(merged.type ?? "string"), spec: merged });
      }
    }
    return out;
  }
  /** Fields by key rank, lowest first. */
  keys(c: string): string[][] {
    const ranks = new Map<number, string[]>();
    for (const [k, f] of this.fields(c)) if (typeof f.spec.key === "number") ranks.set(f.spec.key, [...(ranks.get(f.spec.key) ?? []), k]);
    return [...ranks.entries()].sort(([a], [b]) => a - b).map(([, v]) => v);
  }
  allows(type: string, from: string, to: string): boolean {
    return (this.ends.get(type) ?? []).some(([a, b]) => this.isA(from, a) && this.isA(to, b));
  }
}

let cached: Model | null = null;

/** cmdb-controller's metamodel, found from here up (source or a dist tree). */
export function metamodel(): Model {
  if (cached) return cached;
  let d = __dirname;
  while (d !== dirname(d)) {
    const m = join(d, "controller", "cmdb-controller", "metamodel");
    if (existsSync(join(m, "ci.json"))) return (cached = new Model(m));
    d = dirname(d);
  }
  throw new Error("cmdb-check: controller/cmdb-controller/metamodel not found above " + __dirname);
}

function typeProblem(type: string, spec: Obj, v: unknown): string | null {
  const e = Array.isArray(spec.enum) ? spec.enum : null;
  switch (type) {
    case "string":
      return typeof v !== "string" ? "a string" : e && !e.includes(v) ? `one of ${e.join(", ")}` : null;
    case "integer":
      return Number.isInteger(v) ? null : "an integer";
    case "number":
      return typeof v === "number" ? null : "a number";
    case "boolean":
      return typeof v === "boolean" ? null : "true or false";
    case "array":
      return Array.isArray(v) ? null : "an array";
    case "object":
      return isObj(v) ? null : "an object";
    default:
      return null;
  }
}

/** What the store would refuse in this report; [] when it would take it. */
export function cmdbProblems(payload: unknown): string[] {
  const report = payload as CmdbReport;
  const mm = metamodel();
  const problems: string[] = [];
  const classOf = new Map<string, string>();
  const allRefs = new Map((report.objects ?? []).filter((o) => o.ref).map((o) => [o.ref as string, o.class]));
  const refClass = (v: unknown, at: string, earlier: boolean): string | null => {
    if (!isObj(v) || typeof v.ref !== "string") {
      problems.push(`${at}: a reference here is a ref to an object of the report (${JSON.stringify(v)})`);
      return null;
    }
    const c = (earlier ? classOf : allRefs).get(v.ref);
    if (!c) problems.push(`${at}: ref ${v.ref} is not an object ${earlier ? "earlier in" : "of"} the report`);
    return c ?? null;
  };
  (report.objects ?? []).forEach((o, i) => {
    const at = `objects[${i}] (${o.class} ${o.name})`;
    if (!mm.has(o.class)) return void problems.push(`${at}: no class ${o.class}`);
    if (mm.abstract.has(o.class)) problems.push(`${at}: ${o.class} is abstract`);
    const fields = mm.fields(o.class);
    const attrs = o.attributes ?? {};
    for (const [k, v] of Object.entries(attrs)) {
      const f = fields.get(k);
      if (!f) {
        problems.push(`${at}: ${o.class} has no field ${k}`);
        continue;
      }
      if (f.spec.derived === true) problems.push(`${at}: ${k} is derived, never reported`);
      if (v === null) continue;
      if (f.type === "relation") {
        const target = refClass(v, `${at}.${k}`, true);
        const rel = String(f.spec.relation);
        if (target && !(f.spec.direction === "in" ? mm.allows(rel, target, o.class) : mm.allows(rel, o.class, target))) {
          problems.push(`${at}.${k}: ${rel} does not join ${o.class} and ${target}`);
        }
        continue;
      }
      const want = typeProblem(f.type, f.spec, v);
      if (want) problems.push(`${at}.${k}: wants ${want}, is ${JSON.stringify(v)}`);
    }
    const keys = mm.keys(o.class);
    if (!o.end || keys.length) {
      const whole = keys.length === 0 || keys.some((k) => k.every((c) => c === "name" || (attrs as Obj)[c] !== undefined));
      if (!whole) problems.push(`${at}: no key: a ${o.class} is known by ${keys.map((k) => `(${k.join(", ")})`).join(" or ")}`);
    }
    if (o.ref) classOf.set(o.ref, o.class);
  });
  (report.relations ?? []).forEach((r, i) => {
    const at = `relations[${i}] (${r.type})`;
    if (!mm.ends.get(r.type)?.length) return void problems.push(`${at}: no relation type ${r.type}`);
    const from = refClass(r.from, `${at}.from`, false);
    const to = refClass(r.to, `${at}.to`, false);
    if (from && to && !mm.allows(r.type, from, to)) problems.push(`${at}: ${r.type} does not join ${from} to ${to}`);
  });
  return problems;
}
