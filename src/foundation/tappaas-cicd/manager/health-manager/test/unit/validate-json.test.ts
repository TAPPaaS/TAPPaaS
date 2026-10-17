// validate-json.test.ts — `validate --json` (ADR-034): every gate typed, each
// finding naming the module, node, pool or peer it is about, so the console can
// put it on that object. Offline: FakeClusterClient, a temp config dir.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkGuestMemory, checkLanUplink, checkPulse, checkServiceLiveness, pulseSubject, runHealthGates } from "../../src/checks";
import { validateDoc } from "../../src/main";
import { CheckSubject, NodeCapacity } from "../../src/types";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const G = 1024 ** 3;
const same = (a: CheckSubject | undefined | null, kind: string, name: string): boolean =>
  !!a && a.kind === kind && a.name === name;

const dir = mkdtempSync(join(tmpdir(), "hm-json-"));
writeFileSync(join(dir, "immich.json"), JSON.stringify({ vmname: "immich", vmid: 361, node: "tappaas1", zone0: "rossen" }));
writeFileSync(join(dir, "jellyfin.json"), JSON.stringify({ vmname: "jellyfin", vmid: 360, node: "tappaas1", zone0: "rossen" }));
writeFileSync(join(dir, "backup.json"), JSON.stringify({ node: "tappaas3" }));
writeFileSync(join(dir, "site.json"), JSON.stringify({ hardware: { nodes: [{ name: "tappaas1" }, { name: "tappaas3" }] } }));

const capacity = (): NodeCapacity[] => [{
  node: "tappaas1", physicalMem: 61 * G, usedMem: 40 * G, committedMem: 20 * G,
  guests: [
    { vmid: 361, name: "immich", node: "tappaas1", status: "running", type: "qemu", declaredMem: 8 * G, usedMem: 7.7 * G, residentMem: 8 * G, measured: true },
    { vmid: 360, name: "jellyfin", node: "tappaas1", status: "running", type: "qemu", declaredMem: 8 * G, usedMem: 2 * G, residentMem: 4 * G, measured: true },
  ],
}];

// ── a row-per-subject gate: the subject rides on each row ─────────────
{
  const c = new FakeClusterClient();
  c.capacity = capacity();
  const r = checkGuestMemory(c);
  const immich = (r.rows ?? []).find((x) => same(x.subject, "module", "immich"));
  check(r.status === "fail", "guest-memory fails on a module at 96% of its memory");
  check(immich?.status === "fail", "immich's row is the failing one, and names immich");
  check((r.rows ?? []).some((x) => x.text.startsWith("── VM totals") && x.subject === undefined), "a totals row names no subject");
}

// ── a gate whose detail carries the objects gets per-object findings ──
{
  const c = new FakeClusterClient();
  c.guests = [{ vmid: 360, name: "jellyfin", node: "tappaas1", status: "running", type: "qemu" }];
  const r = checkServiceLiveness(c, dir, "tappaas1");
  check(r.status === "fail" && r.detail === "not running: immich", "service-liveness text is unchanged");
  check(r.rows === undefined, "…and still prints no rows");
  check((r.findings ?? []).length === 1 && same(r.findings![0].subject, "module", "immich"), "…but its finding names immich");
}

// ── a fabric gate: the node ──────────────────────────────────────────
{
  const c = new FakeClusterClient();
  c.nodes = ["tappaas1"];
  c.uplinks.set("tappaas1", {
    mode: "lacp", ports: ["nic2", "nic3"],
    findings: [{ level: "warn", text: "every leg reaches the same switch (USW-Pro-XG-10-PoE)" }],
  });
  const r = checkLanUplink(c);
  check(r.status === "warn" && same(r.rows?.[0].subject, "node", "tappaas1"), "lan-uplink's finding names its node");
}

// ── the pulse: own parts by role, a buddy by name ─────────────────────
{
  check(same(pulseSubject("firewall"), "module", "network"), "pulse firewall → module network");
  check(same(pulseSubject("mothership"), "module", "tappaas-cicd"), "pulse mothership → module tappaas-cicd");
  check(same(pulseSubject("pulled-by-rasmus"), "peer", "rasmus"), "pulse pulled-by-rasmus → peer rasmus");
  check(same(pulseSubject("uplink"), "site", "uplink"), "pulse uplink → the site");
  const c = new FakeClusterClient();
  c.nodes = ["tappaas3"];
  c.pulseState = { timer: "active", targets: [{ id: "pbs", state: "up" }, { id: "pulled-by-rasmus", state: "DOWN" }] };
  const r = checkPulse(c, dir);
  const rasmus = (r.findings ?? []).find((f) => same(f.subject, "peer", "rasmus"));
  check(r.status === "warn" && rasmus?.status === "warn", "a DOWN buddy is a warn finding on that peer");
}

// ── the document: every gate, typed ───────────────────────────────────
{
  const c = new FakeClusterClient();
  c.capacity = capacity();
  c.guests = [{ vmid: 360, name: "jellyfin", node: "tappaas1", status: "running", type: "qemu" }];
  const report = runHealthGates(c, { configDir: dir, defaultNode: "tappaas1", threshold: 80, memoryThreshold: 100 });
  const doc = validateDoc(report, new Date("2026-10-17T18:00:00Z")) as {
    version: number; generated: string; status: string; failed: number;
    gates: { name: string; status: string; detail: string; findings: { status: string; text: string; subject: CheckSubject | null }[] }[];
  };
  const parsed = JSON.parse(JSON.stringify(doc)) as typeof doc;
  check(parsed.version === 1 && parsed.generated === "2026-10-17T18:00:00.000Z", "the document is versioned and dated");
  check(parsed.gates.length === report.checks.length, `every gate is in it (${parsed.gates.length})`);
  check(parsed.gates.map((g) => g.name).join(",") === report.checks.map((g) => g.name).join(","), "…in validate's order");
  check(parsed.status === "fail" && parsed.failed === report.failed, "its status is the worst gate's; failed matches the text count");
  check(parsed.gates.every((g) => Array.isArray(g.findings)), "every gate has a findings array, empty or not");
  const gm = parsed.gates.find((g) => g.name === "guest-memory");
  check(!!gm?.findings.some((f) => f.status === "fail" && same(f.subject, "module", "immich")), "immich's memory FAIL is a finding on immich");
  check(parsed.gates.every((g) => g.findings.every((f) => f.subject === null || typeof f.subject.name === "string")), "a finding's subject is null or named");
}

console.log(`\nvalidate-json: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
