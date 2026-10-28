// reads.ts — every read the console serves, each one a manager verb's --json
// (ADR-034 D1, D4 "P1 is read-only"). One cache per read with its own timer:
// health 10 minutes, the module list and the topology 5, drift on demand, the
// storage inventory when looked at and older than 10 minutes. The
// only files read directly are the sweep's own record (last-update-result.json
// and the failures ledger), its journal, which no manager prints, and
// zones.json through lib/ts zones.ts — the same parse network-manager's own
// `list` and `show` run, read once instead of one process per zone.

import { existsSync, mkdirSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { writeJsonAtomic } from "../../lib/ts/src/config-io";
import { WanAddress, readWanAddress, wanAddressFile } from "../../lib/ts/src/wan-address";
import { environmentZoneIn, readZonesFile, sharedZonesIn } from "../../lib/ts/src/zones";
import { parseJournal, parseLedger, sweepRuns, SweepRun } from "./activity";
import { Cached, CachedMap, Entry } from "./cache";
import { RepositoryCatalog, moduleSourceOf, repositoryCatalog } from "./catalog";
import { ModuleFields, moduleFieldRows, moduleSchema, schemaDoc } from "./fields";
import { composeFields } from "../../lib/ts/src/compose-fields";
import { DefaultRule, FieldDef, FieldKind, FieldManifest, FormMode, RefContext, backupDefs, buildManifest, environmentDefaults, environmentDefs, flattenSchema, moduleAddDefaults, moduleDefs, zoneAddDefaults, zoneDefs } from "./fieldmanifest";
import { Runner, runJson } from "./run";
import { SetupInputs, gatherSetup, runSetupTests } from "./setup";
import { ModuleIcon, moduleIcon } from "./icons";
import { BackupRow, BackupRunsDoc, EnvironmentRow, HealthDoc, ModuleList, StorageDoc, TopologyDoc } from "./model";

// The positions the topology carries (network-manager topology .positions), the parts read here.
export interface PositionsRead {
  racks: {
    name: string; displayName: string | null; units: number; width: string; numbering: string; room: string | null; description: string | null;
    placements: { device: string; rack: string; u: number; height: number; width: string; slot: number; face: string; faceplate: string | null; suggested: boolean; label: string | null; description: string | null }[];
  }[];
  unplaced: { device: string; suggestion: string | null; location?: string | null }[];
  rooms?: { name: string; displayName: string | null; description: string | null; location?: string | null; recorded: boolean; loose?: (PositionsRead["racks"][number]["placements"][number] & { room?: string | null })[] }[];
}

// Every device the topology names: what a placement may name.
export function topologyDevices(t: Record<string, unknown> | null): string[] {
  const names = (k: string) => (Array.isArray(t?.[k]) ? (t![k] as { name?: unknown }[]) : []).map((x) => x.name).filter((n): n is string => typeof n === "string");
  return [...new Set([...names("nodes"), ...names("switches"), ...names("accessPoints"), ...names("devices")])].sort((a, b) => a.localeCompare(b, "en", { numeric: true }));
}

// The location a device is at (ADR-036 D2): the topology's word on it, else
// the view's for a device placed nowhere, else the primary.
export function deviceLocationIn(t: Record<string, unknown> | null, device: string, primary: string | null): string | null {
  for (const k of ["nodes", "switches", "accessPoints", "devices"]) {
    const d = (Array.isArray(t?.[k]) ? (t![k] as { name?: unknown; location?: unknown }[]) : []).find((x) => x.name === device);
    if (typeof d?.location === "string" && d.location) return d.location;
  }
  const u = ((t?.positions as PositionsRead | null | undefined)?.unplaced ?? []).find((x) => x.device === device);
  return u?.location ?? primary;
}

// Where a device can be placed: the rooms at its location, and the racks in
// them (a rack in no room only at the primary location, where validate puts it).
export function placesAt(view: PositionsRead | null, location: string | null, primary: string | null): { rooms: string[]; racks: string[] } {
  const rooms = (view?.rooms ?? []).filter((r) => (r.location ?? primary) === location);
  const names = new Set(rooms.map((r) => r.name));
  return {
    rooms: rooms.filter((r) => r.recorded).map((r) => r.name).sort(),
    racks: (view?.racks ?? []).filter((r) => (r.room ? names.has(r.room) : location === primary)).map((r) => r.name).sort(),
  };
}

const MIN = 60_000;

export const TTL = {
  health: 10 * MIN,
  modules: 5 * MIN,
  topology: 5 * MIN,
  zones: 5 * MIN,
  aps: 5 * MIN,
  ssids: 5 * MIN,
  environments: 5 * MIN,
  site: 5 * MIN,
  backup: 10 * MIN,
  security: 10 * MIN,
  peers: 10 * MIN,
  activity: 5 * MIN,
  moduleDetail: 5 * MIN,
  identity: 5 * MIN,
  setup: 10 * MIN,
  schema: 10 * MIN,
  catalogs: 10 * MIN,
  faceplates: 10 * MIN,
  storage: 10 * MIN,
  backupRuns: 10 * MIN,
  icons: 10 * MIN,
  ipv6: 10 * MIN,
  nodeProgress: 10_000, // while a node is being added
  drift: 0, // on demand
};

export interface ReadsConfig {
  // Cluster membership for the Setup checklist (lib/ts cluster.ts by default).
  clusterNodes?: (siteNodes: string[]) => string[] | null;
  configDir: string;
  // The repository the managers run from (its schemas/), /home/tappaas/TAPPaaS.
  repoRoot?: string;
  stateDir: string; // where the health document is handed to `topology --health`
  // What the firewall's WAN held at the last network update (default
  // $TAPPAAS_WAN_ADDRESS_FILE or /var/lib/tappaas/wan-address.json): shown
  // beside network.publicIp "auto".
  wanAddressFile?: string;
  run: Runner;
  journalDays: number;
  now?: () => number;
}

// The site's IPv6 prefix, the one each zone's /64 is numbered in: site.json
// `ipv6` and `network.wan.ipv6`, and for a dynamic WAN the prefix the
// firewall holds now (`ipv6-manager wan --json`, over ssh). No prefix (IPv6
// off, the WAN takes none, or the firewall holds none or did not answer) is
// an answer, with why.
export interface Ipv6Read {
  on: boolean;
  mode: string; // dynamic | static | none
  prefix: string | null;
  source: "delegated" | "site.json" | null;
  error?: string;
}

// A node being added (site-manager node add), as the records show it:
// its provisioning registration, the PXE window, cluster membership, site.json.
export interface NodeProgress {
  name: string;
  registration: "pending" | "answered" | "none";
  pxe: { enabled: boolean | null; text: string };
  inCluster: boolean | null; // null: no node answered
  cluster: string[] | null;
  inSite: boolean;
  siteNodes: string[];
}

// A node name as site-manager accepts one.
export const NODE_NAME = /^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$/;
// Any object a form names: a module, zone, environment, identity object (a
// group may carry a space: "authentik Admins").
export const OBJECT_NAME = /^[A-Za-z0-9_][A-Za-z0-9 _.-]{0,62}$/;

export interface Activity {
  runs: SweepRun[];
  ledger: { at: string | null; text: string }[];
  lastResult: Record<string, unknown> | null;
  sweepActive: boolean;
}

// A module name as the managers spell one; anything else never reaches an argv.
export const MODULE_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;

export const IDENTITY_KINDS = ["org", "group", "user", "role"];

// A resolve value is a string; a list or an object is its JSON.
function parseMaybe(v: string): unknown {
  if (!/^[[{]/.test(v) && v !== "true" && v !== "false" && v !== "null" && !/^-?\d+$/.test(v)) return v;
  try {
    return JSON.parse(v);
  } catch {
    return v;
  }
}

export class Reads {
  readonly health: Cached<HealthDoc>;
  readonly modules: Cached<ModuleList>;
  readonly backup: Cached<BackupRow[]>;
  readonly topology: Cached<TopologyDoc & Record<string, unknown>>;
  readonly zones: Cached<Record<string, unknown>[]>;
  readonly aps: Cached<Record<string, unknown>[]>;
  readonly ssids: Cached<Record<string, unknown>[]>;
  readonly environments: Cached<EnvironmentRow[]>;
  readonly site: Cached<Record<string, unknown>>;
  readonly security: Cached<Record<string, unknown> | null>;
  readonly peers: Cached<Record<string, unknown>[]>;
  readonly activity: Cached<Activity>;
  readonly moduleShow: CachedMap<Record<string, unknown>>;
  readonly moduleResolve: CachedMap<Record<string, unknown>>;
  readonly moduleBackup: CachedMap<Record<string, unknown>>;
  readonly moduleDrift: CachedMap<Record<string, unknown>>;
  readonly moduleFields: CachedMap<Record<string, unknown>>;
  readonly identity: Cached<Record<string, string[]>>;
  readonly identityRecords: Cached<Record<string, Record<string, unknown>[]>>;
  readonly schemas: CachedMap<Record<string, unknown>>;
  readonly nodeProgress: CachedMap<NodeProgress>;
  readonly catalogs: Cached<RepositoryCatalog[]>;
  readonly faceplates: Cached<{ key: string; kind: string; units: number; width: string; site?: boolean }[]>;
  readonly storage: Cached<StorageDoc>;
  readonly backupRuns: Cached<BackupRunsDoc>;
  readonly moduleIcons: CachedMap<ModuleIcon | null>;
  readonly setup: Cached<SetupInputs>;
  readonly ipv6: Cached<Ipv6Read>;

  constructor(private readonly cfg: ReadsConfig) {
    const run = cfg.run;
    const now = cfg.now ?? Date.now;
    const j = <T>(bin: string, args: string[], okRcs: number[] = [0], timeoutMs = 2 * MIN): Promise<T> =>
      runJson<T>(run, bin, args, { okRcs, timeoutMs });

    // validate exits 1 when a gate fails; the document is complete either way.
    this.health = new Cached("health", TTL.health, () => j<HealthDoc>("health-manager", ["validate", "--json"], [0, 1], 10 * MIN), now);
    this.modules = new Cached("modules", TTL.modules, () => j<ModuleList>("module-manager", ["list", "--json"]), now);
    this.backup = new Cached("backup", TTL.backup, () => j<BackupRow[]>("backup-manager", ["list", "--json"]), now);
    this.topology = new Cached("topology", TTL.topology, () => this.loadTopology(), now);
    this.zones = new Cached("zones", TTL.zones, () => this.loadZones(), now);
    // The access points and the SSIDs each maps to a zone (Setup's WiFi).
    this.aps = new Cached("aps", TTL.aps, () => j<Record<string, unknown>[]>("ap-manager", ["list", "--json"]), now);
    // The site-wide SSIDs: zone, security, the APs that broadcast each, and
    // whether its passphrase is set — never the passphrase (#889).
    this.ssids = new Cached("ssids", TTL.ssids, () => j<Record<string, unknown>[]>("ap-manager", ["ssid", "list", "--json"]), now);
    this.environments = new Cached("environments", TTL.environments, async () => {
      // The environment names no zone; the zone naming it is its zone (#865).
      // A shared service zone listing it is not its zone, and is listed apart (#876).
      const envs = await j<EnvironmentRow[]>("environment-manager", ["list", "--json"]);
      const zones = this.zoneEntries();
      return envs.map((e) => ({ ...e, zone: environmentZoneIn(zones, e.name), sharedZones: sharedZonesIn(zones, e.name) }));
    }, now);
    this.site = new Cached("site", TTL.site, () => this.loadSite(), now);
    // Not timed: the firewall is read when a page asks, at most every TTL.
    this.ipv6 = new Cached("ipv6", TTL.ipv6, () => this.loadIpv6(), now);
    // No scan yet is an answer (null), not a failure.
    this.security = new Cached("security", TTL.security, async () => {
      const r = await run("health-manager", ["report", "security", "--json"]);
      if (r.ran && r.rc !== 0 && /no security scan yet/.test(r.stderr + r.stdout)) return null;
      return runJson<Record<string, unknown>>(async () => r, "health-manager", ["report", "security", "--json"]);
    }, now);
    this.peers = new Cached("peers", TTL.peers, () => j<Record<string, unknown>[]>("backup-manager", ["peers", "--json"]), now);
    this.activity = new Cached("activity", TTL.activity, () => this.loadActivity(), now);
    this.moduleShow = new CachedMap("show", TTL.moduleDetail, (m) => j<Record<string, unknown>>("module-manager", ["show", m, "--json"]), now);
    this.moduleResolve = new CachedMap("resolve", TTL.moduleDetail, (m) => j<Record<string, unknown>>("module-manager", ["resolve", m, "--json"]), now);
    this.moduleBackup = new CachedMap("backup", TTL.backup, async (m) => {
      const [policy, coverage] = await Promise.all([
        j<Record<string, unknown>>("backup-manager", ["show", m, "--json"]),
        j<Record<string, unknown>>("backup-manager", ["coverage", m, "--json"]).catch((e: Error) => ({ error: e.message })),
      ]);
      return { policy, coverage };
    }, now);
    // What `modify --set` may change, with each field's ADR-020 change class.
    this.moduleFields = new CachedMap("fields", TTL.moduleDetail, (m) => j<Record<string, unknown>>("module-manager", ["fields", m, "--json"]), now);
    // The field schemas a form reads (zones-fields.json, environment-fields.json).
    this.schemas = new CachedMap("schema", TTL.schema, async (n) => schemaDoc(cfg.repoRoot ?? "/home/tappaas/TAPPaaS", n), now);
    this.identity = new Cached("identity", TTL.identity, async () => {
      const out: Record<string, string[]> = {};
      await Promise.all(IDENTITY_KINDS.map(async (k) => (out[k] = await j<string[]>("identity-manager", [k, "list", "--json"]))));
      return out;
    }, now);
    // What each registered repository offers, and which of it is installed.
    this.catalogs = new Cached("catalogs", TTL.catalogs, async () => {
      const [repos, mods] = await Promise.all([j<Record<string, unknown>[]>("site-manager", ["repository", "list", "--json"]), this.modules.get()]);
      const instances = (mods.value?.modules ?? []).map((m) => ({ name: m.name, source: moduleSourceOf(cfg.configDir, m.name) }));
      return (Array.isArray(repos) ? repos : []).map((r) => repositoryCatalog(r, instances));
    }, now);
    // The faceplate catalog: the keys a placement's faceplate may name, the site's own first.
    this.faceplates = new Cached("faceplates", TTL.faceplates, () => j<{ key: string; kind: string; units: number; width: string; site?: boolean }[]>("position-manager", ["faceplates", "list", "--json"]), now);
    // The disks and pools of every node, with SMART (≈15 s on three nodes): no
    // timer of its own, read when a page asks and the answer is older than
    // its TTL.
    this.storage = new Cached("storage", TTL.storage, () => this.loadStorage(), now);
    // Each guest's and target's last backup and last verify: one ssh to the PBS
    // Host and one to a node. Like the storage inventory, no timer of its own:
    // read when the Backup page asks and the answer is older than its TTL.
    this.backupRuns = new Cached("backup-runs", TTL.backupRuns, async () => {
      const d = await j<BackupRunsDoc>("backup-manager", ["restore", "list-all", "--json"]);
      if (!d || typeof d.reachable !== "boolean" || !Array.isArray(d.guests) || !Array.isArray(d.targets)) {
        throw new Error("backup-manager restore list-all --json gave no runs (no reachable, guests, targets)");
      }
      return d;
    }, now);
    // A module's icon file (icons.ts): read once per ten minutes at most.
    this.moduleIcons = new CachedMap("icon", TTL.icons, async (m) => moduleIcon(cfg.configDir, m), now);
    this.nodeProgress = new CachedMap("node-progress", TTL.nodeProgress, (n) => this.loadNodeProgress(n), now);
    // Every identity object's record, for the graph of their relations: each
    // kind's list, then `show` per object (a name from the manager's own list).
    this.identityRecords = new Cached("identity-records", TTL.identity, async () => {
      const lists = (await this.identity.get()).value ?? {};
      const out: Record<string, Record<string, unknown>[]> = {};
      await Promise.all(IDENTITY_KINDS.map(async (k) => {
        const names = (lists[k] ?? []).filter((n) => typeof n === "string" && n !== "" && !n.startsWith("-"));
        out[k] = await Promise.all(names.map((n) => j<Record<string, unknown>>("identity-manager", [k, "show", n, "--json"]).catch((e: Error) => ({ name: n, error: e.message }))));
      }));
      return out;
    }, now);
    // The Setup checklist's records: read on demand. The module tests behind
    // three of its steps run only through refreshSetup (the explicit refresh).
    this.setup = new Cached("setup", TTL.setup, () =>
      gatherSetup({
        configDir: cfg.configDir,
        stateDir: cfg.stateDir,
        run,
        clusterNodes: cfg.clusterNodes ?? (() => null),
        stacks: async () => {
          const m = await this.modules.get();
          return [...new Set((m.value?.modules ?? []).map((x) => x.stack).filter((x): x is string => !!x && x !== "foundation"))].sort();
        },
      }), now);
    this.moduleDrift = new CachedMap("drift", TTL.drift, (m) => j<Record<string, unknown>>("module-manager", ["drift", m, "--json"], [0, 1, 2], 5 * MIN), now);
  }

  // ── the field manifest of an add or modify form (fieldmanifest.ts) ──

  private schemaFile(file: string): Record<string, unknown> {
    const p = join(this.cfg.repoRoot ?? "/home/tappaas/TAPPaaS", "src", "foundation", "schemas", file);
    return existsSync(p) ? (JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>) : {};
  }

  // The module field schema: the site's registered repositories composed, and
  // the repository the console runs from winning for the fields it defines (on
  // a site they are the same checkout), so references read as that release
  // has them.
  private moduleSchemaDoc(): Record<string, unknown> {
    const foundation = join(this.cfg.repoRoot ?? "/home/tappaas/TAPPaaS", "src", "foundation");
    const site = composeFields(foundation, this.cfg.configDir).schema;
    const own = composeFields(foundation, join(foundation, ".no-site")).schema;
    return { ...site, fields: { ...(site.fields as Record<string, unknown>), ...(own.fields as Record<string, unknown>) } };
  }

  private configJson(name: string): Record<string, unknown> | null {
    return this.readJson(`${name}.json`);
  }

  // The defined objects a `references` field may name. The racks' kinds also
  // name the topology's devices, the racks and the faceplates.
  private async refContext(racks = false): Promise<RefContext> {
    const [envs, site, ids] = await Promise.all([this.environments.get(), this.site.get(), this.identity.get()]);
    let zones: string[] = [];
    try {
      zones = readZonesFile(join(this.cfg.configDir, "zones.json")).entries
        .filter(([, z]) => !["Disabled", "Inactive"].includes(String(z.state ?? "")))
        .map(([n]) => n)
        .sort();
    } catch {
      zones = [];
    }
    const nodes = (Array.isArray(site.value?.nodes) ? (site.value!.nodes as { name?: unknown; storagePools?: unknown }[]) : [])
      .filter((n) => typeof n.name === "string")
      .map((n) => ({ name: n.name as string, pools: Array.isArray(n.storagePools) ? n.storagePools.filter((p): p is string => typeof p === "string") : [] }))
      .sort((a, b) => a.name.localeCompare(b.name));
    const list = (k: string) => (ids.value?.[k] ?? []).filter((n) => typeof n === "string" && n !== "" && !n.startsWith("-")).sort();
    let rackRefs = { devices: [] as string[], racks: [] as string[], rooms: [] as string[], faceplates: [] as string[] };
    if (racks) {
      const [t, f] = await Promise.all([this.topology.get(), this.faceplates.get()]);
      const view = (t.value?.positions ?? null) as { racks?: { name: string }[]; rooms?: { name: string; recorded: boolean }[] } | null;
      rackRefs = {
        devices: topologyDevices(t.value ?? null),
        racks: (view?.racks ?? []).map((r) => r.name).sort(),
        rooms: (view?.rooms ?? []).filter((r) => r.recorded).map((r) => r.name).sort(),
        // The site's own plates first, as the list gives them, then the shipped ones.
        faceplates: [...(f.value ?? []).filter((x) => x.site).map((x) => x.key).sort(), ...(f.value ?? []).filter((x) => !x.site).map((x) => x.key).sort()],
      };
    }
    const locations = Object.keys(((site.value?.site ?? {}) as { locations?: Record<string, unknown> }).locations ?? {}).sort();
    return {
      ...rackRefs,
      locations,
      zones,
      environments: (envs.value ?? []).map((e) => e.name).sort(),
      nodes,
      organizations: list("org"),
      users: list("user"),
      groups: list("group"),
      roles: list("role"),
    };
  }

  // The primary domain of an environment, for a template's <domain>.
  private async domainOf(env: string | null): Promise<string | null> {
    const envs = (await this.environments.get()).value ?? [];
    const site = (await this.site.get()).value?.site as { defaultEnvironment?: string } | undefined;
    const e = envs.find((x) => x.name === (env ?? site?.defaultEnvironment));
    return (e as { domains?: { primary?: string } } | undefined)?.domains?.primary ?? null;
  }

  async fieldManifest(kind: FieldKind, name: string | null, mode: FormMode): Promise<FieldManifest> {
    let refs = await this.refContext(kind === "rack" || kind === "placement" || kind === "room");
    const vars: Record<string, string | null> = { name };
    let defs: FieldDef[] = [];
    let record: Record<string, unknown> | null = null;
    let defaults: Record<string, unknown> | undefined;
    let classes: Record<string, { class: string; apply?: string | null; coordinate?: string; settable: boolean; reason: string | null; offRelease?: boolean }> | undefined;
    let services: string[] | undefined;
    let moduleClasses: Record<string, { class?: string; apply?: string; changeNote?: string }> | undefined;
    let defaultBy: Record<string, DefaultRule[]> | undefined;
    switch (kind) {
      case "module": {
        const schema = this.moduleSchemaDoc();
        defs = moduleDefs(schema);
        moduleClasses = (this.schemaFile("fields.json").fields ?? {}) as Record<string, { class?: string; apply?: string; changeNote?: string }>;
        if (mode === "modify" && name) {
          const [f, r] = await Promise.all([this.moduleFields.of(name).get(), this.moduleResolve.of(name).get()]);
          if (f.error && !f.value) throw new Error(f.error);
          classes = {};
          for (const x of Array.isArray(f.value?.fields) ? (f.value!.fields as Record<string, unknown>[]) : []) {
            if (typeof x.field === "string") classes[x.field] = { class: typeof x.class === "string" ? x.class : "", apply: typeof x.apply === "string" ? x.apply : null, coordinate: typeof x.coordinate === "string" ? x.coordinate : undefined, settable: x.settable === true, reason: typeof x.reason === "string" ? x.reason : null };
          }
          // The value in effect: configured, or the default resolve applied.
          record = {};
          defaults = {};
          for (const [k, v] of Object.entries((r.value?.fields ?? {}) as Record<string, { value?: unknown; defaulted?: boolean; notTracking?: boolean }>)) {
            const val = typeof v.value === "string" ? parseMaybe(v.value) : v.value;
            // resolve's .orig note: the field is kept off its release on purpose
            if (v.notTracking === true && classes[k]) classes[k].offRelease = true;
            if (v.defaulted === false) record[k] = val;
            else if (val !== null && val !== undefined) defaults[k] = val;
          }
          // No node configured: cluster:vm creates it on the site's first node.
          if (record.node === undefined && defaults.node === undefined) {
            const nodes = ((await this.site.get()).value?.nodes ?? []) as { name?: unknown }[];
            if (typeof nodes[0]?.name === "string") defaults.node = `${nodes[0].name}, the site's first node`;
          }
          const own = this.configJson(name) ?? {};
          vars.vmname = typeof own.vmname === "string" ? own.vmname : name;
          vars.zone0 = typeof own.zone0 === "string" ? own.zone0 : null;
          vars.domain = await this.domainOf(typeof own.environment === "string" ? own.environment : null);
        } else if (name) {
          // An add: the catalogue module's own JSON is what an empty field gets.
          const cat = ((await this.catalogs.get()).value ?? []).flatMap((c) => c.modules).find((m) => m.name === name);
          if (!cat) throw new Error(`no module '${name}' in the repositories' catalogues`);
          const own = existsSync(cat.json) ? (JSON.parse(readFileSync(cat.json, "utf8")) as Record<string, unknown>) : {};
          defaults = Object.fromEntries(Object.entries(own).filter(([k]) => k !== "config"));
          services = [...(Array.isArray(own.dependsOn) ? own.dependsOn : []), ...(Array.isArray(own.integratesWith) ? own.integratesWith : [])].filter((x): x is string => typeof x === "string");
          // What module-manager add computes for a field left empty: the VM's
          // name and id, its node and zone0.
          const [envs, site] = await Promise.all([this.environments.get(), this.site.get()]);
          const nodes = Array.isArray(site.value?.nodes) ? (site.value!.nodes as { name?: unknown }[]) : [];
          const computed = moduleAddDefaults({
            module: name,
            own,
            defaultEnv: ((site.value?.site as { defaultEnvironment?: string } | undefined)?.defaultEnvironment) ?? null,
            envs: [{ name: "mgmt", zone: "mgmt" }, ...(envs.value ?? []).filter((e) => e.name !== "mgmt").map((e) => ({ name: e.name, zone: e.zone ?? null }))],
            firstNode: typeof nodes[0]?.name === "string" ? nodes[0].name : null,
            usedVmids: this.configVmids(`${name}.json`),
            primaryLocation: ((site.value?.site as { primaryLocation?: string } | undefined)?.primaryLocation) ?? null,
          });
          defaults = { ...defaults, ...computed.defaults };
          defaultBy = computed.by;
          vars.vmname = typeof own.vmname === "string" ? own.vmname : name;
          vars.zone0 = typeof own.zone0 === "string" ? own.zone0 : null;
          vars.domain = await this.domainOf(null);
        }
        break;
      }
      case "backup": {
        defs = backupDefs(this.moduleSchemaDoc());
        if (!name) throw new Error("fields/backup/<module>");
        record = ((this.configJson(name) ?? {}).backup as Record<string, unknown> | undefined) ?? {};
        // The cascade's answer (site → environment → module) is what an unset field gets.
        const show = await this.moduleBackup.of(name).get();
        const policy = (show.value?.policy ?? {}) as Record<string, unknown>;
        defaults = Object.fromEntries(["enabled", "retention", "exclude", "schedule"].filter((k) => policy[k] !== undefined && policy[k] !== null).map((k) => [k, policy[k]]));
        break;
      }
      case "zone": {
        defs = zoneDefs(this.schemaFile("zones-fields.json"));
        if (name) {
          const z = readZonesFile(join(this.cfg.configDir, "zones.json")).entries.find(([n]) => n === name);
          record = z ? z[1] : null;
          if (!record && mode === "modify") throw new Error(`no zone '${name}'`);
        }
        // network-manager add's own rules for what is left empty: the plain
        // Service zone, else what --archetype, --from-zone or the typeId give.
        if (mode === "add") {
          let zones: Array<[string, Record<string, unknown>]> = [];
          try {
            zones = readZonesFile(join(this.cfg.configDir, "zones.json")).entries;
          } catch {
            zones = [];
          }
          const archetypes = (this.schemaFile("zones-fields.json").archetypes ?? {}) as { catalog?: Record<string, unknown> };
          const computed = zoneAddDefaults(zones, archetypes.catalog ?? {});
          defaults = computed.defaults;
          defaultBy = computed.by;
        }
        break;
      }
      case "environment": {
        defs = environmentDefs(this.schemaFile("environment-fields.json"));
        // The record as environment-manager shows it, every field pre-filled,
        // and its zone: the zone naming it.
        if (name && mode === "modify") {
          record = await runJson<Record<string, unknown>>(this.cfg.run, "environment-manager", ["show", name, "--json"]);
          record = { ...record, zone: environmentZoneIn(this.zoneEntries(), name) };
        }
        const siteBackup = ((((await this.site.get()).value?.site ?? {}) as Record<string, unknown>).backup ?? {}) as Record<string, unknown>;
        defaults = environmentDefaults(name && mode === "modify" ? "modify" : "add", { firstOrg: refs.organizations[0] ?? null, siteBackup, record });
        break;
      }
      case "org":
      case "group":
      case "user":
      case "role": {
        const file = { org: "organization", group: "group", user: "user", role: "role" }[kind];
        defs = flattenSchema(this.schemaFile(`${file}-fields.json`));
        // identity-manager <kind> add names the object for itself when no display name is given.
        if (mode === "add") defaults = { displayName: "<name>" };
        if (name && mode === "modify") {
          const all = (await this.identityRecords.get()).value ?? {};
          record = (all[kind] ?? []).find((x) => x.name === name) ?? null;
          if (!record) throw new Error(`no ${kind} '${name}'`);
        }
        break;
      }
      case "site": {
        defs = flattenSchema(this.schemaFile("site-fields.json"));
        record = ((await this.site.get()).value?.site ?? null) as Record<string, unknown> | null;
        break;
      }
      case "location": {
        // site-fields.json's $defs.location; the record from site.json's locations.
        defs = flattenSchema(((this.schemaFile("site-fields.json").$defs ?? {}) as Record<string, unknown>).location);
        if (name) {
          const site = ((await this.site.get()).value?.site ?? {}) as { locations?: Record<string, Record<string, unknown>> };
          record = site.locations?.[name] ?? null;
          if (!record && mode === "modify") throw new Error(`no location '${name}'`);
        }
        if (mode === "add") defaults = { displayName: "<name>", kind: "site" };
        break;
      }
      case "rack":
      case "placement":
      case "room": {
        // positions-fields.json's $defs; the record as the topology resolves it.
        const $defs = (this.schemaFile("positions-fields.json").$defs ?? {}) as Record<string, unknown>;
        defs = flattenSchema($defs[kind]);
        const topo = (await this.topology.get()).value ?? null;
        const view = (topo?.positions ?? null) as PositionsRead | null;
        const primary = ((((await this.site.get()).value?.site ?? {}) as { primaryLocation?: unknown }).primaryLocation as string | undefined) ?? null;
        // A room is at the primary location unless it names another.
        if (kind === "room" && mode === "add" && primary) defaults = { location: `${primary}, the primary location` };
        // A device is placed only in a room, or a rack, at its own location.
        if (kind === "placement" && name) refs = { ...refs, ...placesAt(view, deviceLocationIn(topo as unknown as Record<string, unknown> | null, name, primary), primary) };
        if (kind === "rack" && name) {
          const r = (view?.racks ?? []).find((x) => x.name === name);
          if (!r && mode === "modify") throw new Error(`no rack '${name}'`);
          if (r) record = Object.fromEntries(Object.entries({ displayName: r.displayName, units: r.units, width: r.width, numbering: r.numbering, room: r.room, description: r.description }).filter(([, v]) => v !== null && v !== undefined));
        }
        if (kind === "room" && name) {
          const r = (view?.rooms ?? []).find((x) => x.name === name && x.recorded);
          if (!r && mode === "modify") throw new Error(`no room '${name}'`);
          if (r) record = Object.fromEntries(Object.entries({ displayName: r.displayName, description: r.description, location: r.location }).filter(([, v]) => v !== null && v !== undefined));
        }
        if (kind === "placement" && name) {
          const m = (view?.racks ?? []).flatMap((r) => r.placements).find((x) => x.device === name);
          const loose = (view?.rooms ?? []).flatMap((r) => r.loose ?? []).find((x) => x.device === name);
          if (!m && !loose && mode === "modify") throw new Error(`${name} is placed nowhere`);
          if (loose) {
            record = Object.fromEntries(Object.entries({ room: loose.room, faceplate: loose.suggested ? null : loose.faceplate, label: loose.label, description: loose.description }).filter(([, v]) => v !== null && v !== undefined));
            if (loose.suggested && loose.faceplate) defaults = { faceplate: `${loose.faceplate}, the catalog's suggestion` };
          } else if (m) {
            record = Object.fromEntries(Object.entries({ rack: m.rack, u: m.u, height: m.height, width: m.width, slot: m.width === "full" ? null : m.slot, face: m.face, faceplate: m.suggested ? null : m.faceplate, label: m.label, description: m.description }).filter(([, v]) => v !== null && v !== undefined));
            if (m.suggested && m.faceplate) defaults = { faceplate: `${m.faceplate}, the catalog's suggestion` };
          } else {
            const u = (view?.unplaced ?? []).find((x) => x.device === name);
            if (u?.suggestion) defaults = { faceplate: `${u.suggestion}, the catalog's suggestion` };
          }
        }
        break;
      }
    }
    return buildManifest({ kind, name, mode, defs, record, defaults, classes, moduleClasses, services, refs, vars, defaultBy });
  }

  // The VM ids the site's module configs hold but the instance's own
  // (install-module.sh's used_vmids, without the cluster's own list).
  private configVmids(own: string): number[] {
    try {
      return readdirSync(this.cfg.configDir)
        .filter((f) => f.endsWith(".json") && f !== own)
        .map((f) => {
          try {
            const o = JSON.parse(readFileSync(join(this.cfg.configDir, f), "utf8")) as { vmid?: unknown; config?: { vmid?: unknown } };
            return Number(o.vmid ?? o.config?.vmid);
          } catch {
            return NaN;
          }
        })
        .filter((n) => Number.isInteger(n) && n > 0);
    } catch {
      return [];
    }
  }

  // A module's fields for its Modify form: class, owner, type, value, default.
  async moduleFieldsOf(m: string): Promise<Entry<ModuleFields>> {
    const [f, r] = await Promise.all([this.moduleFields.of(m).get(), this.moduleResolve.of(m).get()]);
    // The released schema (references), else the site's composed one; the
    // module-level classes as the console's release declares them.
    let schema: Record<string, unknown>;
    try {
      schema = (this.moduleSchemaDoc().fields ?? {}) as Record<string, unknown>;
    } catch {
      schema = moduleSchema(this.cfg.configDir);
    }
    let classes: Record<string, { class?: string; apply?: string; changeNote?: string }> = {};
    try {
      classes = (this.schemaFile("fields.json").fields ?? {}) as Record<string, { class?: string; apply?: string; changeNote?: string }>;
    } catch {
      classes = {};
    }
    const value = f.value && r.value ? moduleFieldRows(f.value, r.value, schema, classes) : null;
    return { at: f.at, value, error: f.error ?? r.error, loading: f.loading || r.loading };
  }

  get configDir(): string {
    return this.cfg.configDir;
  }

  // The reads with timers, refreshed in the background from the start.
  timed(): Cached<unknown>[] {
    return [this.health, this.modules, this.backup, this.topology, this.zones, this.environments, this.site, this.security, this.peers, this.activity] as Cached<unknown>[];
  }

  start(): void {
    for (const c of this.timed()) {
      void c.refresh();
      c.start();
    }
  }

  stop(): void {
    for (const c of this.timed()) c.stop();
  }

  // Refresh one read, or every read, now (the explicit refresh endpoint).
  async refresh(what: string): Promise<string[]> {
    const all: Record<string, Cached<unknown>> = {
      health: this.health, modules: this.modules, backup: this.backup, topology: this.topology,
      zones: this.zones, aps: this.aps, ssids: this.ssids, environments: this.environments, site: this.site, security: this.security,
      peers: this.peers, activity: this.activity, storage: this.storage, "backup-runs": this.backupRuns, ipv6: this.ipv6,
    } as Record<string, Cached<unknown>>;
    if (what === "all") {
      this.moduleShow.clear();
      this.moduleIcons.clear();
      this.moduleResolve.clear();
      this.moduleBackup.clear();
      this.moduleDrift.clear();
      this.moduleFields.clear();
      // health first: the topology places its findings
      await this.health.refresh();
      // the storage inventory (SMART on every disk), the backup runs and the
      // firewall's IPv6 only once someone has looked
      const looked = (k: string) => !["storage", "backup-runs", "ipv6"].includes(k) || all[k].peek().at !== null;
      await Promise.all(Object.entries(all).filter(([k]) => k !== "health" && looked(k)).map(([, c]) => c.refresh()));
      if (this.catalogs.peek().at !== null) await this.catalogs.refresh();
      return Object.keys(all);
    }
    const c = all[what];
    if (!c) throw new Error(`unknown read '${what}' (one of: all, ${Object.keys(all).join(", ")})`);
    await c.refresh();
    if (what === "health") void this.topology.refresh();
    return [what];
  }

  // GET /setup?refresh=1: run the foundation modules' tests (minutes), keep the
  // results, then gather the checklist again. Nothing else runs them.
  async refreshSetup(): Promise<void> {
    await runSetupTests({ configDir: this.cfg.configDir, stateDir: this.cfg.stateDir, run: this.cfg.run }, this.cfg.now ?? Date.now);
    // Not refresh(): a gather already running (the page's own read) read the
    // results before the tests wrote them, and would be what this returns.
    await this.setup.refreshAfterChange();
  }

  // A test job wrote a result (recordSetupTest): the checklist follows, if
  // anyone has looked at it.
  setupTestRecorded(): Promise<void> {
    return this.setup.peek().at !== null || this.setup.peek().loading ? this.setup.refreshAfterChange() : Promise.resolve();
  }

  // After a job changed the site: what it may have changed is read again now
  // (health keeps its own ten-minute timer; validate takes half a minute).
  refreshAfterJob(): Promise<void> {
    this.moduleShow.clear();
    this.moduleIcons.clear();
    this.moduleResolve.clear();
    this.moduleBackup.clear();
    this.moduleDrift.clear();
    this.moduleFields.clear();
    // The Setup checklist is records only (no module test runs here, ever):
    // re-read if someone has looked, so the step a job just completed shows.
    const setup = this.setup.peek().at !== null ? [this.setup] : [];
    // The identity records follow the lists they are read from.
    const identity = this.identity.refresh().then(() => (this.identityRecords.peek().at !== null ? this.identityRecords.refresh() : undefined));
    // The catalogues mark what is installed: after the module list.
    const modules = this.modules.refresh().then(() => (this.catalogs.peek().at !== null ? this.catalogs.refresh() : undefined));
    // A faceplate added or changed: the forms' plates follow.
    const plates = this.faceplates.peek().at !== null ? [this.faceplates] : [];
    return Promise.all([identity, modules, ...[...setup, ...plates, this.topology, this.zones, ...(this.aps.peek().at !== null ? [this.aps] : []), ...(this.ssids.peek().at !== null ? [this.ssids] : []), ...(this.storage.peek().at !== null ? [this.storage] : []), ...(this.backupRuns.peek().at !== null ? [this.backupRuns] : []), this.environments, this.site, this.backup, this.peers, this.activity].map((c) => (c as Cached<unknown>).refresh())]).then(() => undefined);
  }

  private async loadStorage(): Promise<StorageDoc> {
    const d = await runJson<StorageDoc>(this.cfg.run, "storage-manager", ["inventory", "--json"], { timeoutMs: 3 * MIN });
    if (!d || !Array.isArray(d.nodes) || !Array.isArray(d.findings)) throw new Error("storage-manager inventory --json gave no inventory (no nodes, no findings)");
    return d;
  }

  private async loadTopology(): Promise<TopologyDoc & Record<string, unknown>> {
    // The topology places the health findings: hand it the document this cache
    // already holds rather than have it run validate a second time.
    const h = await this.health.get();
    let args = ["topology", "--json", "--no-health"];
    if (h.value) {
      mkdirSync(this.cfg.stateDir, { recursive: true });
      const f = join(this.cfg.stateDir, "health.json");
      writeJsonAtomic(f, h.value);
      args = ["topology", "--json", "--health", f];
    }
    return runJson<TopologyDoc & Record<string, unknown>>(this.cfg.run, "network-manager", args, { timeoutMs: 3 * MIN });
  }

  // Each zone as `network-manager show <name> --json` prints it, plus its name:
  // zones.json read once (lib/ts zones.ts, the manager's own parse and rule).
  // zones.json's zones, or none when it cannot be read.
  private zoneEntries(): Array<[string, Record<string, unknown>]> {
    try {
      return readZonesFile(join(this.cfg.configDir, "zones.json")).entries;
    } catch {
      return [];
    }
  }

  private async loadZones(): Promise<Record<string, unknown>[]> {
    const { entries } = readZonesFile(join(this.cfg.configDir, "zones.json"));
    return entries.map(([name, z]) => {
      const { name: _n, ...rest } = z;
      return { name, ...rest };
    });
  }

  private async loadNodeProgress(name: string): Promise<NodeProgress> {
    const dir = join(this.cfg.configDir, "provision");
    const registration = existsSync(join(dir, `${name}.json`)) ? "pending" : existsSync(join(dir, `${name}.json.consumed`)) ? "answered" : "none";
    const [list, pxe] = await Promise.all([
      runJson<{ name?: string }[]>(this.cfg.run, "site-manager", ["node", "list", "--json"]).catch(() => []),
      this.cfg.run("node-provisioner", ["status"], 30_000),
    ]);
    const siteNodes = list.map((n) => n.name).filter((n): n is string => typeof n === "string");
    const cluster = (this.cfg.clusterNodes ?? (() => null))(siteNodes);
    return {
      name,
      registration,
      // status exits 0 only when the window is fully open.
      pxe: { enabled: pxe.ran ? pxe.rc === 0 : null, text: (pxe.stdout + pxe.stderr).trim() },
      inCluster: cluster ? cluster.includes(name) : null,
      cluster,
      inSite: siteNodes.includes(name),
      siteNodes,
    };
  }

  private async loadSite(): Promise<Record<string, unknown>> {
    const run = this.cfg.run;
    const [site, nodes, repositories] = await Promise.all([
      runJson<Record<string, unknown>>(run, "site-manager", ["site", "show", "--json"]),
      runJson<unknown[]>(run, "site-manager", ["node", "list", "--json"]).catch(() => null),
      runJson<unknown[]>(run, "site-manager", ["repository", "list", "--json"]).catch(() => null),
    ]);
    // A missing or unreadable record is no address, not a failed site read.
    let wan: WanAddress | null = null;
    try {
      wan = readWanAddress(this.cfg.wanAddressFile ?? wanAddressFile());
    } catch {
      wan = null;
    }
    return { site, nodes, repositories, lastSweep: this.readJson("last-update-result.json"), wan };
  }

  private async loadIpv6(): Promise<Ipv6Read> {
    const site = ((await this.site.get()).value?.site ?? {}) as { ipv6?: unknown; network?: { wan?: { ipv6?: { mode?: string; prefix?: string } } } };
    const wan = site.network?.wan?.ipv6 ?? {};
    const mode = wan.mode ?? "dynamic";
    if (site.ipv6 !== true || mode === "none") return { on: site.ipv6 === true, mode, prefix: null, source: null };
    if (mode === "static") return { on: true, mode, prefix: wan.prefix || null, source: wan.prefix ? "site.json" : null };
    const r = await this.cfg.run("ipv6-manager", ["wan", "--json"], 90_000);
    if (!r.ran || r.rc !== 0) {
      const why = (r.stderr || r.stdout).trim().split("\n").pop() || `exit ${r.rc}`;
      return { on: true, mode, prefix: null, source: null, error: `ipv6-manager wan: ${why}` };
    }
    try {
      const prefix = String((JSON.parse(r.stdout) as { prefix?: unknown }).prefix ?? "").trim();
      return { on: true, mode, prefix: prefix || null, source: prefix ? "delegated" : null, ...(prefix ? {} : { error: "the firewall holds no delegated prefix" }) };
    } catch {
      return { on: true, mode, prefix: null, source: null, error: "ipv6-manager wan: not JSON" };
    }
  }

  private async loadActivity(): Promise<Activity> {
    const run = this.cfg.run;
    const [journal, active] = await Promise.all([
      run("journalctl", ["-u", "update-tappaas.service", "--since", `-${this.cfg.journalDays}d`, "-o", "short-iso", "--no-pager"], 60_000),
      run("systemctl", ["is-active", "update-tappaas.service"], 10_000),
    ]);
    if (!journal.ran || (journal.rc !== 0 && journal.stdout === "")) {
      throw new Error(`journalctl -u update-tappaas.service: ${journal.stderr.trim() || `exit ${journal.rc}`}`);
    }
    const ledgerFile = join(this.cfg.configDir, "update-tappaas.failures");
    return {
      runs: sweepRuns(parseJournal(journal.stdout)),
      ledger: existsSync(ledgerFile) ? parseLedger(readFileSync(ledgerFile, "utf8")) : [],
      lastResult: this.readJson("last-update-result.json"),
      sweepActive: active.ran && ["active", "activating"].includes(active.stdout.trim()),
    };
  }

  private readJson(file: string): Record<string, unknown> | null {
    const f = join(this.cfg.configDir, file);
    if (!existsSync(f)) return null;
    try {
      return JSON.parse(readFileSync(f, "utf8")) as Record<string, unknown>;
    } catch {
      return null;
    }
  }
}
