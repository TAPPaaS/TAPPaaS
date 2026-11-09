// nodecis.ts — the CIs `node delete` retires (ADR-040 D7): the node's own CI
// and what is known by it — its pools and the software on it, whose key is
// the node. The node's end retires them with it (cmdb-controller); this reads
// them from the CMDB first, so the preview can name them and the apply say
// what went. A CI is never reused: a node added again under this name is a
// new one. The asset is another lifecycle (nodeasset.ts).

import { CmdbUnavailable, cmdbRelations, cmdbRequest } from "../../../lib/ts/src/cmdb";

type Obj = Record<string, unknown>;

export interface NodeCi {
  class: string;
  name: string;
  id: string;
}

export interface NodeCis {
  answered: boolean; // false: the CMDB did not answer
  node: NodeCi | null; // the node's own CI, when the CMDB has it
  known: NodeCi[]; // what is known by it, retired with it
}

export interface CmdbReader {
  relationsTo: (cls: string, name: string) => Obj[]; // live relations to the object
  classKeys: (cls: string) => Obj; // GET /v1/classes/<cls>
}

const realReader: CmdbReader = {
  relationsTo: (cls, name) => cmdbRelations({ to: `${cls}/${name}` }),
  classKeys: (cls) => cmdbRequest("GET", `/v1/classes/${encodeURIComponent(cls)}`) as Obj,
};

/** Whether objects of a class are known by what they point at with `type`:
 *  a key component is a relation field of that type, outward. */
export function keyedBy(info: Obj, type: string): boolean {
  const fields = Array.isArray(info.fields) ? (info.fields as Obj[]) : [];
  const keys = Array.isArray(info.keys) ? (info.keys as Obj[]) : [];
  const components = new Set(keys.flatMap((k) => (Array.isArray(k.components) ? (k.components as string[]) : [])));
  return fields.some((f) => {
    const spec = (f.spec ?? {}) as Obj;
    return components.has(String(f.name)) && f.type === "relation" && spec.relation === type && spec.direction !== "in";
  });
}

/** The node's CI and the CIs retired with it, as the CMDB has them now. */
export function nodeCis(name: string, reader: CmdbReader = realReader): NodeCis {
  let rels: Obj[];
  try {
    rels = reader.relationsTo("machine", name);
  } catch (e) {
    // Refused (no live machine of that name): nothing to retire.
    return { answered: !(e instanceof CmdbUnavailable), node: null, known: [] };
  }
  const end = (x: unknown): NodeCi | null => {
    const o = (x ?? {}) as Obj;
    return typeof o.id === "string" && typeof o.class === "string" ? { id: o.id, class: o.class, name: String(o.name) } : null;
  };
  const cache = new Map<string, boolean>();
  const isKeyed = (cls: string, type: string): boolean => {
    const k = `${cls}|${type}`;
    if (!cache.has(k)) {
      let v = false;
      try {
        v = keyedBy(reader.classKeys(cls), type);
      } catch {
        v = false;
      }
      cache.set(k, v);
    }
    return cache.get(k)!;
  };
  let node: NodeCi | null = null;
  const known = new Map<string, NodeCi>();
  for (const r of rels) {
    const to = end(r.to);
    const from = end(r.from);
    if (to && to.class === "machine" && to.name === name) node = to;
    if (!from || !to || to.name !== name) continue;
    if (isKeyed(from.class, String(r.type))) known.set(from.id, from);
  }
  return { answered: true, node, known: [...known.values()].sort((a, b) => a.class.localeCompare(b.class) || a.name.localeCompare(b.name)) };
}

/** What node delete's change report ends: what is known by the node, by id
 *  (so no live pool of the same name on another node is touched), before
 *  the node (whose end would end them: an end by id of what has ended is
 *  refused). */
export function retireObjects(name: string, cis: NodeCis | null): { id?: string; class: string; name: string; end: true }[] {
  return [...(cis?.known ?? []).map((c) => ({ id: c.id, class: c.class, name: c.name, end: true as const })), { class: "machine", name, end: true as const }];
}

/** The CIs in the operator's words: "pools tanka1, rpool; app pve". */
export function ciWords(cis: NodeCi[]): string {
  const by = new Map<string, string[]>();
  for (const c of cis) by.set(c.class, [...(by.get(c.class) ?? []), c.name]);
  const word = (cls: string, n: number): string => (cls === "storage-pool" ? (n === 1 ? "pool" : "pools") : n === 1 ? cls : `${cls}s`);
  return [...by.entries()].map(([cls, names]) => `${word(cls, names.length)} ${names.join(", ")}`).join("; ");
}

/** What the preview (or the apply) says of the CIs. */
export function retireLine(name: string, r: NodeCis, apply: boolean): string {
  const lead = apply ? "retired in the CMDB" : "then: retired in the CMDB";
  if (!r.answered) return `${lead}: CI ${name}${apply ? "" : " and what runs on it"} (the CMDB did not answer${apply ? "; the change is spooled" : ""})`;
  const what = r.known.length ? ` with its ${ciWords(r.known)}` : "";
  if (!r.node) return `${lead}: nothing — the CMDB has no live CI ${name}`;
  return `${lead}: CI ${name}${what} — never reused, its history kept`;
}
