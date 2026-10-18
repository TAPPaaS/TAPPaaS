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

export interface SiteRead {
  site: { name?: string; displayName?: string; channel?: string; version?: string; network?: { publicIp?: string } } & Record<string, unknown>;
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
  findings: TopoFinding[];
  sources: { name: string; ok: boolean; error?: string }[];
}

// ── jobs (ADR-034 D4) ─────────────────────────────────────────────────
export type JobPreview = { kind: "read" } | { kind: "apply-flag"; flag: string } | { kind: "dry-run-flag"; flag: string } | { kind: "none"; touches: string };
export interface JobSummary {
  id: string;
  kind: "preview" | "apply" | "read";
  state: "queued" | "running" | "done" | "refused";
  who: { user: string | null; name: string | null; role: string; via: string };
  route: string;
  origin: string;
  bin: string;
  verb: string;
  argv: string[];
  ran: string[] | null;
  preview: JobPreview;
  previewOf: string | null;
  destructive: boolean;
  object: string;
  created: string;
  started: string | null;
  ended: string | null;
  durationMs: number | null;
  exit: number | null;
  truncated: boolean;
  refused: string | null;
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
