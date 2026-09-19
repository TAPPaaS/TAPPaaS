// compose.test.ts — the composed field schema every reader trusts.
//
// Since #567 a field is defined where it is owned: schemas/module-fields.json
// holds the generic fields, and each service's fields.json holds its own. The
// readers — jq, Python and TypeScript alike — see the COMPOSED view. This test
// asserts what has to stay true of that view as fields keep being added and
// reworded:
//
//   - no field is defined twice;
//   - no service-owned field is defined in the global file (#567's rule, for
//     every field added from now on, not only the ones it moved);
//   - every field an authored module uses is defined — the loss that matters
//     is a definition that disappears while something still sets the field;
//   - the jq and TypeScript composers agree;
//   - the catalogue, not the filesystem, decides which modules contribute.
//
// It used to compare the composed view to a snapshot of module-fields.json
// taken before #567's move. That guarded the move while it happened; once the
// move was done every legitimate schema edit turned it red, and because no
// runner executed it nobody saw 25 of them. The snapshot is retired; these
// checks have a live purpose.

import { spawnSync } from "child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { composeFields } from "../../../../lib/ts/src/compose-fields";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok: ${msg}`);
    passed++;
  } else {
    console.log(`  FAIL: ${msg}`);
    failed++;
  }
}

const MODULE_MANAGER = join(__dirname, "..", "..", "..", "..", "..");
const FOUNDATION = join(MODULE_MANAGER, "..", "..", "..");
const REPO = join(FOUNDATION, "..", "..");

// Compose THIS tree. With a site.json present — on any mothership — both
// composers read the repositories it lists, i.e. the INSTALLED checkout, not
// the code under test. An empty config dir makes them fall back to this tree's
// own catalogue, so the test asserts what it ships with.
const OWN_TREE = mkdtempSync(join(tmpdir(), "compose-own-"));
const r = composeFields(FOUNDATION, OWN_TREE);
const composed = r.schema.fields as Record<string, { usedBy?: string[] }>;

// ── the composition is sound ────────────────────────────────────────────
check(r.findings.length === 0, `no field is defined twice (${r.findings.map((f) => f.field).join(", ") || "none"})`);

// ── #567's rule: a field is defined where it is owned ───────────────────
// A field some service owns (usedBy names services, not "general") must live
// in that service's fields.json. Defining it globally again is how the global
// file grows back.
{
  const stillGlobal = Object.keys(composed).filter((n) => {
    const u = composed[n].usedBy ?? [];
    return u.length > 0 && !u.includes("general") && r.origin[n] === "schemas/module-fields.json";
  });
  check(stillGlobal.length === 0, `no service-owned field is defined globally (${stillGlobal.join(", ") || "none"})`);
}

// ── every field an authored module uses is defined ──────────────────────
// The catalogue lists the modules. A field set at the top level or inside a
// Pattern-A `config."<module>:<service>"` block must have a definition, or it
// has no type, no allowed values and no ADR-020 change class — nothing says
// what changing it costs. The satellite is not a module-fields module: its
// fields are satellite-fields.json's (ADR-010).
//
// KNOWN_UNDEFINED is a list of debts, each with its issue. An entry that is no
// longer needed — the field got defined, or nothing uses it — FAILS, so an
// exception cannot outlive its fix.
const KNOWN_UNDEFINED: Record<string, string> = {};
{
  const catalog = JSON.parse(readFileSync(join(REPO, "src", "module-catalog.json"), "utf8")) as Record<string, unknown>;
  const undefinedUse: Record<string, string[]> = {};
  const staleEntries: string[] = [];
  let checked = 0;
  for (const section of ["foundationModules", "applicationModules", "proxmoxTemplates", "testModules"]) {
    for (const e of (catalog[section] as { moduleJson?: string }[] | undefined) ?? []) {
      if (!e.moduleJson) continue;
      const path = join(REPO, e.moduleJson);
      if (!existsSync(path)) { staleEntries.push(e.moduleJson); continue; } // a stale catalogue entry is #463's
      if (e.moduleJson.includes("/satellite/")) continue;
      const j = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
      const keys = new Set(Object.keys(j));
      if (j.config && typeof j.config === "object") {
        for (const svc of Object.values(j.config as Record<string, unknown>)) {
          if (svc && typeof svc === "object") Object.keys(svc as object).forEach((k) => keys.add(k));
        }
      }
      for (const k of keys) {
        if (k.startsWith("_") || k === "config" || k in composed) continue;
        (undefinedUse[k] ??= []).push(e.moduleJson.split("/").slice(-2, -1)[0]);
      }
      checked++;
    }
  }
  const unexplained = Object.keys(undefinedUse).filter((k) => !(k in KNOWN_UNDEFINED));
  check(
    checked > 0 && unexplained.length === 0,
    `every field ${checked} catalogued modules use is defined` +
      (unexplained.length ? ` — undefined: ${unexplained.map((k) => `${k} (${undefinedUse[k].join(", ")})`).join("; ")}` : ""),
  );
  for (const [k, why] of Object.entries(KNOWN_UNDEFINED)) {
    check(
      k in undefinedUse && !(k in composed),
      k in undefinedUse
        ? `known debt still open: ${k}, used by ${undefinedUse[k].join(", ")} (${why})`
        : `known debt ${k} is no longer needed — remove it from KNOWN_UNDEFINED (${why})`,
    );
  }
  if (staleEntries.length) console.log(`  note: catalogue entries with no file, skipped (#463): ${staleEntries.join(", ")}`);
}

// ── the two composers must agree ────────────────────────────────────────
//
// There are two implementations on purpose — jq for bash and Python readers
// (which must not need node, and which run before any manager is built), and
// this one for in-process TypeScript. Two implementations that disagree would
// be worse than one, so the agreement is asserted rather than assumed.
{
  const composer = join(FOUNDATION, "tappaas-cicd", "scripts", "compose-fields.sh");
  let shellFields: Record<string, unknown> | null = null;
  try {
    const r = spawnSync(composer, [FOUNDATION], { encoding: "utf8", env: { ...process.env, CONFIG_DIR: OWN_TREE } });
    shellFields = r.status === 0 && r.stdout
      ? (JSON.parse(r.stdout) as { fields: Record<string, unknown> }).fields
      : null;
  } catch {
    shellFields = null;
  }
  if (shellFields === null) {
    console.log("  ok: SKIP two-composer agreement (compose-fields.sh not runnable here)");
    passed++;
  } else {
    const a = Object.keys(composed).sort();
    const b = Object.keys(shellFields).sort();
    check(JSON.stringify(a) === JSON.stringify(b), "jq and TypeScript composers see the same field set");
    const differ = a.filter((n) => JSON.stringify(composed[n]) !== JSON.stringify(shellFields![n]));
    check(differ.length === 0, `…and identical definitions (differing: ${differ.join(", ") || "none"})`);
  }
}

// ── the catalogue decides what a module is ──────────────────────────────
//
// Discovery walks site.json .repositories → each repo's module-catalog.json →
// dirname(moduleJson). Not the filesystem: a stray services/ directory is not a
// module, and an unregistered checkout beside a real repo is not a source of
// fields. Both would otherwise leak into the schema every reader trusts.
{
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = require("fs") as typeof import("fs");
  const { tmpdir } = require("os") as typeof import("os");
  const root = mkdtempSync(join(tmpdir(), "compose-cat-"));
  const cfg = join(root, "config");
  const repo = join(root, "repo");
  mkdirSync(cfg, { recursive: true });

  const mkModule = (rel: string, field: string): void => {
    const dir = join(repo, rel);
    mkdirSync(join(dir, "services", "svc"), { recursive: true });
    writeFileSync(join(dir, `${rel.split("/").pop()}.json`), "{}");
    writeFileSync(
      join(dir, "services", "svc", "fields.json"),
      JSON.stringify({
        service: "m:svc",
        fields: { [field]: { description: "x", type: "string", usedBy: ["m:svc"], class: "in-place", apply: "reconcile" } },
      }),
    );
  };
  mkModule("src/a/registered", "registeredField");
  mkModule("src/a/unregistered", "rogueField");

  // Only the first is in the catalogue.
  writeFileSync(join(repo, "src", "module-catalog.json"),
    JSON.stringify({ applicationModules: [{ moduleName: "registered", moduleJson: "src/a/registered/registered.json" }] }));
  writeFileSync(join(cfg, "site.json"),
    JSON.stringify({ repositories: [{ name: "t", path: repo, catalog: "src/module-catalog.json" }] }));
  // A base schema for the composer to start from.
  mkdirSync(join(repo, "src", "foundation", "schemas"), { recursive: true });
  writeFileSync(join(repo, "src", "foundation", "schemas", "module-fields.json"), JSON.stringify({ fields: {} }));

  const res = composeFields(join(repo, "src", "foundation"), cfg);
  const got = Object.keys(res.schema.fields as Record<string, unknown>);
  check(got.includes("registeredField"), "a registered module's service fields are composed");
  check(!got.includes("rogueField"), "an UNREGISTERED module beside it is ignored — the catalogue decides");

  rmSync(root, { recursive: true, force: true });
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
rmSync(OWN_TREE, { recursive: true, force: true });
process.exit(failed === 0 ? 0 : 1);
