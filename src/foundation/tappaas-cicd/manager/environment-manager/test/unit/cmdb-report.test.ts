// cmdb-report.test.ts — `environment-manager report --json` (ADR-040 D3, D4):
// each environment with its domain and update window, owned-by its
// organization, served by the zones naming it; add/delete report their change
// with the console job.

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { run } from "../../src/main";
import { updateWindow } from "../../src/cmdb-report";
import { cmdbProblems } from "../../../../lib/ts/test/cmdb-check";
import { FakeDnsTlsClient, FakeModuleClient, FakeNetworkClient } from "./fake-clients";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`FAIL - ${msg}`);
  }
}

function capture(f: () => unknown): string[] {
  const out: string[] = [];
  const log = console.log;
  const err = console.error;
  console.log = (m: string) => void out.push(String(m));
  console.error = (m: string) => void out.push(String(m));
  try {
    f();
  } finally {
    console.log = log;
    console.error = err;
  }
  return out;
}

type Obj = Record<string, any>;

function setup(): string {
  const d = mkdtempSync(join(tmpdir(), "env-cmdb-"));
  mkdirSync(join(d, "environments"));
  mkdirSync(join(d, "identities", "organizations"), { recursive: true });
  writeFileSync(join(d, "identities", "organizations", "acme.json"), JSON.stringify({ name: "acme" }));
  writeFileSync(join(d, "site.json"), JSON.stringify({ name: "hrossen", updateSchedule: { frequency: "weekly", weekday: "Tuesday", hour: 2 } }));
  writeFileSync(
    join(d, "zones.json"),
    JSON.stringify({
      mgmt: { type: "Management", environment: "mgmt" },
      acme: { type: "Service", environment: "acme" },
      home: { type: "Client", environment: ["acme", "lab"] },
      lab: { type: "Service", environment: "lab" },
    }),
  );
  const w = (n: string, o: unknown): void => writeFileSync(join(d, "environments", `${n}.json`), JSON.stringify(o));
  w("mgmt", { name: "mgmt", displayName: "Management" });
  w("acme", { name: "acme", displayName: "Acme", ownerOrg: "acme", domains: { primary: "acme.example.org" } });
  return d;
}

const clients = (): [FakeNetworkClient, FakeModuleClient, FakeDnsTlsClient] => [new FakeNetworkClient(), new FakeModuleClient(), new FakeDnsTlsClient()];

// ── the update window ──────────────────────────────────────────────────
{
  const d = setup();
  check(updateWindow(d) === "weekly Tuesday 02:00", `the site's window (${updateWindow(d)})`);
  writeFileSync(join(d, "site.json"), JSON.stringify({ updateSchedule: ["daily", "Monday", 3] }));
  check(updateWindow(d) === "daily 03:00", "daily: no weekday");
}

// ── report --json ──────────────────────────────────────────────────────
{
  const d = setup();
  let rc = -1;
  const out = capture(() => (rc = run(["report", "--json", "--config-dir", d], ...clients())));
  check(rc === 0, `report --json exits 0 (${out.join("\n").slice(0, 300)})`);
  const r = JSON.parse(out.join("\n")) as Obj;
  const one = (cls: string, name: string): Obj | undefined => r.objects.find((o: Obj) => o.class === cls && o.name === name);
  const rel = (type: string, from: string | undefined, to: string | undefined): boolean =>
    r.relations.some((x: Obj) => x.type === type && x.from?.ref === from && x.to?.ref === to);
  check(r.source === "environment-manager" && r.kind === "observation", "an observation by environment-manager");
  const problems = cmdbProblems(r);
  check(problems.length === 0, `cmdb-controller's metamodel takes it: ${problems.join("; ")}`);
  const acme = one("environment", "acme");
  check(acme?.attributes?.domain === "acme.example.org" && acme?.attributes?.updateWindow === "weekly Tuesday 02:00", "domain and update window");
  check(acme?.attributes?.desired?.file === "environments/acme.json", "its desired record");
  check(acme?.attributes?.organization?.ref === one("organization", "acme")?.ref, "owned-by its organization (a stub)");
  check(one("environment", "mgmt")?.attributes?.organization === undefined, "mgmt has no owner");
  check(rel("serves", one("zone", "acme")?.ref, acme?.ref) && rel("serves", one("zone", "home")?.ref, acme?.ref), "its own zone and a client zone serve it");
  check(rel("serves", one("zone", "mgmt")?.ref, one("environment", "mgmt")?.ref), "the Management zone serves mgmt");
  check(!one("zone", "lab"), "a zone serving no reported environment is not named");
}

// report --discover: nothing deeper exists for this plane (D15).
{
  const d = setup();
  let rc = -1;
  const a = capture(() => (rc = run(["report", "--json", "--discover", "--config-dir", d], ...clients()))).join("\n");
  const b = capture(() => run(["report", "--json", "--config-dir", d], ...clients())).join("\n");
  check(rc === 0 && a === b, "--discover is accepted and reports the same");
}

// ── add and delete report their change, with the job ───────────────────
{
  const d = setup();
  const saved = { ...process.env };
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(d, "no.sock");
  process.env.TAPPAAS_JOB_ID = "20261030130000-0a0b0c";
  try {
    capture(() => run(["add", "lab", "--owner", "acme", "--domain", "lab.example.org", "--config-dir", d], ...clients()));
    capture(() => run(["delete", "lab", "--check", "--config-dir", d], ...clients()));
    capture(() => run(["delete", "lab", "--force", "--config-dir", d], ...clients()));
  } finally {
    for (const k of ["TAPPAAS_CMDB", "CMDB_SOCKET", "TAPPAAS_JOB_ID"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
  const dir = join(d, ".cmdb-spool");
  const reports = readdirSync(dir).filter((f) => f.endsWith(".json")).sort().map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")) as Obj);
  check(reports.length === 2, `add and delete each report, --check does not (${reports.length})`);
  const [add, del] = reports;
  check(add?.kind === "change" && add?.verb === "add lab" && add?.job === "20261030130000-0a0b0c", "the add's change, verb and job");
  check(add?.objects?.some((o: Obj) => o.class === "environment" && o.name === "lab" && o.attributes?.domain === "lab.example.org"), "the environment as added");
  check(!add?.objects?.some((o: Obj) => o.class === "environment" && o.name === "acme"), "only the environment the verb touched");
  for (const x of reports) {
    const p = cmdbProblems(x);
    check(p.length === 0, `the metamodel takes the ${x.verb} change: ${p.join("; ")}`);
  }
  check(del?.verb === "delete lab" && del?.objects?.some((o: Obj) => o.name === "lab" && o.end === true), "a deleted environment ends");
}

console.log(`cmdb-report: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
