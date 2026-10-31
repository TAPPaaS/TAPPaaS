// cipanel.ts — a CI's panel (ADR-040 D10): its attributes with their source and
// since, its relations both ways, its history, its drift, its open events (the
// conditions that are not ok, D11) and its trace up the backbone (D1): the
// objects it runs on or is part of, then the desired record, the release and
// the module of the nearest one that has them, the module's open issues and
// the ADRs its design names. Pure: cmdb.ts and reads.ts read, this shapes.

import { CmdbEnd, CmdbHistory, CmdbShow } from "./cmdb";
import { Acknowledged, Status, conditionsOf, holds } from "./health";

type Obj = Record<string, unknown>;

const RANK: Record<Status, number> = { ok: 0, unknown: 1, warning: 2, critical: 3 };

export interface CiAttribute {
  name: string;
  value: unknown;
  source: string;
  since: string;
}

export interface CiRelation {
  id: string;
  type: string;
  direction: "in" | "out";
  other: CmdbEnd;
  source: string | null;
  since: string | null;
}

export interface CiEvent {
  type: string;
  status: Status;
  reason: string | null;
  message: string | null;
  since: string | null;
  source: string | null;
  derived: boolean;
  acknowledged: boolean;
  maintenance: boolean;
}

export interface CiRecord {
  id: string;
  class: string;
  ancestors: string[];
  name: string;
  label: string;
  attributes: CiAttribute[]; // conditions and drift have sections of their own
  relations: CiRelation[];
  drift: unknown;
  events: CiEvent[];
}

// The attributes shown as their own sections, not as rows.
const OWN_SECTION = new Set(["conditions", "drift"]);

// A condition that is not ok is an open event; the worst first, then the newest.
export function openEvents(attributes: Obj, now: number): CiEvent[] {
  return conditionsOf(attributes)
    .filter((c) => c.status !== "ok")
    .map((c) => ({
      type: c.type,
      status: c.status,
      reason: c.reason ?? null,
      message: c.message ?? null,
      since: c.since ?? null,
      source: c.source ?? null,
      derived: c.derived === true,
      acknowledged: !!c.acknowledged && holds((c.acknowledged as Acknowledged).until, now),
      maintenance: !!c.maintenance && holds(c.maintenance.until, now),
    }))
    .sort((a, b) => RANK[b.status] - RANK[a.status] || Date.parse(b.since ?? "") - Date.parse(a.since ?? "") || a.type.localeCompare(b.type));
}

export function ciRecord(show: CmdbShow, now: number): CiRecord {
  const values: Obj = Object.fromEntries(Object.entries(show.attributes).map(([k, a]) => [k, a.value]));
  return {
    id: show.id,
    class: show.class,
    ancestors: show.ancestors ?? [],
    name: show.name,
    label: show.displayName || show.name,
    attributes: Object.entries(show.attributes)
      .filter(([k]) => !OWN_SECTION.has(k))
      .map(([name, a]) => ({ name, value: a.value, source: a.source, since: a.since }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    relations: show.relations
      .map((r) => ({ id: String(r.id), type: r.type, direction: r.direction, other: r.other, source: r.source ?? null, since: r.since ?? null }))
      .sort((a, b) => Number(a.direction === "in") - Number(b.direction === "in") || a.type.localeCompare(b.type) || a.other.name.localeCompare(b.other.name)),
    drift: show.drift ?? null,
    events: openEvents(values, now),
  };
}

// ── history ───────────────────────────────────────────────────────────

export interface CiHistoryRow {
  at: string;
  what: "attribute" | "relation" | "change";
  name: string; // the attribute, the relation type, the verb or the change's kind
  value: unknown; // an attribute's value; a relation's far end
  source: string | null;
  until: string | null; // when the period ended; null while it holds
  detail: string | null; // a relation's direction; a change's actor and job
  drift: boolean;
}

// Every period that opened and every change that touched the object, the
// newest first; at one moment the change before what it wrote.
export function ciHistory(h: CmdbHistory, limit = 300): CiHistoryRow[] {
  const ORDER = { change: 0, attribute: 1, relation: 2 } as const;
  const rows: CiHistoryRow[] = [
    ...h.attributes.map((a): CiHistoryRow => ({ at: a.from, what: "attribute", name: a.name, value: a.value, source: a.source, until: a.to, detail: null, drift: a.name === "drift" })),
    ...(h.relations ?? []).map((r): CiHistoryRow => ({ at: r.from, what: "relation", name: r.type, value: r.other, source: r.source ?? null, until: r.to, detail: r.direction, drift: false })),
    ...h.changes.map((c): CiHistoryRow => ({
      at: c.time,
      what: "change",
      name: c.verb ?? c.kind,
      value: null,
      source: c.source,
      until: null,
      detail: [c.actor, c.job ? `job ${c.job}` : null].filter(Boolean).join(" · ") || null,
      drift: c.drift === true,
    })),
  ];
  return rows.sort((a, b) => Date.parse(b.at) - Date.parse(a.at) || ORDER[a.what] - ORDER[b.what] || a.name.localeCompare(b.name)).slice(0, limit);
}

// ── the trace up the backbone ─────────────────────────────────────────

export interface TraceStep {
  class: string; // a CI's class, or desired, release, module, issues, adr
  name: string;
  id: string | null; // a CI's id: its panel opens; null for what is not a CI
  relation: string | null; // how it is reached from the step before; null on the first
  link: string | null; // where a step that is not a CI opens: a console path or a URL
}

// The relations that lead up, in the order tried: a port to its asset, an
// asset to the CI it is allocated to, software and guests to what they run on,
// a node to its cluster (else its environment).
export const TRACE_UP = ["part-of", "allocated-to", "runs-on", "member-of"];
const MEMBER_OF = ["cluster", "environment"];
export const TRACE_HOPS = 8;

export function nextUp(show: CmdbShow, seen: Set<string>): { type: string; other: CmdbEnd } | null {
  for (const type of TRACE_UP) {
    const up = show.relations.filter((r) => r.type === type && r.direction === "out" && !seen.has(r.other.id));
    if (!up.length) continue;
    const rank = (c: string): number => (MEMBER_OF.includes(c) ? MEMBER_OF.indexOf(c) : MEMBER_OF.length);
    const pick = [...up].sort((a, b) => rank(a.other.class) - rank(b.other.class) || a.other.name.localeCompare(b.other.name))[0];
    return { type, other: pick.other };
  }
  return null;
}

// What a CI records of its desired record and its release (D3's ci fields).
export interface Backbone {
  desired: { file: string; key: string | null } | null;
  release: { module: string; version: string | null } | null;
}

export function backboneOf(show: CmdbShow): Backbone {
  const d = show.attributes.desired?.value as Obj | undefined;
  const r = show.attributes.release?.value as Obj | undefined;
  return {
    desired: d && typeof d.file === "string" && d.file ? { file: d.file, key: typeof d.key === "string" && d.key ? d.key : null } : null,
    release: r && typeof r.module === "string" && r.module ? { module: r.module, version: typeof r.version === "string" && r.version ? r.version : null } : null,
  };
}

// What the repository says of a module: read by the caller, never by the walk.
export interface ModuleRef {
  name: string;
  version: string | null; // the module JSON's, when the CI records none
  issues: string | null; // its open issues on the forge
  adrs: { name: string; link: string | null }[];
}

export function backboneSteps(b: Backbone, mod: ModuleRef | null): TraceStep[] {
  const out: TraceStep[] = [];
  if (b.desired) {
    const file = b.desired.file.includes("/") ? b.desired.file : `config/${b.desired.file.replace(/\.json$/, "")}.json`;
    out.push({ class: "desired", name: b.desired.key ? `${file} · ${b.desired.key}` : file, id: null, relation: "desired record", link: null });
  }
  const name = b.release?.module ?? mod?.name ?? null;
  if (!name) return out;
  const version = b.release?.version ?? mod?.version ?? null;
  out.push({ class: "release", name: version ? `${name} ${version}` : name, id: null, relation: "instance of", link: null });
  out.push({ class: "module", name, id: null, relation: "release of", link: `/modules/${encodeURIComponent(name)}` });
  if (mod?.issues) out.push({ class: "issues", name: `open issues of ${name}`, id: null, relation: "backlog", link: mod.issues });
  for (const a of mod?.adrs ?? []) out.push({ class: "adr", name: a.name, id: null, relation: "implements", link: a.link });
  return out;
}

// From the CI up through TRACE_UP to the top, or TRACE_HOPS hops; then the
// backbone of the nearest object on the way that records one. A CI the CMDB
// cannot show ends the walk where it stands.
export async function walkTrace(start: CmdbShow, show: (id: string) => Promise<CmdbShow>, moduleOf: (b: Backbone, ci: CmdbShow) => Promise<ModuleRef | null>, hops = TRACE_HOPS): Promise<TraceStep[]> {
  const steps: TraceStep[] = [{ class: start.class, name: start.displayName || start.name, id: start.id, relation: null, link: null }];
  const seen = new Set([start.id]);
  let at = start;
  let anchor: { b: Backbone; ci: CmdbShow } | null = null;
  for (let i = 0; ; i++) {
    const b = backboneOf(at);
    if (!anchor && (b.desired || b.release)) anchor = { b, ci: at };
    if (i >= hops) break;
    const up = nextUp(at, seen);
    if (!up) break;
    seen.add(up.other.id);
    steps.push({ class: up.other.class, name: up.other.name, id: up.other.id, relation: up.type, link: null });
    try {
      at = await show(up.other.id);
    } catch {
      break;
    }
    steps[steps.length - 1].name = at.displayName || at.name;
  }
  if (!anchor) return steps;
  return [...steps, ...backboneSteps(anchor.b, await moduleOf(anchor.b, anchor.ci).catch(() => null))];
}

// ── reading the repository for a module ───────────────────────────────

// The ADRs a design names, each once, in order.
export function adrRefs(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(/\bADR-?(\d{3})([a-z]?)\b/g)) {
    const n = `ADR-${m[1]}${m[2]}`;
    if (!out.includes(n)) out.push(n);
  }
  return out.sort();
}

// A git remote as the forge's web address: ssh or https, with or without .git.
export function webUrlOf(remote: string | null): string | null {
  if (!remote) return null;
  const ssh = /^(?:ssh:\/\/)?[^@/]+@([^:/]+)[:/](?:\d+\/)?(.+?)(?:\.git)?\/?$/.exec(remote);
  if (ssh && !remote.startsWith("http")) return `https://${ssh[1]}/${ssh[2]}`;
  const http = /^(https?:\/\/[^/]+\/.+?)(?:\.git)?\/?$/.exec(remote);
  return http ? http[1] : null;
}

export function issuesUrl(web: string | null, module: string): string | null {
  return web ? `${web}/issues?state=open&q=${encodeURIComponent(module)}` : null;
}
