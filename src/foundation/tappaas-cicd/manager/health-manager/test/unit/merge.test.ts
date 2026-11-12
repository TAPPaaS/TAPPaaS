// merge.test.ts — the merge of a released rule set into what a site runs: one
// case per row of the table (ours against base, theirs against base), renames,
// a newly released rule that conflicts with a local one, a release that does
// not hold, anchoring, reach, and the files the store writes.

import { mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { HealthRecord } from "../../../../lib/ts/src/health-records";
import { Release, RuleStore, mergeReleases } from "../../src/rulestore";
import { cond, obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const now = "2026-11-12T10:00:00.000Z";
const model = shippedModel();
const mk = (id: string, status: "warning" | "critical" = "critical", description?: string): HealthRecord =>
  ({ id, kind: "propagate", ...(description ? { description } : {}), when: { relation: "built-on", dependant: { name: id.split(".").pop() }, condition: { type: "operational", status: "critical" } }, as: { status } }) as HealthRecord;
const core = (recs: HealthRecord[], scenarios: Release["scenarios"] = []): Map<string, Release> => new Map([["core", { origin: "core", records: recs, scenarios, foundation: true, file: "", problems: [] }]]);
const ids = (s: RuleStore, origin = "core"): string => (s.rules.get(origin) ?? []).map((r) => r.id).join(",");
const statusOf = (s: RuleStore, id: string): string | undefined => { const r = s.find(id)?.rec; return r && r.kind === "propagate" && r.as !== "none" ? r.as.status : undefined; };
const merge = (s: RuleStore, rels: Map<string, Release>, extra = {}): ReturnType<typeof mergeReleases> => mergeReleases(s, rels, { now, model, ...extra });
const dir = mkdtempSync(join(tmpdir(), "hm-merge-"));

try {
  const store = new RuleStore(join(dir, "health"));
  const r1 = merge(store, core([mk("core.p.a"), mk("core.p.b"), mk("core.p.c"), mk("core.p.d"), mk("core.p.e"), mk("core.p.f")]));
  check(r1.ok && ids(store) === "core.p.a,core.p.b,core.p.c,core.p.d,core.p.e,core.p.f" && (store.base.get("core") ?? []).length === 6, "a first merge installs the release, and keeps it as base");

  // Local changes: b edited, c edited, d edited, e deleted, f deleted.
  store.put("core", mk("core.p.b", "warning"));
  store.put("core", mk("core.p.c", "warning"));
  store.put("core", mk("core.p.d", "warning"));
  store.state.rules["core.p.d"] = { local: "edited", by: "lars", at: now, note: "dmz guests are fine", editedFrom: mk("core.p.d") };
  store.drop("core.p.e");
  store.state.rules["core.p.e"] = { local: "deleted", by: "lars", at: now };
  store.drop("core.p.f");
  store.state.rules["core.p.f"] = { local: "deleted", by: "lars", at: now };
  check(store.localOf("core.p.b") === "edited" && store.localOf("core.p.a") === undefined, "an edit by hand is found against base");

  // The next release: a same→changed, b edited→same, c edited→changed, d edited→gone,
  // e deleted→changed, f deleted→gone, g new.
  const r2 = merge(store, core([mk("core.p.a", "warning"), mk("core.p.b"), mk("core.p.c", "critical", "changed upstream"), mk("core.p.e", "warning"), mk("core.p.g")]));
  const what = (id: string): string => r2.changes.filter((c) => c.id === id).map((c) => c.what).join("+");
  check(statusOf(store, "core.p.a") === "warning" && what("core.p.a") === "updated", "same here, changed upstream: updated");
  check(statusOf(store, "core.p.b") === "warning" && what("core.p.b") === "kept" && store.state.rules["core.p.b"]?.local === "edited", "edited here, same upstream: kept, recorded as an edit (author unknown)");
  check(statusOf(store, "core.p.c") === "warning" && what("core.p.c") === "upstream-changed" && store.state.rules["core.p.c"]?.upstream === "changed" && store.pending("core.p.c"), "edited here, changed upstream: kept as edited, marked, pending");
  check(statusOf(store, "core.p.d") === "warning" && store.state.rules["core.p.d"]?.upstream === "removed" && store.state.rules["core.p.d"]?.note === "dmz guests are fine", "edited here, gone upstream: kept, upstream removed; the site's now");
  check(!store.find("core.p.e") && store.state.rules["core.p.e"]?.local === "deleted" && store.state.rules["core.p.e"]?.upstream === "changed", "deleted here, changed upstream: stays deleted, the change noted");
  check(!store.find("core.p.f") && !store.state.rules["core.p.f"] && what("core.p.f") === "tombstone-dropped", "deleted here, gone upstream: the tombstone is dropped");
  check(!!store.find("core.p.g") && what("core.p.g") === "added", "a new rule: added");
  check((store.base.get("core") ?? []).length === 5 && !(store.base.get("core") ?? []).some((r) => r.id === "core.p.d"), "…and base becomes the new release");
  check(r2.before !== r2.after, "the active set changed: a new hash");

  // Removed upstream while the same here.
  const r3 = merge(store, core([mk("core.p.a", "warning"), mk("core.p.b"), mk("core.p.c", "critical", "changed upstream"), mk("core.p.e", "warning")]));
  check(!store.find("core.p.g") && r3.changes.some((c) => c.id === "core.p.g" && c.what === "removed"), "same here, gone upstream: removed");
  // Edited to the same as the new release: in step.
  store.put("core", mk("core.p.c", "warning", "changed again"));
  const r4 = merge(store, core([mk("core.p.a", "warning"), mk("core.p.b"), mk("core.p.c", "warning", "changed again"), mk("core.p.e", "warning")]));
  check(!store.state.rules["core.p.c"] && r4.changes.some((c) => c.id === "core.p.c" && c.what === "in-step"), "edited to the same as the new release: in step, local state cleared");
  // A deleted rule released again is never re-added.
  merge(store, core([mk("core.p.a", "warning"), mk("core.p.b"), mk("core.p.c", "warning", "changed again"), mk("core.p.e", "critical")]));
  check(!store.find("core.p.e"), "a deleted rule is never re-added, however often it changes upstream");

  // Rename: the replacement of an edited rule comes in held.
  const ren = { ...mk("core.p.b2"), replaces: ["core.p.b"] } as HealthRecord;
  const r5 = merge(store, core([mk("core.p.a", "warning"), ren, mk("core.p.c", "warning", "changed again"), mk("core.p.e", "critical")]));
  check(store.state.rules["core.p.b2"]?.held?.why === "replaces" && store.active().find((r) => r.id === "core.p.b2")?.enabled === false && !!store.find("core.p.b"), "a rename of an edited rule: the edit kept, the new rule held");
  void r5;

  // A newly released rule that conflicts with a local one is held, the rest runs.
  store.put("site", { id: "site.propagate.dmz", kind: "propagate", when: { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, as: { status: "critical" } } as HealthRecord);
  const ha = { id: "core.p.ha", kind: "propagate", when: { relation: "runs-on", dependant: { attr: { haNode: { exists: true } } }, condition: { type: "operational", status: "critical" } }, as: { status: "warning" } } as HealthRecord;
  const r6 = merge(store, core([mk("core.p.a", "warning"), ren, mk("core.p.c", "warning", "changed again"), ha]));
  check(store.state.rules["core.p.ha"]?.held?.why === "conflict" && store.state.rules["core.p.ha"]?.held?.detail.includes("site.propagate.dmz") && r6.activate, "a released rule conflicting with a site rule: held, the rest activated");

  // A release that does not hold changes nothing.
  const beforeIds = ids(store);
  const r7 = merge(store, core([{ id: "core.p.bad", kind: "propagate", when: { relation: "powers" }, as: { status: "critical" } } as HealthRecord]));
  check(!r7.ok && ids(store) === beforeIds && r7.problems.some((p) => p.message.includes("nothing changed")), "a release that does not validate: nothing changes, and it says so");
  check(store.state.lastMerge?.ok === false, "…recorded for the site's drift warning");

  // A module's rules: anchored, and their reach.
  const nc = (recs: HealthRecord[], foundation = false): Map<string, Release> => new Map([["nextcloud", { origin: "nextcloud", records: recs, scenarios: [], foundation, file: "", problems: [] }]]);
  const loose = { id: "nextcloud.propagate.x", kind: "propagate", when: { relation: "runs-on", condition: { type: "operational", status: "critical" } }, as: { status: "critical" } } as HealthRecord;
  const ra = merge(store, nc([loose]), { origins: ["nextcloud"] });
  check(!ra.ok && ra.problems.some((p) => p.message.includes("names nextcloud at one end")) && !store.rules.has("nextcloud"), "a module record not anchored at its own end is refused");
  const node = obj("machine", "n"), vms = [0, 1, 2, 3].map((i) => obj("vm", `g${i}`, { module: i === 0 ? "nextcloud" : "other" }));
  const snap = { objects: [node, ...vms], relations: vms.map((v) => rel("runs-on", v, node)) };
  const wide = { id: "nextcloud.propagate.slow", kind: "propagate", description: "A slow nextcloud node slows its neighbours.", when: { relation: "runs-on", provider: { class: "machine" }, dependant: { module: "nextcloud" }, condition: { type: "operational", status: "warning" } }, as: { status: "critical" } } as HealthRecord;
  const rr = merge(store, nc([wide]), { origins: ["nextcloud"], snapshot: snap, reachHold: 0 });
  check(rr.ok && store.state.rules["nextcloud.propagate.slow"]?.reach?.with === 1 && store.state.rules["nextcloud.propagate.slow"]?.held?.why === "reach", "an app module's rule over the site's reach threshold: installed held, its reach recorded");
  const fstore = new RuleStore(join(dir, "f"));
  mergeReleases(fstore, nc([wide], true), { now, model, origins: ["nextcloud"], snapshot: snap, reachHold: 0 });
  check(!fstore.state.rules["nextcloud.propagate.slow"]?.held && fstore.state.rules["nextcloud.propagate.slow"]?.reach?.with === 1, "…a foundation module's is never held: its reach recorded, and it runs");
  const removed = merge(store, new Map(), { origins: ["nextcloud"] });
  check(!store.find("nextcloud.propagate.slow") && removed.changes.some((c) => c.what === "removed"), "a module removed: its released rules go");

  // The network module's zone record anchors on a class its manager reports.
  const CICD = process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../..");
  const net = JSON.parse(readFileSync(join(CICD, "../network/network-health.json"), "utf8")) as { records: HealthRecord[] };
  const nrel = new Map([["network", { origin: "network", records: net.records, scenarios: [], foundation: true, file: "", problems: [] }]]);
  const ns = new RuleStore(join(dir, "n"));
  const un = mergeReleases(ns, nrel, { now, model, origins: ["network"] });
  check(!un.ok && un.problems.some((p) => p.message.includes("names network at one end")), "the network module's zone record without the registry: not anchored");
  const an = mergeReleases(ns, nrel, { now, model, origins: ["network"], reports: new Map([["network", ["zone", "address"]]]) });
  check(an.ok && !!ns.find("network.propagate.zone-down"), "…with network-manager registered to report zones for it: anchored and installed");

  // A scenario that no longer holds is a warning, not a refusal.
  const sc = { id: "core.scenario.x", objects: [{ class: "machine", name: "n" }, { class: "vm", name: "g" }], relations: [{ type: "runs-on", from: "vm/g", to: "machine/n" }], conditions: [{ object: "machine/n", type: "operational", status: "critical" }], expect: { impact: { "vm/g": "critical" } } } as never;
  const s2 = new RuleStore(join(dir, "s2"));
  const rs = mergeReleases(s2, core([], [sc]), { now, model });
  check(rs.activate && rs.problems.some((p) => p.level === "warning" && p.id === "core.scenario.x"), "a scenario that fails after a merge: a warning, the set still runs");

  // A module that ships no rules gets no files.
  const empty = new RuleStore(join(dir, "e"));
  mergeReleases(empty, new Map([["backup", { origin: "backup", records: [], scenarios: [], foundation: true, file: "", problems: [] }], ...core([mk("core.p.a")])]), { now, model });
  check(!empty.rules.has("backup") && !empty.base.has("backup") && empty.rules.has("core"), "a module that ships no rules: no file of its own");

  // The files.
  store.write();
  const st = JSON.parse(readFileSync(join(dir, "health", "state.json"), "utf8"));
  const back = RuleStore.read(join(dir, "health"));
  check(st.rules["core.p.d"].upstream === "removed" && back.find("core.p.d") !== null && back.base.has("core") && back.rules.has("site"), "the store writes rules/, base/, state.json and reads them back");
  void cond;
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
