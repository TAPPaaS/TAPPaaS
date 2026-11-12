// migrate-types.test.ts — the one-time move of what was stored under the old
// condition types (maintenance, security) to upkeep, vulnerability and threat:
// the shared mapping, a site's rule store as the release before the split left
// it (with a site edit and a site rule), and the CMDB objects as captured from
// a running site, with acknowledgements, emit's cursor and the digest's keys.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { HealthRecord, checkSet, migrateRecordTypes, recordsOf } from "../../../../lib/ts/src/health-records";
import { currentType, currentTypesOf } from "../../../../lib/ts/src/health-rules";
import { migrateConditions, migrateDigestKey, migrateKeyed, migrateStoredObjects } from "../../../../lib/ts/src/health-migrate";
import { RuleStore, mergeReleases, readCoreRelease } from "../../src/rulestore";
import { MigrateObject, migrateTypes } from "../../src/migrate-types";
import { CURSOR_FILE } from "../../src/emit";
import { shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const CICD = process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../..");
const HERE = join(CICD, "manager/health-manager/test/unit");
const now = "2026-11-12T10:00:00.000Z";

// ── the mapping ───────────────────────────────────────────────────────
console.log("the mapping");
check(currentType("maintenance", "reboot-pending") === "upkeep" && currentType("maintenance", "backup-key-not-escrowed") === "backup", "maintenance is upkeep; an unescrowed backup key is backup");
check(currentType("security", "cve-high") === "vulnerability" && currentType("security", "cve-scan-stale") === "vulnerability" && currentType("security", "controller-unverified") === "vulnerability" && currentType("security", "repository-unverified") === "vulnerability" && currentType("security", "cve-baseline") === "vulnerability", "CVE, scan, signature, control-plane trust and the baseline are vulnerability");
check(currentType("security", "siem-ssh-brute-force") === "threat" && currentType("security", "system-not-built") === "threat" && currentType("security", "alert-root-key-changed") === "threat" && currentType("security", "ok", "siem") === "threat", "the SIEM, a hand-made system and an exposed-alert are threat (an ok one by its owner)");
check(currentType("security", "certificate-expiry") === "upkeep", "certificate expiry is upkeep");
check(currentType("operational", "x") === "operational" && currentType("bogus") === null, "a current type stays, an unknown one is null");
check(currentTypesOf("security").join() === "vulnerability,threat" && currentTypesOf("security", { source: ["siem"] }).join() === "threat", "a match on security with nothing to decide it reads both; a source decides");

const cs = migrateConditions([{ type: "security", status: "warning", reason: "cve-high" }, { type: "maintenance", status: "warning", reason: "backup-key-not-escrowed" }, { type: "backup", status: "critical", reason: "backup-not-covered" }]);
check(cs.map((c) => `${c.type}:${c.status}`).join() === "vulnerability:warning,backup:critical", "two old conditions on one new type: the worse stays");
const words = migrateKeyed({ security: { at: "2026-11-01T00:00:00Z" }, threat: { at: "2026-10-01T00:00:00Z" } }, [{ type: "security", reason: "siem-x" }]);
check(!!words && !("security" in words) && words.threat.at === "2026-11-01T00:00:00Z", "an ack under security moves to the type its condition now has; the newer word wins");
check(migrateDigestKey("vm/coturn security cve-high") === "vm/coturn vulnerability cve-high" && migrateDigestKey("cve coturn CVE-1 risk") === "cve coturn CVE-1 risk", "a digest key moves; a CVE item's key is not a type's");

// ── a site's rule store from before the split ────────────────────────
console.log("the rule store");
const dir = mkdtempSync(join(tmpdir(), "hm-migrate-"));
try {
  const oldRel = readCoreRelease(join(HERE, "fixtures/core-before-split"));
  const hdir = join(dir, "config/health");
  const before = new RuleStore(hdir);
  before.base.set("core", oldRel.records);
  // The site edited the CVE-level notify (a medium level is no news here) and added rules
  // that quiet the lab's exposed-alerts and put every security root in the digest.
  const cveLevel = oldRel.records.find((r) => r.id === "core.notify.cve-level")!;
  const edited = { ...cveLevel, when: { condition: { type: "security", reason: ["cve-high", "cve-critical", "cve-baseline"] } } } as HealthRecord;
  const siteRule = { id: "site.classify.lab-alerts", kind: "classify", description: "The lab's exposed-alerts are known.", when: { finding: { source: "alerts", type: "security" }, object: { name: "lab" } }, quiet: true, overrides: ["core.classify.alert-security"] } as unknown as HealthRecord;
  const siteMatch = { id: "site.notify.any-security", kind: "notify", description: "Every security root in the digest.", when: { condition: { type: "security" } }, notify: "digest", overrides: ["core.notify.critical-root"] } as unknown as HealthRecord;
  before.rules.set("core", oldRel.records.map((r) => (r.id === edited.id ? edited : r)));
  before.rules.set("site", [siteRule, siteMatch]);
  before.state.rules[edited.id] = { local: "edited", by: "lars", at: now, note: "mail it", editedFrom: cveLevel };
  before.state.rules[siteRule.id] = { local: "added", by: "lars", at: now };
  before.write();

  const store = RuleStore.read(hdir);
  check(store.migratedTypes.includes("core.notify.cve-level") && store.migratedTypes.includes("core.classify.alert-security") && store.migratedTypes.includes("site.classify.lab-alerts"), "reading maps every record that named an old type");
  const ed = store.find("core.notify.cve-level")!.rec as { when: { condition: { type: unknown; reason: string[] } } };
  check(ed.when.condition.type === "vulnerability" && !ed.when.condition.reason.includes("cve-medium"), "the site's edit keeps what it changed, under the new type");
  check(store.localOf("core.notify.cve-level") === "edited" && (store.state.rules["core.notify.cve-level"].editedFrom as { when: { condition: { type: string } } }).when.condition.type === "vulnerability", "…still an edit against base, and its as-released copy is mapped too");
  const sr = store.find("site.classify.lab-alerts")!.rec as { when: { finding: { type: unknown } } };
  check(sr.when.finding.type === "threat", "a site rule on alerts' security findings matches threat");
  const sm = store.find("site.notify.any-security")!.rec as { when: { condition: { type: unknown } } };
  check(JSON.stringify(sm.when.condition.type) === '["vulnerability","threat"]', "a site rule on security with nothing to decide it matches both");
  check(!checkSet(store.active(), shippedModel()).some((p) => p.level === "error"), "the mapped set holds");

  const rel = readCoreRelease(join(CICD, "controller/cmdb-controller/metamodel/health"));
  const res = mergeReleases(store, new Map([["core", rel]]), { now, model: shippedModel() });
  const what = (id: string): string => res.changes.filter((c) => c.id === id).map((c) => c.what).join("+");
  check(res.ok && res.activate, "the release after the split merges into it");
  check(what("core.notify.cve-level") === "kept" && !(store.find("core.notify.cve-level")!.rec as { when: { condition: { reason: string[] } } }).when.condition.reason.includes("cve-medium"), "the site-edited rule is kept, never dropped");
  check(!!store.find("site.classify.lab-alerts") && !!store.find("site.notify.any-security"), "the site's own rules stay");
  check(["core.classify.siem-warning", "core.classify.siem-critical", "core.classify.cve-baseline"].every((id) => what(id) === "updated"), "the SIEM hold rules and the baseline rule take the release's new type");
  check((store.find("core.classify.alert-security")!.rec as { set: { type: string } }).set.type === "threat", "the exposed-alerts rule sets threat");
  store.write();
  const again = RuleStore.read(hdir);
  check(again.migratedTypes.length === 0, "written back: read again, nothing left to map");
  check(!/"(security|maintenance)"/.test(readFileSync(join(hdir, "rules/core.json"), "utf8") + readFileSync(join(hdir, "state.json"), "utf8")), "…no old type is left in the files");
  check(!rel.records.some((r) => migrateRecordTypes(r) !== r), "the released core records name no old type");
  check(recordsOf({ records: oldRel.records.map(migrateRecordTypes) }, "x").problems.length === 0, "every old core record maps to one that reads");

  // ── the CMDB as captured from a running site ────────────────────────
  console.log("the CMDB, emit's cursor and the digest");
  const objects = JSON.parse(readFileSync(join(CICD, "ui/test/fixtures/cmdb/objects.json"), "utf8")) as MigrateObject[];
  const legacy = (os: MigrateObject[]): number => os.filter((o) => ((o.attributes.conditions as { type: string }[] | undefined) ?? []).some((c) => c.type === "security" || c.type === "maintenance")).length;
  check(legacy(objects) > 20, `the capture holds conditions under the old types (${legacy(objects)} objects)`);
  const byName = (n: string): MigrateObject => objects.find((o) => o.name === n)!;
  byName("coturn").attributes.acknowledgements = { security: { ack: { by: "lars", note: "known", until: null, sticky: false, at: now }, at: now } };
  byName("cluster").attributes.acknowledgements = { security: { ack: { by: "lars", note: "rotated", until: null, sticky: true, at: now }, at: now } };
  byName("cluster").attributes.flapping = { security: { held: "warning" } };
  const conf = join(dir, "config");
  writeFileSync(join(conf, CURSOR_FILE), JSON.stringify({ time: now, change: 1, roots: { [`${byName("coturn").id}:security`]: { ci: byName("coturn").id, class: "vm", name: "coturn", type: "security", symptoms: [] } }, notices: {} }));
  writeFileSync(join(conf, ".health-digest-seen.json"), JSON.stringify({ at: now, keys: ["vm/coturn security cve-act", "app/cluster security alert-root-key-changed", "sweep x"] }));
  const writes: { id: string; attributes: Record<string, unknown> }[] = [];
  const io = { configDir: conf, objects: () => objects, write: (o: MigrateObject, attributes: Record<string, unknown>) => void writes.push({ id: o.id, attributes }) };

  const dry = migrateTypes(io, false);
  check(dry.objects.length === 2 && writes.length === 0 && dry.cursor === 1 && dry.digest === 2, "without --apply: says what it would move, writes nothing");
  check(JSON.parse(readFileSync(join(conf, CURSOR_FILE), "utf8")).roots[`${byName("coturn").id}:security`] !== undefined, "…the cursor untouched");
  const r = migrateTypes(io, true);
  const w = (n: string) => writes.find((x) => x.id === byName(n).id)?.attributes;
  check(r.objects.length === 2 && Object.keys(w("coturn")!.acknowledgements as object).join() === "vulnerability", "the CVE module's ack moves to vulnerability");
  check(Object.keys(w("cluster")!.acknowledgements as object).join() === "threat" && Object.keys(w("cluster")!.flapping as object).join() === "threat", "the exposed-alert's ack and its flapping hold move to threat");
  const cur = JSON.parse(readFileSync(join(conf, CURSOR_FILE), "utf8"));
  check(Object.keys(cur.roots).join() === `${byName("coturn").id}:vulnerability` && cur.roots[`${byName("coturn").id}:vulnerability`].type === "vulnerability", "a told root keeps being told, under its new type: no RESOLVED and new ALERT");
  const seen = JSON.parse(readFileSync(join(conf, ".health-digest-seen.json"), "utf8"));
  check(seen.keys.join("|") === "vm/coturn vulnerability cve-act|app/cluster threat alert-root-key-changed|sweep x", "the digest's told lines move: nothing comes back as new");
  // After the write-back the objects carry the new keys; a second run moves nothing.
  for (const x of writes) Object.assign(objects.find((o) => o.id === x.id)!.attributes, x.attributes);
  const twice = migrateTypes(io, true);
  check(twice.objects.length === 0 && twice.cursor === 0 && twice.digest === 0 && twice.rules.length === 0, "a second run changes nothing");
  check(twice.conditions === legacy(objects), "…the conditions are left for the next assess, and said so");

  const read = migrateStoredObjects(objects);
  check(legacy(read) === 0, "every reader sees the new types before assess writes them");
  const site = read.find((o) => o.class === "site" && Array.isArray(o.attributes.rootCauses) && (o.attributes.rootCauses as unknown[]).length);
  check(!site || !(site.attributes.rootCauses as { type?: string }[]).some((x) => x.type === "security" || x.type === "maintenance"), "…the site's root list too");
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
