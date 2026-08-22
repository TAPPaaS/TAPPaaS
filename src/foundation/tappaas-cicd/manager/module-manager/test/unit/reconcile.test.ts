// reconcile.test.ts — offline unit tests for the leaf converge
// (`module reconcile --apply`, src/reconcile.ts).
//
// #495 shipped with NO coverage for this path at all, which is why three
// defects in it went unnoticed. Everything here runs against throwaway temp
// fixtures: a config dir (TAPPAAS_CONFIG), a module dir with an update.sh, and
// provider dirs holding recording stub service scripts. No cluster, no VMs.
//
// The stubs record their argv AND their working directory, which is what lets
// the cwd contract (#495) be asserted directly.

import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { reconcileModule } from "../../src/reconcile";

// The provider entry point reconcile invokes. Step 3 of the #495 work flips this
// from install-service.sh (create semantics — wrong for an already-installed
// module) to update-service.sh (the converge). Kept as one constant so the
// switch is a single, reviewable line here as well.
const SERVICE_SCRIPT = "update-service.sh";

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

const ROOT = mkdtempSync(join(tmpdir(), "mm-reconcile-"));
const CONFIG = join(ROOT, "config");
mkdirSync(CONFIG, { recursive: true });

// Every stub appends "<label>|<argv>|<cwd>" to this log.
const LOG = join(ROOT, "calls.log");

function stub(path: string, label: string, exitCode = 0): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(
    path,
    `#!/usr/bin/env bash\nprintf '%s|%s|%s\\n' "${label}" "$*" "$PWD" >> "${LOG}"\nexit ${exitCode}\n`,
  );
  chmodSync(path, 0o755);
}

function calls(): string[] {
  if (!existsSync(LOG)) return [];
  return readFileSync(LOG, "utf8").trim().split("\n").filter(Boolean);
}

function resetLog(): void {
  if (existsSync(LOG)) rmSync(LOG);
}

// A provider module: <root>/providers/<name>, registered in the config dir so
// resolveProviderModule()/getModuleDir() can find it via .location.
function makeProvider(name: string, services: { svc: string; exit?: number; kind?: string }[]): string {
  const dir = join(ROOT, "providers", name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(CONFIG, `${name}.json`), JSON.stringify({ location: dir }, null, 2));
  for (const s of services) {
    const kind = s.kind ?? SERVICE_SCRIPT;
    stub(join(dir, "services", s.svc, kind), `${name}:${s.svc}:${kind}`, s.exit ?? 0);
  }
  return dir;
}

// A consuming module: <root>/modules/<name> with an update.sh, plus its config.
function makeModule(name: string, dependsOn: string[], opts: { updateExit?: number } = {}): string {
  const dir = join(ROOT, "modules", name);
  mkdirSync(dir, { recursive: true });
  stub(join(dir, "update.sh"), `${name}:update.sh`, opts.updateExit ?? 0);
  writeFileSync(
    join(CONFIG, `${name}.json`),
    JSON.stringify({ location: dir, dependsOn, vmid: 900, vmname: name }, null, 2),
  );
  return dir;
}

const OPTS = { silent: false, debug: false } as const;

// Reconcile reads the config root from TAPPAAS_CONFIG (the canonical override).
process.env.TAPPAAS_CONFIG = CONFIG;

// ── 1. happy path: dependency services then the module's own update.sh ──
{
  resetLog();
  makeProvider("prov", [{ svc: "thing" }]);
  const moduleDir = makeModule("app-a", ["prov:thing"]);
  const rc = reconcileModule("app-a", { ...OPTS });
  const c = calls();
  check(rc === 0, "happy path exits 0");
  check(
    c.some((l) => l.startsWith(`prov:thing:${SERVICE_SCRIPT}|app-a|`)),
    `Step 2 calls the provider's ${SERVICE_SCRIPT} with the consuming module name`,
  );
  check(
    c.some((l) => l.startsWith("app-a:update.sh|app-a|")),
    "Step 3 runs the module's own update.sh",
  );
  const depCall = c.find((l) => l.startsWith("prov:thing:"))!;
  const updCall = c.find((l) => l.startsWith("app-a:update.sh"))!;
  check(c.indexOf(depCall) < c.indexOf(updCall), "Step 2 runs before Step 3");
  // #495: the dependency script must run FROM the module directory, exactly as
  // update-module.sh has always done. Asserting the recorded $PWD is the whole
  // point — the cwd dependency is what broke templates:nixos.
  check(
    depCall.endsWith(`|${moduleDir}`),
    "Step 2 runs dependency services from the module directory (#495)",
  );
  check(updCall.endsWith(`|${moduleDir}`), "Step 3 runs update.sh from the module directory");
}

// ── 2. #495: a failing dependency must NOT skip Step 3 ──────────────────
// The regression that damaged a live instance: templates:nixos rebuilt the VM,
// cluster:vm then failed, and reconcile aborted before the module's update.sh
// could restore what the rebuild dropped.
{
  resetLog();
  makeProvider("badprov", [{ svc: "boom", exit: 1 }]);
  makeModule("app-b", ["badprov:boom"]);
  const rc = reconcileModule("app-b", { ...OPTS });
  const c = calls();
  check(rc === 1, "a failed dependency service still makes reconcile exit 1");
  check(
    c.some((l) => l.startsWith("app-b:update.sh|app-b|")),
    "Step 3 STILL runs after a Step 2 failure (#495 — never leave the module less converged)",
  );
}

// ── 3. every dependency is attempted; one failure does not stop the rest ─
{
  resetLog();
  makeProvider("p1", [{ svc: "a", exit: 1 }]);
  makeProvider("p2", [{ svc: "b" }]);
  makeModule("app-c", ["p1:a", "p2:b"]);
  const rc = reconcileModule("app-c", { ...OPTS });
  const c = calls();
  check(rc === 1, "one failing dependency of two exits 1");
  check(
    c.some((l) => l.startsWith(`p2:b:${SERVICE_SCRIPT}|`)),
    "a later dependency still runs after an earlier one failed",
  );
  check(c.some((l) => l.startsWith("app-c:update.sh|")), "Step 3 runs with a partial Step 2 failure");
}

// ── 4. a provider with no service script is skipped, not fatal ─────────
// reconcile must tolerate a dependency whose provider ships no service script
// (several dependsOn entries name providers with no services/ directory at all).
{
  resetLog();
  makeProvider("noservice", []);
  makeModule("app-d", ["noservice:nothing"]);
  const rc = reconcileModule("app-d", { ...OPTS });
  check(rc === 0, `a provider with no ${SERVICE_SCRIPT} is skipped, not a failure`);
  check(
    calls().some((l) => l.startsWith("app-d:update.sh|")),
    "Step 3 still runs when a dependency was skipped",
  );
}

// ── 5. module's own update.sh failing is fatal ──────────────────────────
{
  resetLog();
  makeProvider("okprov", [{ svc: "s" }]);
  makeModule("app-e", ["okprov:s"], { updateExit: 3 });
  const rc = reconcileModule("app-e", { ...OPTS });
  check(rc === 1, "a failing module update.sh exits 1");
}

// ── 6. an uninstalled module is refused before anything runs ────────────
{
  resetLog();
  const rc = reconcileModule("not-installed-at-all", { ...OPTS });
  check(rc === 1, "reconcile of a module with no config exits 1");
  check(calls().length === 0, "nothing is executed for an uninstalled module");
}

// ── 7. no dependsOn: Step 3 alone ───────────────────────────────────────
{
  resetLog();
  makeModule("app-f", []);
  const rc = reconcileModule("app-f", { ...OPTS });
  check(rc === 0, "a module with no dependencies reconciles");
  check(calls().length === 1 && calls()[0].startsWith("app-f:update.sh|"), "only Step 3 runs");
}

rmSync(ROOT, { recursive: true, force: true });
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
