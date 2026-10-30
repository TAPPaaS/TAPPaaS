// fake-cmdb.ts — the CMDB of the Health fixture site (test/fixtures/health-site.json):
// one node down with its guests impacted, one acknowledged root, one flapping
// condition, one guest in a maintenance window. `set` moves an object's
// conditions and `tell` plays the change stream, so a test sees what a report
// would do. Built by hand: health-assess writes this shape on a real site.

import { readFileSync } from "fs";
import { join } from "path";
import { Cmdb, CmdbAttributePeriod, CmdbChange, CmdbObject, CmdbQuery, CmdbRelationQuery, CmdbRelationRow } from "../../src/cmdb";

const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";

export interface HealthSite {
  objects: CmdbObject[];
  relations: CmdbRelationRow[];
  ids: Record<string, string>;
  history: CmdbAttributePeriod[];
}

export function healthSite(): HealthSite {
  return JSON.parse(readFileSync(join(FIX, "health-site.json"), "utf8")) as HealthSite;
}

export class FakeCmdb {
  readonly site = healthSite();
  calls: string[] = [];
  down = false;
  at: string[] = [];
  private onChange: ((c: CmdbChange) => void) | null = null;
  private onLink: ((up: boolean) => void) | null = null;

  private guard(what: string): void {
    this.calls.push(what);
    if (this.down) throw new Error("the CMDB did not answer");
  }
  async query(q: CmdbQuery = {}): Promise<CmdbObject[]> {
    this.guard("query");
    if (q.at) this.at.push(q.at);
    return this.site.objects;
  }
  async relations(q: CmdbRelationQuery = {}): Promise<CmdbRelationRow[]> {
    this.guard(`relations ${q.type ?? ""}`);
    return this.site.relations.filter((r) => !q.type || r.type === q.type);
  }
  async classes(): Promise<{ name: string; parent: string | null }[]> {
    this.guard("classes");
    return [{ name: "gadget", parent: "device" }];
  }
  async show(id: string): Promise<unknown> {
    this.guard(`show ${id}`);
    const o = this.site.objects.find((x) => x.id === id);
    if (!o) throw new Error(`no object ${id}`);
    return {
      id, class: o.class, name: o.name, ancestors: [o.class, "ci", "object"], displayName: null, drift: null,
      attributes: Object.fromEntries(Object.entries(o.attributes).map(([k, value]) => [k, { value, source: "x", since: "2026-10-01T00:00:00Z" }])),
      relations: this.site.relations.flatMap((r) => [
        ...(r.from.id === id ? [{ id: r.id, type: r.type, direction: "out", other: r.to }] : []),
        ...(r.to.id === id ? [{ id: r.id, type: r.type, direction: "in", other: r.from }] : []),
      ]),
    };
  }
  async history(id: string): Promise<unknown> {
    this.guard(`history ${id}`);
    return { id, attributes: this.site.history, changes: [{ id: 7, kind: "observation", source: "health-manager", job: null, verb: null, actor: null, time: "2026-10-30T02:14:00Z", drift: false }] };
  }
  async roots(): Promise<Record<string, unknown>[]> {
    this.guard("roots");
    return [{ id: this.site.ids.tappaas2, impacted: 4 }];
  }
  subscribe(onChange: (c: CmdbChange) => void, onLink: (up: boolean) => void): () => void {
    this.onChange = onChange;
    this.onLink = onLink;
    return () => undefined;
  }
  link(up: boolean): void {
    this.onLink?.(up);
  }
  tell(): void {
    this.onChange?.({ id: 1, kind: "observation", source: "health-manager", time: "2026-10-30T09:00:00Z", objects: [], relations: [], drift: false });
  }
  set(key: string, conditions: unknown[]): void {
    this.site.objects.find((o) => o.id === this.site.ids[key])!.attributes.conditions = conditions;
  }
  asCmdb(): Cmdb {
    return this as unknown as Cmdb;
  }
}
