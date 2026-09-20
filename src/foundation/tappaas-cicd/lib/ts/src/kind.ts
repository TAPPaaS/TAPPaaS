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
// "Official" is the module's own `source` (ADR-007b) when it states one, else
// its repository's: `source` at the top of module-catalog.json, stated once
// rather than copied onto every entry (#463). The Community catalogue states
// none, so its modules are not official. A config with no moduleSource
// (pre-#609, found by vmname only) has no knowable origin and gets no default.

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

// repo root → { repository source, module dir (relative to root) → entry `source` }
// The per-entry source is the pre-#463 shape, still read for a stable cycle.
const catalogCache = new Map<string, { repo: string | null; entries: Map<string, string | null> }>();

function catalogOf(root: string): { repo: string | null; entries: Map<string, string | null> } {
  const cached = catalogCache.get(root);
  if (cached) return cached;
  const entries = new Map<string, string | null>();
  const collect = (node: unknown): void => {
    if (Array.isArray(node)) {
      node.forEach(collect);
    } else if (node && typeof node === "object") {
      const o = node as Record<string, unknown>;
      if (typeof o.moduleJson === "string") {
        entries.set(dirname(o.moduleJson), typeof o.source === "string" ? o.source : null);
      }
      Object.values(o).forEach(collect);
    }
  };
  const cat = readJson(join(root, "src", "module-catalog.json"));
  collect(cat);
  const out = { repo: typeof cat?.source === "string" ? cat.source : null, entries };
  catalogCache.set(root, out);
  return out;
}

/**
 * Where the module at <location> comes from: its own `source` (ADR-007b), else
 * its repository's — the catalogue's top-level `source`, or the entry's own in a
 * pre-#463 catalogue. Null when nothing says.
 */
export function catalogSourceOf(location: string): string | null {
  const loc = location.replace(/\/+$/, "");
  const own = readJson(moduleSourceJson(loc))?.source;
  if (typeof own === "string" && own !== "") return own;
  let dir = loc;
  while (dir && dir !== "/" && dir !== ".") {
    if (existsSync(join(dir, "src", "module-catalog.json"))) {
      const cat = catalogOf(dir);
      // dir is an ancestor of loc, so the module dir relative to the root is the rest.
      return cat.entries.get(loc.slice(dir.length + 1)) ?? cat.repo;
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
