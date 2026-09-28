// blueprint.test.ts — the ADR-027 blueprint check (#674), against a fake tree.
//
// What it must hold: a missing MUST is an error and a missing SHOULD a warning,
// for every module alike (D5); a service is its D3 set; fields.json is required
// exactly when something declares fields nothing else defines; a directory the
// module does not provide is reported; and test fixtures are not modules.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { BlueprintFinding, BlueprintFs, checkModule, dirTarget, realBlueprintFs, repoTargets, schemaFacts } from "../../src/blueprint";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

// A tree of files: path → content ("" for a script, JSON text for JSON).
function fakeFs(files: Record<string, string>): BlueprintFs {
  const dirs = new Set<string>();
  for (const f of Object.keys(files)) {
    const parts = f.split("/");
    for (let i = 1; i < parts.length; i++) dirs.add(parts.slice(0, i).join("/"));
  }
  return {
    isFile: (p) => p in files,
    isDir: (p) => dirs.has(p),
    list: (d) => [...new Set([...Object.keys(files), ...dirs].filter((p) => p.startsWith(d + "/") && !p.slice(d.length + 1).includes("/")).map((p) => p.slice(d.length + 1)))].sort(),
    readJson: (p) => { try { return JSON.parse(files[p]); } catch { return null; } },
  };
}

const complete = (m: string, extra: Record<string, string> = {}): Record<string, string> => ({
  [`/r/${m}/${m}.json`]: JSON.stringify({ description: "x", stack: "ai", provides: ["api"] }),
  [`/r/${m}/install.sh`]: "", [`/r/${m}/update.sh`]: "", [`/r/${m}/test.sh`]: "",
  [`/r/${m}/README.md`]: "", [`/r/${m}/INSTALL.md`]: "",
  [`/r/${m}/services/api/install-service.sh`]: "", [`/r/${m}/services/api/update-service.sh`]: "",
  [`/r/${m}/services/api/delete-service.sh`]: "", [`/r/${m}/services/api/test-service.sh`]: "",
  [`/r/${m}/services/api/README.md`]: "",
  ...extra,
});
const schema = schemaFacts({ description: {}, stack: {}, vmid: {}, secret: { usedBy: ["app:api"] } })!;
const run = (files: Record<string, string>, m = "app"): BlueprintFinding[] =>
  checkModule({ name: m, dir: `/r/${m}`, moduleJson: `/r/${m}/${m}.json` }, fakeFs(files), schema);
const has = (fs: BlueprintFinding[], sev: string, re: RegExp): boolean => fs.some((f) => f.severity === sev && re.test(f.message));

console.log("checkModule — D2, D3, ADR-013");
{
  const ok: Record<string, string> = { ...complete("app"), "/r/app/services/api/fields.json": "{}" };
  check(run(ok).length === 0, "a complete module reports nothing");

  const noUpdate = { ...ok }; delete noUpdate["/r/app/update.sh"];
  check(has(run(noUpdate), "error", /missing update\.sh/), "missing update.sh (MUST) is an error");
  const noTest = { ...ok }; delete noTest["/r/app/test.sh"];
  const nt = run(noTest);
  check(has(nt, "warning", /missing test\.sh/) && !nt.some((f) => f.severity === "error"), "missing test.sh (SHOULD) is only a warning");
  const noInstallMd = { ...ok }; delete noInstallMd["/r/app/INSTALL.md"];
  check(has(run(noInstallMd), "error", /INSTALL\.md.*ADR-013/), "INSTALL.md is ADR-013's, reported by its rule");

  const noDir = { ...ok, "/r/app/app.json": JSON.stringify({ stack: "ai", provides: ["api", "extra"] }) };
  check(has(run(noDir), "error", /provides 'extra' but has no services\/extra\//), "a provided service without a directory is an error");
  const extraDir = { ...ok, "/r/app/services/old/install-service.sh": "" };
  check(has(run(extraDir), "warning", /services\/old\/ is not a service app provides/), "a directory for a service not provided is a warning");

  const noDelete = { ...ok }; delete noDelete["/r/app/services/api/delete-service.sh"];
  check(has(run(noDelete), "error", /services\/api\/delete-service\.sh/), "a service without delete-service.sh is an error");
  const noSvcTest = { ...ok }; delete noSvcTest["/r/app/services/api/test-service.sh"];
  check(has(run(noSvcTest), "warning", /services\/api\/test-service\.sh/), "a service without test-service.sh is a warning");
  const noSvcReadme = { ...ok }; delete noSvcReadme["/r/app/services/api/README.md"];
  check(has(run(noSvcReadme), "error", /services\/api\/README\.md/), "a service without README.md is an error");
}

console.log("checkModule — the fields.json rules");
{
  check(has(run(complete("app")), "error", /services\/api\/fields\.json.*usedBy/), "a service a field names in usedBy needs fields.json");
  const other = run(complete("other"), "other");
  check(!other.some((f) => /fields\.json/.test(f.message)), "a service no field names needs no fields.json");
  const own = { ...complete("app", { "/r/app/services/api/fields.json": "{}" }), "/r/app/app.json": JSON.stringify({ stack: "ai", provides: ["api"], widgetColour: "red", config: { "cluster:vm": { cores: 2 } } }) };
  const f = run(own);
  check(has(f, "error", /declares 'cores', 'widgetColour', which no schema defines/), "a field no tier defines means the module must ship fields.json");
  check(run({ ...own, "/r/app/fields.json": "{}" }).length === 0, "…and with fields.json it is satisfied");
  check(!run({ ...own, "/r/app/app.json": JSON.stringify({ stack: "ai", provides: ["api"], _note: "doc" }) }).some((x) => /_note/.test(x.message)), "`_` keys are documentation, not fields (D4)");
  const sat = checkModule({ name: "app", dir: "/r/app", moduleJson: "/r/app/app.json" }, fakeFs(own),
    schemaFacts({ description: {}, stack: {} }, ["/s"], fakeFs({ "/s/app-fields.json": "{}" })));
  check(!sat.some((x) => /widgetColour/.test(x.message)), "a module with schemas/<module>-fields.json defines its fields there (the satellite)");
  const noSchema = checkModule({ name: "app", dir: "/r/app", moduleJson: "/r/app/app.json" }, fakeFs(own), null);
  check(!noSchema.some((x) => /fields\.json/.test(x.message)), "no schema available → the fields rules are skipped, not guessed");
}

console.log("repoTargets / dirTarget");
{
  const files = {
    "/repo/src/module-catalog.json": JSON.stringify({ modules: [
      { moduleName: "templates", moduleJson: "src/foundation/templates/templates.json", stack: "foundation" },
      { moduleName: "tappaas-nixos", moduleJson: "src/foundation/templates/tappaas-nixos.json", stack: "template" },
      { moduleName: "template", moduleJson: "src/apps/00-Template/template.json", stack: "template" },
      { moduleName: "test-debian", moduleJson: "src/foundation/test-debian/test-debian.json", stack: "test" },
      { moduleName: "app", moduleJson: "src/apps/app/app.json", stack: "ai" },
    ] }),
    "/repo/src/foundation/templates/templates.json": "{}",
    "/repo/src/apps/00-Template/template.json": "{}",
  };
  const r = repoTargets("/repo", "/repo/src/module-catalog.json", fakeFs(files));
  const names = r.targets.map((t) => t.name).sort().join(",");
  check(names === "app,template,templates", `one target per module directory; fixtures skipped (${names})`);
  check(r.targets.find((t) => t.name === "templates")?.moduleJson.endsWith("templates/templates.json") === true,
    "a directory shared with the VM templates it builds is checked as the module named after it");
  check(r.targets.find((t) => t.name === "template")?.moduleJson.endsWith("00-Template/template.json") === true, "00-Template is checked (D6)");
  const legacy = repoTargets("/c", "/c/src/module-catalog.json", fakeFs({ "/c/src/module-catalog.json": JSON.stringify({
    applicationModules: [{ moduleName: "hue", moduleJson: "src/x/hue/hue.json" }], testModules: [{ moduleName: "t", moduleJson: "src/t/t.json" }] }) }));
  check(legacy.targets.length === 1 && legacy.targets[0].name === "hue", "the legacy catalogue shape is read, its test list skipped");
  check(repoTargets("/none", "/none/x.json", fakeFs({})).problem !== "", "no catalogue is reported, not an empty pass");
  check(dirTarget("/r/app", fakeFs(complete("app")))?.moduleJson === "/r/app/app.json", "a directory names its module by <dir>.json");
}

console.log("realBlueprintFs, on a real tree");
{
  const d = mkdtempSync(join(tmpdir(), "bp-"));
  mkdirSync(join(d, "m", "services", "s"), { recursive: true });
  writeFileSync(join(d, "m", "m.json"), JSON.stringify({ stack: "ai", provides: ["s"] }));
  const f = checkModule({ name: "m", dir: join(d, "m"), moduleJson: join(d, "m", "m.json") }, realBlueprintFs, null);
  check(f.filter((x) => x.severity === "error").length === 8 && f.filter((x) => x.severity === "warning").length === 2,
    `an empty module on disk: 8 errors, 2 warnings (${f.length})`);
  rmSync(d, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
