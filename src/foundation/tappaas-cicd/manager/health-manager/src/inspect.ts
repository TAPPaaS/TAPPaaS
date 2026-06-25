// inspect.ts — the read-only inspection logic (pure, client-injected).
//
//   inspectCluster()  = inspect-cluster.sh   → `list vm` (and `list vm --diff`)
//   inspectVm(name)   = inspect-vm.sh        → `show vm <name>`
//
// Depends ONLY on the ClusterClient interface + the loaded config, so tests
// inject a fake cluster and assert the classification without any SSH.

import { join } from "path";
import { loadConfigModules, readModuleJson, resolveGitJson } from "./config";
import {
  ClusterClient,
  ClusterDiff,
  ClusterInspection,
  ClusterRow,
  ConfigModule,
  DriftRow,
  MissingModule,
  VmInspection,
} from "./types";

function asString(v: unknown): string {
  if (typeof v === "string") return v;
  if (typeof v === "number") return String(v);
  return "";
}

// ── list vm (= inspect-cluster.sh) ────────────────────────────────────
// Two-way comparison: running guests vs. configured modules. Classifies every
// running guest (managed / external / not-in-config) and lists configured
// modules whose VM is not running (missing / archived / external).
export function inspectCluster(
  client: ClusterClient,
  configDir: string,
  defaultNode: string,
): ClusterInspection {
  const running = client.clusterResources();
  const configs = loadConfigModules(configDir, defaultNode);
  const byVmid = new Map<number, ConfigModule>();
  for (const c of configs) byVmid.set(c.vmid, c);

  const rows: ClusterRow[] = [];
  let warnings = 0;
  for (const g of [...running].sort((a, b) => a.vmid - b.vmid)) {
    const cfg = byVmid.get(g.vmid);
    let config: ClusterRow["config"];
    if (cfg) {
      config = cfg.status === "external" ? "external" : "managed";
    } else {
      config = "not-in-config";
      warnings++;
    }
    rows.push({
      vmid: g.vmid,
      name: g.name,
      node: g.node,
      type: g.type === "qemu" ? "vm" : "ct",
      status: g.status,
      config,
    });
  }

  const runningVmids = new Set(running.map((g) => g.vmid));
  const missing: MissingModule[] = [];
  let missingCount = 0;
  for (const c of configs) {
    if (runningVmids.has(c.vmid)) continue;
    let kind: MissingModule["kind"];
    if (c.status === "archived") kind = "archived";
    else if (c.status === "external") kind = "external";
    else {
      kind = "missing";
      missingCount++;
    }
    missing.push({ vmid: c.vmid, module: c.module, node: c.node, kind });
  }

  return { rows, missing, warnings, missingCount };
}

// ── show vm <name> (= inspect-vm.sh) ──────────────────────────────────
// The three-way drift table. Released = git source JSON, Desired = config JSON,
// Actual = the live VM via Proxmox. level: warn = Desired!=Released (config
// drift), error = Actual!=Desired (VM drift) — mirroring inspect-vm.sh's
// yellow/red rules.
//
// NOTE (scope): the NIC drift rows (bridge/zone/vlan/trunks/mac) in inspect-vm.sh
// resolve zone→VLAN and expand the "ALL" trunk sentinel via cluster/lib/vm-net.sh
// (vmnet_parse / vmnet_resolve_trunks / vmnet_zone_vlantag). That resolver is not
// ported here — see TODO(question) below. This pass ports the scalar fields
// (identity, cpu, memory, disk, bios, cputype, tags), which are the unambiguous
// part of the three-way diff.
function driftRow(field: string, released: string, desired: string, actual: string): DriftRow {
  let level: DriftRow["level"] = "ok";
  // Yellow: Desired differs from Released (only when Released has a value).
  if (released && desired !== released) level = "warn";
  // Red wins: Actual differs from Desired (only when both present, Desired != "-").
  if (actual && desired && desired !== "-" && actual !== desired) level = "error";
  return { field, released, desired, actual, level };
}

export function inspectVm(
  client: ClusterClient,
  configDir: string,
  module: string,
): VmInspection {
  const cfgRaw = readModuleJson(join(configDir, `${module}.json`));
  if (!cfgRaw) {
    throw new Error(`Module config not found: ${join(configDir, `${module}.json`)} — is '${module}' installed?`);
  }
  const vmid = Number(asString(cfgRaw.vmid));
  if (!Number.isFinite(vmid) || vmid === 0) {
    throw new Error(`No vmid defined in ${module}.json`);
  }
  const node = asString(cfgRaw.node) || "tappaas1";
  const vmname = asString(cfgRaw.vmname) || module;

  const git = resolveGitJson(configDir, module, vmname);
  const cfg = (k: string): string => asString(cfgRaw[k]);
  const gitv = (k: string): string => (git ? asString(git[k]) : "");

  const actual = client.vmConfig(node, vmid);
  const status = client.vmStatus(node, vmid);
  const actualNode = client.actualNode(node, vmid);

  const rows: DriftRow[] = [];
  // Identity
  rows.push(driftRow("vmname", gitv("vmname"), cfg("vmname"), actual.name ?? ""));
  rows.push(driftRow("vmid", gitv("vmid"), cfg("vmid"), String(vmid)));
  rows.push(driftRow("node", gitv("node"), cfg("node"), actualNode));
  rows.push(driftRow("status", "-", "-", status));
  // CPU / memory
  rows.push(driftRow("cores", gitv("cores"), cfg("cores"), actual.cores ?? ""));
  rows.push(driftRow("memory", gitv("memory"), cfg("memory"), actual.memory ?? ""));
  // Disk: parse size= out of the first present disk bus, as inspect-vm.sh does.
  let actualDisk = "";
  for (const key of ["scsi0", "virtio0", "ide0", "sata0"]) {
    if (actual[key]) {
      const m = /size=([^,]+)/.exec(actual[key]);
      if (m) actualDisk = m[1];
      break;
    }
  }
  rows.push(driftRow("diskSize", gitv("diskSize"), cfg("diskSize"), actualDisk));
  rows.push(driftRow("storage", gitv("storage"), cfg("storage"), ""));
  // BIOS / CPU type
  rows.push(driftRow("bios", gitv("bios"), cfg("bios"), actual.bios ?? "seabios"));
  rows.push(driftRow("cputype", gitv("cputype"), cfg("cputype"), actual.cpu ?? ""));
  // Tags — normalize to sorted lowercase before comparing (inspect-vm.sh).
  const normTags = (s: string): string =>
    s
      .split(/[,;]/)
      .map((x) => x.trim().toLowerCase())
      .filter(Boolean)
      .sort()
      .join(";");
  const cfgTag = cfg("vmtag");
  const actualTags = actual.tags ?? "";
  const tagActual = cfgTag && actualTags && normTags(cfgTag) === normTags(actualTags) ? cfgTag : actualTags;
  rows.push(driftRow("vmtag", gitv("vmtag"), cfgTag, tagActual));

  // TODO(followup #Q3): NIC drift rows (bridge/zone/vlan/trunks/mac for net0,net1)
  // require porting cluster/lib/vm-net.sh (vmnet_parse / vmnet_resolve_trunks /
  // vmnet_zone_vlantag) — zone→VLAN resolution + "ALL" sentinel expansion.
  // DEFERRED (coordinator-approved follow-up), not in this pass.
  // TODO(followup): HANode + description rows — inspect-vm.sh shows HANode with
  // an empty Actual and description as config-vs-git only (Proxmox HTML-wraps it).
  // Folded into the NIC/vm-net follow-up; omitted here.

  let warnings = 0;
  let errors = 0;
  for (const r of rows) {
    if (r.level === "warn") warnings++;
    else if (r.level === "error") errors++;
  }

  return { module, vmname, vmid, node, rows, warnings, errors };
}

// ── list vm --diff (= per-VM three-way rollup) ────────────────────────
// Runs the inspectVm three-way (orig/config/running) for EVERY managed config
// module and rolls up the drift counts. "Managed" = a configured module that is
// not archived/external (the bootable, owned VMs). A VM that cannot be queried
// (node down, migrated, not yet provisioned) is collected in `unreachable`
// rather than aborting the whole rollup — the cluster diff stays useful even
// when one node is offline.
export function clusterDiff(
  client: ClusterClient,
  configDir: string,
  defaultNode: string,
): ClusterDiff {
  const managed = loadConfigModules(configDir, defaultNode).filter((m) => m.status === "");
  const vms: VmInspection[] = [];
  const unreachable: { module: string; error: string }[] = [];
  let warnings = 0;
  let errors = 0;
  for (const m of managed) {
    try {
      const insp = inspectVm(client, configDir, m.module);
      vms.push(insp);
      warnings += insp.warnings;
      errors += insp.errors;
    } catch (e) {
      unreachable.push({ module: m.module, error: e instanceof Error ? e.message : String(e) });
    }
  }
  return { vms, unreachable, warnings, errors };
}
