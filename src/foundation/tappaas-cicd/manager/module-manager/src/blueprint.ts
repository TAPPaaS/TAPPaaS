// blueprint.ts — the ADR-027 blueprint check (#674): is a module made of what a
// module is made of?
//
// It reads a module's SOURCE directory, never a deployed config, and reports:
//
//   D2  the module's own artifacts   <module>.json, install.sh, update.sh (MUST),
//                                    test.sh (SHOULD), fields.json (MUST when the
//                                    module declares a field nothing else defines),
//                                    services/<s>/ for every service it provides
//   D3  each services/<s>/           install-, update-, delete-service.sh and
//                                    README.md (MUST), test-service.sh (SHOULD),
//                                    fields.json (MUST when a field names the
//                                    service in its usedBy)
//   ADR-013  README.md and INSTALL.md, mandatory for catalogue inclusion
//
// A missing MUST is an error and a missing SHOULD a warning — the same for every
// module, whatever its stack and whoever wrote it (D5). The check runs in
// `module-manager validate --blueprint` and at the release boundary (tappaas-train);
// an install never runs it, so
// it can never fail a user's install.
//
// Pure: every filesystem question goes through BlueprintFs, so the unit tests
// hand it a fake tree.

import { readFileSync, readdirSync, statSync } from "fs";
import { basename, dirname, join } from "path";

export type Severity = "error" | "warning";

export interface BlueprintFinding {
  module: string;
  severity: Severity;
  path: string; // relative to the module directory
  message: string;
}

export interface BlueprintFs {
  isFile(p: string): boolean;
  isDir(p: string): boolean;
  list(dir: string): string[];
  readJson(p: string): Record<string, unknown> | null;
}

export const realBlueprintFs: BlueprintFs = {
  isFile: (p) => {
    try {
      return statSync(p).isFile();
    } catch {
      return false;
    }
  },
  isDir: (p) => {
    try {
      return statSync(p).isDirectory();
    } catch {
      return false;
    }
  },
  list: (dir) => {
    try {
      return readdirSync(dir).sort();
    } catch {
      return [];
    }
  },
  readJson: (p) => {
    try {
      const o = JSON.parse(readFileSync(p, "utf8")) as unknown;
      return o && typeof o === "object" && !Array.isArray(o) ? (o as Record<string, unknown>) : null;
    } catch {
      return null;
    }
  },
};

// What the composed field schema says, reduced to the two questions the check
// asks of it. null = no schema available (a repository checked on its own,
// without the foundation's schemas): the two field rules are then skipped and
// the report says so, rather than guessing.
export interface SchemaFacts {
  defined: Set<string>; // every field name any tier defines
  usedBy: Set<string>; // every "<module>:<service>" some field names in usedBy
  // Modules whose fields have a schema of their own, schemas/<module>-fields.json
  // (the satellite's, ADR-010) — their fields are defined there, not in a
  // fields.json, so the D2 fields rule does not apply to them.
  ownSchema: Set<string>;
}

export interface BlueprintTarget {
  name: string; // the module's name — its services are "<name>:<service>"
  dir: string; // absolute path of the module directory
  moduleJson: string; // absolute path of its own JSON
}

// Keys of a module JSON that are not fields: the module's identity and wiring,
// and `config`, whose entries are the fields grouped by service (Pattern A).
const NOT_FIELDS = new Set(["config", "dependsOn", "integratesWith", "provides", "controllers", "managers"]);

export function checkModule(t: BlueprintTarget, fs: BlueprintFs, schema: SchemaFacts | null): BlueprintFinding[] {
  const out: BlueprintFinding[] = [];
  const add = (severity: Severity, path: string, message: string): void =>
    void out.push({ module: t.name, severity, path, message });
  const must = (rel: string, why: string): void => {
    if (!fs.isFile(join(t.dir, rel))) add("error", rel, `missing ${rel} — ${why}`);
  };
  const should = (rel: string, why: string): void => {
    if (!fs.isFile(join(t.dir, rel))) add("warning", rel, `missing ${rel} — ${why}`);
  };

  // ── D2: the module's own artifacts ──
  const jsonRel = basename(t.moduleJson);
  const mj = fs.isFile(t.moduleJson) ? fs.readJson(t.moduleJson) : null;
  if (!fs.isFile(t.moduleJson)) add("error", jsonRel, `missing ${jsonRel} — the module's own file (ADR-027 D2)`);
  else if (!mj) add("error", jsonRel, `${jsonRel} is not a JSON object`);
  must("install.sh", "module add runs it; a module another module provisions ships one that says so (ADR-027 D2)");
  must("update.sh", "the nightly sweep runs it (ADR-027 D2)");
  should("test.sh", "the update gate and module test run it; without one the module is never tested (ADR-027 D2)");
  // ADR-013: the two documents a catalogue entry needs. Reported here, by
  // ADR-013's rule — ADR-027 does not restate it.
  must("README.md", "what an end user gets — mandatory for catalogue inclusion (ADR-013)");
  must("INSTALL.md", "what an admin must do that automation cannot — mandatory for catalogue inclusion (ADR-013)");

  // A field this module declares that no tier defines is one it must define
  // itself, in fields.json (#567).
  if (mj && schema && !schema.ownSchema.has(t.name) && !fs.isFile(join(t.dir, "fields.json"))) {
    const keys = new Set<string>();
    for (const k of Object.keys(mj)) if (!NOT_FIELDS.has(k)) keys.add(k);
    const cfg = mj.config;
    if (cfg && typeof cfg === "object" && !Array.isArray(cfg)) {
      for (const block of Object.values(cfg as Record<string, unknown>)) {
        if (block && typeof block === "object" && !Array.isArray(block)) {
          for (const k of Object.keys(block as Record<string, unknown>)) keys.add(k);
        }
      }
    }
    const own = [...keys].filter((k) => !k.startsWith("_") && !schema.defined.has(k)).sort();
    if (own.length > 0) {
      add("error", "fields.json", `missing fields.json — ${jsonRel} declares ${own.map((k) => `'${k}'`).join(", ")}, which no schema defines (ADR-027 D2, #567)`);
    }
  }

  // Services: one directory per service the module provides …
  const provides = Array.isArray(mj?.provides) ? (mj!.provides as unknown[]).filter((s): s is string => typeof s === "string") : [];
  for (const s of provides) {
    if (!fs.isDir(join(t.dir, "services", s))) {
      add("error", `services/${s}/`, `provides '${s}' but has no services/${s}/ — a consumer's dependency runs it (ADR-027 D2)`);
    }
  }
  // … and a directory for a service it does not declare is either dead or a
  // declaration missing — a consumer's dependency on it is refused either way.
  const dirs = fs.isDir(join(t.dir, "services")) ? fs.list(join(t.dir, "services")).filter((d) => fs.isDir(join(t.dir, "services", d))) : [];
  for (const d of dirs) {
    if (!provides.includes(d)) {
      add("warning", `services/${d}/`, `services/${d}/ is not a service ${t.name} provides — declare '${d}' in provides, or remove the directory`);
    }
  }

  // ── D3: each service directory ──
  for (const s of dirs) {
    const rel = (f: string): string => `services/${s}/${f}`;
    must(rel("install-service.sh"), "gives the service to a consumer (ADR-027 D3)");
    must(rel("update-service.sh"), "re-applies it when a consumer's declaration changes (ADR-027 D3, #495)");
    must(rel("delete-service.sh"), "takes it away again (ADR-027 D3)");
    should(rel("test-service.sh"), "is this consumer's instance working (ADR-027 D3)");
    must(rel("README.md"), "what a consumer gets and must declare (ADR-027 D3)");
    if (schema && schema.usedBy.has(`${t.name}:${s}`) && !fs.isFile(join(t.dir, rel("fields.json")))) {
      add("error", rel("fields.json"), `missing ${rel("fields.json")} — fields name ${t.name}:${s} in usedBy, so the service declares fields (ADR-027 D3, #567)`);
    }
  }

  // ── ADR-035: the controllers and managers the module contributes ──
  checkComponents(mj, "controllers", "controller", "-controller", must, should, add, fs, t.dir);
  checkComponents(mj, "managers", "manager", "-manager", must, should, add, fs, t.dir);
  return out;
}

// One kind of contributed component (ADR-035 D2, D3): each declared entry is a
// directory laid out as tappaas-cicd's own components, under the naming rule;
// a directory under controller/ or manager/ nobody declared is dead or a
// declaration missing — it is never linked either way.
function checkComponents(
  mj: Record<string, unknown> | null,
  field: "controllers" | "managers",
  dirName: string,
  suffix: string,
  must: (rel: string, why: string) => void,
  should: (rel: string, why: string) => void,
  add: (severity: Severity, path: string, message: string) => void,
  fs: BlueprintFs,
  dir: string,
): void {
  const raw = mj?.[field];
  if (raw !== undefined && !Array.isArray(raw)) {
    add("error", field, `${field} must be a list of {name, path${field === "controllers" ? ", plugsInto" : ""}} (ADR-035 D3)`);
    return;
  }
  const declared: string[] = [];
  const seen = new Set<string>();
  for (const [i, e] of ((raw as unknown[] | undefined) ?? []).entries()) {
    const o = e && typeof e === "object" && !Array.isArray(e) ? (e as Record<string, unknown>) : null;
    const name = typeof o?.name === "string" ? o.name : "";
    const path = typeof o?.path === "string" ? o.path.replace(/\/+$/, "") : "";
    const at = `${field}[${i}]`;
    if (!name || !path) {
      add("error", at, `${at} needs a name and a path (ADR-035 D3)`);
      continue;
    }
    if (!name.endsWith(suffix) || !/^[a-z][a-z0-9-]*$/.test(name)) {
      add("error", at, `${field === "controllers" ? "a controller" : "a manager"} is named <${field === "controllers" ? "application" : "domain"}>${suffix}, in lower case: '${name}' is not (ADR-035 D3)`);
    }
    if (seen.has(name)) add("error", at, `'${name}' is declared twice`);
    seen.add(name);
    if (field === "controllers") {
      const plugs = Array.isArray(o?.plugsInto) ? (o!.plugsInto as unknown[]) : [];
      if (plugs.length === 0 || plugs.some((m) => typeof m !== "string" || !m.endsWith("-manager"))) {
        add("error", at, `${name}: plugsInto names the managers that drive it (e.g. ["switch-manager"]) (ADR-035 D3)`);
      }
    }
    if (path.split("/")[0] !== dirName || path.split("/").length !== 2) {
      add("error", at, `${name}: its path is ${dirName}/<name> in the module, not '${path}' (ADR-035 D2)`);
    }
    if (!fs.isDir(join(dir, path))) {
      add("error", `${path}/`, `declares ${name} but has no ${path}/ (ADR-035 D2)`);
      continue;
    }
    declared.push(path.split("/").slice(-1)[0]);
    const r = (f: string): string => `${path}/${f}`;
    must(r("install.sh"), "builds and links it when the module installs (ADR-035 D2)");
    must(r("update.sh"), "rebuilds and relinks it when the module updates (ADR-035 D2)");
    must(r("README.md"), "what it does and how to use it, published with the module (ADR-035 D8)");
    should(r("test.sh"), "its offline self-test (ADR-035 D2)");
    should(r("DESIGN.md"), `how it works${field === "controllers" ? " and the contract it answers" : ""} (ADR-035 D2, D4)`);
  }
  // tappaas-cicd declares its standard components in components.json (ADR-035
  // D5), not in its module JSON: those directories are declared too.
  const std = fs.readJson(join(dir, "components.json"));
  for (const c of Array.isArray(std?.components) ? (std!.components as unknown[]) : []) {
    const p = c && typeof c === "object" ? (c as Record<string, unknown>).path : undefined;
    if (typeof p === "string" && p.split("/")[0] === dirName) declared.push(p.split("/").slice(-1)[0]);
  }
  const dirs = fs.isDir(join(dir, dirName)) ? fs.list(join(dir, dirName)).filter((d) => fs.isDir(join(dir, dirName, d))) : [];
  for (const d of dirs) {
    if (!declared.includes(d)) {
      add("warning", `${dirName}/${d}/`, `${dirName}/${d}/ is not declared in ${field} — declare it, or remove the directory; an undeclared ${dirName} is never linked (ADR-035 D3)`);
    }
  }
}

// ── which modules a repository has ────────────────────────────────────────
// Every catalogue entry except the test fixtures (`stack: test` — fixtures, not
// modules). One target per module DIRECTORY: `templates` shares its directory
// with the VM templates it builds (#741), and the directory is the module
// (D1), named by the entry whose JSON is <dir>/<dir>.json. 00-Template is
// checked like any module (D6), under its catalogue name.
export function repoTargets(repoRoot: string, catalogFile: string, fs: BlueprintFs): { targets: BlueprintTarget[]; problem: string } {
  const cat = fs.readJson(catalogFile);
  if (!cat) return { targets: [], problem: `no readable module catalogue at ${catalogFile}` };
  type Entry = { name: string; json: string; stack: string };
  const entries: Entry[] = [];
  const take = (list: unknown, skip: boolean): void => {
    if (!Array.isArray(list)) return;
    for (const e of list) {
      if (!e || typeof e !== "object") continue;
      const o = e as Record<string, unknown>;
      const name = typeof o.moduleName === "string" ? o.moduleName : "";
      const json = typeof o.moduleJson === "string" ? o.moduleJson : "";
      const stack = typeof o.stack === "string" ? o.stack : "";
      if (name && json && !skip) entries.push({ name, json, stack });
    }
  };
  take(cat.modules, false);
  take(cat.foundationModules, false);
  take(cat.applicationModules, false);
  take(cat.proxmoxTemplates, true); // legacy shape: VM templates, not modules
  take(cat.testModules, true);
  const byDir = new Map<string, Entry[]>();
  for (const e of entries) {
    if (e.stack === "test") continue;
    const dir = join(repoRoot, dirname(e.json));
    byDir.set(dir, [...(byDir.get(dir) ?? []), e]);
  }
  const targets: BlueprintTarget[] = [];
  for (const [dir, es] of [...byDir.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const own = es.find((e) => basename(e.json, ".json") === basename(dir)) ?? (es.length === 1 ? es[0] : null);
    if (!own) continue; // a directory of templates only — no module lives there
    targets.push({ name: own.name, dir, moduleJson: join(repoRoot, own.json) });
  }
  return { targets, problem: "" };
}

// A module named on the command line: a directory, checked as it stands.
export function dirTarget(dir: string, fs: BlueprintFs): BlueprintTarget | null {
  const own = join(dir, `${basename(dir)}.json`);
  if (fs.isFile(own)) return { name: basename(dir), dir, moduleJson: own };
  const jsons = fs.list(dir).filter((f) => f.endsWith(".json") && f !== "fields.json");
  if (jsons.length === 1) return { name: basename(jsons[0], ".json"), dir, moduleJson: join(dir, jsons[0]) };
  return null;
}

// `fields` of a composed module-fields.json; null or empty = no schema.
// `schemaDirs`: the schemas/ directories to look in for <module>-fields.json.
export function schemaFacts(
  fields: Record<string, unknown> | null | undefined,
  schemaDirs: string[] = [],
  fs: BlueprintFs = realBlueprintFs,
): SchemaFacts | null {
  if (!fields || typeof fields !== "object" || Object.keys(fields).length === 0) return null;
  const ownSchema = new Set<string>();
  for (const d of schemaDirs) {
    for (const f of fs.list(d)) {
      const m = /^(.+)-fields\.json$/.exec(f);
      if (m) ownSchema.add(m[1]);
    }
  }
  const defined = new Set<string>();
  const usedBy = new Set<string>();
  for (const [name, def] of Object.entries(fields as Record<string, unknown>)) {
    defined.add(name);
    const u = (def as Record<string, unknown> | null)?.usedBy;
    if (Array.isArray(u)) for (const x of u) if (typeof x === "string") usedBy.add(x);
  }
  return { defined, usedBy, ownSchema };
}

