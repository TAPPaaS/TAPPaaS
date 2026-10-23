// fieldmanifest.ts — one field manifest for every add and modify form
// (GET /api/v1/fields/<kind>[/<name>]). It is derived from the schema JSONs the
// managers validate against — the composed module field schema, zones-fields,
// environment-fields, the identity *-fields, site-fields and its location, the module schema's
// backup block, racks-fields' rack and mount — plus, where the object exists, its record. Per field: its
// type, its choices (an enum, or the defined objects a `references` field names),
// its default (a literal, or a template such as <vmname>.<domain> rendered with
// the object's values when they are known), the configured value, whether it is
// required, its change class, a one-line description, whether this form may
// change it, and how a change is passed to the manager's own verb (`--set` or
// the verb's own flag). Pure: the reads that feed it are in reads.ts.

export const FIELD_KINDS = ["module", "zone", "environment", "org", "group", "user", "role", "site", "location", "backup", "rack", "mount", "room"] as const;
export type FieldKind = (typeof FIELD_KINDS)[number];
export type FormMode = "add" | "modify";

export interface ManifestField {
  name: string; // the field's path in the record (environment: domains.primary)
  type: "string" | "integer" | "boolean" | "list" | "object";
  typeText: string; // the label's second half: "integer", "one of a, b", "a zone", "zones"
  choices: string[] | null; // an enum, or the defined objects a reference names
  references: string | null;
  default: string | null; // the default as text; null: the field has none
  defaultTemplate: boolean; // the default is a template some of whose values are not known
  value: unknown; // the configured value; null when it is not configured
  configured: boolean;
  required: boolean;
  class: string | null; // the ADR-020 change class, where the kind has them
  apply: string | null; // its apply mode (none: recorded, shows at the next update)
  offRelease: boolean; // resolve's .orig note: kept off its release on purpose
  description: string; // one line
  editable: boolean; // this form may change it
  why: string | null; // why it may not
  arg: string | null; // "--set" (field=value) or the verb's own flag
  // A default the manager computes from what else the form says: an option's
  // value (--archetype, --environment) or another field's (typeId). The first
  // rule whose key has a value listed wins over `default`.
  defaultBy: DefaultRule[];
}

// on: an option's flag, or a field's name. values: the default's text per
// value of it; "*" stands for any value, "<value>" in its text for that value.
export interface DefaultRule {
  on: string;
  values: Record<string, string>;
}

export interface FieldManifest {
  kind: FieldKind;
  name: string | null;
  mode: FormMode;
  exists: boolean;
  fields: ManifestField[];
  // The field the verb's positional fills (environment, identity, site:
  // `name`): its one-line description, for the form's name row. null where the
  // schema has no such field (a zone is keyed by its name; a module's is its
  // catalogue's).
  nameField: { description: string } | null;
}

// A field definition as the schema files spell it, normalised.
export interface FieldDef {
  name: string;
  type?: unknown;
  enum?: unknown;
  values?: unknown; // zones-fields' documented enum: value -> meaning
  default?: unknown;
  description?: string;
  references?: string;
  required?: boolean;
  changeClass?: string;
  changeNote?: string; // why that class (site-fields: why a field is refused)
  usedBy?: unknown;
}

// The defined objects a `references` field may name.
export interface RefContext {
  zones: string[];
  environments: string[];
  nodes: { name: string; pools: string[] }[];
  organizations: string[];
  users: string[];
  groups: string[];
  roles: string[];
  // The racks' kinds (rack, mount): the topology's devices, the racks, the
  // faceplate catalog's keys. Empty for the other kinds.
  devices: string[];
  racks: string[];
  rooms: string[];
  faceplates: string[];
  // site.json's locations, by name
  locations: string[];
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const strs = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

// ── the pieces ─────────────────────────────────────────────────────────

export function typeOf(t: unknown): ManifestField["type"] {
  const words = (Array.isArray(t) ? t : typeof t === "string" ? t.split("|") : []).filter((x): x is string => typeof x === "string" && x !== "null");
  if (words.includes("array")) return "list";
  if (words.length === 1) {
    if (words[0] === "integer" || words[0] === "number") return "integer";
    if (words[0] === "boolean") return "boolean";
    if (words[0] === "object") return "object";
  }
  return "string";
}

const ONE: Record<string, string> = { zones: "a zone", environments: "an environment", nodes: "a node", storage: "a storage pool", organizations: "an organization", users: "a user", groups: "a group", roles: "a role", devices: "a device", racks: "a rack", rooms: "a room", faceplates: "a faceplate", locations: "a location" };
const MANY: Record<string, string> = { zones: "zones", environments: "environments", nodes: "nodes", storage: "storage pools", organizations: "organizations", users: "users", groups: "groups", roles: "roles", devices: "devices", racks: "racks", rooms: "rooms", faceplates: "faceplates", locations: "locations" };

export function typeTextOf(type: ManifestField["type"], references: string | null, enumValues: string[] | null): string {
  if (references) return type === "list" ? MANY[references] ?? references : ONE[references] ?? references;
  if (enumValues && enumValues.length) return enumValues.length <= 8 ? `one of ${enumValues.join(", ")}` : `one of ${enumValues.length}`;
  return type;
}

// A schema description as one line: without the issue and ADR references that
// tell a developer where it came from, and only its first sentence.
export function oneLine(s: string | undefined): string {
  if (!s) return "";
  const t = s
    .replace(/\s*\((?:(?:#\d+|CR-\d+)(?:[,;] ?)?)+\)/g, "")
    .replace(/\s*\(ADR-\d+[^)]*\)/g, "")
    .replace(/\s+/g, " ")
    .trim();
  // The first sentence end that is not an abbreviation's (e.g., i.e., etc.).
  let first = t;
  const ends = /[.!?](?=\s|$)/g;
  for (let e = ends.exec(t); e; e = ends.exec(t)) {
    const upto = t.slice(0, e.index + 1);
    if (/\b(e\.g|i\.e|etc|vs|cf)\.$/i.test(upto)) continue;
    first = upto;
    break;
  }
  return first.length > 180 ? `${first.slice(0, first.lastIndexOf(" ", 177))}…` : first;
}

// The default as an operator reads it. A template (<vmname>.<domain>) is
// rendered from the object's values when every one is known, else it stays as
// written; a placeholder in words (<computed from …>) is its words. An empty
// list or string is "empty"; no default at all is null ("no default").
export function renderDefault(d: unknown, vars: Record<string, string | null | undefined>): { text: string; template: boolean } | null {
  if (d === null || d === undefined) return null;
  if (Array.isArray(d)) return { text: d.length ? d.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(", ") : "empty", template: false };
  if (typeof d === "object") return { text: Object.keys(d as Obj).length ? JSON.stringify(d) : "empty", template: false };
  if (typeof d !== "string") return { text: String(d), template: false };
  if (d === "") return { text: "empty", template: false };
  // <words: …> — a placeholder in words, never applied
  if (/^<.*>$/.test(d) && /^<[^<>]*[\s:]/.test(d)) {
    return { text: d.slice(1, -1).replace(/^(internal default|derived|computed)\s*:\s*/i, "").trim(), template: false };
  }
  if (!/<[A-Za-z][\w.]*>/.test(d)) return { text: d, template: false };
  let missing = false;
  const out = d.replace(/<([A-Za-z][\w.]*)>/g, (_m, k: string) => {
    const v = vars[k] ?? vars[k.split(".").pop() ?? k];
    if (v === null || v === undefined || v === "") {
      missing = true;
      return `<${k.split(".").pop()}>`;
    }
    return v;
  });
  return { text: out, template: missing };
}

function enumOf(def: FieldDef): string[] | null {
  if (Array.isArray(def.enum)) return def.enum.filter((x) => x !== null).map(String);
  if (def.values && typeof def.values === "object" && !Array.isArray(def.values)) return Object.keys(def.values as Obj);
  return null;
}

export function choicesFor(references: string | null, refs: RefContext, record: Obj | null): string[] | null {
  switch (references) {
    case "zones":
      return refs.zones;
    case "environments":
      return refs.environments;
    case "nodes":
      return refs.nodes.map((n) => n.name);
    case "storage": {
      const node = typeof record?.node === "string" ? record.node : null;
      const pools = node ? refs.nodes.find((n) => n.name === node)?.pools ?? [] : [...new Set(refs.nodes.flatMap((n) => n.pools))];
      return pools.sort();
    }
    case "organizations":
      return refs.organizations;
    case "users":
      return refs.users;
    case "groups":
      return refs.groups;
    case "roles":
      return refs.roles;
    case "devices":
      return refs.devices;
    case "racks":
      return refs.racks;
    case "rooms":
      return refs.rooms;
    case "faceplates":
      return refs.faceplates;
    case "locations":
      return refs.locations;
    default:
      return null;
  }
}

// A value at a dotted path of a record.
export function valueAt(record: Obj | null, path: string): unknown {
  let v: unknown = record;
  for (const p of path.split(".")) {
    if (v === null || typeof v !== "object" || Array.isArray(v)) return undefined;
    v = (v as Obj)[p];
  }
  return v;
}

// An environment's zone is not a field of its file (#865): the zone in
// zones.json names the environment. The form still offers it, as the verbs do:
// environment-manager add/modify --zone links the zone to the environment.
export const ENVIRONMENT_ZONE_FIELD: FieldDef = {
  name: "zone",
  type: "string",
  description: "The Service zone its modules run in: the zone in zones.json that names this environment. Setting it links that zone to the environment (network-manager bind) and clears the old zone's link.",
  references: "zones",
  required: false,
  changeClass: "in-place",
};

// environment-fields' fields, with the environment's zone after its owner.
export function environmentDefs(doc: unknown): FieldDef[] {
  const defs = flattenSchema(doc);
  const at = defs.findIndex((d) => d.name === "ownerOrg");
  defs.splice(at < 0 ? defs.length : at + 1, 0, ENVIRONMENT_ZONE_FIELD);
  return defs;
}

// A JSON-Schema document's properties as dotted leaves (environment-fields,
// site-fields, the identity *-fields, a racks-fields $def): an object with
// properties of its own is walked, every other property is a field. `required`
// is per level; a property's changeClass is carried where the schema has one.
export function flattenSchema(doc: unknown, prefix = "", requiredHere = true, inherited: { changeClass?: string; changeNote?: string } = {}): FieldDef[] {
  const d = obj(doc);
  const required = new Set(strs(d.required));
  const out: FieldDef[] = [];
  for (const [k, raw] of Object.entries(obj(d.properties))) {
    const p = obj(raw);
    const name = prefix ? `${prefix}.${k}` : k;
    const isReq = requiredHere && required.has(k);
    // A leaf takes its object's class (site.json: diskAutoGrow in-place, so diskAutoGrow.threshold).
    const cls = typeof p.changeClass === "string" ? { changeClass: p.changeClass, ...(typeof p.changeNote === "string" ? { changeNote: p.changeNote } : {}) } : inherited;
    if (Object.keys(obj(p.properties)).length > 0) {
      out.push(...flattenSchema(p, name, isReq, cls));
      continue;
    }
    out.push({ name, type: p.type, enum: p.enum, default: p.default, description: typeof p.description === "string" ? p.description : undefined, references: typeof p.references === "string" ? p.references : undefined, required: isReq, ...cls });
  }
  return out;
}

// zones-fields.json: `fields` by name, with `required`, `values` and `changeClass`.
export function zoneDefs(doc: unknown): FieldDef[] {
  return Object.entries(obj(obj(doc).fields)).map(([name, raw]) => {
    const p = obj(raw);
    return { name, type: p.type, enum: p.enum, values: p.values, default: p.default, description: typeof p.description === "string" ? p.description : undefined, references: typeof p.references === "string" ? p.references : undefined, required: p.required === true, changeClass: typeof p.changeClass === "string" ? p.changeClass : undefined };
  });
}

// The composed module schema's fields, in the schema's own order (fieldOrder,
// then the rest by name).
export function moduleDefs(schemaDoc: unknown): FieldDef[] {
  const d = obj(schemaDoc);
  const fields = obj(d.fields);
  const order = strs(d.fieldOrder);
  const names = [...order.filter((n) => n in fields), ...Object.keys(fields).filter((n) => !order.includes(n)).sort()];
  // `config` is the services' nesting (Pattern A), not a field of its own.
  return names.filter((n) => n !== "config").map((name) => {
    const p = obj(fields[name]);
    return { name, type: p.type, enum: p.enum, values: p.values, default: p.default, description: typeof p.description === "string" ? p.description : undefined, references: typeof p.references === "string" ? p.references : undefined, usedBy: p.usedBy };
  });
}

// The module schema's backup block: the leaf of the site → environment → module
// cascade that backup-manager modify changes.
export function backupDefs(schemaDoc: unknown): FieldDef[] {
  const b = obj(obj(obj(schemaDoc).fields).backup);
  return Object.entries(obj(b.properties)).map(([name, raw]) => {
    const p = obj(raw);
    return { name, type: p.type, enum: p.enum, default: p.default, description: typeof p.description === "string" ? p.description : undefined };
  });
}

// ── how each kind's verb takes a field ─────────────────────────────────

// The verb's own flags, by field: the one table from a schema field to the
// manager's option (displayName → --displayName, primaryEmail → --email,
// memberOf → --groups, …). A field with no flag cannot change through that
// verb: the form shows it read-only. test/unit/flags.test.ts holds the
// identity and backup rows to identity-manager's and backup-manager's own
// option lists.
export const FLAGS: Partial<Record<FieldKind, Partial<Record<FormMode, Record<string, string>>>>> = {
  environment: {
    add: { displayName: "--display", ownerOrg: "--owner", zone: "--zone", "domains.primary": "--domain", "domains.dnsMode": "--dns-mode" },
    modify: { displayName: "--display", ownerOrg: "--owner", zone: "--zone", "domains.primary": "--domain", "domains.dnsMode": "--dns-mode" },
  },
  org: { add: { displayName: "--displayName", type: "--type", owner: "--owner", parentOrg: "--parentOrg" }, modify: { displayName: "--displayName", type: "--type", owner: "--owner", parentOrg: "--parentOrg" } },
  group: { add: { displayName: "--displayName", type: "--type", ownerOrg: "--ownerOrg", roles: "--roles" }, modify: { displayName: "--displayName", type: "--type", ownerOrg: "--ownerOrg", roles: "--roles" } },
  user: {
    add: { displayName: "--displayName", primaryEmail: "--email", state: "--state", roles: "--roles", memberOf: "--groups" },
    modify: { displayName: "--displayName", primaryEmail: "--email", state: "--state", roles: "--roles", memberOf: "--groups" },
  },
  role: { add: { displayName: "--displayName", description: "--description" }, modify: { displayName: "--displayName", description: "--description" } },
  site: {
    modify: {
      displayName: "--displayName", owner: "--owner", email: "--email", channel: "--channel", automaticReboot: "--automaticReboot", ipv6: "--ipv6", requireSigned: "--requireSigned",
      snapshotRetention: "--snapshotRetention", "backup.target": "--backupTarget", "backup.offsite": "--backupOffsite", "backup.defaultSchedule": "--backupDefaultSchedule",
      "backup.defaultRetention": "--backupDefaultRetention", primaryLocation: "--primaryLocation", locale: "--locale", keyboard: "--keyboard", "branding.logo": "--brandingLogo", "branding.logoDark": "--brandingLogoDark", "network.isp": "--networkIsp", "network.publicIp": "--networkPublicIp",
      dnssec: "--dnssec", "dnsBlocklists.lists": "--dnsBlocklistsLists", "dnsBlocklists.zones": "--dnsBlocklistsZones", "dnsBlocklists.allow": "--dnsBlocklistsAllow",
      "diskAutoGrow.enabled": "--diskAutoGrowEnabled", "diskAutoGrow.threshold": "--diskAutoGrowThreshold", "diskAutoGrow.growPercent": "--diskAutoGrowGrowPercent",
      "diskAutoGrow.minGrowGB": "--diskAutoGrowMinGrowGB", "diskAutoGrow.poolCeiling": "--diskAutoGrowPoolCeiling",
      "updateSchedule.frequency": "--updateFrequency", "updateSchedule.weekday": "--updateWeekday", "updateSchedule.hour": "--updateHour",
    },
  },
  // site-manager location add/modify: one flag per field of site-fields' $defs.location.
  location: {
    add: { displayName: "--displayName", kind: "--kind", country: "--country", city: "--city", address: "--address", timezone: "--timezone", latitude: "--latitude", longitude: "--longitude" },
    modify: { displayName: "--displayName", kind: "--kind", country: "--country", city: "--city", address: "--address", timezone: "--timezone", latitude: "--latitude", longitude: "--longitude" },
  },
  backup: { modify: { enabled: "--enabled", retention: "--retention", exclude: "--exclude" } },
  zone: { add: { type: "--type", typeId: "--typeId", vlantag: "--vlan", variant: "--variant", environment: "--environment", "tftp-server-name": "--tftp-server-name", "bootfile-name": "--bootfile-name" } },
  rack: { add: { displayName: "--display-name", units: "--units", width: "--width", numbering: "--numbering", room: "--room", description: "--description" } },
  room: { add: { displayName: "--display-name", description: "--description" } },
  mount: { add: { rack: "--rack", u: "--u", room: "--room", height: "--height", width: "--width", slot: "--slot", face: "--face", faceplate: "--faceplate", label: "--label", description: "--description" } },
};

// Fields a form never offers whatever the schema says: the object's name is
// the verb's positional.
const NAME_FIELDS: Partial<Record<FieldKind, string[]>> = { environment: ["name"], org: ["name"], group: ["name"], user: ["name"], role: ["name"], rack: ["name"], mount: ["device"], room: ["name"], location: ["name"] };

// The classes a --set refuses before anything is written, per kind whose modify
// is `--set field=value` within each field's class (zones-fields, racks-fields).
const SET_REFUSED: Partial<Record<FieldKind, Record<string, string>>> = {
  zone: {
    immutable: "cannot change in place: delete the zone and add it again",
    recreate: "only by deleting the zone and adding it again",
    manual: "has a verb of its own",
  },
  rack: { immutable: "the rack's name is its key: add a rack under the new name and move the mounts" },
  mount: { immutable: "the device is the mount's key: remove the mount and mount the other device" },
  room: { immutable: "the room's name is how racks and mounts name it: add the new room, move them, delete this one" },
};

// ── the manifest ───────────────────────────────────────────────────────

export interface ManifestInput {
  kind: FieldKind;
  name: string | null;
  mode: FormMode;
  defs: FieldDef[];
  record: Obj | null; // the object's record (configured values); null for an add
  defaults?: Record<string, unknown>; // what stands in for a field left empty when the schema's default does not (a module's own JSON at add, the backup cascade, a manager's rule)
  // module modify: `module-manager fields` — the fields the module uses, each
  // with its change class, or why the pre-gate refuses it
  classes?: Record<string, { class: string; apply?: string | null; coordinate?: string; settable: boolean; reason: string | null; offRelease?: boolean }>;
  // schemas/fields.json of the console's own repository: the class and apply
  // mode of each field no service owns (what module-manager reports there too)
  moduleClasses?: Record<string, { class?: string; apply?: string; changeNote?: string }>;
  // module: the services the module declares, which decide which fields it uses at add
  services?: string[];
  refs: RefContext;
  vars: Record<string, string | null | undefined>; // a template's values: vmname, domain, zone0, name, …
  defaultBy?: Record<string, DefaultRule[]>; // by field: the defaults the manager computes from the other inputs
}

export function buildManifest(i: ManifestInput): FieldManifest {
  const flags = FLAGS[i.kind]?.[i.mode] ?? null;
  const hidden = new Set(NAME_FIELDS[i.kind] ?? []);
  const fields: ManifestField[] = [];
  let nameField: FieldManifest["nameField"] = null;
  for (const def of i.defs) {
    if (hidden.has(def.name)) {
      nameField = { description: oneLine(def.description) };
      continue;
    }
    const reported = i.classes?.[def.name];
    const own = i.kind === "module" ? i.moduleClasses?.[def.name] : undefined;
    // A field no service owns takes the class schemas/fields.json declares —
    // module-manager's label for it ("config-only") is never shown.
    const moduleLevel = own !== undefined && (!reported || reported.coordinate === "" || reported.class === "config-only");
    const klass = moduleLevel ? own!.class ?? null : reported?.class && reported.class !== "config-only" ? reported.class : def.changeClass ?? null;
    const apply = moduleLevel ? own!.apply ?? null : reported?.apply ?? null;
    const notByHand = klass === "immutable" || klass === "recreate" || klass === "manual";
    // A module shows the fields it uses: at modify the ones `module-manager
    // fields` lists, at add the ones its own JSON carries and its services use
    // (never one the release or the install writes).
    if (i.kind === "module") {
      if (i.mode === "modify" && i.classes && !reported) continue;
      if (i.mode === "add") {
        if (moduleLevel && notByHand) continue;
        const usedBy = strs(def.usedBy);
        const mine = i.defaults !== undefined && Object.prototype.hasOwnProperty.call(i.defaults, def.name);
        if (!mine && !usedBy.some((u) => (i.services ?? []).includes(u))) continue;
      }
    }
    const type = typeOf(def.type);
    const references = def.references ?? null;
    const en = enumOf(def);
    // A storage pool is one of the node in effect: configured, else the default.
    const choices = references ? choicesFor(references, i.refs, { ...((i.defaults as Obj | undefined) ?? {}), ...(i.record ?? {}) }) : en;
    const raw = i.record ? valueAt(i.record, def.name) : undefined;
    const configured = raw !== undefined && raw !== null;
    const fallback = i.defaults && def.name in i.defaults ? i.defaults[def.name] : def.default;
    const dflt = renderDefault(fallback, i.vars);
    // What may change here, and how.
    let arg: string | null = null;
    let why: string | null = null;
    if (i.kind === "module" && i.mode === "modify") {
      // why: the class's own reason, as schemas/fields.json words it
      if (moduleLevel && notByHand) why = oneLine(own!.changeNote) || (klass === "manual" ? "changed in the module's own JSON, then an update" : "the release or the install writes it");
      else if (reported && !reported.settable) why = reported.reason ?? "the pre-gate refuses it";
      else arg = "--set";
    } else if (i.kind === "module") arg = `--${def.name}`;
    else if (SET_REFUSED[i.kind] && i.mode === "modify") {
      const c = def.changeClass ?? "";
      if (!c) why = "has no change class: it cannot be set through a verb";
      else if (SET_REFUSED[i.kind]![c]) why = SET_REFUSED[i.kind]![c];
      else arg = "--set";
    } else if (i.kind === "site" && i.mode === "modify" && def.changeClass && def.changeClass !== "in-place") {
      // site-fields.json's class: name, version, defaultEnvironment are immutable
      why = `${def.changeClass}: ${oneLine(def.changeNote) || "site modify does not change it"}`;
    } else if (flags && flags[def.name]) arg = flags[def.name];
    else why = i.mode === "add" ? "not set when adding: change it afterwards" : "the verb has no option for it";
    fields.push({
      name: def.name,
      type,
      // A decimal (latitude) takes the integer input but is labelled for what it is.
      typeText: type === "integer" && /\bnumber\b/.test(JSON.stringify(def.type ?? "")) && !references && !en ? "number" : typeTextOf(type, references, en),
      choices,
      references,
      default: dflt?.text ?? null,
      defaultTemplate: dflt?.template ?? false,
      value: configured ? raw : null,
      configured,
      // At an add, a field the manager fills in itself is not the operator's to give.
      required: def.required === true && !(i.mode === "add" && i.defaults !== undefined && def.name in i.defaults && i.defaults[def.name] !== null),
      class: klass,
      apply,
      offRelease: reported?.offRelease === true,
      description: oneLine(def.description),
      editable: arg !== null,
      why: arg !== null ? null : why,
      arg,
      defaultBy: i.defaultBy?.[def.name] ?? [],
    });
  }
  return { kind: i.kind, name: i.name, mode: i.mode, exists: i.record !== null, fields, nameField };
}

// ── the defaults a manager computes at an add ──────────────────────────

const listText = (v: unknown): string => (Array.isArray(v) ? (v.length ? v.map(String).join(", ") : "empty") : String(v ?? ""));

// network-manager add's VLAN: the highest tag free in the zone type's band
// <typeId>60-<typeId>99 (zones.ts allocateVlan), its subId and network with it.
export const ZONE_SUB_MIN = 60;
export const ZONE_SUB_MAX = 99;

export function nextFreeVlan(zones: Array<[string, Obj]>, typeId: number): number | null {
  const used = new Set(zones.map(([, z]) => Number(z.vlantag)).filter((n) => Number.isInteger(n)));
  for (let s = ZONE_SUB_MAX; s >= ZONE_SUB_MIN; s--) if (!used.has(typeId * 100 + s)) return typeId * 100 + s;
  return null;
}

function bandDefaults(zones: Array<[string, Obj]>, typeId: number): Record<string, string> {
  const v = nextFreeVlan(zones, typeId);
  const range = `${typeId * 100 + ZONE_SUB_MIN}-${typeId * 100 + ZONE_SUB_MAX}`;
  if (v === null) return { vlantag: `none free in band ${typeId} (${range}): give one`, subId: "from the VLAN", ip: "from the VLAN" };
  const sub = v % 100;
  return { vlantag: `${v}, the highest free in band ${typeId} (${range})`, subId: String(sub), ip: `10.${typeId}.${sub}.0/24` };
}

// network-manager add <name> with fields left empty (zones.ts authorZone): a
// Service zone in band 2 reaching the internet, untiered; --archetype stamps
// the catalogue's type, typeId, tier, isolated and access-to seed; --from-zone
// inherits the source zone's; a typed typeId moves the VLAN to its band.
// catalog: zones-fields.json's archetypes.catalog.
export function zoneAddDefaults(zones: Array<[string, Obj]>, catalog: Obj): { defaults: Record<string, unknown>; by: Record<string, DefaultRule[]> } {
  const untiered = "untiered: no archetype";
  const defaults: Record<string, unknown> = {
    type: "Service", typeId: 2, ...bandDefaults(zones, 2), state: "Active", bridge: "lan", "access-to": ["internet"], "pinhole-allowed-from": [],
    tier: untiered, isolated: false, ipv6Subnet: "from the VLAN tag", description: "Zone <name>",
  };
  const by: Record<string, DefaultRule[]> = {};
  const add = (field: string, rule: DefaultRule) => (by[field] = [...(by[field] ?? []), rule]);
  const per = (on: string, rows: Record<string, Record<string, string>>) => {
    const fields = new Set(Object.values(rows).flatMap((r) => Object.keys(r)));
    for (const f of fields) add(f, { on, values: Object.fromEntries(Object.entries(rows).filter(([, r]) => r[f] !== undefined).map(([k, r]) => [k, r[f]])) });
  };
  per("--archetype", Object.fromEntries(Object.entries(catalog).map(([name, raw]) => {
    const a = obj(raw);
    const t = Number(a.typeId);
    return [name, { type: String(a.type), typeId: String(t), tier: String(a.tier), isolated: String(a.isolated === true), "access-to": listText(a["access-to"]), "pinhole-allowed-from": "empty", ...bandDefaults(zones, t), description: String(a.description ?? "") }];
  })));
  per("--from-zone", Object.fromEntries(zones.map(([name, z]) => {
    const t = Number(z.typeId);
    const row: Record<string, string> = { type: String(z.type ?? ""), typeId: String(z.typeId ?? ""), bridge: String(z.bridge ?? "lan"), "access-to": listText(z["access-to"] ?? []), "pinhole-allowed-from": listText(z["pinhole-allowed-from"] ?? []), tier: untiered, description: `Zone <name> (inherited from ${name})` };
    if (typeof z["tftp-server-name"] === "string") row["tftp-server-name"] = z["tftp-server-name"];
    if (typeof z["bootfile-name"] === "string") row["bootfile-name"] = z["bootfile-name"];
    return [name, Number.isInteger(t) ? { ...row, ...bandDefaults(zones, t) } : row];
  })));
  per("typeId", Object.fromEntries(Array.from({ length: 10 }, (_, t) => [String(t), bandDefaults(zones, t)])));
  return { defaults, by };
}

// environment-manager add <env> with fields left empty (main.ts cmdAdd): the
// name capitalised, the first organization by name, the zone named like the
// environment, and no domains block at all without --domain. At either verb,
// what an unset field of the backup cascade gets: the site's retention and
// schedule, the environment's own data residency.
export function environmentDefaults(mode: FormMode, o: { firstOrg: string | null; siteBackup: Obj; record: Obj | null }): Record<string, unknown> {
  const sb = o.siteBackup;
  const out: Record<string, unknown> = {
    "domains.primary": "no public domain (reached only from inside)",
    "backup.retention": `${typeof sb.defaultRetention === "string" ? sb.defaultRetention : "7y"}, the site's`,
    "backup.schedule": `${typeof sb.defaultSchedule === "string" ? sb.defaultSchedule : "daily"}, the site's`,
    "backup.residency": `${typeof o.record?.dataResidency === "string" ? o.record.dataResidency : "eu-only"}, the environment's data residency`,
  };
  if (mode === "add") Object.assign(out, { displayName: "<Name>", ownerOrg: o.firstOrg, zone: "<name>" });
  return out;
}

// module-manager add <module> with fields left empty (install-module.sh): the
// VM is named for the module, suffixed with an environment that is neither the
// default nor mgmt, or for --instance; it keeps the module's own VM id unless a
// config already uses it (then the next free one up); it goes on the module's
// node, else the site's first; its zone0 is the module's, else its
// environment's zone.
export function moduleAddDefaults(o: { module: string; own: Obj; defaultEnv: string | null; envs: { name: string; zone: string | null }[]; firstNode: string | null; usedVmids: number[] }): { defaults: Record<string, unknown>; by: Record<string, DefaultRule[]> } {
  const defaults: Record<string, unknown> = { vmname: o.module };
  const by: Record<string, DefaultRule[]> = {};
  const named = (env: string) => (env === "mgmt" || env === o.defaultEnv ? o.module : `${o.module}-${env}`);
  by.vmname = [{ on: "--instance", values: { "*": "<value>" } }, { on: "--environment", values: Object.fromEntries(o.envs.map((e) => [e.name, named(e.name)])) }];
  const own = Number(o.own.vmid);
  if (Number.isInteger(own) && own > 0 && o.usedVmids.includes(own)) {
    let n = own;
    while (o.usedVmids.includes(n)) n++;
    defaults.vmid = `${n}, the next free (${own}, the module's own, is taken)`;
  }
  if (typeof o.own.node !== "string" && o.firstNode) defaults.node = `${o.firstNode}, the site's first node`;
  if (typeof o.own.zone0 !== "string") {
    const zoneOf = (env: string | null) => o.envs.find((e) => e.name === env)?.zone ?? null;
    const base = zoneOf(o.defaultEnv);
    if (base) defaults.zone0 = `${base}, the environment's zone`;
    by.zone0 = [{ on: "--environment", values: Object.fromEntries(o.envs.filter((e) => e.zone).map((e) => [e.name, `${e.zone}, the environment's zone`])) }];
  }
  return { defaults, by };
}
