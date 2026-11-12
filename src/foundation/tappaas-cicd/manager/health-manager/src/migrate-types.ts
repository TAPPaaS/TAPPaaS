// migrate-types.ts — `health-manager migrate types [--apply]`: the one-time
// write-back of what was stored before the condition types split
// (maintenance → upkeep, security → vulnerability and threat).
//
// Every reader maps an old type on the fly (lib/ts/src/health-migrate.ts), so a
// site runs correctly before this has run; this writes it back so the mapping
// is done once:
//
//   the rule store    config/health/: the installed records, their base and the
//                     site's edits (RuleStore.read maps them); a site-edited
//                     rule stays edited, under its new type
//   acknowledgements  per object, keyed by type (the ack verbs' attribute)
//   flapping          per object, keyed by type (emit's attribute)
//   emit's cursor     the roots and notices told, by "<ci>:<type>"
//   the digest        the keys it told
//
// The conditions and the site's root list are assess's to write: the next
// assess writes them under the new types, keeping each since and ack. Without
// --apply it says what it would change and writes nothing. Running it again
// changes nothing.

import { StoredCondition, StoredWord, isLegacy, migrateDigestKey, migrateKeyed, migrateRootKey } from "../../../lib/ts/src/health-migrate";
import { RuleStore, healthDir } from "./rulestore";
import { Cursor, readCursor, writeCursor } from "./emit";
import { readSeen, writeSeen } from "./digest";

export interface MigrateObject { id: string; class: string; name: string; attributes: Record<string, unknown> }
export interface MigrateIO {
  configDir: string;
  objects(): MigrateObject[]; // as stored, not mapped
  write(o: MigrateObject, attributes: Record<string, unknown>): void;
}
export interface MigrateResult { rules: string[]; objects: string[]; conditions: number; cursor: number; digest: number }

const condsOf = (o: MigrateObject | undefined): StoredCondition[] => (Array.isArray(o?.attributes.conditions) ? (o!.attributes.conditions as StoredCondition[]) : []);

/** What the migration changes; written only with apply. */
export function migrateTypes(io: MigrateIO, apply: boolean): MigrateResult {
  const res: MigrateResult = { rules: [], objects: [], conditions: 0, cursor: 0, digest: 0 };

  const store = RuleStore.read(healthDir(io.configDir));
  if (store.installed && store.migratedTypes.length) {
    res.rules = store.migratedTypes;
    if (apply) store.write();
  }

  const objects = io.objects();
  const byId = new Map(objects.map((o) => [o.id, o]));
  for (const o of objects) {
    const before = condsOf(o);
    if (before.some((c) => isLegacy(c.type))) res.conditions++;
    const a = o.attributes;
    const acks = migrateKeyed(a.acknowledgements as Record<string, StoredWord> | undefined, before);
    const flaps = migrateKeyed(a.flapping as Record<string, StoredWord> | undefined, before);
    const write: Record<string, unknown> = {};
    if (acks !== a.acknowledgements) write.acknowledgements = acks;
    if (flaps !== a.flapping) write.flapping = flaps;
    if (!Object.keys(write).length) continue;
    res.objects.push(`${o.class}/${o.name}`);
    if (apply) io.write(o, write);
  }

  const cur = readCursor(io.configDir);
  if (cur) {
    const ofCi = (ci: string): StoredCondition[] => condsOf(byId.get(ci));
    const remap = <V extends { type?: string }>(m: Record<string, V> | undefined): Record<string, V> | undefined => {
      if (!m) return m;
      const out: Record<string, V> = {};
      for (const [k, v] of Object.entries(m)) {
        const keys = migrateRootKey(k, ofCi);
        if (keys.length !== 1 || keys[0] !== k) res.cursor++;
        for (const nk of keys) out[nk] = isLegacy(v.type) ? { ...v, type: nk.slice(nk.lastIndexOf(":") + 1) } : v;
      }
      return out;
    };
    const next: Cursor = { ...cur, roots: remap(cur.roots) ?? {}, ...(cur.notices ? { notices: remap(cur.notices as Record<string, { type?: string }>) as Cursor["notices"] } : {}) };
    if (res.cursor && apply) writeCursor(io.configDir, next);
  }

  const seen = readSeen(io.configDir);
  if (seen) {
    const keys = seen.keys.map(migrateDigestKey);
    res.digest = keys.filter((k, i) => k !== seen.keys[i]).length;
    if (res.digest && apply) writeSeen(io.configDir, { ...seen, keys });
  }
  return res;
}

export function migrateLines(r: MigrateResult, apply: boolean): string[] {
  const will = apply ? "" : "would be ";
  const out: string[] = [];
  if (r.rules.length) out.push(`health rules ${will}rewritten to the new types: ${r.rules.join(", ")}`);
  if (r.objects.length) out.push(`acknowledgements ${will}moved to the new types on ${r.objects.length} object(s): ${r.objects.slice(0, 8).join(", ")}${r.objects.length > 8 ? ", …" : ""}`);
  if (r.cursor) out.push(`${r.cursor} told root cause(s) and notice(s) ${will}carried over to the new types`);
  if (r.digest) out.push(`${r.digest} digest line(s) ${will}carried over to the new types`);
  if (r.conditions) out.push(`${r.conditions} object(s) still hold conditions under the old types: the next assess writes them under the new ones`);
  if (!out.length) out.push("nothing stored under the old condition types");
  return out;
}

