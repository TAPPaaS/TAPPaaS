// catalog.ts — what each registered repository offers (the Modules page's
// repository tabs), read-only. The repositories are `site-manager repository
// list` (each with its path and the catalogue's place in it); a catalogue is
// that repository's module-catalog.json, whatever its grouping (a flat
// `modules` list, or lists by kind); each entry's own module JSON gives its
// description and maturity. A module is installed when a deployed instance's
// moduleSource is that module's directory (an instance may carry another name:
// deconz-test is deconz). Where several entries share a directory (templates/
// holds templates.json and the template JSONs), the instance is the entry whose
// JSON is named like the directory, else the one named like the instance.

import { existsSync, readFileSync } from "fs";
import { basename, dirname, join } from "path";

export interface CatalogModule {
  name: string;
  stack: string | null;
  description: string | null;
  maturity: string | null;
  category: string | null;
  vmid: number | null; // the guest's VM id the module gives an instance (a second one needs another)
  instances: string[];
}

export interface RepositoryCatalog {
  name: string;
  url: string | null;
  path: string | null;
  catalog: string | null;
  error: string | null; // why the catalogue could not be read
  modules: CatalogModule[];
}

type Obj = Record<string, unknown>;
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

function readJson(file: string): Obj {
  return JSON.parse(readFileSync(file, "utf8")) as Obj;
}

// Every object in the catalogue that names a module, at any depth.
export function catalogEntries(doc: unknown): Obj[] {
  const out: Obj[] = [];
  const walk = (n: unknown): void => {
    if (Array.isArray(n)) n.forEach(walk);
    else if (n && typeof n === "object") {
      const o = n as Obj;
      if (typeof o.moduleName === "string" && typeof o.moduleJson === "string") out.push(o);
      else Object.values(o).forEach(walk);
    }
  };
  walk(doc);
  return out;
}

// instances: each deployed module's name and its config's moduleSource.
export function repositoryCatalog(repo: Obj, instances: { name: string; source: string | null }[]): RepositoryCatalog {
  const base: RepositoryCatalog = { name: str(repo.name) ?? "?", url: str(repo.url), path: str(repo.path), catalog: str(repo.catalog), error: null, modules: [] };
  if (!base.path) return { ...base, error: "the repository has no path in site.json" };
  const cat = base.catalog ?? "src/module-catalog.json";
  const file = join(base.path, cat);
  if (!existsSync(file)) return { ...base, error: `${cat} not found in ${base.path}` };
  let doc: Obj;
  try {
    doc = readJson(file);
  } catch (e) {
    return { ...base, error: `${cat} is not valid JSON: ${(e as Error).message}` };
  }
  const root = base.path.replace(/\/+$/, "");
  const entries = catalogEntries(doc).map((e) => ({ e, name: String(e.moduleName), json: String(e.moduleJson), dir: join(root, dirname(String(e.moduleJson))) }));
  // Each deployed instance belongs to at most one entry.
  const owner = new Map<string, string>();
  for (const i of instances) {
    const names = (x: (typeof entries)[number]) => [x.name, ...(typeof x.e.legacyName === "string" ? [x.e.legacyName] : [])];
    const src = i.source?.replace(/\/+$/, "") ?? null;
    const here = src !== null ? entries.filter((x) => x.dir === src) : entries.filter((x) => names(x).includes(i.name));
    const pick = here.length <= 1 ? here[0] : here.find((x) => basename(x.json, ".json") === basename(x.dir)) ?? here.find((x) => names(x).includes(i.name)) ?? here[0];
    if (pick) owner.set(i.name, pick.name);
  }
  const modules = entries.map(({ e, name, json }): CatalogModule => {
    let own: Obj = {};
    try {
      own = readJson(join(root, json));
    } catch {
      /* the catalogue's own fields stand */
    }
    return {
      name,
      stack: str(own.stack) ?? str(e.stack),
      description: str(own.description) ?? str(e.description),
      maturity: str(own.status) ?? str(e.status),
      category: str(e.category),
      vmid: typeof own.vmid === "number" ? own.vmid : null,
      instances: instances.filter((i) => owner.get(i.name) === name).map((i) => i.name).sort(),
    };
  });
  modules.sort((a, b) => a.name.localeCompare(b.name));
  return { ...base, modules };
}

// A deployed module's moduleSource, from its config (null when it has none).
export function moduleSourceOf(configDir: string, name: string): string | null {
  try {
    return str(readJson(join(configDir, `${name}.json`)).moduleSource);
  } catch {
    return null;
  }
}
