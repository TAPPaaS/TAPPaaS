// module.test.ts — offline unit tests for the module-manager.
//
// No cluster, no bash scripts: a FakeModuleClient records the lifecycle
// invocations, and the CONFIG-layer verbs (list/show/validate) read a fixture
// config tree. Tiny assert harness (no test framework). Run via the test/unit
// tsconfig (see test.sh).

import { join } from "path";
import {
  listModules,
  loadModule,
  resolveDefaultEnvironment,
  resolveEffectiveModuleName,
} from "../../src/config";
import { validateModules } from "../../src/validate";
import { AddOptions, DeleteOptions } from "../../src/types";
import { FakeModuleClient } from "./fake-client";
import { run } from "../../src/main";

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

// Fixtures live in the SOURCE tree (not copied into dist-test). From the
// compiled location dist-test/test/unit/, "../../../test/fixtures/config"
// resolves back to module-manager/test/fixtures/config. test.sh may override
// via MM_FIXTURES_CONFIG.
const CONFIG =
  process.env.MM_FIXTURES_CONFIG ??
  join(__dirname, "..", "..", "..", "test", "fixtures", "config");

// ── 1. listModules enumerates ONLY module configs (filters state files) ──
{
  const mods = listModules(CONFIG);
  const names = mods.map((m) => m.name);
  check(
    names.includes("nextcloud") && names.includes("identity") && names.includes("legacyapp"),
    "list includes deployed module configs",
  );
  check(!names.includes("zones"), "list EXCLUDES zones.json (non-module state file)");
  check(!names.includes("site"), "list EXCLUDES site.json (non-module state file)");
  check(
    names[0] <= names[names.length - 1] && JSON.stringify(names) === JSON.stringify([...names].sort()),
    "list is sorted by name",
  );
  // Provider-only module: `templates` has NO vmid/vmname but IS a module — it
  // must be enumerated (selected by its provides/location), not filtered out.
  const templates = mods.find((m) => m.name === "templates");
  check(templates !== undefined, "list INCLUDES provider-only module 'templates' (no vmid/vmname)");
  check(
    templates !== undefined && templates.vmid == null && templates.provides!.includes("nixos"),
    "vmid-less module is kept with vmid=null and its provides[]",
  );
  // The kind=="module" tag is the authoritative selector (nextcloud carries it).
  check(mods.find((m) => m.name === "nextcloud")?.kind === "module", "kind=module tag is read");
}

// ── 2. loadModule returns the parsed config; missing → null ─────────────
{
  const nc = loadModule(CONFIG, "nextcloud");
  check(nc !== null && nc.vmid === 340 && nc.zone0 === "srvWork", "show/load reads vmid + zone0");
  check(nc !== null && nc.provides!.includes("fileservice"), "show/load reads provides[]");
  check(loadModule(CONFIG, "does-not-exist") === null, "load of a missing module → null");
}

// ── 3. validate: foundation+official passes, foundation+community fails ──
{
  const all = listModules(CONFIG);
  const report = validateModules(all, {});
  // badfork = foundation + community → error
  check(
    report.findings.some(
      (f) => f.module === "badfork" && f.severity === "error" && /requires source:official/.test(f.message),
    ),
    "foundation+community is a lint ERROR",
  );
  check(report.errors >= 1, "validate reports at least one error (badfork)");
  // identity = foundation + official → no error
  check(
    !report.findings.some((f) => f.module === "identity" && f.severity === "error"),
    "foundation+official passes (no error)",
  );
  // legacyapp = no tier → warning, no error
  check(
    report.findings.some(
      (f) => f.module === "legacyapp" && f.severity === "warning" && /defaulting to 'app'/.test(f.message),
    ),
    "tier-less legacy app WARNS (defaults to app)",
  );
}

// ── 4. validate --allow-fork downgrades the foundation-fork error → warn ─
{
  const all = listModules(CONFIG);
  const report = validateModules(all, { allowFork: true });
  check(
    !report.findings.some((f) => f.module === "badfork" && f.severity === "error"),
    "--allow-fork removes the foundation-fork error",
  );
  check(
    report.findings.some((f) => f.module === "badfork" && f.severity === "warning"),
    "--allow-fork turns the foundation fork into a warning",
  );
}

// ── 5. effective-name resolution (env suffix rules) ─────────────────────
{
  // fixture site.json.name = 'acme' → default env is 'acme'.
  check(resolveDefaultEnvironment(CONFIG) === "acme", "default environment = site.json.name");
  check(resolveEffectiveModuleName(CONFIG, "myapp", undefined) === "myapp", "no env → plain name");
  check(resolveEffectiveModuleName(CONFIG, "myapp", "mgmt") === "myapp", "mgmt env → no suffix");
  check(resolveEffectiveModuleName(CONFIG, "myapp", "acme") === "myapp", "default env → no suffix");
  check(resolveEffectiveModuleName(CONFIG, "myapp", "dev") === "myapp-dev", "non-default env → <module>-<env>");
}

// ── 6. add forwards flags to install-module via the client ──────────────
{
  const c = new FakeModuleClient();
  const rc = run(
    ["module", "add", "nextcloud", "--environment", "dev", "--allow-fork", "--node", "tappaas2"],
    c,
  );
  check(rc === 0, "add returns the client rc (0)");
  check(c.log.length === 1 && c.log[0].verb === "add" && c.log[0].module === "nextcloud", "add invoked once for nextcloud");
  const a = c.log[0].opts as AddOptions;
  check(a.environment === "dev" && a.allowFork === true, "add forwards --environment + --allow-fork");
  check(
    a.passthrough.join(" ") === "--node tappaas2",
    "add captures unknown --field/value as passthrough to copy-update-json",
  );
}

// ── 7. delete maps --remove/--force/--yes; mutual-exclusion guard ───────
{
  const c = new FakeModuleClient();
  run(["module", "delete", "nextcloud", "--remove", "--yes"], c);
  const d = c.log[0].opts as DeleteOptions;
  check(d.mode === "remove" && d.yes === true, "delete maps --remove + --yes");

  const c2 = new FakeModuleClient();
  const rc = run(["module", "delete", "nextcloud", "--archive", "--remove"], c2);
  check(rc === 1 && c2.log.length === 0, "delete --archive + --remove is rejected (no invocation)");
}

// ── 8. reconcile is its OWN leaf converge (reconcile-module.sh, NOT modify) ─
{
  const c = new FakeModuleClient();
  run(["module", "reconcile", "nextcloud", "--environment", "foo"], c);
  check(c.log.length === 1 && c.log[0].verb === "reconcile", "reconcile delegates to reconcile-module (NOT update/modify)");
  check(
    (c.log[0].opts as { environment?: string }).environment === "foo",
    "reconcile forwards --environment",
  );
}

// ── 9. snapshot-vm sub-actions map to the right flag ────────────────────
{
  const c = new FakeModuleClient();
  run(["module", "snapshot-vm", "nextcloud", "--cleanup", "3"], c);
  check(c.log[0].verb === "snapshot", "snapshot-vm delegates to the snapshot client");
  const act = c.log[0].opts as { kind: string; keep?: number };
  check(act.kind === "cleanup" && act.keep === 3, "snapshot-vm --cleanup 3 → cleanup action keep=3");

  const c2 = new FakeModuleClient();
  run(["module", "snapshot-vm", "nextcloud"], c2);
  check((c2.log[0].opts as { kind: string }).kind === "create", "bare snapshot-vm → create action");
}

// ── 10. the leading `module` entity keyword is optional ─────────────────
{
  const c = new FakeModuleClient();
  const rc = run(["test", "nextcloud", "--deep"], c); // no `module` prefix
  check(rc === 0 && c.log[0].verb === "test", "verbs work without the `module` entity keyword");
  check((c.log[0].opts as { deep?: boolean }).deep === true, "test forwards --deep");
}

// ── 11. a client failure rc propagates as the process exit code ─────────
{
  const c = new FakeModuleClient();
  c.rc = 2; // simulate install-module.sh failing
  const rc = run(["module", "add", "nextcloud"], c);
  check(rc === 2, "a non-zero script rc propagates back out of run()");
}

// ── 12. list --json emits a machine-readable summary the cascade parses ─
{
  // Capture stdout for the duration of the call.
  const real = console.log;
  let captured = "";
  console.log = (...a: unknown[]): void => {
    captured += a.map(String).join(" ") + "\n";
  };
  let rc: number;
  try {
    rc = run(["module", "list", "--json", "--config-dir", CONFIG], new FakeModuleClient());
  } finally {
    console.log = real;
  }
  check(rc === 0, "list --json returns 0");
  let parsed: Array<{ name: string; vmid: number | null }> = [];
  let ok = true;
  try {
    parsed = JSON.parse(captured);
  } catch {
    ok = false;
  }
  check(ok && Array.isArray(parsed), "list --json output is a JSON array");
  check(
    parsed.some((m) => m.name === "nextcloud" && m.vmid === 340),
    "list --json carries name + vmid per module",
  );
  check(
    parsed.some((m) => m.name === "templates" && m.vmid === null),
    "list --json includes vmid-less provider modules (vmid:null)",
  );
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
