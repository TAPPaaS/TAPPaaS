// cmdb-report.test.ts — `module-manager report --json` (ADR-040 D3, D4): each
// instance as the CI of its kind, its services and provides, depends-on, the
// control plane's components; and the change a verb reports, with its job.

import { run } from "../../src/main";
import { FakeModuleClient } from "./fake-client";
import { cmdbProblems } from "../../../../lib/ts/test/cmdb-check";
import { DeleteOptions, ModifyOptions } from "../../src/types";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
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

function fixture(): string {
  const root = mkdtempSync(join(tmpdir(), "mm-cmdb-"));
  const cfg = join(root, "config");
  mkdirSync(cfg);
  const src = (m: string, services: string[] = []): string => {
    const d = join(root, "src", m);
    mkdirSync(d, { recursive: true });
    for (const s of services) mkdirSync(join(d, "services", s), { recursive: true });
    return d;
  };
  const w = (f: string, v: unknown): void => writeFileSync(join(cfg, `${f}.json`), JSON.stringify(v));
  w("site", { name: "hrossen" });
  w("tappaas1", { kind: "machine", moduleSource: src("pvehost", ["nfs"]), version: "0.3.0", address: "tappaas1.mgmt.internal", environment: "mgmt", stack: "foundation" });
  w("cluster", { kind: "application", moduleSource: src("cluster", ["vm", "ha"]), version: "0.8.0", stack: "foundation" });
  w("backup", { kind: "application", moduleSource: src("backup", ["vm"]), version: "0.4.0", node: "tappaas1" });
  w("tappaas-cicd", { kind: "vm", moduleSource: src("tappaas-cicd"), version: "1.2.0", vmid: 110, node: "tappaas1", environment: "mgmt" });
  w("identity", { kind: "vm", moduleSource: src("identity"), version: "0.5.2", vmid: 140, node: "tappaas1", environment: "mgmt", dependsOn: ["cluster:vm", "backup:vm", "nowhere:x"] });
  w("nextcloud", { kind: "vm", moduleSource: src("nextcloud"), version: "2.0.0", vmid: 200, node: "tappaas1", environment: "hrossen", dependsOn: ["cluster:vm"] });
  w("old", { kind: "vm", moduleSource: src("old"), version: "1.0", vmid: 300, status: "archived" });
  w("control-plane", {
    version: 1,
    components: [
      { name: "site-manager", kind: "manager", module: "tappaas-cicd", aliases: [] },
      { name: "proxmox-controller", kind: "controller", module: "tappaas-cicd", aliases: ["pve-controller"] },
      { name: "cmdb", kind: "service", module: "tappaas-cicd" },
    ],
  });
  return cfg;
}

// ── report --json ──────────────────────────────────────────────────────
{
  const cfg = fixture();
  const fake = new FakeModuleClient();
  fake.guests = [{ vmid: 140, name: "identity", node: "tappaas1", status: "running", type: "qemu" }];
  let rc = -1;
  const out = capture(() => (rc = run(["report", "--json", "--config-dir", cfg], fake)));
  check(rc === 0, `report --json exits 0 (${rc}: ${out.join("\n").slice(0, 400)})`);
  let r: Obj = {};
  try {
    r = JSON.parse(out.join("\n"));
  } catch {
    check(false, `report --json prints JSON: ${out.join("\n").slice(0, 300)}`);
  }
  const objs: Obj[] = r.objects ?? [];
  const one = (cls: string, name: string, pred: (o: Obj) => boolean = () => true): Obj | undefined => objs.find((o) => o.class === cls && o.name === name && pred(o));
  const rel = (type: string, from: string | undefined, to: string | undefined): boolean =>
    (r.relations ?? []).some((x: Obj) => x.type === type && x.from?.ref === from && x.to?.ref === to);

  check(r.source === "module-manager" && r.kind === "observation", "an observation by module-manager");
  const problems = cmdbProblems(r);
  check(problems.length === 0, `cmdb-controller's metamodel takes it: ${problems.join("; ")}`);
  const m = one("machine", "tappaas1");
  check(m?.attributes?.release?.module === "pvehost" && m?.attributes?.desired?.file === "tappaas1.json", "a machine instance: desired and release");
  const id = one("vm", "identity");
  check(id?.attributes?.vmid === 140 && id?.attributes?.stage === "operational", "a vm instance: its vmid, running");
  check(id?.attributes?.onNode?.ref === m?.ref, "a vm runs-on its machine (the instance in the batch)");
  check(id?.attributes?.environment?.ref === one("environment", "mgmt")?.ref, "a vm is member-of its environment (stubbed)");
  check(one("vm", "nextcloud")?.attributes?.stage === "created", "a configured guest the cluster does not run is created");
  check(!objs.some((o) => o.name === "old"), "an archived instance is not reported");

  const cl = one("app", "cluster");
  check(cl?.attributes?.onNode?.ref === m?.ref && cl?.attributes?.version === "0.8.0", "an application without a node is an app on the primary node");
  const bk = one("app", "backup");
  check(bk?.attributes?.onNode?.ref === m?.ref, "an application is an app on the node it names");

  const svc = one("service", "cluster:vm");
  check(svc?.attributes?.provider === "cluster" && svc?.attributes?.onNode?.ref === m?.ref, "a service per services/<svc>/, on its provider's node");
  check(!!one("service", "cluster:ha") && !!one("service", "pvehost:nfs") && !!one("service", "backup:vm"), "every services/ dir is a service");
  check(rel("provides", m?.ref, svc?.ref), "the provider's node provides the service");
  check(rel("depends-on", id?.ref, svc?.ref), "identity depends-on cluster:vm");
  check(rel("depends-on", id?.ref, one("service", "backup:vm")?.ref), "identity depends-on backup:vm");
  check(!JSON.stringify(r.relations).includes("nowhere"), "a dependency no instance provides is not reported");

  const sm = one("manager", "site-manager");
  check(sm?.attributes?.onNode?.ref === one("vm", "tappaas-cicd")?.ref && sm?.attributes?.version === "1.2.0", "a manager runs on the instance that brings it");
  check(one("controller", "proxmox-controller")?.attributes?.aliases?.[0] === "pve-controller", "a controller with its aliases");
  check(one("controller", "proxmox-controller")?.attributes?.registry?.module === "tappaas-cicd", "its registry entry");
  check(!objs.some((o) => o.name === "cmdb"), "a service component is no controller or manager");
  check(!JSON.stringify(r).includes("null"), "no attribute is null");
}

// ── a verb's change, with the console job ──────────────────────────────
class WritingClient extends FakeModuleClient {
  constructor(private cfg: string) {
    super();
  }
  modify(module: string, opts: ModifyOptions): number {
    const f = join(this.cfg, `${module}.json`);
    const raw = JSON.parse(readFileSync(f, "utf8"));
    writeFileSync(f, JSON.stringify({ ...raw, version: "2.1.0" }));
    return super.modify(module, opts);
  }
  delete(module: string, opts: DeleteOptions): number {
    const f = join(this.cfg, `${module}.json`);
    writeFileSync(f, JSON.stringify({ ...JSON.parse(readFileSync(f, "utf8")), status: "archived" }));
    return super.delete(module, opts);
  }
}

function spooled(cfg: string): Obj[] {
  const dir = join(cfg, ".cmdb-spool");
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
}

{
  const cfg = fixture();
  const saved = { ...process.env };
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(cfg, "no.sock");
  process.env.TAPPAAS_JOB_ID = "20261030101500-a1b2c3";
  process.env.TAPPAAS_ACTOR = "lars";
  try {
    const c = new WritingClient(cfg);
    let rc = -1;
    capture(() => (rc = run(["modify", "nextcloud", "--config-dir", cfg], c)));
    check(rc === 0, "modify succeeds");
    capture(() => run(["delete", "nextcloud", "--archive", "--config-dir", cfg], c));
    const fails = new WritingClient(cfg);
    fails.rc = 1;
    capture(() => run(["modify", "identity", "--config-dir", cfg], fails));
  } finally {
    for (const k of ["TAPPAAS_CMDB", "CMDB_SOCKET", "TAPPAAS_JOB_ID", "TAPPAAS_ACTOR"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
  const reports = spooled(cfg);
  check(reports.length === 2, `two changes spooled, none for the failed verb (${reports.length})`);
  const [mod, del] = reports;
  for (const x of reports) check(cmdbProblems(x).length === 0, `the metamodel takes the ${x.verb} change: ${cmdbProblems(x).join("; ")}`);
  check(mod?.kind === "change" && mod?.verb === "modify nextcloud", `a change with its verb (${mod?.verb})`);
  check(mod?.job === "20261030101500-a1b2c3" && mod?.actor === "lars", "the change carries the console job and actor");
  check(mod?.objects?.some((o: Obj) => o.class === "vm" && o.name === "nextcloud" && o.attributes?.release?.version === "2.1.0"), "the instance as the verb left it");
  const end = del?.objects?.find((o: Obj) => o.class === "vm" && o.name === "nextcloud");
  check(end?.end === true && end?.attributes?.vmid === 200, "an archived instance ends, by its key");
}

console.log(`cmdb-report: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
