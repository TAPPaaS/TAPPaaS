// envcards.ts — the Environments page as data: one card per environment, in
// it one box per zone it owns (its own zone, and every zone that `serves` it),
// and in each box the modules installed there. A module sits in its own
// environment's card, in the box of its zone; a zone the environment does not
// own (the DMZ, mgmt) gets a box of its own marked shared, a module with no
// zone a box "no zone". Plain data: the unit tests run it over hrossen's
// records.

export interface EnvLike {
  name: string;
  displayName?: string;
  network?: { zone?: string };
  domains?: { primary?: string };
}
export interface ZoneLike {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  serves?: string | string[];
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
  type: string | null; // its own zone's type
  isDefault: boolean;
  boxes: ZoneBox<M>[];
  modules: number;
}

const servesOf = (z: ZoneLike): string[] => (Array.isArray(z.serves) ? z.serves : typeof z.serves === "string" && z.serves ? [z.serves] : []);

export function envCards<E extends EnvLike, M extends ModuleLike>(envs: E[], zones: ZoneLike[], modules: M[], defaultEnv: string | null): EnvCard<E, M>[] {
  return envs.map((e) => {
    const own = e.network?.zone ?? null;
    const owned = [...(own ? [own] : []), ...zones.filter((z) => z.name !== own && servesOf(z).includes(e.name)).map((z) => z.name)];
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
    return { env: e, type: z?.type ?? null, isDefault: e.name === defaultEnv, boxes, modules: mine.length };
  });
}
