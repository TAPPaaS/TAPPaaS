// store.ts — config/positions.json on disk: read, lock, write. One writer at a
// time, every write atomic (temp file + rename), an absent file an empty one.
// A site the migration has not reached yet still has config/racks.json: it is
// read, and a write is refused until migration 0020 has renamed it.
// Also the faceplate catalog (faceplates/<vendor>/<model>.json beside the
// sources, or in the built package) and the topology the checks need.

import { existsSync, mkdirSync, readFileSync, readdirSync, rmdirSync, statSync } from "fs";
import { join } from "path";
import { writeJsonAtomic } from "../../../lib/ts/src/config-io";
import { captureResult } from "../../../lib/ts/src/exec";
import { Faceplate, LEGACY_RACKS_FILE, POSITIONS_FILE, RacksDoc, SiteDevice, TopoLike, parseFaceplate, siteDevices } from "../../../lib/ts/src/racks";

export class Store {
  constructor(readonly configDir: string) {}

  get file(): string {
    return join(this.configDir, POSITIONS_FILE);
  }

  // config/racks.json, when the migration has not renamed it yet.
  get legacy(): string | null {
    const f = join(this.configDir, LEGACY_RACKS_FILE);
    return existsSync(f) ? f : null;
  }

  load(): RacksDoc {
    const file = existsSync(this.file) ? this.file : this.legacy;
    if (!file) return {};
    const v: unknown = JSON.parse(readFileSync(file, "utf8"));
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error(`${file} is not a JSON object`);
    return v as RacksDoc;
  }

  save(doc: RacksDoc): void {
    if (this.legacy) throw new Error(`${this.legacy} is still there: migration 0020 makes it positions.json (the next update, or scripts/run-migrations.sh) — nothing was changed`);
    writeJsonAtomic(this.file, doc);
  }

  // withLock — one position-manager writer at a time. A directory lock: created
  // atomically, removed after; a lock older than 10 minutes is a crashed run's.
  withLock<T>(fn: () => T): T {
    const lock = join(this.configDir, ".positions.lock");
    for (let i = 0; ; i++) {
      try {
        mkdirSync(lock);
        break;
      } catch {
        try {
          if (Date.now() - statSync(lock).mtimeMs > 10 * 60 * 1000) {
            rmdirSync(lock);
            continue;
          }
        } catch {
          continue;
        }
        if (i >= 60) throw new Error(`${lock} is held by another position-manager run`);
        const until = Date.now() + 1000;
        while (Date.now() < until) {
          /* wait a second — Atomics.wait would need a SharedArrayBuffer */
        }
      }
    }
    try {
      return fn();
    } finally {
      try {
        rmdirSync(lock);
      } catch {
        /* already gone */
      }
    }
  }
}

// Where the catalog is: $TAPPAAS_FACEPLATES, else beside the compiled sources
// (the package copies faceplates/ next to src/), else the component's own
// directory above dist/ (a tree built in place).
export function catalogDir(): string | null {
  const candidates = [
    process.env.TAPPAAS_FACEPLATES,
    join(__dirname, "..", "faceplates"),
    join(__dirname, "..", "..", "..", "..", "faceplates"),
  ].filter((x): x is string => !!x);
  return candidates.find((d) => existsSync(d)) ?? null;
}

// The catalog: every <vendor>/<model>.json, each checked; a broken entry is
// reported, not loaded.
export function loadCatalog(dir: string | null = catalogDir()): { catalog: Faceplate[]; errors: string[] } {
  const catalog: Faceplate[] = [];
  const errors: string[] = [];
  if (!dir) return { catalog, errors: ["the faceplate catalog was not found (faceplates/ beside position-manager, or $TAPPAAS_FACEPLATES)"] };
  for (const vendor of readdirSync(dir).filter((x) => !x.startsWith(".")).sort()) {
    const vd = join(dir, vendor);
    if (!statSync(vd).isDirectory()) continue;
    for (const f of readdirSync(vd).filter((x) => x.endsWith(".json") && !x.startsWith(".")).sort()) {
      const key = `${vendor}/${f.slice(0, -".json".length)}`;
      try {
        const p = parseFaceplate(key, JSON.parse(readFileSync(join(vd, f), "utf8")));
        if ("error" in p) errors.push(p.error);
        else catalog.push(p);
      } catch (e) {
        errors.push(`${key}: ${(e as Error).message}`);
      }
    }
  }
  return { catalog, errors };
}

// The site's devices: from a topology document the caller holds (--topology,
// the console's cache), else `network-manager topology` without the racks
// (which it reads from here). null: it could not be read.
export function readDevices(topologyFile: string | undefined): { devices: SiteDevice[] | null; topology: TopoLike | null; error: string | null } {
  try {
    let t: TopoLike;
    if (topologyFile) t = JSON.parse(readFileSync(topologyFile, "utf8")) as TopoLike;
    else {
      const r = captureResult("network-manager", ["topology", "--json", "--no-health", "--no-racks"]);
      if (!r.ran) return { devices: null, topology: null, error: "network-manager not found" };
      t = JSON.parse(r.stdout) as TopoLike;
    }
    return { devices: siteDevices(t), topology: t, error: null };
  } catch (e) {
    return { devices: null, topology: null, error: (e as Error).message };
  }
}
