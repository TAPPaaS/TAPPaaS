// cmdbreport.ts — health-manager's report to the CMDB (ADR-040 D11): the
// health of every CI a gate of `validate` names, written on the CI as its
// `health` (ok, warning, critical, unknown), from the run that just happened;
// no check of its own.
//
// A finding names its subject by kind and name (CheckSubject). Health is a CI's
// attribute and a report creates what it does not match, so only CIs the CMDB
// already has get one: before sending, the subjects are matched to the CMDB's
// objects by name (cmdbQuery), and one it does not have is left out. Offline
// (--json) a subject's class is the one config/ says (a module's kind).
//
// The metamodel's `health` is a string: the gate that set it and when are the
// report's source and time, not the attribute.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { CmdbBatch } from "../../../lib/ts/src/cmdb-reporter";
import { CheckStatus } from "./types";

export const SOURCE = "health-manager";

export type Health = "ok" | "warning" | "critical" | "unknown";
const HEALTH: Record<CheckStatus, Health> = { pass: "ok", warn: "warning", fail: "critical", skip: "unknown" };
const RANK: Record<Health, number> = { unknown: 0, ok: 1, warning: 2, critical: 3 };

// What `validate --json` prints (validateDoc), as far as the report reads it.
export interface ValidateDoc {
  generated?: string;
  gates: { name: string; status: CheckStatus; findings: { status: CheckStatus; subject: { kind: string; name: string } | null }[] }[];
}

export interface SubjectHealth {
  kind: string;
  name: string;
  health: Health;
}

/** The worst health each subject got, over every gate that names it. */
export function subjectHealth(doc: ValidateDoc): SubjectHealth[] {
  const by = new Map<string, SubjectHealth>();
  for (const g of doc.gates ?? []) {
    for (const f of g.findings ?? []) {
      if (!f.subject) continue;
      const key = `${f.subject.kind}\u0000${f.subject.name}`;
      const h = HEALTH[f.status] ?? "unknown";
      const had = by.get(key);
      if (!had || RANK[h] > RANK[had.health]) by.set(key, { kind: f.subject.kind, name: f.subject.name, health: h });
    }
  }
  return [...by.values()].sort((a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name));
}

// The CMDB classes a subject kind can be: a module is a node of its kind.
export const KIND_CLASSES: Record<string, string[]> = {
  module: ["vm", "lxc", "machine", "device"],
  node: ["machine"],
  switch: ["device"],
  pool: ["storage-pool"],
  peer: ["backup-peer"],
};

/** A subject's class as config/ says it, for an offline report. */
export function configClass(configDir: string): (kind: string, name: string) => string | null {
  return (kind, name) => {
    if (kind !== "module") return KIND_CLASSES[kind]?.[0] ?? null;
    const f = join(configDir, `${name}.json`);
    if (!existsSync(f)) return null;
    try {
      const m = JSON.parse(readFileSync(f, "utf8")) as { kind?: unknown; vmid?: unknown };
      if (typeof m.kind === "string") return KIND_CLASSES.module.includes(m.kind) ? m.kind : null;
      return m.vmid !== undefined ? "vm" : null; // a module from before ADR-022d's kind
    } catch {
      return null;
    }
  };
}

/** A subject's class as the CMDB has it: the one object of the kind's classes by that name. */
export function cmdbClass(objects: { class: string; name: string }[]): (kind: string, name: string) => string | null {
  return (kind, name) => {
    const hits = objects.filter((o) => o.name === name && (KIND_CLASSES[kind] ?? []).includes(o.class));
    return hits.length === 1 ? hits[0].class : null;
  };
}

export function buildHealthReport(doc: ValidateDoc, classOf: (kind: string, name: string) => string | null): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  for (const s of subjectHealth(doc)) {
    const cls = classOf(s.kind, s.name);
    if (cls) b.put(cls, s.name, { health: s.health });
  }
  return b;
}
