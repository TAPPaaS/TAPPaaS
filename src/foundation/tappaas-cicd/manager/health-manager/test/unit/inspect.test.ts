// inspect.test.ts — offline unit tests for the read-only inspection + health-gate
// logic. No SSH, no Proxmox; a FakeClusterClient holds in-memory cluster state.
// Tiny assert harness (no test framework). Run via test/unit tsconfig (see test.sh).

import { existsSync, mkdtempSync, writeFileSync } from "fs";
import { join } from "path";
import { clusterDiff, inspectCluster, inspectVm } from "../../src/inspect";
import { checkDiskThreshold, checkServiceLiveness } from "../../src/checks";
import { siteNodeHostnames } from "../../src/config";
import { RunningGuest } from "../../src/types";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

// Compiled output lives under dist-test/test/unit, so the source fixtures are
// not beside __dirname. Walk up until we find test/fixtures (works whether run
// from src or the dist-test mirror).
function findFixtures(): string {
  for (const up of ["..", "../..", "../../..", "../../../.."]) {
    const cand = join(__dirname, up, "test", "fixtures", "config");
    if (existsSync(cand)) return cand;
    const cand2 = join(__dirname, up, "fixtures", "config");
    if (existsSync(cand2)) return cand2;
  }
  return join(__dirname, "..", "fixtures", "config");
}
const FIXTURES = findFixtures();
const GIT_SRC = join(FIXTURES, "..", "git-src");

function guest(vmid: number, name: string, status: string, type: "qemu" | "lxc" = "qemu"): RunningGuest {
  return { vmid, name, node: "tappaas1", status, type };
}

// ── list vm (= inspect-cluster.sh) ────────────────────────────────────
function testInspectCluster(): void {
  const c = new FakeClusterClient();
  // 311 = managed (in config), 999 = not in config, 320 (archived) absent.
  c.guests = [guest(311, "nextcloud", "running"), guest(999, "stray", "running")];
  const insp = inspectCluster(c, FIXTURES, "tappaas1");

  const nc = insp.rows.find((r) => r.vmid === 311);
  check(nc?.config === "managed", "running VM 311 classified managed");
  const stray = insp.rows.find((r) => r.vmid === 999);
  check(stray?.config === "not-in-config", "running VM 999 classified not-in-config");
  check(insp.warnings === 1, "one running-but-not-in-config warning");

  // legacy-vm (320) is archived in config and NOT running → reported, not missing.
  const arch = insp.missing.find((m) => m.vmid === 320);
  check(arch?.kind === "archived", "archived config module reported as archived");
  check(insp.missingCount === 0, "archived module does not count as missing");

  // site.json (no vmid) must be skipped entirely.
  check(!insp.missing.some((m) => m.module === "site"), "site.json (no vmid) skipped");
}

// ── show vm <name> (= inspect-vm.sh three-way drift) ──────────────────
function testInspectVm(): void {
  // Build a config dir whose nextcloud.json points `location` at the git-src
  // fixture (absolute), so resolveGitJson finds the Released column.
  const dir = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "health-vm-"));
  const gitSrc = GIT_SRC;
  writeFileSync(
    join(dir, "nextcloud.json"),
    JSON.stringify({
      vmname: "nextcloud",
      vmid: "311",
      node: "tappaas1",
      cores: "4", // DESIRED differs from git (2) → config drift (warn)
      memory: "4096",
      diskSize: "32G",
      bios: "ovmf",
      cputype: "host",
      location: gitSrc,
    }),
  );

  const c = new FakeClusterClient();
  c.configs.set("tappaas1/311", {
    name: "nextcloud",
    cores: "8", // ACTUAL differs from desired (4) → VM drift (error)
    memory: "4096",
    scsi0: "tanka1:vm-311-disk-0,size=32G",
    bios: "ovmf",
    cpu: "host",
  });
  c.statuses.set("tappaas1/311", "running");
  c.actualNodes.set("tappaas1/311", "tappaas1");

  const insp = inspectVm(c, dir, "nextcloud");
  const cores = insp.rows.find((r) => r.field === "cores");
  check(cores?.released === "2" && cores?.desired === "4" && cores?.actual === "8", "cores three-way values surfaced");
  check(cores?.level === "error", "cores actual!=desired → error (VM drift)");

  const mem = insp.rows.find((r) => r.field === "memory");
  check(mem?.level === "ok", "memory matches all three → ok");

  const disk = insp.rows.find((r) => r.field === "diskSize");
  check(disk?.actual === "32G", "diskSize parsed from scsi0 size=");

  check(insp.errors >= 1, "at least one error counted");
}

// ── validate gates (= check-disk-threshold / service-liveness) ────────
function testGates(): void {
  const c = new FakeClusterClient();
  // service-liveness: nextcloud (311) configured + running → pass.
  c.guests = [guest(311, "nextcloud", "running")];
  const live = checkServiceLiveness(c, FIXTURES, "tappaas1");
  check(live.status === "pass", "service-liveness pass when managed module running");

  // now stop it → fail.
  c.guests = [];
  const dead = checkServiceLiveness(c, FIXTURES, "tappaas1");
  check(dead.status === "fail", "service-liveness fail when managed module not running");

  // disk-threshold: nextcloud target over threshold → fail; unreachable → skip.
  c.diskUsage.set("nextcloud.mgmt.internal", 95);
  const over = checkDiskThreshold(c, FIXTURES, "tappaas1", 80);
  check(over.status === "fail", "disk-threshold fail when a guest is over threshold");

  const c2 = new FakeClusterClient(); // no disk answers → all unreachable
  const skip = checkDiskThreshold(c2, FIXTURES, "tappaas1", 80);
  check(skip.status === "skip", "disk-threshold skip when no guest reachable");
}

// ── list vm --diff (= clusterDiff three-way rollup) ───────────────────
function testClusterDiff(): void {
  // Stage a config dir with TWO managed modules + one archived (skipped) one.
  const dir = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "health-diff-"));
  writeFileSync(
    join(dir, "nextcloud.json"),
    JSON.stringify({ vmname: "nextcloud", vmid: "311", node: "tappaas1", cores: "4", location: GIT_SRC }),
  );
  writeFileSync(
    join(dir, "clean.json"),
    JSON.stringify({ vmname: "clean", vmid: "312", node: "tappaas1", cores: "2" }),
  );
  writeFileSync(
    join(dir, "legacy-vm.json"),
    JSON.stringify({ vmname: "legacy-vm", vmid: "320", node: "tappaas1", status: "archived" }),
  );

  const c = new FakeClusterClient();
  // nextcloud: live cores 8 != cfg 4 → 1 error; cfg 4 != git 2 → 1 warn.
  c.configs.set("tappaas1/311", { name: "nextcloud", cores: "8" });
  c.statuses.set("tappaas1/311", "running");
  // clean: live matches cfg, no git → ok.
  c.configs.set("tappaas1/312", { name: "clean", cores: "2" });
  c.statuses.set("tappaas1/312", "running");
  // (320 archived → must be excluded from the managed rollup)

  const diff = clusterDiff(c, dir, "tappaas1");
  check(diff.vms.length === 2, "rollup covers exactly the 2 managed VMs (archived excluded)");
  check(diff.errors >= 1, "rollup totals at least one live-vs-config error");
  check(diff.warnings >= 1, "rollup totals at least one config-vs-git warning");
  check(diff.unreachable.length === 0, "no unreachable VMs in the rollup");

  // A managed VM with no fake qm config → collected as unreachable, not a throw.
  writeFileSync(join(dir, "ghost.json"), JSON.stringify({ vmname: "ghost", vmid: "999", node: "tappaas9" }));
  const diff2 = clusterDiff(c, dir, "tappaas1");
  check(diff2.unreachable.some((u) => u.module === "ghost"), "unqueryable managed VM degrades to unreachable");
}

// ── site.json node source (Q8) ────────────────────────────────────────
function testSiteNodes(): void {
  const dir = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "health-site-"));
  writeFileSync(
    join(dir, "site.json"),
    JSON.stringify({ name: "s", hardware: { nodes: [{ name: "tappaas1" }, { name: "tappaas2" }] } }),
  );
  const nodes = siteNodeHostnames(dir);
  check(nodes.length === 2 && nodes[0] === "tappaas1" && nodes[1] === "tappaas2", "site.json node hostnames read");

  const empty = mkdtempSync(join(process.env.TMPDIR ?? "/tmp", "health-nosite-"));
  check(siteNodeHostnames(empty).length === 0, "no site.json → empty list (caller falls back to scan)");
}

console.log("health-manager inspect/gate unit tests");
check(existsSync(FIXTURES), "fixtures present");
testInspectCluster();
testInspectVm();
testGates();
testClusterDiff();
testSiteNodes();

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
