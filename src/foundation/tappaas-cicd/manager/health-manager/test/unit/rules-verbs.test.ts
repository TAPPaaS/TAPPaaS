// rules-verbs.test.ts — the verbs that change what a site runs, on a scratch
// config/: merge installs the release, an edit is previewed then applied and
// recorded, an update keeps it, delete and restore, take and keep after an
// upstream change, a held rule accepted, a module's rules switched off, a
// scenario retired, and a write that would break a scenario needs --force.

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { cmdRules } from "../../src/rules";
import { RulesEnv, cmdRulesWrite } from "../../src/rules-verbs";
import { RuleStore, healthDir } from "../../src/rulestore";
import { obj, rel, shippedModel } from "./assess-fixture";

let passed = 0;
let failed = 0;
function check(c: boolean, name: string): void {
  if (c) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const CICD = process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../..");
const tmp = mkdtempSync(join(tmpdir(), "hm-verbs-"));
const coreDir = join(tmp, "release", "health");
const copy = (from: string, to: string): void => {
  mkdirSync(to, { recursive: true });
  for (const f of readdirSync(from)) {
    if (statSync(join(from, f)).isDirectory()) copy(join(from, f), join(to, f));
    else writeFileSync(join(to, f), readFileSync(join(from, f), "utf8"));
  }
};
copy(join(CICD, "controller/cmdb-controller/metamodel/health"), coreDir);
const config = join(tmp, "config");
mkdirSync(config);
process.env.TAPPAAS_HEALTH_CORE_DIR = coreDir;
const model = shippedModel();
let recalcs = 0;
const node = obj("machine", "tappaas1");
const ha = obj("vm", "firewall", { haNode: "tappaas2" });
const env: RulesEnv = {
  configDir: config,
  meta: { relations: model.relations, ancestors: model.ancestors },
  now: () => "2026-11-12T10:00:00.000Z",
  snapshot: () => ({ objects: [{ ...node, attributes: { conditions: [{ type: "operational", status: "critical", reason: "node-down", message: "down", since: "2026-11-12T09:00:00.000Z", lastChecked: "2026-11-12T09:00:00.000Z", source: "health-manager", derived: false, rootCause: null, acknowledged: null, maintenance: null }] } }, ha], relations: [rel("runs-on", ha, node)] }),
  recalc: () => void recalcs++,
};
const run = (...args: string[]): { rc: number | null; out: string[] } => {
  const out: string[] = [];
  const rc = cmdRulesWrite(args, env, (l) => out.push(l));
  return { rc, out };
};
const store = (): RuleStore => RuleStore.read(healthDir(config));
const statusOf = (id: string): string | undefined => { const r = store().find(id)?.rec; return r && r.kind === "propagate" && r.as !== "none" ? r.as.status : undefined; };

try {
  let threw = false;
  try { run("edit", "core.propagate.runs-on.down-ha", "--set", "as.status=critical"); } catch (e) { threw = (e as Error).message.includes("merge --apply"); }
  check(threw, "before any merge: a write says the rules are not installed yet");
  const preview = run("merge");
  check(preview.rc === 0 && preview.out.some((l) => l === "added: core.propagate.runs-on.down") && !store().installed, "merge previews what it would add, and writes nothing");
  const m = run("merge", "--apply");
  check(m.rc === 0 && store().installed && store().rules.get("core")!.length === model.records.length && recalcs === 1, "merge --apply installs core into config/health/ and recalculates at once");
  check(store().allScenarios().length >= 8, "…with the contract scenarios");

  // An edit, previewed then applied.
  const refused = run("edit", "core.propagate.runs-on.down-ha", "--set", "as.status=critical", "--note", "this site has no HA", "--apply");
  check(refused.rc === 1 && refused.out.some((l) => l.includes("core.scenario.ha-guest no longer holds")) && statusOf("core.propagate.runs-on.down-ha") === "warning", "an edit that breaks a contract scenario (HA guests degrade): refused without --force");
  const pe = run("edit", "core.propagate.runs-on.down-ha", "--set", "as.status=critical", "--note", "this site has no HA", "--force");
  check(pe.rc === 0 && pe.out.some((l) => l.startsWith("~ core.propagate.runs-on.down-ha")) && pe.out.some((l) => l.includes("vm firewall: warning → critical")) && statusOf("core.propagate.runs-on.down-ha") === "warning", "edit previews the change and what it does on the site now, and writes nothing");
  const ae = run("edit", "core.propagate.runs-on.down-ha", "--set", "as.status=critical", "--note", "this site has no HA", "--force", "--apply");
  const st = store().state.rules["core.propagate.runs-on.down-ha"];
  check(ae.rc === 0 && statusOf("core.propagate.runs-on.down-ha") === "critical" && st?.local === "edited" && st.note?.startsWith("this site has no HA; written with --force over scenario core.scenario.ha-guest") === true && !!st.editedFrom && recalcs === 2, "edit --apply writes it, records who, why and as released, and recalculates");
  const listed: string[] = [];
  cmdRules(["list", "--state", "edited"], { ...model, records: store().active() }, (l) => listed.push(l), undefined, { store: store() });
  check(listed.length === 1 && listed[0].includes("[edited"), "rules list --state edited shows it");

  // An update over the edit: kept, marked when upstream changed.
  const pf = join(coreDir, "propagate.json");
  const doc = JSON.parse(readFileSync(pf, "utf8"));
  doc.records.find((r: { id: string }) => r.id === "core.propagate.runs-on.down-ha").description = "Changed upstream.";
  doc.records.find((r: { id: string }) => r.id === "core.propagate.depends-on.down").description = "Also changed upstream.";
  writeFileSync(pf, JSON.stringify(doc));
  run("merge", "--apply");
  check(statusOf("core.propagate.runs-on.down-ha") === "critical" && store().pending("core.propagate.runs-on.down-ha"), "an update that changes an edited rule: kept as edited, pending");
  check(store().find("core.propagate.depends-on.down")?.rec.description === "Also changed upstream.", "…an unedited rule takes the change");
  const diff: string[] = [];
  cmdRulesWrite(["diff", "core.propagate.runs-on.down-ha"], env, (l) => diff.push(l));
  check(diff.some((l) => l.trim().startsWith("as:") && l.includes("changed here")) && diff.some((l) => l.includes("description") && l.includes("changed upstream")), "diff: three columns, each field marked here or upstream");
  run("take", "core.propagate.runs-on.down-ha", "--field", "description", "--apply", "--force");
  check(store().find("core.propagate.runs-on.down-ha")?.rec.description === "Changed upstream." && statusOf("core.propagate.runs-on.down-ha") === "critical", "take --field: one field from upstream, the edit stays");
  run("keep", "core.propagate.runs-on.down-ha", "--apply", "--force");
  check(!store().pending("core.propagate.runs-on.down-ha") && store().state.rules["core.propagate.runs-on.down-ha"]?.local === "edited", "keep: reviewed, no longer pending, still edited");

  // Delete, an update, restore.
  run("delete", "core.follow.disk", "--apply", "--force");
  run("merge", "--apply");
  check(!store().find("core.follow.disk") && store().state.rules["core.follow.disk"]?.local === "deleted", "delete: a tombstone; an update never re-adds it");
  const dl: string[] = [];
  cmdRules(["list", "--state", "deleted"], { ...model, records: store().active() }, (l) => dl.push(l), undefined, { store: store() });
  check(dl.length === 1 && dl[0].startsWith("core.follow.disk"), "…listed under --state deleted");
  run("restore", "core.follow.disk", "--apply", "--force");
  check(!!store().find("core.follow.disk") && !store().state.rules["core.follow.disk"], "restore: back as released");

  // A site rule, a conflict refused.
  const add = join(tmp, "site.json");
  writeFileSync(add, JSON.stringify({ records: [{ id: "site.propagate.dmz", kind: "propagate", when: { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, as: { status: "warning" } }] }));
  const clash = run("add", add, "--apply");
  check(clash.rc === 1 && clash.out.some((l) => l.startsWith("refused:") && l.includes("conflicts")) && !store().find("site.propagate.dmz"), "add a site rule that conflicts: refused, nothing written");
  writeFileSync(add, JSON.stringify({ records: [{ id: "site.propagate.dmz", kind: "propagate", overrides: ["core.propagate.runs-on.down-ha", "core.propagate.runs-on.down"], when: { relation: "runs-on", dependant: { zone: "dmz" }, condition: { type: "operational", status: "critical" } }, as: { status: "warning" } }] }));
  check(run("add", add, "--apply", "--force").rc === 0 && store().state.rules["site.propagate.dmz"]?.local === "added", "…with overrides it holds: the site's own rule, added");

  // A write that breaks a scenario needs --force.
  const br = run("disable", "core.propagate.runs-on.down", "--apply");
  check(br.rc === 1 && br.out.some((l) => l.includes("core.scenario.node-down") && l.includes("--force")), "a write under which a scenario no longer holds is refused without --force");
  run("scenario", "retire", "core.scenario.node-down", "--note", "nodes here never go down alone", "--apply", "--force");
  check(store().state.scenarios["core.scenario.node-down"]?.retired.note === "nodes here never go down alone", "scenario retire: local state with why");
  const forced = run("disable", "core.propagate.runs-on.down", "--force", "--apply");
  void forced.out;
  check(forced.rc === 0 && store().active().find((r) => r.id === "core.propagate.runs-on.down")?.enabled === false, "…with the failing scenarios retired or forced, the write goes through");
  run("enable", "core.propagate.runs-on.down", "--apply", "--force");
  run("scenario", "restore", "core.scenario.node-down", "--apply", "--force");
  check(!store().state.scenarios["core.scenario.node-down"] && store().active().find((r) => r.id === "core.propagate.runs-on.down")?.enabled !== false, "enable and scenario restore take it back");

  // Held, accept; a module's rules off.
  const s = store();
  s.state.rules["core.follow.port"] = { held: { why: "reach", detail: "test", at: "x" } };
  s.write();
  check(store().active().find((r) => r.id === "core.follow.port")?.enabled === false, "a held rule does not run");
  run("accept", "core.follow.port", "--apply", "--force");
  check(!store().state.rules["core.follow.port"], "accept releases it");
  run("disable", "--origin", "core", "--note", "test", "--apply", "--force");
  check(store().active().filter((r) => r.id.startsWith("core.")).every((r) => r.enabled === false) && store().active().some((r) => r.id === "site.propagate.dmz" && r.enabled !== false) && !!store().state.origins.core?.disabled, "disable --origin: every rule of that origin off, as local state");
  run("enable", "--origin", "core", "--apply", "--force");
  run("merge", "--apply");
  check(!store().state.origins.core && store().active().some((r) => r.enabled !== false), "…and on again; it stays as set across a merge");

  const show: string[] = [];
  cmdRulesWrite(["show", "core.propagate.runs-on.down-ha"], env, (l) => show.push(l));
  check(show[0].startsWith("core.propagate.runs-on.down-ha (core)") && show.some((l) => l.includes("state: edited")) && show.some((l) => l.includes("decides")), "show: the record, its state, what it decides now");
} finally {
  rmSync(tmp, { recursive: true, force: true });
  delete process.env.TAPPAAS_HEALTH_CORE_DIR;
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
