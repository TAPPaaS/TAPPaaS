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
  w("cluster", { kind: "application", moduleSource: src("cluster", ["vm", "ha"]), version: "0.8.0", stack: "foundation", dependsOn: ["cluster:ha"] });
  w("backup", { kind: "application", moduleSource: src("backup", ["vm"]), version: "0.4.0", node: "tappaas1", dependsOn: ["identity:sso"], zone0: "srv" });
  w("tappaas-cicd", { kind: "vm", moduleSource: src("tappaas-cicd"), version: "1.2.0", vmid: 110, node: "tappaas1", environment: "mgmt" });
  w("identity", { kind: "vm", moduleSource: src("identity", ["sso"]), version: "0.5.2", vmid: 140, node: "tappaas1", environment: "mgmt", dependsOn: ["cluster:vm", "backup:vm", "nowhere:x"], zone0: "mgmt" });
  w("identity-test", { kind: "vm", moduleSource: src("identity", ["sso"]), version: "0.5.2", vmid: 141, node: "tappaas1", environment: "mgmt" });
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
  check(id?.attributes?.state === "running" && one("vm", "nextcloud")?.attributes?.state === "stopped", "a guest's run state, for the topology");
  check(!objs.some((o) => o.name === "old"), "an archived instance is not reported");
  check(id?.attributes?.module === "identity" && one("vm", "identity-test")?.attributes?.module === "identity", "a CI's module is the catalog name, not the instance (identity-test is of identity)");
  check(one("app", "backup")?.attributes?.module === "backup" && one("service", "identity:sso", (o) => o.attributes?.provider === "identity")?.attributes?.module === "identity" && one("manager", "site-manager")?.attributes?.module === "tappaas-cicd", "…on its app, its services and the control plane's managers too");
  const zoneRel = (from: string | undefined, zone: string): boolean => (r.relations ?? []).some((x: Obj) => x.type === "member-of" && x.from?.ref === from && x.to?.ref !== undefined && x.to.ref === one("zone", zone)?.ref);
  check(zoneRel(id?.ref, "mgmt") && zoneRel(one("app", "backup")?.ref, "srv"), "a node and an app are member-of the zone of their record");
  const completes: Obj[] = r.complete ?? [];
  check(completes.some((c) => c.type === "member-of" && c.from?.ref === id?.ref && c.toClass === "zone") && completes.some((c) => c.type === "member-of" && c.from?.ref === one("vm", "identity-test")?.ref && c.toClass === "zone"), "…named whole, so a changed or dropped zone ends the old one, and only the zone");

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
  const sso = one("service", "identity:sso")?.ref;
  check(rel("depends-on", bk?.ref, sso), "an application's dependency is on the app");
  check(!rel("depends-on", m?.ref, sso), "…never on its host, where the service may run");
  check(!(r.relations ?? []).some((x: Obj) => x.type === "depends-on" && x.from?.ref === cl?.ref), "a module never depends on a service it provides itself");
  const complete = (r.complete ?? []) as Obj[];
  check(complete.some((c) => c.type === "depends-on" && c.from?.ref === id?.ref) && complete.some((c) => c.type === "depends-on" && c.from?.ref === bk?.ref), "the report is complete for each instance's depends-on: a dropped dependency ends");
  check(complete.some((c) => c.type === "depends-on" && c.from?.ref === m?.ref), "…and for an application's host, so a dependency an earlier release put there ends");

  const sm = one("manager", "site-manager");
  check(sm?.attributes?.onNode?.ref === one("vm", "tappaas-cicd")?.ref && sm?.attributes?.version === "1.2.0", "a manager runs on the instance that brings it");
  check(one("controller", "proxmox-controller")?.attributes?.aliases?.[0] === "pve-controller", "a controller with its aliases");
  check(one("controller", "proxmox-controller")?.attributes?.registry?.module === "tappaas-cicd", "its registry entry");
  check(!objs.some((o) => o.name === "cmdb"), "a service component is no controller or manager");
  check(!JSON.stringify(r).includes("null"), "no attribute is null");
}

// report --discover: nothing deeper exists for this plane (D15).
{
  const cfg = fixture();
  const fake = new FakeModuleClient();
  let rc = -1;
  const a = capture(() => (rc = run(["report", "--json", "--discover", "--config-dir", cfg], fake))).join("\n");
  const b = capture(() => run(["report", "--json", "--config-dir", cfg], fake)).join("\n");
  check(rc === 0 && a === b, "--discover is accepted and reports the same");
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

// ── report --end: what delete-module.sh sends, while the config is there ──
// A guest ends alone (its software with it, in the store); an application's
// node stays, so the app and its services end by their key on that node.
{
  const cfg = fixture();
  const saved = { ...process.env };
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(cfg, "no.sock");
  try {
    const c = new FakeModuleClient();
    capture(() => run(["report", "--end", "identity", "--config-dir", cfg], c));
    capture(() => run(["report", "--end", "backup", "--config-dir", cfg], c));
  } finally {
    for (const k of ["TAPPAAS_CMDB", "CMDB_SOCKET"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
  const [vm, app] = spooled(cfg);
  for (const x of [vm, app]) check(cmdbProblems(x).length === 0, `the metamodel takes the ${x?.verb} end: ${cmdbProblems(x).join("; ")}`);
  check(vm?.kind === "change" && vm?.verb === "delete identity", `a change with its verb (${vm?.verb})`);
  check(vm?.objects?.length === 1 && vm.objects[0].class === "vm" && vm.objects[0].end === true && vm.objects[0].attributes?.vmid === 140, "a guest ends by its key");
  const ends = (app?.objects ?? []).filter((o: Obj) => o.end === true);
  check(ends.map((o: Obj) => `${o.class}/${o.name}`).sort().join(" ") === "app/backup service/backup:vm", `an application ends with its services (${ends.map((o: Obj) => `${o.class}/${o.name}`).join(" ")})`);
  check(ends.every((o: Obj) => o.attributes?.onNode !== undefined), "…each by its key, the name on its node");
  check(!(app?.objects ?? []).some((o: Obj) => o.class === "machine" && o.end === true), "its node stays");
}

// ── report --end of a guest whose config names no kind (a test fixture) ──
// Only the live cluster ever said whether it was a vm or an lxc, so the end
// names both by the vmid: the one it is ends, the other is an end of nothing.
{
  const cfg = fixture();
  writeFileSync(join(cfg, "test-ghost.json"), JSON.stringify({ vmid: 902, vmname: "test-ghost", node: "tappaas1", status: "Testing", dependsOn: ["cluster:vm"] }));
  const saved = { ...process.env };
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(cfg, "no.sock");
  try {
    capture(() => run(["report", "--end", "test-ghost", "--config-dir", cfg], new FakeModuleClient()));
  } finally {
    for (const k of ["TAPPAAS_CMDB", "CMDB_SOCKET"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
  const [r] = spooled(cfg);
  check(cmdbProblems(r).length === 0, `the metamodel takes the kind-less end: ${cmdbProblems(r).join("; ")}`);
  const ends = (r?.objects ?? []).filter((o: Obj) => o.end === true);
  check(ends.length === 2 && ends.map((o: Obj) => o.class).sort().join() === "lxc,vm" && ends.every((o: Obj) => o.attributes?.vmid === 902 && o.name === "test-ghost"), "a kind-less guest ends as vm and as lxc, by its vmid");
}

// ── update carries what it applied to the guest ────────────────────────
// The update leaves config/tappaas-cicd.json as it was and halves the guest's
// memory: the change names the vm with the fields read back from its config,
// as site-manager observes them, so the sweep credits the verb.
{
  const cfg = fixture();
  const saved = { ...process.env };
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(cfg, "no.sock");
  try {
    const c = new FakeModuleClient();
    c.confs.set(110, "boot: order=scsi0\ncores: 4\nmemory: 8192\nscsi0: tanka1:vm-110-disk-0,size=64G\nefidisk0: tanka1:vm-110-disk-1,size=1M\nide2: none,media=cdrom\nnet0: virtio=BC:24:11:AA:BB:CC,bridge=lan,tag=10\n[pre-update]\nmemory: 16384\n");
    c.confs.set(140, "cores: 2\nmemory: 2048\n");
    let rc = -1;
    const out = capture(() => (rc = run(["update", "tappaas-cicd", "--config-dir", cfg], c)));
    check(rc === 0, `update succeeds (${out.join("\n").slice(0, 300)})`);
    capture(() => run(["modify", "identity", "--dry-run", "--set", "instance=identity2", "--config-dir", cfg], c));
  } finally {
    for (const k of ["TAPPAAS_CMDB", "CMDB_SOCKET"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
  const reports = spooled(cfg);
  const upd = reports.find((r) => r.verb === "update tappaas-cicd");
  const vm = upd?.objects?.find((o: Obj) => o.class === "vm" && o.name === "tappaas-cicd");
  check(!!vm, "update reports the vm it names, its config unchanged");
  check(vm?.attributes?.memory === 8192 && vm?.attributes?.cores === 4, `memory and cores as applied, not the snapshot's (${vm?.attributes?.memory}/${vm?.attributes?.cores})`);
  check(
    JSON.stringify(vm?.attributes?.disks) === JSON.stringify([{ storage: "tanka1", size: "64G" }, { storage: "tanka1", size: "1M" }]),
    `disks as site-manager reads them, no cdrom (${JSON.stringify(vm?.attributes?.disks)})`,
  );
  check(vm?.attributes?.nics?.[0]?.tag === 10 && vm?.attributes?.nics?.[0]?.mac === "bc:24:11:aa:bb:cc", "the nics as configured");
  check(upd ? cmdbProblems(upd).length === 0 : false, `the metamodel takes the update's fields: ${upd ? cmdbProblems(upd).join("; ") : "no report"}`);
  check(!reports.some((r) => String(r.verb).startsWith("modify identity")), "a dry run reports nothing");
}

console.log(`cmdb-report: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
