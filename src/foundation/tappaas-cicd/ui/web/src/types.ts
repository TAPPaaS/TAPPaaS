// types.ts — the shapes /api/v1 answers in (the backend passes the managers'
// documents through; these name the fields the pages read).

export interface Envelope<T> {
  data: T | null;
  at: string | null;
  ageSeconds: number | null;
  refreshing: boolean;
  error: string | null;
}

export interface Me {
  user: string | null;
  name: string | null;
  groups: string[];
  role: "installer" | "admin" | "read";
  via: "gate" | "local" | "setup-token";
  route: "console" | "status";
}

export interface Subject {
  kind: string;
  name: string;
}
export interface GateFinding {
  status: string;
  text: string;
  subject: Subject | null;
}
export interface Gate {
  name: string;
  status: "pass" | "warn" | "fail" | "skip";
  detail: string;
  findings: GateFinding[];
}
export interface AttentionRow {
  gate: string;
  level: "fail" | "warn";
  text: string;
  subject: Subject | null;
}
export interface Health {
  status: string;
  generated: string;
  failed: number;
  warned: number;
  gates: Gate[];
  attention: AttentionRow[];
}

export interface ModuleSummary {
  name: string;
  kind: string;
  vmname: string | null;
  vmid: number | null;
  node: string | null;
  zone0: string | null;
  stack: string | null;
  status: string | null;
  environment: string | null;
  running: string;
  actualNode: string | null;
  badges: {
    run: "running" | "stopped" | "none";
    health: "fail" | "warn" | "pass" | "unknown";
    backup: "covered" | "disabled" | "not-in-job" | "not-opted" | "unknown";
    cve: "act" | "ok" | "unknown";
    maturity: string | null;
  };
  findings: { gate: string; status: string; text: string }[];
}

export interface ModuleDetail {
  summary: ModuleSummary;
  findings: { gate: string; status: string; text: string }[];
  show: Envelope<Record<string, unknown>>;
  resolve: Envelope<{ module: string; dependsOn?: string[]; integratesWith?: string[]; fields?: Record<string, ResolvedField> }>;
  backup: Envelope<{ policy: Record<string, unknown>; coverage: Record<string, unknown> }> | null;
  activity: { run: string; line: RunLine }[] | null;
  jobs: JobSummary[];
}
export interface ResolvedField {
  value: unknown;
  defaulted?: boolean;
  literal?: unknown;
  notTracking?: boolean;
}

export interface Jump {
  target: string;
  label: string;
  url: string;
}

export interface RunLine {
  at: string;
  level: "error" | "warning";
  text: string;
}
export interface SweepRun {
  start: string;
  end: string | null;
  result: "ok" | "failed" | "running" | "unknown";
  lines: RunLine[];
  truncated: number;
}
export interface Activity {
  runs: SweepRun[];
  ledger: { at: string | null; text: string }[];
  lastResult: Record<string, unknown> | null;
  sweepActive: boolean;
}

// What the firewall's WAN held at the last network update (wan-address.json).
export interface WanAddress {
  ipv4: string | null;
  prefix: number | null;
  ipv6: string[];
  private: boolean;
  observed: string | null;
}

export interface SiteRead {
  site: { name?: string; displayName?: string; channel?: string; version?: string; network?: { publicIp?: string } } & Record<string, unknown>;
  wan?: WanAddress | null;
  nodes: { name: string; storagePools?: string[] }[] | null;
  repositories: { name: string; branch?: string; url?: string }[] | null;
  lastSweep: { start_time?: string; end_time?: string; total?: number; succeeded?: number; failed?: number; ok?: boolean; reboot?: string; failed_modules?: string[] } | null;
}

export interface EnvironmentRow {
  name: string;
  displayName?: string;
  network?: { zone?: string };
  domains?: { primary?: string };
}

export interface ZoneRow {
  name: string;
  vlantag?: number;
  state?: string;
  type?: string;
  tier?: number;
}

// ── the topology document (network-manager topology --json) ──────────
export interface TopoRef {
  kind: string;
  name: string;
  switch?: string;
}
export interface TopoLeg {
  nic: string;
  mac: string;
  speed: string | null;
  up: boolean;
  peer: { switch: string; port: string; known: boolean; via: string } | null;
}
export interface TopoUplink {
  name: "lan" | "wan";
  mode: string;
  bond: string | null;
  mtu: number | null;
  declared: { mode: string | null; ports: string[] } | null;
  legs: TopoLeg[];
}
export interface TopoGuest {
  module: string;
  vmid: number | null;
  kind: string;
  zone: string | null;
  environment: string | null;
  stack: string | null;
  maturity: string | null;
  state: string;
}
export interface TopoNode {
  name: string;
  storagePools: string[];
  roles: string[];
  ha: { lrm: string } | null;
  corosync: { links: number; disconnected: number } | null;
  lldpd: string | null;
  uplinks: TopoUplink[];
  guests: TopoGuest[];
}
export interface TopoPort {
  port: string;
  role: string;
  type: string | null;
  mode: string;
  native: number;
  tagged: number[];
  zones: string[];
  target: { kind: string; name: string | null; port: string | null } | null;
  description: string | null;
  lag: string | null;
  lagLead?: string | null; // a LAG member: the lead whose VLANs it carries (#854)
  parked?: boolean; // an access port in the park zone, used for nothing (#853)
  link?: string | null;
  drift: string;
  add: number[];
  remove: number[];
  seen: { node: string; nic: string } | null;
}
export interface TopoSwitch {
  name: string;
  lldpName: string | null;
  vendor: string | null;
  model: string | null;
  managementIp: string | null;
  managed: string | null;
  controller: string | null;
  controllerAddress: string | null;
  ports: TopoPort[];
  lags: { name: string; ports: string[]; formed: boolean; live: string[]; node: string | null; bond: string | null }[];
}
export interface TopoAp {
  name: string;
  vendor: string | null;
  model: string | null;
  address: string | null;
  uplink: { switch: string; port: string } | null;
  ssids: { name: string; zone: string | null; vlan: number | null; security: string | null; enabled: boolean }[];
}
export interface TopoZone {
  name: string;
  vlan: number | null;
  state: string | null;
  type: string | null;
  tier: number | null;
}
export interface TopoOutside {
  kind: "buddy" | "satellite";
  name: string;
  role: string | null;
  location: string | null;
  tunnel: string | null;
  address: string | null;
  state: "up" | "down" | null;
}
export interface TopoFinding {
  gate: string;
  level: "fail" | "warn";
  text: string;
  on: TopoRef;
  refs: TopoRef[];
}
export interface Topology {
  generated: string;
  site: {
    name: string | null;
    wan: {
      publicIp: string | null;
      discovered?: WanAddress | null;
      ipv6: boolean;
      isp: string | null;
      zone: string | null;
      vlan: number | null;
      handoff: { switch: string; port: string; description: string | null } | null;
      firewall: { module: string; vmid: number | null; node: string | null; standby: string | null } | null;
      paths: { node: string; nic: string; switch: string | null; port: string | null; active: boolean }[];
    };
  };
  nodes: TopoNode[];
  switches: TopoSwitch[];
  accessPoints: TopoAp[];
  zones: TopoZone[];
  outside: TopoOutside[];
  // The machines, the devices a switch port names, and the devices rack-manager
  // records (recorded: a modem, an ONT, a UPS, a patch panel; with their ports).
  devices?: { name: string; kind: "machine" | "device" | RecordedKind; vendor: string | null; model: string | null; recorded?: true; ports?: string[]; displayName?: string | null; description?: string | null }[];
  // Where the hardware sits (rack-manager), resolved against the site; null or
  // absent when the racks were not read.
  racks?: RacksView | null;
  findings: TopoFinding[];
  sources: { name: string; ok: boolean; error?: string }[];
}

// ── the racks the topology carries (lib/ts racks.ts RacksView) ────────
export type PortKind = "rj45" | "sfp+" | "sfp28" | "poe" | "console" | "power";
export type RecordedKind = "modem" | "ont" | "ups" | "patch-panel" | "other";
export interface PlatePort {
  id: string; // the topology's
  name: string; // the controller's
  kind: PortKind;
  up: boolean | null;
  disabled: boolean;
  lag: string | null;
  zones: string[];
}
export interface ResolvedPlate {
  key: string;
  vendor: string;
  model: string;
  kind: string;
  units: number;
  width: "full" | "half" | "third";
  passive: boolean;
  rows: (PlatePort | null)[][];
  labels: { text: string; at?: "left" | "right" }[];
}
export interface RackMount {
  device: string;
  kind: "node" | "switch" | "ap" | "machine" | "device" | "passive";
  recorded?: RecordedKind;
  rack: string; // "" for a device loose in a room
  room?: string | null;
  u: number;
  height: number;
  width: "full" | "half" | "third";
  slot: number;
  face: "front" | "rear";
  label: string | null;
  description: string | null;
  faceplate: string | null;
  suggested: boolean;
  plate: ResolvedPlate | null;
  up: boolean | null;
}
export interface RackInfo {
  name: string;
  displayName: string | null;
  units: number;
  width: "19in" | "10in";
  numbering: "bottom-up" | "top-down";
  building: string | null;
  room: string | null;
  description: string | null;
  mounts: RackMount[];
}
export interface RackCable {
  from: { device: string; port: string; side?: "front" | "rear" }; // side: a patch panel's port
  to: { device: string; port: string; side?: "front" | "rear" };
  kind: string;
  source: "topology" | "recorded";
  zones: string[];
  lag: string | null;
  up: boolean | null;
  label: string | null;
}
// A room: its racks (by name) and the devices loose in it; recorded false: a
// room only a rack's free text names.
export interface RoomInfo {
  name: string;
  displayName: string | null;
  building: string | null;
  description: string | null;
  recorded: boolean;
  racks: string[];
  loose: RackMount[];
}
export interface RacksView {
  racks: RackInfo[];
  rooms?: RoomInfo[];
  unplaced: { device: string; kind: "node" | "switch" | "ap" | "machine" | "device"; recorded?: RecordedKind; vendor: string | null; model: string | null; suggestion: string | null }[];
  cables: RackCable[];
  outside: { device: string; faceplate: string | null; plate: ResolvedPlate | null }[];
  findings: { text: string; device: string; kind: "gone" | "unplaced"; rack: string | null }[];
}

// ── the storage inventory (storage-manager inventory --json) ──────────
export type StorageState = "ok" | "warn" | "fail";
export interface StorageDisk {
  device: string;
  byId: string | null;
  model: string | null;
  serial: string | null;
  wwn: string | null;
  size: number | null;
  type: "hdd" | "ssd" | "nvme" | "unknown";
  wearout: number | null; // % of life left
  smart: {
    read: boolean;
    health: string | null;
    temperature: number | null;
    reallocated: number | null;
    pending: number | null;
    uncorrectable: number | null;
    mediaErrors: number | null;
    criticalWarning: number | null;
    powerOnHours: number | null;
  } | null;
  zfs: { pool: string; vdev: string; state: string; read: number; write: number; cksum: number; msg: string | null } | null;
  exportedPool: { name: string; health: string | null } | null;
  state: StorageState;
  reasons: string[];
}
export interface StorageVdev {
  name: string;
  type: string; // mirror, raidz1, stripe…
  parity: number | null;
  role: string; // data, log, cache, spare, special
  health: string;
  state: StorageState;
  disks: StorageDisk[];
  missing: { name: string; state: string }[]; // a member ZFS names that is not among the node's disks
}
export interface StorageVolume {
  name: string;
  vmid: number;
  module: string | null;
  guest: string | null;
  kind: "own" | "mirror" | "template" | "orphan";
  runsOn: string | null;
  type: string;
  size: number;
  used: number;
  refer: number;
  snapshots: number;
  replica: string | null;
  mirroredOn: string[];
  note: string | null;
}
export interface StorageDataset {
  name: string;
  kind: "pbs-datastore" | "nfs-share" | "dataset" | "volume";
  label: string;
  mountpoint: string | null;
  used: number;
  exact: boolean;
}
export interface StoragePool {
  name: string;
  declared: boolean;
  present: boolean;
  health: string | null;
  status: string | null;
  size: number | null;
  allocated: number | null;
  free: number | null;
  fragmentation: number | null;
  dedup: number | null;
  compression: string | null;
  compressRatio: number | null;
  usable: { total: number; used: number; avail: number; pct: number } | null;
  scrub: { state: string; last: string | null; errors: number | null; text: string | null };
  vdevs: StorageVdev[];
  volumes: StorageVolume[];
  datasets: StorageDataset[];
  totals: { total: number; own: number; mirror: number; other: number; free: number };
  state: StorageState;
  reasons: string[];
}
export interface StorageReplication {
  id: string;
  vmid: number;
  module: string | null;
  source: string;
  target: string;
  schedule: string | null;
  lastSync: string | null;
  nextSync: string | null;
  failCount: number;
  error: string | null;
  state: StorageState;
  reasons: string[];
}
export interface StorageNode {
  name: string;
  reachable: boolean;
  boot: StorageDisk[];
  pools: StoragePool[];
  otherDisks: StorageDisk[];
  replication: StorageReplication[];
  state: StorageState;
  reasons: string[];
}
export interface StorageFinding {
  level: "fail" | "warn";
  cause: string;
  on: { kind: "disk" | "pool" | "replication" | "node"; node: string; name: string };
  text: string;
}
export interface StorageInventory {
  version: number;
  generated: string;
  smart: boolean;
  nodes: StorageNode[];
  findings: StorageFinding[];
  sources: { name: string; ok: boolean; error: string | null }[];
}

// ── jobs (ADR-034 D4) ─────────────────────────────────────────────────
export type JobPreview = { kind: "read" } | { kind: "apply-flag"; flag: string } | { kind: "dry-run-flag"; flag: string } | { kind: "none"; touches: string };
export interface JobSummary {
  id: string;
  kind: "preview" | "apply" | "read";
  state: "queued" | "running" | "done" | "refused";
  who: { user: string | null; name: string | null; role: string; via: string };
  route: string;
  origin: "ui" | "assistant";
  assistant?: { conversation: string; turn: number; proposal: string } | null; // the card it came from
  bin: string;
  verb: string;
  argv: string[];
  ran: string[] | null;
  preview: JobPreview;
  previewOf: string | null;
  destructive: boolean;
  object: string; // what the typed confirmation names
  objectLabel?: string; // the object as shown, "<switch>:<port>" (#855)
  created: string;
  started: string | null;
  ended: string | null;
  durationMs: number | null;
  exit: number | null;
  truncated: boolean;
  refused: string | null;
  interrupted?: boolean; // the console stopped while it ran: cut off, no exit code
}
export interface Job extends JobSummary {
  output: string;
}
export interface SweepState {
  active: boolean;
  state: string;
  since: string | null;
  stage: string | null;
}

// ── the verb manifest (GET /api/v1/manifests) ─────────────────────────
export interface ManifestOption {
  flag: string;
  takesValue: boolean;
  arg: string | null;
  choices: string[] | null;
  repeatable: boolean;
  description: string;
}
export interface ManifestVerb {
  verb: string;
  keys: string[][];
  usage: string;
  note: string | null;
  details: string | null;
  positionals: { name: string; optional: boolean; repeatable: boolean }[];
  options: ManifestOption[];
  open: boolean;
  effect: "read" | "write";
  preview: JobPreview;
  destructive: boolean;
  destructiveWhen: string[];
  readWhen: string[];
  writeWhen: { flag: string; touches: string }[]; // a read verb's options that make a call a write with no dry run (test --deep)
  disruptions: { flag: string; consequence: string }[];
}
export interface Manifest {
  name: string;
  version: string;
  tagline: string;
  verbs: ManifestVerb[];
}

// backup-manager list --json
export interface BackupRowView {
  module: string;
  enabled: boolean;
  optedIn?: boolean;
  archived?: boolean;
  inPbsJob?: boolean;
  schedule?: string;
  retention?: string;
}

// ── the assistant (GET /api/v1/assistant/status, ADR-034 D7) ─────────
export interface AssistantStatus {
  available: boolean;
  reason: string;
  model: string | null;
  modelFrom: "console.json" | "default" | "first listed" | null;
  endpoint: string | null;
  keyFile: string | null;
  checkedAt: string;
}
