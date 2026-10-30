// cmdb-report.test.ts — `site-manager report --json` (ADR-040 D4): the site, its
// locations, the cluster, the nodes and the guests, with the classes, keys
// and relations of D3/D5; the probes' parsers; reconcile's side-effect report.

import { run } from "../../src/main";
import { parseClusterProbe, parseGuestConf, parseHostProbe } from "../../src/cmdb-report";
import { FakeSiteClient } from "./fake-client";
import { cmdbProblems } from "../../../../lib/ts/test/cmdb-check";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "fs";
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
  const cfg = mkdtempSync(join(tmpdir(), "report-"));
  const w = (f: string, v: unknown): void => writeFileSync(join(cfg, f), JSON.stringify(v));
  w("site.json", {
    name: "hrossen", displayName: "Rossen", defaultEnvironment: "hrossen",
    locations: { home: { country: "DK", city: "Hellerup", timezone: "Europe/Copenhagen", kind: "site" }, buddy: { country: "DK", kind: "remote" } },
    primaryLocation: "home",
  });
  w("tappaas1.json", { moduleSource: "/repo/src/foundation/pvehost", kind: "machine", version: "0.3.0", address: "tappaas1.mgmt.internal", storagePools: ["tanka1"] });
  w("tappaas2.json", { moduleSource: "/repo/src/foundation/pvehost", kind: "machine", version: "0.3.0", address: "tappaas2.mgmt.internal", storagePools: ["tankb1"], location: "buddy" });
  w("identity.json", { moduleSource: "/repo/src/foundation/identity", kind: "vm", version: "0.5.2", vmid: 140, node: "tappaas1", environment: "mgmt", imageType: "clone", image: "8080" });
  w("old.json", { moduleSource: "/repo/src/apps/old", kind: "vm", version: "1.0", vmid: 300, status: "archived" });
  return cfg;
}

const CLUSTER_OUT = [
  "@@status",
  JSON.stringify([
    { type: "cluster", name: "hrossen", quorate: 1, nodes: 2 },
    { type: "node", name: "tappaas1", online: 1, ip: "10.0.0.11" },
    { type: "node", name: "tappaas2", online: 1, ip: "10.0.0.12" },
  ]),
  "@@resources",
  JSON.stringify([
    { type: "qemu", vmid: 140, name: "identity", node: "tappaas1", status: "running", maxcpu: 2, maxmem: 4294967296 },
    { type: "qemu", vmid: 8080, name: "tappaas-nixos", node: "tappaas1", status: "stopped", template: 1 },
    { type: "lxc", vmid: 201, name: "scratch", node: "tappaas2", status: "running" },
    { type: "storage", storage: "tanka1", node: "tappaas1" },
  ]),
  "@@ha",
  JSON.stringify([{ sid: "vm:140", state: "started", group: "ha-tappaas1" }]),
  "@@conf /etc/pve/nodes/tappaas1/qemu-server/140.conf",
  "cores: 2\nmemory: 4096\nscsi0: tanka1:vm-140-disk-0,iothread=1,size=32G\nide2: none,media=cdrom\nefidisk0: tanka1:vm-140-disk-1,size=1M\n[snap1]\ncores: 1",
  "@@conf /etc/pve/nodes/tappaas2/lxc/201.conf",
  "cores: 1\nmemory: 512\nrootfs: tankb1:subvol-201-disk-0,size=8G\nunprivileged: 1",
].join("\n");

// ── the parsers ────────────────────────────────────────────────────────
{
  const g = parseGuestConf("cores: 4\nmemory: 8192\nvirtio0: tanka1:vm-1-disk-0,size=10G\nsata1: local:iso/x.iso,media=cdrom\n[s]\ncores: 1");
  check(g.cores === 4 && g.memory === 8192, "conf: cores and memory, the snapshot section ignored");
  check(JSON.stringify(g.disks) === JSON.stringify([{ storage: "tanka1", size: "10G" }]), `conf: disks without the cdrom (${JSON.stringify(g.disks)})`);

  const c = parseClusterProbe(CLUSTER_OUT);
  check(c.quorate === true && c.members.length === 2, "probe: quorum and members");
  check(c.guests.length === 3, `probe: guests only, storage rows skipped (${c.guests.length})`);
  const id = c.guests.find((x) => x.vmid === 140)!;
  check(id.haPolicy === "started/ha-tappaas1" && id.cores === 2 && id.disks?.length === 2, `probe: guest 140 (${JSON.stringify(id)})`);
  check(c.guests.find((x) => x.vmid === 8080)?.template === true, "probe: a template is a template");

  const h = parseHostProbe("os=debian\nosVersion=13\nhostname=tappaas1.mgmt.internal\naddresses=10.0.0.11 fd00::11\npve=9.1.2\npools=tankb1 tanka1 ");
  check(h.os === "debian" && h.osVersion === "13" && h.pveVersion === "9.1.2", "host: os and pve");
  check(JSON.stringify(h.pools) === '["tanka1","tankb1"]' && h.addresses?.length === 2, "host: pools sorted, addresses");
}

// ── report --json ──────────────────────────────────────────────────────
{
  const cfg = fixture();
  const fake = new FakeSiteClient();
  fake.cluster = parseClusterProbe(CLUSTER_OUT);
  fake.cluster.hosts.tappaas1 = parseHostProbe("os=debian\nosVersion=13\nhostname=tappaas1.mgmt.internal\naddresses=10.0.0.11\npve=9.1.2\npools=tanka1");
  let rc = -1;
  const out = capture(() => (rc = run(["report", "--json", "--config-dir", cfg], fake)));
  check(rc === 0, `report --json exits 0 (${rc}: ${out.join("\n")})`);
  let r: Obj = {};
  try {
    r = JSON.parse(out.join("\n"));
  } catch {
    check(false, `report --json prints JSON: ${out.join("\n").slice(0, 300)}`);
  }
  const objs: Obj[] = r.objects ?? [];
  const one = (cls: string, name: string): Obj | undefined => objs.find((o) => o.class === cls && o.name === name);
  const refOf = (cls: string, name: string): string | undefined => one(cls, name)?.ref;
  const rel = (type: string, from: string | undefined, to: string | undefined): boolean =>
    (r.relations ?? []).some((x: Obj) => x.type === type && x.from?.ref === from && x.to?.ref === to);

  check(r.source === "site-manager" && r.kind === "observation", "an observation by site-manager");
  const problems = cmdbProblems(r);
  check(problems.length === 0, `cmdb-controller's metamodel takes it: ${problems.join("; ")}`);
  check(one("site", "hrossen")?.attributes?.code === "hrossen", "the site, by its code");
  check(one("site", "hrossen")?.attributes?.primaryLocation?.ref === refOf("location", "home"), "the site is at its primary location");
  check(one("location", "home")?.attributes?.timezone === "Europe/Copenhagen" && !!one("location", "buddy"), "both locations");
  check(one("cluster", "hrossen")?.attributes?.quorum === true, "the cluster, named by the site code, quorate");

  const m1 = one("machine", "tappaas1");
  check(m1?.attributes?.desired?.file === "tappaas1.json", "a node's desired record is its pvehost instance");
  check(m1?.attributes?.release?.module === "pvehost" && m1?.attributes?.release?.version === "0.3.0", "a node's release is pvehost + version");
  check(m1?.attributes?.os === "debian" && m1?.attributes?.clusterMember === true, "a node's os, cluster member");
  check(JSON.stringify(m1?.attributes?.storagePools) === '["tanka1"]', "a node's pools");
  check(rel("member-of", refOf("machine", "tappaas1"), refOf("cluster", "hrossen")), "machine member-of cluster");
  check(rel("at", refOf("machine", "tappaas1"), refOf("location", "home")), "a node without a location is at the primary one");
  check(rel("at", refOf("machine", "tappaas2"), refOf("location", "buddy")), "a node's own location");
  check(m1?.attributes?.environment?.ref === refOf("environment", "mgmt") && !!one("environment", "mgmt"), "a node serves mgmt, through a stub environment");
  check(objs.findIndex((o) => o.class === "environment") < objs.findIndex((o) => o.class === "machine"), "the stub comes before the objects naming it");
  check(one("app", "pve")?.attributes?.onNode?.ref === refOf("machine", "tappaas1") && one("app", "pve")?.attributes?.version === "9.1.2", "pve is an app on its node");

  const vm = one("vm", "identity");
  check(vm?.attributes?.vmid === 140, "a module's guest is named by the module, keyed by vmid");
  check(vm?.attributes?.desired?.file === "identity.json" && vm?.attributes?.release?.module === "identity", "a module guest's desired and release");
  check(vm?.attributes?.onNode?.ref === refOf("machine", "tappaas1"), "vm runs-on its machine");
  check(vm?.attributes?.template === "tappaas-nixos" && vm?.attributes?.haPolicy === "started/ha-tappaas1", "its template and HA");
  check(JSON.stringify(vm?.attributes?.disks?.[0]) === '{"storage":"tanka1","size":"32G"}', "its disks");
  const tmpl = one("vm", "tappaas-nixos");
  check(!!tmpl && tmpl.attributes?.desired === undefined, "a guest that is no module has no desired record");
  const ct = one("lxc", "scratch");
  check(ct?.attributes?.unprivileged === true && ct?.attributes?.rootfs === "tankb1:subvol-201-disk-0", "an lxc's rootfs and privilege");
  check(!objs.some((o) => o.name === "old"), "an archived module is not reported");
  check(!JSON.stringify(r).includes("null"), "no attribute is null (null would unset it)");
}

// ── no cluster: config only ────────────────────────────────────────────
{
  const cfg = fixture();
  const fake = new FakeSiteClient();
  let rc = -1;
  const out = capture(() => (rc = run(["report", "--json", "--config-dir", cfg], fake)));
  const text = out.filter((l) => !l.includes("[Warning]")).join("\n");
  const r = JSON.parse(text) as Obj;
  check(rc === 0 && out.some((l) => l.includes("no cluster node answered")), "an unreachable cluster warns");
  check(cmdbProblems(r).length === 0, `the metamodel takes the config-only report: ${cmdbProblems(r).join("; ")}`);
  check(r.objects.some((o: Obj) => o.class === "machine" && o.name === "tappaas2") && !r.objects.some((o: Obj) => o.class === "vm"), "config only: nodes, no guests");
}

// ── node reconcile reports what it read ────────────────────────────────
{
  const cfg = fixture();
  const fake = new FakeSiteClient();
  fake.liveNodes = ["tappaas1", "tappaas2"];
  fake.livePools.set("tappaas2", ["tankb1"]);
  const before = process.env.TAPPAAS_CMDB;
  process.env.TAPPAAS_CMDB = "";
  process.env.CMDB_SOCKET = join(cfg, "no.sock");
  try {
    capture(() => run(["node", "reconcile", "--config-dir", cfg], fake));
  } finally {
    process.env.TAPPAAS_CMDB = before;
  }
  const spool = join(cfg, ".cmdb-spool");
  const files = readdirSync(spool).filter((f) => f.endsWith(".json"));
  check(files.length === 1, `node reconcile spools one report when the CMDB is down (${files.length})`);
  const r = JSON.parse(readFileSync(join(spool, files[0]), "utf8")) as Obj;
  check(r.kind === "observation" && r.source === "site-manager", "a side-effect observation");
  check(cmdbProblems(r).length === 0, `the metamodel takes it: ${cmdbProblems(r).join("; ")}`);
  check(r.objects.some((o: Obj) => o.class === "machine" && o.name === "tappaas2" && o.attributes?.storagePools?.[0] === "tankb1"), "with the members and pools it read");
}

console.log(`report: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
