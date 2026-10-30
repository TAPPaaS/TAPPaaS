// cmdbreport.test.ts — health-manager's health on the CIs (ADR-040 D11): the
// worst status each subject got over a fixture `validate --json`, each
// subject's class from config/ (offline) or from the CMDB's objects, and
// `report --json --from` printing the payload.
//
// Run: HM_FIXTURE_DIR=<health-manager>/test/fixtures node cmdbreport.test.js

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { CmdbReport } from "../../../../lib/ts/src/cmdb";
import { ValidateDoc, buildHealthReport, cmdbClass, configClass, subjectHealth } from "../../src/cmdbreport";
import { run } from "../../src/main";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const FIXTURE = join(process.env.HM_FIXTURE_DIR ?? join(__dirname, "../../../../../test/fixtures"), "validate.json");
const doc = JSON.parse(readFileSync(FIXTURE, "utf8")) as ValidateDoc;
const hs = subjectHealth(doc);
const h = (kind: string, name: string) => hs.find((x) => x.kind === kind && x.name === name)?.health;

check(h("module", "nextcloud") === "critical", "a module passing one gate and failing another is critical (the worst)");
check(h("pool", "tappaas3/tankc1") === "warning" && h("pool", "tappaas3/tanka1") === "ok", "warn is warning, pass is ok");
check(h("peer", "aunt") === "unknown", "skip is unknown");
check(hs.every((x) => x.name !== "total"), "a finding about nothing in particular is about no CI");

const tmp = mkdtempSync(join(tmpdir(), "hm-cmdb-"));
try {
  writeFileSync(join(tmp, "nextcloud.json"), JSON.stringify({ kind: "vm", vmid: 200 }));
  writeFileSync(join(tmp, "dns.json"), JSON.stringify({ kind: "lxc", vmid: 105 }));
  writeFileSync(join(tmp, "backup.json"), JSON.stringify({ kind: "application" }));
  const off = buildHealthReport(doc, configClass(tmp)).report();
  const o = (cls: string, name: string) => off.objects!.find((x) => x.class === cls && x.name === name);
  check(off.source === "health-manager" && off.kind === "observation", "an observation from health-manager");
  check(o("vm", "nextcloud")?.attributes?.health === "critical" && o("lxc", "dns")?.attributes?.health === "ok", "offline: a module is the node of its config kind");
  check(!off.objects!.some((x) => x.name === "backup"), "…an application module is no node: left out");
  check(o("storage-pool", "tappaas3/tankc1")?.attributes?.health === "warning", "a pool is the storage-pool <node>/<pool>");
  check(o("machine", "tappaas3")?.attributes?.health === "ok" && o("backup-peer", "aunt")?.attributes?.health === "unknown", "a node is a machine, a peer a backup-peer");
  check(!off.objects!.some((x) => x.name === "home"), "the site is not given a health");
  check(off.objects!.every((x) => Object.keys(x.attributes ?? {}).join() === "health"), "only health is written");

  const live = buildHealthReport(doc, cmdbClass([
    { class: "lxc", name: "nextcloud" }, // the CMDB knows better than a guess
    { class: "storage-pool", name: "tappaas3/tankc1" },
    { class: "machine", name: "tappaas3" },
  ])).report();
  check(live.objects!.map((x) => `${x.class}/${x.name}`).sort().join() === "lxc/nextcloud,machine/tappaas3,storage-pool/tappaas3/tankc1",
    "against the CMDB: each subject as the class it has there, and none it does not have");

  let buf = "";
  const w = process.stdout.write.bind(process.stdout);
  (process.stdout as unknown as { write: (s: string) => boolean }).write = (x: string) => ((buf += x), true);
  let rc: number;
  try {
    rc = run(["report", "--json", "--from", FIXTURE, "--config-dir", tmp], new FakeClusterClient());
  } finally {
    (process.stdout as unknown as { write: typeof w }).write = w;
  }
  const printed = JSON.parse(buf) as CmdbReport;
  check(rc === 0 && printed.objects!.some((x) => x.class === "vm" && x.name === "nextcloud"), "report --json --from prints the payload");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
