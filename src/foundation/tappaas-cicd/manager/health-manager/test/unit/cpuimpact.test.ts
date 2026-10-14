// cpuimpact.test.ts — the cpu-impact report (#827) against a seeded inventory,
// module configs and AVX-512 probe answers; and the probe parser.

import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkCpuImpact, configField, haCommonCpu } from "../../src/checks";
import { parseAvx512Use } from "../../src/client";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const V3 = ["aes", "avx2"];
const inv = {
  levels: { "x86-64-v3": 15, "x86-64-v4": 20 },
  levelFlags: { "x86-64-v3": V3, "x86-64-v4": [...V3, "avx512f"] },
  nodes: [{ node: "n1", level: "x86-64-v4" }, { node: "n2", level: "x86-64-v4" }, { node: "n3", level: "x86-64-v3" },
          { node: "n4", level: "x86-64-v4" }],
  matrix: [
    { from: "n1", to: "n3", liveSafe: false }, { from: "n3", to: "n1", liveSafe: true },
    { from: "n1", to: "n2", liveSafe: true }, { from: "n2", to: "n1", liveSafe: false },
    { from: "n1", to: "n4", liveSafe: true }, { from: "n4", to: "n1", liveSafe: true },
  ],
};

check(haCommonCpu(inv, "n1", "n3") === "x86-64-v3", "a v4 + v3 pair runs at v3");
check(haCommonCpu(inv, "n1", "n2") === "x86-64-v4", "two v4 nodes with different extras run at v4");
check(haCommonCpu(inv, "n1", "n4") === "host", "a pair safe both ways keeps host");
check(haCommonCpu(inv, "n1", "nx") === null, "an unknown node: no answer");
check(configField({ config: { "m:cluster:ha": { HANode: "n3" } } }, "HANode") === "n3", "a Pattern A field is found");

const u = parseAvx512Use("banner\ncpu 1\nuse 12 gunicorn: worker\nuse 900000 bash\nuse 40 gunicorn: worker\nuse 5 bash\n");
check(u.available && u.recent.join(",") === "bash,gunicorn: worker" && u.earlier.length === 0,
      `probe parsed: recent use wins, names once (${JSON.stringify(u)})`);

const dir = mkdtempSync(join(tmpdir(), "cpuimpact-"));
const mod = (name: string, vmid: number, extra: Record<string, unknown>) =>
  writeFileSync(join(dir, `${name}.json`), JSON.stringify({ vmid, vmname: name, node: "n1", dependsOn: ["cluster:vm", "cluster:ha"], ...extra }));
try {
  writeFileSync(join(dir, "cluster-cpu.json"), JSON.stringify(inv));
  mod("idp", 140, { HANode: "n3" });                 // drops AVX-512 and uses it
  mod("vault", 610, { HANode: "n3" });               // drops it, uses none
  mod("cicd", 130, { HANode: "n2" });                // keeps v4
  mod("fw", 110, { HANode: "n3", haCpu: "host" });   // opted out
  writeFileSync(join(dir, "plain.json"), JSON.stringify({ vmid: 200, vmname: "plain", dependsOn: ["cluster:vm"] }));
  const c = new FakeClusterClient();
  c.avx.set("idp.mgmt.internal", { available: true, recent: ["gunicorn: worker", "systemd"], earlier: [] });
  c.avx.set("vault.mgmt.internal", { available: true, recent: [], earlier: [] });
  const r = checkCpuImpact(c, dir, "n1");
  const row = (m: string) => (r.rows ?? []).find((x) => x.text.startsWith(`${m}:`));
  check(r.status === "warn", `a guest using what its level drops warns (${r.detail})`);
  check(row("idp")?.status === "warn" && /2 process/.test(row("idp")!.text), "…naming how many processes and which");
  check(row("vault")?.status === "pass" && /costs nothing/.test(row("vault")!.text), "a guest using none of it: no cost");
  check(/keeps AVX-512/.test(row("cicd")?.text ?? ""), "a pair at v4 loses nothing measurable");
  check(/haCpu host/.test(row("fw")?.text ?? ""), "haCpu host is reported as keeping the full CPU");
  check(!row("plain"), "a guest without cluster:ha is not assessed");
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
