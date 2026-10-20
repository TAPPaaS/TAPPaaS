// controlplane.test.ts — the control-plane-trust gate (ADR-035 D7): no registry,
// standard components only, a verified module controller, an unverified one in
// a foundation manager (warned, one row), and one plugging into a module's own.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkControlPlaneTrust } from "../../src/controlplane";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const std = [
  { name: "switch-manager", kind: "manager", module: "tappaas-cicd" },
  { name: "ap-manager", kind: "manager", module: "tappaas-cicd" },
];
function dir(components: object[]): string {
  const d = mkdtempSync(join(tmpdir(), "hm-cp-"));
  writeFileSync(join(d, "control-plane.json"), JSON.stringify({ version: 1, components }));
  return d;
}
const unifi = { name: "unifi-controller", kind: "controller", module: "unifi-os", repository: "Community", plugsInto: ["switch-manager", "ap-manager"], instances: ["unifi-os"] };

{
  const r = checkControlPlaneTrust(mkdtempSync(join(tmpdir(), "hm-cp-")));
  check(r.status === "skip", "no registry — skip");
}
{
  const r = checkControlPlaneTrust(dir(std));
  check(r.status === "pass" && r.detail === "no component from a module", "standard components only — pass");
}
{
  const r = checkControlPlaneTrust(dir([...std, { ...unifi, verified: true }]));
  check(r.status === "pass" && (r.rows ?? []).length === 0, "a verified module controller — pass");
}
{
  const r = checkControlPlaneTrust(dir([...std, { ...unifi, verified: false }]));
  check(r.status === "warn", "an unverified controller in a foundation manager — warn");
  check((r.rows ?? []).length === 1 && /unifi-controller.*Community.*plugs into switch-manager, ap-manager/.test(r.rows![0].text), `…one row naming it, its repository and the managers (${r.rows?.[0]?.text})`);
  check(r.rows?.[0]?.subject?.name === "unifi-os", "…about the module instance");
}
{
  const r = checkControlPlaneTrust(dir([...std, { name: "foo-manager", kind: "manager", module: "foo" },
    { name: "bar-controller", kind: "controller", module: "foo", verified: false, plugsInto: ["foo-manager"] }]));
  check(r.status === "pass", "an unverified controller in a module's own manager — pass");
}

console.log(`controlplane: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
