// store.ts — config/shares.json on disk (ADR-029 v0.9 D18): read, lock, write. One
// writer at a time, every write atomic (temp file + rename), an absent file an empty
// one. Also the instance lookups the verbs need from the rest of config/.

import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, statSync, writeFileSync } from "fs";
import { join } from "path";
import { ConfigReader, SHARES_INSTANCE, SharesDoc, mountsShare } from "../../../lib/ts/src/nfs-shares";
import { moduleSourceOf } from "../../../lib/ts/src/instance";

export class Store {
  constructor(readonly configDir: string) {}

  get file(): string {
    return join(this.configDir, `${SHARES_INSTANCE}.json`);
  }

  load(): SharesDoc {
    if (!existsSync(this.file)) return {};
    const v: unknown = JSON.parse(readFileSync(this.file, "utf8"));
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error(`${this.file} is not a JSON object`);
    return v as SharesDoc;
  }

  save(doc: SharesDoc): void {
    const tmp = `${this.file}.tmp-${process.pid}`;
    writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", "utf8");
    renameSync(tmp, this.file);
  }

  // withLock — one storage-manager writer at a time. A directory lock: created
  // atomically, removed after; a lock older than 10 minutes is a crashed run's.
  withLock<T>(fn: () => T): T {
    const lock = join(this.configDir, ".shares.lock");
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
        if (i >= 60) throw new Error(`${lock} is held by another storage-manager run`);
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

  readonly read: ConfigReader = (instance) => {
    try {
      const v: unknown = JSON.parse(readFileSync(join(this.configDir, `${instance}.json`), "utf8"));
      return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
    } catch {
      return null;
    }
  };

  instances(): string[] {
    try {
      return readdirSync(this.configDir)
        .filter((f) => f.endsWith(".json"))
        .map((f) => f.slice(0, -".json".length));
    } catch {
      return [];
    }
  }

  // Does the instance's module ship the NFS server hook (D19)?
  readonly hasHook = (instance: string): boolean => {
    const src = moduleSourceOf(this.read(instance) ?? {});
    return !!src && existsSync(join(src, "storage", "nfs-server.sh"));
  };

  managed(instance: string): boolean {
    const c = this.read(instance);
    return !!c && (typeof c.management !== "string" || c.management === "managed");
  }

  // The deployed consumers that mount a share — what delete and revoke refuse over.
  mountedBy(share: string): string[] {
    return this.instances().filter((i) => mountsShare(this.read(i), share));
  }

  // The storage module's directory, through its registration (ADR-029 D1).
  storageDir(): string | null {
    const src = moduleSourceOf(this.read("storage") ?? {});
    return src && existsSync(src) ? src : null;
  }
}
