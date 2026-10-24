// zone-environment.test.ts — a module's zone0 against its environment (#876):
// a shared service zone (a Service zone whose `environment` is a list) is a
// valid zone0 for a module of any environment it lists, and refused for one
// it does not list.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { validateModules, zoneEnvironmentRefusal } from "../../src/validate";
import { ModuleConfig } from "../../src/types";

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

// Erik's shape: gridtefy and acmeco each have a zone of their own; srvWork
// serves both.
const cfg = mkdtempSync(join(tmpdir(), "mm-zone-env-"));
writeFileSync(join(cfg, "zones.json"), JSON.stringify({
  mgmt: { type: "Management", environment: "mgmt" },
  gridtefy: { type: "Service", environment: "gridtefy" },
  acmeco: { type: "Service", environment: "acmeco" },
  erik: { type: "Service", environment: "erik" },
  srvWork: { type: "Service", environment: ["gridtefy", "acmeco"] },
  work: { type: "Client", environment: ["gridtefy", "acmeco"] },
}));
const mod = (zone0: string, environment: string): ModuleConfig =>
  ({ name: `m-${environment}`, stack: "apps", zone0, environment, raw: { zone0, environment } }) as ModuleConfig;

check(zoneEnvironmentRefusal(cfg, mod("srvWork", "gridtefy")) === null, "zone0 srvWork for a module of gridtefy, which it lists, is accepted");
check(zoneEnvironmentRefusal(cfg, mod("srvWork", "acmeco")) === null, "…and for a module of acmeco");
check(zoneEnvironmentRefusal(cfg, mod("gridtefy", "gridtefy")) === null, "the environment's own zone is accepted");
const no = zoneEnvironmentRefusal(cfg, mod("srvWork", "erik"));
check(no !== null && no.includes("shared service zone serving gridtefy, acmeco") && no.includes("'erik'"),
  "zone0 srvWork for a module of erik, which it does not list, is refused");
check(zoneEnvironmentRefusal(cfg, mod("nosuch", "erik")) === null && zoneEnvironmentRefusal(cfg, { name: "x" } as ModuleConfig) === null,
  "a zone it cannot judge, or a module without zone0/environment, is left to the other checks");

const r = validateModules([mod("srvWork", "gridtefy"), mod("srvWork", "erik")], { configDir: cfg });
const zoneErrs = r.findings.filter((f) => f.severity === "error" && f.message.includes("shared service zone"));
check(zoneErrs.length === 1 && zoneErrs[0].module === "m-erik", "module validate reports only the module whose environment the shared zone does not serve");

console.log(`\nzone-environment: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
