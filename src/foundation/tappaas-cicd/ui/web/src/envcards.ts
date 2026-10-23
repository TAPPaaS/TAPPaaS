// envcards.ts — the Environments page as data: one card per environment, in
// it one box per zone it owns (every zone naming it: its own Service zone, and
// the client and IoT zones that serve it),
// and in each box the modules installed there. A module sits in its own
// environment's card, in the box of its zone; a zone the environment does not
// own (the DMZ, mgmt) gets a box of its own marked shared, a module with no
// zone a box "no zone". Plain data: the unit tests run it over hrossen's
// records.

export interface EnvLike {
  name: string;
  displayName?: string;
  zone?: string | null; // the zone naming it, as the environments read joins it
  domains?: { primary?: string };
}
export interface ZoneLike {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  environment?: string;
}
export interface ModuleLike {
  name: string;
  zone0: string | null;
  environment: string | null;
}

export interface ZoneBox<M extends ModuleLike> {
  zone: string | null; // null: the modules with no zone
  record: ZoneLike | null;
  own: boolean; // the environment owns it
  modules: M[];
}

export interface EnvCard<E extends EnvLike, M extends ModuleLike> {
  env: E;
  zone: string | null; // its own zone
  type: string | null; // its own zone's type
  isDefault: boolean;
  boxes: ZoneBox<M>[];
  modules: number;
}

// An environment's own zone: the Service (or Management) zone naming it.
const OWN_TYPES = new Set(["Service", "Management"]);
export const ownZoneOf = (zones: ZoneLike[], env: string): string | null =>
  zones.find((z) => z.environment === env && OWN_TYPES.has(z.type ?? ""))?.name ?? null;

export function envCards<E extends EnvLike, M extends ModuleLike>(envs: E[], zones: ZoneLike[], modules: M[], defaultEnv: string | null): EnvCard<E, M>[] {
  return envs.map((e) => {
    const own = e.zone ?? ownZoneOf(zones, e.name);
    const owned = [...(own ? [own] : []), ...zones.filter((z) => z.name !== own && z.environment === e.name).map((z) => z.name)];
    const boxes: ZoneBox<M>[] = owned.map((z) => ({ zone: z, record: zones.find((x) => x.name === z) ?? null, own: true, modules: [] }));
    const mine = modules.filter((m) => m.environment === e.name).sort((a, b) => a.name.localeCompare(b.name));
    for (const m of mine) {
      let box = boxes.find((b) => b.zone === m.zone0);
      if (!box) {
        box = { zone: m.zone0, record: m.zone0 ? zones.find((x) => x.name === m.zone0) ?? null : null, own: false, modules: [] };
        boxes.push(box);
      }
      box.modules.push(m);
    }
    // Owned zones first (its own zone leading), then shared ones, then "no zone".
    const rank = (b: ZoneBox<M>) => (b.zone === own ? 0 : b.own ? 1 : b.zone ? 2 : 3);
    boxes.sort((a, b) => rank(a) - rank(b) || (a.zone ?? "").localeCompare(b.zone ?? ""));
    const z = zones.find((x) => x.name === own);
    return { env: e, zone: own, type: z?.type ?? null, isDefault: e.name === defaultEnv, boxes, modules: mine.length };
  });
}
