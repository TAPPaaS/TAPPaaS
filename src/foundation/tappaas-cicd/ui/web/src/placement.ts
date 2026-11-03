// placement.ts — Rest of foundation's placement panel, without the DOM: what a
// row does, and how a row follows a changed machine. The rules (which pools a
// machine has, which HA machines a guest may use) come from the proposal
// (rest-of-foundation.sh --proposal); this only reads its choices.

export interface Place {
  node: string;
  ha: string; // "" for none
  storage: string;
}

export interface PlacementRow {
  module: string;
  kind: "guest" | "backup";
  installed: boolean;
  current: Place | null;
  proposal: Place;
  choices: Record<string, { ha: string[]; pools: Record<string, string[]> }>;
  note: string | null;
}

export interface PlacementNode {
  name: string;
  memoryGiB: number;
  pools: { name: string; sizeGiB: number; freeGiB: number; boot: boolean }[];
}

export interface Placement {
  nodes: PlacementNode[];
  rows: PlacementRow[];
}

export type Action = "install" | "move" | "stays" | "installed" | "placeholder";

export function rowAction(r: PlacementRow, p: Place): Action {
  if (r.kind === "backup" && !p.node) return r.installed ? "installed" : "placeholder";
  if (!r.installed) return "install";
  if (r.kind === "backup" || !r.current) return "installed";
  return r.current.node !== p.node || r.current.storage !== p.storage || r.current.ha !== p.ha ? "move" : "stays";
}

export const ACTION_LABEL: Record<Action, string> = { install: "Install", move: "Move", stays: "Stays", installed: "Installed", placeholder: "Placeholder" };

// A row after its machine or HA machine changed: an HA machine the new machine
// cannot pair with goes, and a pool the pair lacks becomes the first they share.
// `changed` says what moved, for the line under the row.
export function follow(r: PlacementRow, p: Place): { place: Place; changed: string[] } {
  const c = r.choices[p.node];
  if (!c) return { place: p, changed: [] };
  const changed: string[] = [];
  let ha = p.ha;
  if (ha && !c.ha.includes(ha)) {
    changed.push(`no HA machine: ${ha} cannot be one for ${p.node}`);
    ha = "";
  }
  const pools = c.pools[ha] ?? [];
  let storage = p.storage;
  if (!pools.includes(storage)) {
    const next = pools[0] ?? "";
    changed.push(next ? `pool ${next}: ${storage || "none"} is not on ${ha ? `${p.node} and ${ha}` : p.node}` : `no pool on ${ha ? `${p.node} and ${ha}` : p.node}`);
    storage = next;
  }
  return { place: { node: p.node, ha, storage }, changed };
}

// Why the row cannot be applied, or null.
export function rowProblem(r: PlacementRow, p: Place): string | null {
  if (r.kind === "backup" && !p.node) return null; // a placeholder
  const c = r.choices[p.node];
  if (!c) return `${r.module}: ${p.node || "no machine"} cannot hold it`;
  if (p.ha && !c.ha.includes(p.ha)) return `${r.module}: ${p.ha} cannot be its HA machine`;
  if (!(c.pools[p.ha] ?? []).includes(p.storage)) return `${r.module}: choose a pool`;
  return null;
}

// What the job gets: a place for every row that has one.
export function placeArgs(rows: PlacementRow[], places: Record<string, Place>): { module: string; node: string; ha: string; storage: string }[] {
  return rows.filter((r) => !(r.kind === "backup" && !places[r.module]?.node)).map((r) => ({ module: r.module, ...places[r.module] }));
}
