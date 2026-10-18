// relations.ts — the identity objects as a graph: organizations, groups, users
// and roles, and the references between them as identity-manager records
// them (a group's ownerOrg, a user's memberOf, a user's and a group's roles,
// an organization's owner and parentOrg). A reference to an object that does
// not exist becomes a node of its own, marked missing. Apart from React so the
// unit tests run it.

export type IdKind = "org" | "group" | "user" | "role";
export const ID_KINDS: IdKind[] = ["org", "group", "user", "role"];

export interface IdNode {
  id: string; // "<kind>:<name>"
  kind: IdKind;
  name: string;
  record: Record<string, unknown> | null; // null: referenced, but there is no such object
}

export interface IdEdge {
  source: string;
  target: string;
  label: string;
}

const list = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && x !== "") : typeof v === "string" && v !== "" ? [v] : []);

export function identityGraph(records: Partial<Record<IdKind, Record<string, unknown>[]>>): { nodes: IdNode[]; edges: IdEdge[] } {
  const nodes = new Map<string, IdNode>();
  for (const kind of ID_KINDS) {
    for (const r of records[kind] ?? []) {
      const name = typeof r.name === "string" ? r.name : "";
      if (name) nodes.set(`${kind}:${name}`, { id: `${kind}:${name}`, kind, name, record: r });
    }
  }
  const edges: IdEdge[] = [];
  const ref = (kind: IdKind, name: string): string => {
    const id = `${kind}:${name}`;
    if (!nodes.has(id)) nodes.set(id, { id, kind, name, record: null });
    return id;
  };
  // Drawn from the top down: organization → group → user → role.
  for (const n of [...nodes.values()]) {
    const r = n.record ?? {};
    if (n.kind === "org") {
      for (const u of list(r.owner)) edges.push({ source: n.id, target: ref("user", u), label: "owner" });
      for (const p of list(r.parentOrg)) edges.push({ source: ref("org", p), target: n.id, label: "parent of" });
    }
    if (n.kind === "group") {
      for (const o of list(r.ownerOrg)) edges.push({ source: ref("org", o), target: n.id, label: "owns" });
      for (const x of list(r.roles)) edges.push({ source: n.id, target: ref("role", x), label: "grants" });
    }
    if (n.kind === "user") {
      for (const g of list(r.memberOf)) edges.push({ source: ref("group", g), target: n.id, label: "member" });
      for (const x of list(r.roles)) edges.push({ source: n.id, target: ref("role", x), label: "has role" });
    }
  }
  return { nodes: [...nodes.values()], edges };
}
