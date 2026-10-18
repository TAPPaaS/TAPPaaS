// fieldmanifest.ts — one field manifest for every add and modify form
// (GET /api/v1/fields/<kind>[/<name>]). It is derived from the schema JSONs the
// managers validate against — the composed module field schema, zones-fields,
// environment-fields, the identity *-fields, site-fields, the module schema's
// backup block — plus, where the object exists, its record. Per field: its
// type, its choices (an enum, or the defined objects a `references` field names),
// its default (a literal, or a template such as <vmname>.<domain> rendered with
// the object's values when they are known), the configured value, whether it is
// required, its change class, a one-line description, whether this form may
// change it, and how a change is passed to the manager's own verb (`--set` or
// the verb's own flag). Pure: the reads that feed it are in reads.ts.

export const FIELD_KINDS = ["module", "zone", "environment", "org", "group", "user", "role", "site", "backup"] as const;
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
}

export interface FieldManifest {
  kind: FieldKind;
  name: string | null;
  mode: FormMode;
  exists: boolean;
  fields: ManifestField[];
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

const ONE: Record<string, string> = { zones: "a zone", environments: "an environment", nodes: "a node", storage: "a storage pool", organizations: "an organization", users: "a user", groups: "a group", roles: "a role" };
const MANY: Record<string, string> = { zones: "zones", environments: "environments", nodes: "nodes", storage: "storage pools", organizations: "organizations", users: "users", groups: "groups", roles: "roles" };

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

// A JSON-Schema document's properties as dotted leaves (environment-fields,
// site-fields, the identity *-fields): an object with properties of its own is
// walked, every other property is a field. `required` is per level.
export function flattenSchema(doc: unknown, prefix = "", requiredHere = true): FieldDef[] {
  const d = obj(doc);
  const required = new Set(strs(d.required));
  const out: FieldDef[] = [];
  for (const [k, raw] of Object.entries(obj(d.properties))) {
    const p = obj(raw);
    const name = prefix ? `${prefix}.${k}` : k;
    const isReq = requiredHere && required.has(k);
    if (Object.keys(obj(p.properties)).length > 0) {
      out.push(...flattenSchema(p, name, isReq));
      continue;
    }
    out.push({ name, type: p.type, enum: p.enum, default: p.default, description: typeof p.description === "string" ? p.description : undefined, references: typeof p.references === "string" ? p.references : undefined, required: isReq });
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

// The verb's own flags, by field. A field with no flag cannot change through
// that verb: the form shows it read-only.
export const FLAGS: Partial<Record<FieldKind, Partial<Record<FormMode, Record<string, string>>>>> = {
  environment: {
    add: { displayName: "--display", ownerOrg: "--owner", "network.zone": "--zone", "domains.primary": "--domain", "domains.dnsMode": "--dns-mode" },
    modify: { displayName: "--display", ownerOrg: "--owner", "network.zone": "--zone", "domains.primary": "--domain", "domains.dnsMode": "--dns-mode" },
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
      "backup.defaultRetention": "--backupDefaultRetention", "location.country": "--locationCountry", "location.timezone": "--locationTimezone", "location.locale": "--locationLocale",
      "location.keyboard": "--locationKeyboard", "location.latitude": "--locationLatitude", "location.longitude": "--locationLongitude", "location.city": "--locationCity",
      "location.building": "--locationBuilding", "branding.logo": "--brandingLogo", "branding.logoDark": "--brandingLogoDark", "network.isp": "--networkIsp", "network.publicIp": "--networkPublicIp",
      "updateSchedule.frequency": "--updateFrequency", "updateSchedule.weekday": "--updateWeekday", "updateSchedule.hour": "--updateHour",
    },
  },
  backup: { modify: { enabled: "--enabled", retention: "--retention", exclude: "--exclude" } },
  zone: { add: { type: "--type", typeId: "--typeId", vlantag: "--vlan", variant: "--variant", "tftp-server-name": "--tftp-server-name", "bootfile-name": "--bootfile-name" } },
};

// Fields a form never offers whatever the schema says: the object's name is
// the verb's positional.
const NAME_FIELDS: Partial<Record<FieldKind, string[]>> = { environment: ["name"], org: ["name"], group: ["name"], user: ["name"], role: ["name"], site: ["name"] };

// zones-fields classes a --set refuses before anything is written.
const ZONE_REFUSED: Record<string, string> = {
  immutable: "cannot change in place: delete the zone and add it again",
  recreate: "only by deleting the zone and adding it again",
  manual: "has a verb of its own",
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
}

export function buildManifest(i: ManifestInput): FieldManifest {
  const flags = FLAGS[i.kind]?.[i.mode] ?? null;
  const hidden = new Set(NAME_FIELDS[i.kind] ?? []);
  const fields: ManifestField[] = [];
  for (const def of i.defs) {
    if (hidden.has(def.name)) continue;
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
    else if (i.kind === "zone" && i.mode === "modify") {
      const c = def.changeClass ?? "";
      if (!c) why = "has no change class: it cannot be set through a verb";
      else if (ZONE_REFUSED[c]) why = ZONE_REFUSED[c];
      else arg = "--set";
    } else if (flags && flags[def.name]) arg = flags[def.name];
    else why = i.mode === "add" ? "not set when adding: change it afterwards" : "the verb has no option for it";
    fields.push({
      name: def.name,
      type,
      typeText: typeTextOf(type, references, en),
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
    });
  }
  return { kind: i.kind, name: i.name, mode: i.mode, exists: i.record !== null, fields };
}
