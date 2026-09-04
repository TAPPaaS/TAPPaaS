// compose-fields.ts — the merged module-field schema (#567).
//
// module-fields.json listed every field any service could ever use, so adding a
// service meant editing a global file, and the file grew a definition for
// something only one provider understood. #567 moves each definition to where
// it is owned; this composes the pieces back into the single view 41 readers
// already expect, so the SOURCE moves without the consumers moving with it.
//
// Three tiers, from the shape of the data rather than an imposed taxonomy —
// of the 74 fields: 19 are owned by no service, 41 by exactly one, and 14 by
// two, where all 14 are the same cluster:vm + cluster:lxc pair (the fields
// common to both guest types):
//
//   schemas/module-fields.json          the 19 generic ones — provenance,
//                                       lifecycle, wiring; no provider needed
//   <module>/fields.json                shared by that module's services
//                                       (cluster/: the 14 guest fields)
//   <module>/services/<svc>/fields.json owned by exactly one service (41)
//
// A field defined in more than one tier is an ERROR, not a merge: two files
// claiming the same definition is the ambiguity this change exists to remove.

import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";

export interface ComposeFinding {
  field: string;
  detail: string;
}

export interface ComposeResult {
  // The merged document, shaped exactly like today's module-fields.json.
  schema: Record<string, unknown>;
  // Where each field's definition came from, for diagnostics.
  origin: Record<string, string>;
  findings: ComposeFinding[];
}

function readJson(p: string): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

// A tier file contributes `fields`; a service manifest also carries change
// semantics (class/apply/...), which are NOT part of the schema view and are
// left where they are. `changeNote` is in this set and `note` is NOT: since
// #567 a merged entry holds both, and `note` belongs to the DEFINITION.
const CHANGE_KEYS = new Set([
  "class", "apply", "liveKey", "setFlag", "hook", "composite",
  "normalize", "sideEffects", "changeNote", "inputs",
]);

function definitionOf(entry: Record<string, unknown>): Record<string, unknown> | null {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(entry)) {
    if (!CHANGE_KEYS.has(k)) out[k] = v;
  }
  // An entry carrying ONLY change semantics defines nothing — it is a manifest
  // entry for a field defined in another tier, which is the pre-#567 shape.
  return Object.keys(out).length > 0 ? out : null;
}

export function composeFields(
  foundationDir: string,
  configDir = "/home/tappaas/config",
): ComposeResult {
  const findings: ComposeFinding[] = [];
  const origin: Record<string, string> = {};
  const fields: Record<string, unknown> = {};

  const base = readJson(join(foundationDir, "schemas", "module-fields.json"));
  if (!base) {
    return {
      schema: {},
      origin,
      findings: [{ field: "-", detail: "schemas/module-fields.json is missing or unparseable" }],
    };
  }

  const add = (name: string, def: Record<string, unknown>, from: string): void => {
    if (name in fields) {
      findings.push({
        field: name,
        detail: `defined in two places: ${origin[name]} and ${from} — one definition, one home`,
      });
      return;
    }
    fields[name] = def;
    origin[name] = from;
  };

  for (const [k, v] of Object.entries((base.fields ?? {}) as Record<string, unknown>)) {
    add(k, v as Record<string, unknown>, "schemas/module-fields.json");
  }

  // Walk the REGISTERED MODULES, not the filesystem. site.json .repositories is
  // the canonical repo list (ADR-007) and each repo's module-catalog.json is the
  // canonical list of what is a module in it. A stray services/ directory is not
  // a module and an unregistered checkout is not a source of fields — neither
  // can leak into the schema every reader trusts.
  //
  // It also removes the guesswork a filesystem walk needs: no prune list, no
  // depth limit, no rule for telling a module directory from any other. Layout
  // stops mattering — foundation modules sit at src/foundation/<module>/ and
  // community ones at src/<author>/<group>/<module>/, and both are simply
  // dirname(moduleJson).
  const seen = new Set<string>();
  const addFrom = (file: string): void => {
    if (!existsSync(file) || seen.has(file)) return;
    seen.add(file);
    const doc = readJson(file);
    for (const [k, v] of Object.entries((doc?.fields ?? {}) as Record<string, unknown>)) {
      const def = definitionOf(v as Record<string, unknown>);
      if (def) add(k, def, file);
    }
  };

  const scanRepo = (root: string, catalogRel: string): number => {
    const cat = readJson(join(root, catalogRel));
    if (!cat) return 0;
    const moduleJsons: string[] = [];
    const collect = (node: unknown): void => {
      if (Array.isArray(node)) {
        node.forEach(collect);
      } else if (node && typeof node === "object") {
        const o = node as Record<string, unknown>;
        if (typeof o.moduleJson === "string") moduleJsons.push(o.moduleJson);
        Object.values(o).forEach(collect);
      }
    };
    collect(cat);
    for (const mj of moduleJsons.sort()) {
      const dir = join(root, mj.slice(0, mj.lastIndexOf("/")));
      addFrom(join(dir, "fields.json"));
      const svcDir = join(dir, "services");
      let svcs: string[] = [];
      try {
        svcs = readdirSync(svcDir);
      } catch {
        continue;
      }
      for (const sname of svcs.sort()) addFrom(join(svcDir, sname, "fields.json"));
    }
    return moduleJsons.length;
  };

  const site = readJson(join(configDir, "site.json"));
  let scanned = 0;
  for (const r of ((site?.repositories ?? []) as Array<Record<string, unknown>>)) {
    const rpath = typeof r.path === "string" ? r.path : "";
    const rcat = typeof r.catalog === "string" ? r.catalog : "src/module-catalog.json";
    if (rpath) scanned += scanRepo(rpath, rcat);
  }
  // Bootstrap / bare checkout: no site.json yet, or it lists no usable repo.
  // Fall back to the catalogue of the tree this composer ships in.
  if (scanned === 0) scanRepo(join(foundationDir, "..", ".."), "src/module-catalog.json");

  const schema: Record<string, unknown> = { ...base, fields };
  return { schema, origin, findings };
}
