// kind.ts — the kind a deployed module effectively has (ADR-022f D1, #669).
//
// `kind` is AUTHORED in a module's source JSON and adopted into the deployed
// config by the 3-way merge. Three places can answer, in this order:
//
//   1. the deployed config's own `kind`;
//   2. the module's source JSON (<moduleSource>/<module>.json) — a module whose
//      release gained a kind reports it before its next update adopts it;
//   3. a default: `vm` for a module that is not official. Community modules
//      declare no kind (operator decision 2026-09-19: they default to vm);
//      every official module declares one, so the default never overrides it.
//
// "Official" is what the module's catalogue entry says (module-catalog.json
// `source`); the Community catalogue records none, so its modules are not.
// A config with no moduleSource (pre-#609, found by vmname only) has no
// knowable origin and gets no default.

import { existsSync, readFileSync } from "fs";
import { dirname, join } from "path";
import { moduleSourceJson, moduleSourceOf } from "./instance";

export const DEFAULT_COMMUNITY_KIND = "vm";

function readJson(file: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(readFileSync(file, "utf8")) as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

// repo root → { module dir (relative to root) → catalogue `source` }
const catalogCache = new Map<string, Map<string, string | null>>();

function catalogOf(root: string): Map<string, string | null> {
  const cached = catalogCache.get(root);
  if (cached) return cached;
  const out = new Map<string, string | null>();
  const collect = (node: unknown): void => {
    if (Array.isArray(node)) {
      node.forEach(collect);
    } else if (node && typeof node === "object") {
      const o = node as Record<string, unknown>;
      if (typeof o.moduleJson === "string") {
        out.set(dirname(o.moduleJson), typeof o.source === "string" ? o.source : null);
      }
      Object.values(o).forEach(collect);
    }
  };
  collect(readJson(join(root, "src", "module-catalog.json")));
  catalogCache.set(root, out);
  return out;
}

/** The catalogue `source` of the module at <location>, or null when no catalogue lists it. */
export function catalogSourceOf(location: string): string | null {
  const loc = location.replace(/\/+$/, "");
  let dir = loc;
  while (dir && dir !== "/" && dir !== ".") {
    if (existsSync(join(dir, "src", "module-catalog.json"))) {
      // dir is an ancestor of loc, so the module dir relative to the root is the rest.
      return catalogOf(dir).get(loc.slice(dir.length + 1)) ?? null;
    }
    dir = dirname(dir);
  }
  return null;
}

/** The kind a deployed config effectively has; null when nothing says. */
export function effectiveKind(raw: Record<string, unknown> | null | undefined): string | null {
  if (typeof raw?.kind === "string" && raw.kind !== "") return raw.kind;
  const location = moduleSourceOf(raw);
  if (!location) return null;
  const authored = readJson(moduleSourceJson(location))?.kind;
  if (typeof authored === "string" && authored !== "") return authored;
  return catalogSourceOf(location) === "official" ? null : DEFAULT_COMMUNITY_KIND;
}
