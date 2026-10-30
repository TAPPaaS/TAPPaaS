// cmdbreport.test.ts — what `backup-manager report` sends to the CMDB (ADR-040
// D4): the datastore, its backs-up and the backup peers, from a fixture
// `pbs-controller runs --json` answer (FakeClient) and peer records in a temp
// config dir; and a peer verb's change carrying the console's job id (spooled:
// no CMDB in the test).
//
// Run: node cmdbreport.test.js

import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { CmdbReport } from "../../../../lib/ts/src/cmdb";
import { buildBackupDiscover } from "../../src/cmdbreport";
import { run } from "../../src/main";
import { RawDiscover, RawRuns } from "../../src/types";
import { FakeClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) { passed++; console.log(`  ✓ ${msg}`); }
  else { failed++; console.log(`  ✗ ${msg}`); }
}

const T = 1793000000;
const raw: RawRuns = {
  reachable: true,
  node: "tappaas3",
  store: "tappaas_backup",
  marker: "TAPPaaS",
  snapshots: [
    { ns: "", type: "vm", id: "200", time: T },
    { ns: "", type: "ct", id: "105", time: T },
    { ns: "", type: "vm", id: "999", time: T }, // a guest no module has
    { ns: "fs/tappaas1", type: "host", id: "tappaas1", time: T },
    { ns: "pull/buddy", type: "vm", id: "300", time: T }, // a buddy's copy, not ours
  ],
  verifyJobs: [],
  syncJobs: [{ id: "s1", remote: "buddy", ns: "pull/buddy", schedule: "daily", "last-run-endtime": T, "last-run-state": "OK" }],
  backupJobs: [],
  tasks: [],
  status: { total: 4000, used: 1000, avail: 3000 },
  pruneJobs: [{ id: "p1", store: "tappaas_backup", "keep-daily": 7, "keep-weekly": 4, comment: "x" }],
};

const tmp = mkdtempSync(join(tmpdir(), "bm-cmdb-"));
const env = process.env;
try {
  writeFileSync(join(tmp, "site.json"), JSON.stringify({ name: "home", locations: { home: { primary: true }, aunt: { city: "Aarhus" } } }));
  writeFileSync(join(tmp, "nextcloud.json"), JSON.stringify({ vmid: 200, dependsOn: ["backup:vm"] }));
  writeFileSync(join(tmp, "dns.json"), JSON.stringify({ kind: "lxc", vmid: 105 }));
  writeFileSync(join(tmp, "pull-buddy.json"), JSON.stringify({ remoteHost: "pbs.buddy.example", location: "aunt" }));
  writeFileSync(join(tmp, "remote-buddy.json"), JSON.stringify({ remoteHost: "pbs.buddy.example" }));
  writeFileSync(join(tmp, "receive-cousin.json"), JSON.stringify({}));
  env.TAPPAAS_CONFIG = tmp;
  env.CONFIG_DIR = tmp;

  const c = new FakeClient();
  c.rawRuns = raw;
  let buf = "";
  const w = process.stdout.write.bind(process.stdout);
  (process.stdout as unknown as { write: (s: string) => boolean }).write = (x: string) => ((buf += x), true);
  let rc: number;
  try {
    rc = run(["report", "--json", "--config-dir", tmp], c);
  } finally {
    (process.stdout as unknown as { write: typeof w }).write = w;
  }
  check(rc === 0, "report --json exits 0");
  const r = JSON.parse(buf) as CmdbReport;
  const objs = r.objects ?? [];
  const rels = r.relations ?? [];
  const obj = (cls: string, name: string) => objs.find((o) => o.class === cls && o.name === name);
  const to = (type: string, from: string) => rels.filter((x) => x.type === type && x.from === from).map((x) => JSON.stringify(x.to)).sort();

  check(r.source === "backup-manager" && r.kind === "observation", "an observation from backup-manager");
  const ds = obj("datastore", "tappaas_backup")?.attributes ?? {};
  check(ds.size === 4000 && ds.used === 1000, "the datastore: its size and used (bytes)");
  check(JSON.stringify(ds.retention) === JSON.stringify({ daily: 7, weekly: 4 }), "…its retention, from its prune job");
  check(JSON.stringify(to("runs-on", "datastore:tappaas_backup")) === JSON.stringify([JSON.stringify({ class: "machine", name: "tappaas3" })]), "…runs-on the machine PBS runs on");
  check(
    JSON.stringify(to("backs-up", "datastore:tappaas_backup")) ===
      JSON.stringify([{ class: "lxc", name: "dns" }, { class: "machine", name: "tappaas1" }, { class: "vm", name: "nextcloud" }].map((x) => JSON.stringify(x)).sort()),
    "backs-up the guests (by module) and the host it holds restore points for — not a buddy's copy, not a guest no module has",
  );
  const buddy = obj("backup-peer", "buddy")?.attributes ?? {};
  check(objs.filter((o) => o.class === "backup-peer").length === 2, "one backup-peer per buddy, whatever its relationships");
  check(buddy.direction === "pull" && buddy.lastSeen === new Date(T * 1000).toISOString(), "a buddy we pull from: pull, last seen at its sync's last run");
  check(JSON.stringify(to("at", "backup-peer:buddy")) === JSON.stringify([JSON.stringify({ class: "location", name: "aunt" })]), "…at the location it names");
  check(obj("backup-peer", "cousin")?.attributes?.direction === "receive", "a buddy that pushes into ours: receive");

  // report --discover: every datastore, with what only the sweep reads.
  const rd = JSON.parse(readFileSync(join(process.env.BM_FIXTURE_DIR ?? "test/fixtures", "discover.json"), "utf8")) as RawDiscover;
  const dr = buildBackupDiscover(rd, T + 86400).report();
  const dsOf = (n: string) => dr.objects!.find((o) => o.class === "datastore" && o.name === n)?.attributes ?? {};
  check(dr.objects!.map((o) => o.name).sort().join() === "offsite,tappaas_backup", "every datastore, also one no job uses");
  check(dsOf("tappaas_backup").size === 4000 && (dsOf("tappaas_backup").gc as { "removed-bytes": number })["removed-bytes"] === 9, "…its usage and GC state");
  check(JSON.stringify(dsOf("tappaas_backup").retention) === JSON.stringify({ daily: 7 }), "…its prune settings");
  const rp = (dsOf("tappaas_backup").restorePoints as { id: string; snapshots: number; ageSeconds: number }[])[0];
  check(rp.id === "200" && rp.snapshots === 3 && rp.ageSeconds === 86400, "…each restore-point group's count and age");
  check((dsOf("offsite").syncJobs as { id: string }[])[0]?.id === "s1" && (dsOf("tappaas_backup").syncJobs as unknown[]).length === 0, "…the sync jobs into it");
  const dc = new FakeClient();
  dc.rawRuns = raw;
  dc.rawDiscover = rd;
  let dbuf = "";
  const dw = process.stdout.write.bind(process.stdout);
  (process.stdout as unknown as { write: (s: string) => boolean }).write = (x: string) => ((dbuf += x), true);
  try {
    run(["report", "--json", "--discover", "--config-dir", tmp], dc);
  } finally {
    (process.stdout as unknown as { write: typeof dw }).write = dw;
  }
  check((JSON.parse(dbuf) as CmdbReport[]).length === 2, "report --json --discover prints the plain report and the discovery");

  // A peer verb reports a change with the job id.
  env.TAPPAAS_JOB_ID = "job-42";
  env.TAPPAAS_CMDB = "";
  env.CMDB_SOCKET = join(tmp, "no.sock");
  const quiet = console.log;
  console.log = () => undefined;
  try {
    rc = run(["peer", "modify", "pull", "buddy", "--contact", "aunt@example.org", "--config-dir", tmp], new FakeClient());
  } finally {
    console.log = quiet;
  }
  const spool = join(tmp, ".cmdb-spool");
  const files = (() => { try { return readdirSync(spool).filter((f) => f.endsWith(".json")); } catch { return []; } })();
  const ch = files.length ? (JSON.parse(readFileSync(join(spool, files[0]), "utf8")) as CmdbReport) : null;
  check(rc === 0 && ch !== null, "peer modify: the change is spooled when the CMDB does not answer");
  check(ch?.kind === "change" && ch.verb === "backup-manager peer modify" && ch.job === "job-42", "…with the verb and the console's job id");
  check(ch?.objects?.[0]?.class === "backup-peer" && ch.objects[0].name === "buddy", "…and the buddy it touched");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
