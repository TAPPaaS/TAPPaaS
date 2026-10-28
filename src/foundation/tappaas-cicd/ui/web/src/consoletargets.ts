// consoletargets.ts — where the assistant may position the console (ADR-034
// D7): a page, or a wizard or Modify dialog opened on it with values filled
// in. One catalog for both sides: the backend's open_console tool validates a
// target against it (assistant-tools.ts) and `tappaas ask` prints its address;
// the drawer routes there and opens the wizard (assistant.tsx, opener.ts).
// Pure, with no DOM and no node: the backend's build compiles it too.

import { MOVED_PATHS } from "./physical/views";

export type TargetValue = string | boolean | string[];
export type TargetValues = Record<string, TargetValue>;

export interface WizardDef {
  name: string;
  title: string; // "the Add node wizard"
  arg: "zone" | "module" | null; // what follows the name: modify-module immich
  path: (arg: string) => string;
  keys: string[] | null; // the values it takes; null: the object's fields
  values: string; // what the values are, for the model
  verbs: string[]; // the manager verbs the wizard runs ("site-manager node add")
}

const DAY2 = "/setup/day2";

export const WIZARDS: WizardDef[] = [
  {
    name: "add-node", title: "the Add node wizard", arg: null, path: () => DAY2,
    keys: ["name", "mac", "boot-disk", "wan-port", "no-wan", "lan-ports", "lan-mode", "pool", "ttl"],
    values: "name (tappaas1..9), mac, boot-disk, wan-port, no-wan, lan-ports, lan-mode, pool",
    verbs: ["site-manager node add"],
  },
  {
    name: "add-environment", title: "the Add an environment wizard", arg: null, path: () => DAY2, keys: null,
    values: "name and the environment's fields (displayName, zone, domains.primary, …)",
    verbs: ["environment-manager add"],
  },
  { name: "add-stack", title: "the Add a stack wizard", arg: null, path: () => DAY2, keys: ["stack"], values: "stack", verbs: ["module-manager add-stack"] },
  { name: "enrol-device", title: "the Enrol a device wizard", arg: null, path: () => DAY2, keys: ["name", "pubkey", "ip", "endpoint"], values: "name, pubkey, ip, endpoint", verbs: ["network-manager wgvpn"] },
  {
    name: "add-wifi", title: "the WiFi wizard", arg: "zone", path: (z) => `${DAY2}#wifi-${z}`,
    keys: ["ssid", "ap", "security"], values: "ssid, ap, security", verbs: ["ap-manager ssid"],
  },
  { name: "add-buddy", title: "the Add a backup buddy wizard", arg: null, path: () => DAY2, keys: ["kind", "name"], values: "kind (pull or remote), name", verbs: ["backup-manager peer add"] },
  {
    name: "adopt-machine", title: "the Adopt a machine wizard", arg: null, path: () => DAY2,
    keys: ["address", "instance", "zone", "location", "switch-port"], values: "address, instance, zone, location (one of the site's), switch-port (<switch>:<port>)", verbs: ["module-manager adopt"],
  },
  {
    name: "add-satellite", title: "the Add a satellite wizard", arg: null, path: () => DAY2,
    keys: ["address", "environment", "roles", "location", "country", "city", "instance"], values: "address, environment, roles, location (one of the site's) or country and city, instance", verbs: [],
  },
  { name: "add-user", title: "the Add a user wizard", arg: null, path: () => DAY2, keys: null, values: "name and the user's fields (email, groups, …)", verbs: ["identity-manager user add"] },
  {
    name: "add-rack", title: "the Add a rack wizard", arg: null, path: () => DAY2, keys: null,
    values: "name and the rack's fields (units, width, numbering, room, …)", verbs: ["position-manager rack add"],
  },
  {
    // The device is a value: a topology name may hold spaces ("USW Pro XG 10 PoE").
    name: "place-device", title: "the Place a device wizard", arg: null, path: () => DAY2,
    keys: ["device", "rack", "u", "height", "width", "slot", "face", "room", "faceplate", "label", "description"],
    values: "device (as the physical view names it), and rack, u, height, width, slot, face — or room, loose in it — faceplate, label, description",
    verbs: ["position-manager place"],
  },
  {
    name: "modify-module", title: "Modify", arg: "module", path: (m) => `/modules/${encodeURIComponent(m)}`, keys: null,
    values: "the module's fields by name, as module_show lists them under modifiable: {\"memory\": \"10240\"}",
    verbs: ["module-manager modify"],
  },
  {
    name: "modify-zone", title: "Modify", arg: "zone", path: (z) => `/zones?zone=${encodeURIComponent(z)}`, keys: null,
    values: "the zone's fields by name", verbs: ["network-manager modify"],
  },
];

// The pages, by path; <module> is a module's name.
export const PAGES: { path: string; title: string }[] = [
  { path: "/", title: "the Overview" },
  { path: "/setup", title: "Setup" },
  { path: "/setup/day1", title: "Setup, Day 1" },
  { path: "/setup/day2", title: "Setup, Day 2" },
  { path: "/site", title: "the Site page (its Overview: the site as built, site.json, the update schedule, Update now, the release train, the repositories)" },
  { path: "/site/overview", title: "the site overview (racks, devices and storage summed up, every finding; Add node; site.json, the update schedule, Update now, the release train, the repositories)" },
  { path: "/site/physical", title: "the physical view (racks, faceplates, cables)" },
  { path: "/site/device", title: "the device view (every physical device and its connections)" },
  { path: "/site/storage", title: "the storage view (nodes, pools, disks, what each pool holds)" },
  { path: "/environments", title: "Environments (a card per environment with its zones and their modules; a click opens its record and verbs)" },
  { path: "/zones", title: "Zones (the zones graph, each zone's fields and verbs)" },
  { path: "/modules", title: "Modules" },
  { path: "/modules/<module>", title: "the module's page" },
  { path: "/identity", title: "Identity" },
  { path: "/backup", title: "Backup" },
  { path: "/activity", title: "Activity" },
];

const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/;

export interface Resolved {
  ok: true;
  target: string; // as it is recorded: "modify-module immich", "/site/physical"
  kind: "page" | "wizard";
  path: string;
  title: string; // "the Add node wizard", "Modify immich", "the physical view"
  wizard: string | null;
  arg: string | null;
  values: TargetValues;
}
export type Resolution = Resolved | { ok: false; reason: string };

export function wizardOf(name: string): WizardDef | null {
  return WIZARDS.find((w) => w.name === name) ?? null;
}

// A value as a form takes it: a string, a tick, or a list (a number is its text).
function valueOf(v: unknown): TargetValue | null {
  if (typeof v === "string" || typeof v === "boolean") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  if (Array.isArray(v) && v.every((x) => typeof x === "string" || typeof x === "number")) return v.map(String);
  return null;
}

// The catalog's word for a target, with its values checked. Values are what
// the form starts from; nothing is applied by opening it.
// Words that name a page.
export const PAGE_WORDS: Record<string, string> = { "rack-view": "/site/physical" };

export function resolveTarget(target: unknown, values?: unknown): Resolution {
  if (typeof target !== "string" || !target.trim()) return { ok: false, reason: "`target` is a page (\"/modules/immich\") or a wizard (\"add-node\", \"modify-module immich\")" };
  const said = target.trim().replace(/\s+/g, " ");
  const t = PAGE_WORDS[said] ?? said;
  if (values !== undefined && values !== null && (typeof values !== "object" || Array.isArray(values))) return { ok: false, reason: "`values` is an object of a form's values: {\"memory\": \"10240\"}" };
  const vals: TargetValues = {};
  for (const [k, v] of Object.entries((values ?? {}) as Record<string, unknown>)) {
    const x = valueOf(v);
    if (x === null) return { ok: false, reason: `the value of '${k}' is not a string, number, true/false or list` };
    vals[k.replace(/^-+/, "")] = x;
  }
  if (t.startsWith("/")) {
    const said = t.split(/[?#]/)[0].replace(/\/+$/, "") || "/";
    const path = MOVED_PATHS[said] ?? said; // an earlier address of a page
    if (Object.keys(vals).length) return { ok: false, reason: "a page takes no values: open a wizard (e.g. modify-module <name>) to fill a form" };
    const m = /^\/modules\/([^/]+)$/.exec(path);
    if (m) {
      const name = decodeURIComponent(m[1]);
      if (!NAME.test(name)) return { ok: false, reason: `'${name}' is not a module's name` };
      return { ok: true, target: path, kind: "page", path: `/modules/${encodeURIComponent(name)}`, title: `${name}'s page`, wizard: null, arg: name, values: {} };
    }
    const p = PAGES.find((x) => x.path === path);
    if (!p) return { ok: false, reason: `no page ${path} (pages: ${PAGES.map((x) => x.path).join(", ")})` };
    return { ok: true, target: path, kind: "page", path, title: p.title, wizard: null, arg: null, values: {} };
  }
  const [name, ...rest] = t.split(" ");
  const w = wizardOf(name);
  if (!w) return { ok: false, reason: `no wizard '${name}' (wizards: ${WIZARDS.map((x) => (x.arg ? `${x.name} <${x.arg}>` : x.name)).join(", ")}; or a page path such as /site/physical)` };
  let arg: string | null = rest.join(" ") || null;
  if (w.arg) {
    // The object may come as a value too: add-wifi {zone: "home"}.
    if (!arg && typeof vals[w.arg] === "string") arg = vals[w.arg] as string;
    delete vals[w.arg];
    if (!arg) return { ok: false, reason: `${w.name} needs the ${w.arg}: "${w.name} <${w.arg}>"` };
    if (!NAME.test(arg)) return { ok: false, reason: `'${arg}' is not a ${w.arg}'s name` };
  } else if (arg) return { ok: false, reason: `${w.name} takes no name after it; give its values instead (${w.values})` };
  if (w.keys) {
    const stray = Object.keys(vals).filter((k) => !w.keys!.includes(k));
    if (stray.length) return { ok: false, reason: `${w.name} has no ${stray.join(", ")}: its values are ${w.values}` };
  }
  const title = w.arg ? (w.name.startsWith("modify-") ? `Modify ${arg}` : `${w.title} for ${arg}`) : w.title;
  return { ok: true, target: arg ? `${w.name} ${arg}` : w.name, kind: "wizard", path: w.path(arg ?? ""), title, wizard: w.name, arg, values: vals };
}

// The wizard that runs a manager verb, for the assistant's refusal of an
// invented tool: the command's own words ("site-manager node add" → add-node).
export function wizardForVerb(bin: string, words: string): WizardDef | null {
  const full = `${bin} ${words}`;
  return WIZARDS.find((w) => w.verbs.some((v) => full === v || full.startsWith(`${v} `))) ?? null;
}

// The catalog in a few lines, for the system prompt.
export function catalogText(): string {
  return [
    `Wizards: ${WIZARDS.map((w) => `${w.arg ? `${w.name} <${w.arg}>` : w.name} (values: ${w.values})`).join("; ")}.`,
    `Pages: ${PAGES.map((p) => p.path).join(", ")} (rack-view is ${PAGE_WORDS["rack-view"]}).`,
  ].join("\n");
}
