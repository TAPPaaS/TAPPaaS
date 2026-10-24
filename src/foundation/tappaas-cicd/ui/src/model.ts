// model.ts — the shapes of the manager outputs the backend itself looks into.
// Only the fields it reads are typed; everything else passes through to the
// browser as the manager printed it. (The topology's full type lives with
// network-manager; the console's build holds only lib/ts and ui/, so it is not
// imported.)

// health-manager validate --json
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
  status: string;
  detail: string;
  findings: GateFinding[];
}
export interface HealthDoc {
  version: number;
  generated: string;
  status: string;
  failed: number;
  warned: number;
  gates: Gate[];
}

// module-manager list --json
export interface ModuleRow {
  name: string;
  kind: string;
  vmname: string | null;
  vmid: number | null;
  node: string | null;
  zone0: string | null;
  stack: string | null;
  scope?: string | null;
  status: string | null;
  environment: string | null;
  running: string;
  actualNode: string | null;
}
export interface ModuleList {
  modules: ModuleRow[];
  orphans?: unknown[];
}

// backup-manager list --json
export interface BackupRow {
  module: string;
  enabled: boolean;
  optedIn?: boolean;
  archived?: boolean;
  inPbsJob?: boolean;
  schedule?: string;
  retention?: string;
}

// environment-manager list --json, with the environment's zone: the zone in
// zones.json naming it (#865), joined here for every reader, and the shared
// service zones that serve it besides (#876).
export interface EnvironmentRow {
  name: string;
  displayName?: string;
  zone?: string | null;
  sharedZones?: string[];
  domains?: { primary?: string };
}

// network-manager topology --json (the parts the jumps read)
export interface TopologyDoc {
  nodes: { name: string; guests: { module: string; vmid: number | null; kind: string }[] }[];
  switches: { name: string; vendor: string | null; controllerAddress: string | null; ports: { port: string }[]; lags: { name: string }[] }[];
  accessPoints: { name: string; vendor: string | null; address: string | null }[];
  zones: { name: string }[];
  outside: { kind: string; name: string }[];
}

// backup-manager restore list-all --json (the parts the console checks; the
// page reads the rest)
export interface BackupRunsDoc {
  reachable: boolean;
  guests: { ns: string; id: string; module: string | null; outcome: string; latestVerify: string }[];
  targets: { ns: string; kind: string }[];
}

// storage-manager inventory --json (the parts the console checks; the page
// reads the rest)
export interface StorageDoc {
  version: number;
  generated: string;
  smart: boolean;
  nodes: { name: string; reachable: boolean; boot: unknown[]; pools: { name: string; state: string }[]; otherDisks: unknown[]; replication: unknown[]; state: string; reasons: string[] }[];
  findings: { level: string; cause: string; on: { kind: string; node: string; name: string }; text: string }[];
  sources: { name: string; ok: boolean; error: string | null }[];
}
