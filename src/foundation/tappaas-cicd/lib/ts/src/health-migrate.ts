// health-migrate.ts — what was stored before the condition types split
// (health-rules.ts LEGACY_TYPES), as it reads now.
//
// The CMDB keeps per object its conditions, the operator's acknowledgements and
// the flapping holds, each keyed by condition type; emit's cursor keeps the
// roots and notices it told by "<ci>:<type>", and the digest the keys it told
// as "<class>/<name> <type> <reason>". A `security` or `maintenance` among them
// is mapped by the condition's reason (and its source), so an acknowledgement,
// a since and a told notice carry over to the new type instead of ending and
// starting again. Pure: the readers use it on the fly until the one-time
// `health-manager migrate types --apply` has written it back.

import { LEGACY_TYPES, currentType, currentTypesOf } from "./health-rules";

export interface StoredCondition { type: string; status?: string; reason?: string | null; owner?: string | null }
export interface StoredWord { at?: string }

const RANK: Record<string, number> = { critical: 3, warning: 2, unknown: 1, ok: 0 };
export const isLegacy = (t: unknown): boolean => typeof t === "string" && (LEGACY_TYPES as readonly string[]).includes(t);

/** A stored condition's type as it reads now. */
export const typeOf = (c: StoredCondition): string => currentType(c.type, c.reason ?? null, c.owner ?? null) ?? c.type;

/** The conditions with their types as they read now: one per type, the worst
 *  when two old ones land on the same new type. The same array when nothing
 *  was written before the split. */
export function migrateConditions<T extends StoredCondition>(cs: T[]): T[] {
  if (!cs.some((c) => isLegacy(c.type))) return cs;
  const out = new Map<string, T>();
  for (const c of cs) {
    const n = isLegacy(c.type) ? { ...c, type: typeOf(c) } : c;
    const had = out.get(n.type);
    if (!had || (RANK[n.status ?? "ok"] ?? 0) > (RANK[had.status ?? "ok"] ?? 0)) out.set(n.type, n);
  }
  return [...out.values()];
}

/** The new types a word keyed by an old type now speaks for: those its
 *  object's old conditions of that type map to, else every type it split into. */
function targets(type: string, conds: StoredCondition[]): string[] {
  const mine = conds.filter((c) => c.type === type).map(typeOf);
  return mine.length ? [...new Set(mine)] : currentTypesOf(type);
}

/** A map keyed by condition type (acknowledgements, flapping) with its old keys
 *  moved to the new types; a word already under the new type stays when it is
 *  newer. The same object when nothing was keyed by an old type. */
export function migrateKeyed<W extends StoredWord>(words: Record<string, W> | undefined, conds: StoredCondition[]): Record<string, W> | undefined {
  if (!words || !Object.keys(words).some(isLegacy)) return words;
  const out: Record<string, W> = {};
  for (const [k, w] of Object.entries(words)) if (!isLegacy(k)) out[k] = w;
  for (const [k, w] of Object.entries(words)) {
    if (!isLegacy(k)) continue;
    for (const t of targets(k, conds)) {
      const had = out[t];
      if (!had || (w.at && had.at && Date.parse(w.at) > Date.parse(had.at))) out[t] = w;
    }
  }
  return out;
}

/** "<ci>:<type>" with an old type, given the object's stored conditions. */
export function migrateRootKey(key: string, condsOf: (ci: string) => StoredCondition[]): string[] {
  const at = key.lastIndexOf(":");
  if (at < 0) return [key];
  const ci = key.slice(0, at), type = key.slice(at + 1);
  return isLegacy(type) ? targets(type, condsOf(ci)).map((t) => `${ci}:${t}`) : [key];
}

/** A digest key "<class>/<name> <type> <reason>" with an old type. */
export function migrateDigestKey(key: string): string {
  const parts = key.split(" ");
  if (parts.length < 3 || !isLegacy(parts[1])) return key;
  return [parts[0], currentType(parts[1], parts.slice(2).join(" ")) ?? parts[1], ...parts.slice(2)].join(" ");
}

interface StoredObject { id: string; attributes: Record<string, unknown> }

/** An object with everything keyed by an old type read as now; the site's root
 *  list with its types mapped by each root's stored conditions. The object
 *  itself when nothing changes. `condsOf` gives another object's stored
 *  conditions (for the site's roots); without it the site's own are used. */
export function migrateStoredObject<O extends StoredObject>(o: O, condsOf?: (id: string) => StoredCondition[]): O {
  const a = o.attributes ?? {};
  const before = Array.isArray(a.conditions) ? (a.conditions as StoredCondition[]) : [];
  const conditions = migrateConditions(before);
  const acks = migrateKeyed(a.acknowledgements as Record<string, StoredWord> | undefined, before);
  const flaps = migrateKeyed(a.flapping as Record<string, StoredWord> | undefined, before);
  const roots = Array.isArray(a.rootCauses) ? (a.rootCauses as { id: string; type?: string }[]) : null;
  const rootsNow = roots?.some((r) => isLegacy(r.type))
    ? roots.flatMap((r) => (isLegacy(r.type) ? targets(r.type!, (condsOf ?? (() => before))(r.id)).map((t) => ({ ...r, type: t })) : [r]))
    : roots;
  if (conditions === before && acks === a.acknowledgements && flaps === a.flapping && rootsNow === roots) return o;
  return {
    ...o,
    attributes: {
      ...a,
      ...(Array.isArray(a.conditions) ? { conditions } : {}),
      ...(acks ? { acknowledgements: acks } : {}),
      ...(flaps ? { flapping: flaps } : {}),
      ...(rootsNow ? { rootCauses: rootsNow } : {}),
    },
  };
}

/** Every object read as now (migrateStoredObject), the site's roots by their
 *  objects' stored conditions. The same array when nothing changes. */
export function migrateStoredObjects<O extends StoredObject>(objects: O[]): O[] {
  const byId = new Map(objects.map((o) => [o.id, o]));
  const condsOf = (id: string): StoredCondition[] => {
    const c = byId.get(id)?.attributes?.conditions;
    return Array.isArray(c) ? (c as StoredCondition[]) : [];
  };
  let changed = false;
  const out = objects.map((o) => {
    const n = migrateStoredObject(o, condsOf);
    if (n !== o) changed = true;
    return n;
  });
  return changed ? out : objects;
}
