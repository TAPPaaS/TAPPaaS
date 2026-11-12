// gen-site.ts — random sites in the metamodel's shape for the differential and
// determinism tests: two to three nodes, pools on mirrored disks, bonded uplinks,
// HA guests, depends-on loops, five condition types. Seeded, so reproducible.

import { CmdbItem, CmdbRel, Condition } from "../../src/assess-model";
import { obj, rel, cond } from "./assess-fixture";
export function rng(seed: number): () => number { let s = seed >>> 0; return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296); }
export interface Site { objects: CmdbItem[]; relations: CmdbRel[]; source: Map<string, Condition[]> }
/** A random site in the metamodel's shape. scale 1 ≈ 60 objects. cycles: allow depends-on loops. */
export function site(seed: number, scale = 1, faults = 0.12, cycles = true): Site {
  const r = rng(seed), pickOf = <X>(a: X[]): X => a[Math.floor(r() * a.length)], n = (k: number): number => Math.max(1, Math.round(k * scale));
  const O: CmdbItem[] = [], L: CmdbRel[] = [];
  const mk = (c: string, name: string, a: Record<string, unknown> = {}): CmdbItem => { const o = obj(c, name, a); O.push(o); return o; };
  const st = mk("site", "home"), cl = mk("cluster", "c1"), room = mk("room", "r1"), rack = mk("rack", "k1");
  L.push(rel("placed-in", rack, room));
  const envs = [mk("environment", "prod"), mk("environment", "test")], zones = [mk("zone", "mgmt"), mk("zone", "srv"), mk("zone", "dmz")];
  for (const z of zones) L.push(rel("serves", z, pickOf(envs)));
  const machines: CmdbItem[] = [], vms: CmdbItem[] = [], svcs: CmdbItem[] = [], pools: CmdbItem[] = [], ports: CmdbItem[] = [];
  for (let i = 0; i < Math.max(2, n(3)); i++) {
    const m = mk("machine", "m" + i), a = mk("server", "srv" + i);
    machines.push(m); L.push(rel("member-of", m, cl), rel("allocated-to", a, m), rel("placed-in", a, rack));
    for (let p = 0; p < 2; p++) {
      const pool = mk("storage-pool", "tank" + i + p); pools.push(pool); L.push(rel("runs-on", pool, m));
      const nd = 1 + Math.floor(r() * 3);
      for (let d = 0; d < nd; d++) { const dk = mk("disk", "d" + i + p + d); L.push(rel("part-of", dk, a), rel("built-on", pool, dk, nd > 1 && r() < 0.8 ? { redundancyGroup: "m" + i + ":" + pool.name + ":mirror-0" } : r() < 0.2 ? { required: false } : {})); }
    }
    // a bond to two switch ports, and a single uplink
    const sw = mk("network-device", "sw" + i);
    const e1 = mk("port", "m" + i + "/eno1"), e2 = mk("port", "m" + i + "/eno2"), s1 = mk("port", "sw" + i + "/1"), s2 = mk("port", "sw" + i + "/2");
    ports.push(e1, e2, s1, s2);
    L.push(rel("part-of", e1, a), rel("part-of", e2, a), rel("part-of", s1, sw), rel("part-of", s2, sw));
    const bond = r() < 0.7 ? { redundancyGroup: "m" + i + ":bond0" } : {};
    L.push(rel("connects", e1, s1, bond), rel("connects", e2, s2, bond));
  }
  for (let i = 0; i < n(14); i++) {
    const v = mk(r() < 0.8 ? "vm" : "lxc", "g" + i, r() < 0.3 ? { haNode: "m1" } : {}); vms.push(v);
    const m = pickOf(machines); L.push(rel("runs-on", v, m), rel("member-of", v, pickOf(envs)));
    L.push(rel("stored-on", v, pickOf(pools)));
    if (r() < 0.7) { const s = mk("service", "g" + i + ":svc"); svcs.push(s); L.push(rel("runs-on", s, v)); }
    if (r() < 0.3) { const a = mk("app", "app" + i); L.push(rel("runs-on", a, v)); if (svcs.length) L.push(rel("depends-on", a, pickOf(svcs))); }
  }
  for (const v of vms) for (let k = 0; k < 2; k++) if (svcs.length && r() < 0.45) {
    const s = pickOf(svcs);
    if (!cycles && s.name.split(":")[0] >= v.name) continue;
    if (s.name.split(":")[0] !== v.name) L.push(rel("depends-on", v, s, r() < 0.1 ? { required: false } : {}));
  }
  const ds = mk("datastore", "ds"); L.push(rel("stored-on", ds, pickOf(pools)), rel("runs-on", ds, pickOf(vms)), rel("backs-up", ds, pickOf(vms)));
  const src = new Map<string, Condition[]>();
  const types = ["operational", "operational", "operational", "performance", "capacity", "security", "drift"] as const;
  const times = ["2026-10-30T02:00:00.000Z", "2026-10-30T02:05:00.000Z", "2026-10-30T03:00:00.000Z", "2026-10-30T08:00:00.000Z"];
  for (const o of O) {
    const cs: Condition[] = [];
    for (const t of new Set([pickOf([...types]), pickOf([...types])])) {
      const x = r();
      if (x < faults) cs.push(cond(t, r() < 0.6 ? "critical" : "warning", t + "-bad", { since: pickOf(times), ...(r() < 0.1 ? { acknowledged: { by: "x", note: "", until: null, sticky: false } } : {}) }));
      else if (x < faults + 0.15) cs.push(cond(t, r() < 0.8 ? "ok" : "unknown", "ok"));
    }
    if (cs.length) src.set(o.id, cs);
  }
  void st; void ports;
  return { objects: O, relations: L, source: src };
}
