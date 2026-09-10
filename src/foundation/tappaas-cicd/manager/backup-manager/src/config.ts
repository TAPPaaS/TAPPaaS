// config.ts — load + resolve the backup-policy cascade from CONFIG_DIR.
//
// Direct port of lib-cascade.sh `bc_resolve` / `bc_module_in_pbs_job` /
// `bc_list_modules` / `bc_module_environment`. Pure config reads from
// CONFIG_DIR; never mutates state and never contacts PBS — so it is fully
// unit-testable against fixtures (exactly as the bash lib was).
//
// The lib stays the source of truth for the BASH controller (which may still
// source it); this is the manager-side reimplementation in TypeScript. The two
// must agree on precedence — keep them in lock-step.
//
// Cascade precedence (most specific wins), verbatim from lib-cascade.sh:
//   retention : module.backup.retention > environment.backup.retention
//               > site.backup.defaultRetention > "7y"
//   residency : module has none; environment.backup.residency
//               > environment.dataResidency > "eu-only"
//   enabled   : module.backup.enabled (default true)
//   exclude   : module.backup.exclude (default [])
//   target    : site.backup.target
//   offsite   : site.backup.offsite
//   schedule  : module.backup.schedule > environment.backup.schedule
//               > site.backup.defaultSchedule > "daily"   (ADR-012 §3.2)

import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { defaultConfigDir, readJsonObject as readJson } from "../../../lib/ts/src/config-io";
import { declaresBackup, discoverModules } from "../../../lib/ts/src/module-discovery";
import { BackupPolicy, Peer, PeerRole, Placement, PlacementKind, ScheduleBucket } from "./types";

// The cascade reads the TARGET config root directly (it holds <module>.json,
// site.json, environments/) — the lib's ONE config-root rule (TAPPAAS_CONFIG >
// CONFIG_DIR > /home/tappaas/config), same default as lib-cascade.sh.
export { defaultConfigDir };

// readJson = lib readJsonObject: an ABSENT file is a legitimately-missing
// cascade layer → null (treated as {}); a PRESENT but unparseable/non-object
// file THROWS naming the file — silently defaulting it would resolve every
// module to default policy while `validate` reports the hierarchy consistent
// (the exact failure that verb exists to catch).

function asObject(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}
function asString(v: unknown): string | null {
  return typeof v === "string" && v !== "" ? v : null;
}
function asStringArray(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
}

// ── Schedule vocabulary (ADR-012 §3.2, D16) ──────────────────────────
//
// daily | weekly | monthly, or a bare HH:MM meaning daily at that time (the
// spelling existing site/environment configs already use). Everything else is
// invalid — including every sub-daily request, which is the point: the ceiling
// is only enforceable because the vocabulary is small enough to check.
//
// Mirrors pbs_schedule_bucket in backup/lib/pbs-schedule.sh.
const HHMM = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;

export function scheduleBucket(spec: string | null | undefined): ScheduleBucket | null {
  const s = (spec ?? "").trim().toLowerCase();
  if (s === "" || s === "daily") return "daily";
  if (s === "weekly") return "weekly";
  if (s === "monthly") return "monthly";
  if (HHMM.test(s)) return "daily";
  return null;
}

// Resolve the environment name for a deployed module: explicit override, else
// the module config's .environment, else null. (bc_module_environment)
export function moduleEnvironment(
  configDir: string,
  module: string,
  override?: string,
): string | null {
  if (override) return override;
  const m = readJson(join(configDir, `${module}.json`));
  if (!m) return null;
  return asString(m.environment);
}

// Resolve the effective backup policy for a module (port of bc_resolve).
export function resolvePolicy(
  configDir: string,
  module: string,
  envOverride?: string,
): BackupPolicy {
  const site = asObject(readJson(join(configDir, "site.json"))?.backup);
  const envName = moduleEnvironment(configDir, module, envOverride);
  const envFile = envName ? readJson(join(configDir, "environments", `${envName}.json`)) : null;
  const envBackup = asObject(envFile?.backup);
  const envDataResidency = envFile ? asString(envFile.dataResidency) : null;
  const mod = asObject(readJson(join(configDir, `${module}.json`))?.backup);

  // retention: module > environment > site.defaultRetention > "7y"
  const siteRet = asString(site.defaultRetention) ?? "7y";
  const envRet = asString(envBackup.retention) ?? siteRet;
  const retention = asString(mod.retention) ?? envRet;

  // schedule: module > environment > site.defaultSchedule > "daily" (§3.2).
  // Resolved, never null: "what does this module actually do?" should not
  // require the reader to re-walk the cascade in their head. Mirrors
  // pbs_schedule_resolve in backup/lib/pbs-schedule.sh — keep them in lock-step.
  const schedule =
    asString(mod.schedule) ?? asString(envBackup.schedule) ?? asString(site.defaultSchedule) ?? "daily";

  // residency: environment.backup.residency > environment.dataResidency > "eu-only"
  const residency = asString(envBackup.residency) ?? envDataResidency ?? "eu-only";

  // enabled: module.backup.enabled (default true) — only an explicit false disables.
  const enabled = mod.enabled === false ? false : true;

  return {
    module,
    environment: envName,
    enabled,
    retention,
    residency,
    schedule,
    scheduleBucket: scheduleBucket(schedule),
    target: asString(site.target),
    offsite: asString(site.offsite),
    exclude: asStringArray(mod.exclude),
  };
}

// True if <module> has DECLARED VM backup, by EITHER relationship (ADR-012
// D18): `dependsOn: backup:vm` (a hard dependency), or `integratesWith:
// backup:vm` (#501 — the optional integration the foundation VMs that bootstrap
// before the backup server use, since they cannot depend on it). Backup stays
// opt-in: a module declaring neither is in no job. Mirrors pbs_optin_vmids in
// backup/lib/pbs-job.sh — the two must agree on the opt-in set.
//
// This was `moduleInPbsJob`, and the name was the bug (#627): it never read the
// job. Membership lives in PBS and is answered by Client.jobStatus().buckets;
// this answers only what the module asked for. An archived module still
// declares (its config is kept for restore), so the two legitimately differ —
// see moduleArchived.
export function moduleOptedIntoVmBackup(configDir: string, module: string): boolean {
  const m = readJson(join(configDir, `${module}.json`));
  if (!m) return false;
  const declared = [...asStringArray(m.dependsOn), ...asStringArray(m.integratesWith)];
  return declared.includes("backup:vm");
}

// True when <module> is archived: `module-manager module delete --archive`
// removed the VM but kept the config, its PBS snapshots, and its backup:vm
// declaration so a restore re-wires itself. There is no guest to snapshot, so
// an archived module must not be reconciled back into the job — the TS twin of
// the _pbs_is_archived guard in backup/lib/pbs-job.sh.
export function moduleArchived(configDir: string, module: string): boolean {
  return readJson(join(configDir, `${module}.json`))?.status === "archived";
}

// List deployed module config basenames (without .json).
//
// #544: this used to be a hand-maintained deny-list of five names, so every
// non-module file in config/ that nobody had added to it — last-update-result,
// module-fields, zones.effective, … — was reported AS a module. Discovery is
// now the shared, SHAPE-based rule (lib/ts/src/module-discovery.ts), the same
// one module-manager uses, so the two managers cannot drift apart again.
//
// `backup` itself is excluded: it is the provider, not one of its own targets.
export function listModules(configDir: string): string[] {
  return discoverModules(configDir)
    .map((m) => m.name)
    .filter((n) => n !== "backup");
}

// The subset that has actually opted into backup (ADR-012 §3.1): a module
// declaring backup:vm or backup:filesystem under dependsOn or integratesWith.
// `list`/`reconcile` speak about backup POLICY, so an opted-out module belongs
// in neither — and #544 is only half-fixed if phantom files stop appearing but
// hardware/test modules still do.
export function listBackupModules(configDir: string): string[] {
  return discoverModules(configDir)
    .filter((m) => m.name !== "backup" && declaresBackup(m.raw))
    .map((m) => m.name);
}

// Resolve a module name to its VMID from the deployed config (used by restore
// and by reconcile to decide job membership).
//
// A deployed config writes vmid as a NUMBER (`"vmid": 340`); the test fixtures
// and some hand-written configs use a string. Reading it as a string only meant
// every live module resolved to "no vmid", so `reconcile` warned "wired into
// the PBS job but has no vmid" for ALL of them and could never add anyone to
// the job — the verb was inert against a real config dir while passing its
// string-fixture tests. Accept both, normalize to string. (Found live 2026-09-09.)
export function moduleVmid(configDir: string, module: string): string | null {
  const m = readJson(join(configDir, `${module}.json`));
  if (!m) return null;
  if (typeof m.vmid === "number" && Number.isFinite(m.vmid)) return String(m.vmid);
  return asString(m.vmid);
}

// Read the raw site.backup block (validate needs offsite/target/offsiteResidency).
export function siteBackup(configDir: string): Record<string, unknown> {
  return asObject(readJson(join(configDir, "site.json"))?.backup);
}

// List environment names that have a JSON file (validate iterates these).
export function listEnvironments(configDir: string): string[] {
  const dir = join(configDir, "environments");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => f.slice(0, -".json".length))
    .sort();
}

// Raw environment block (validate reads residency/dataResidency/backup.retention).
export function environmentRaw(configDir: string, env: string): Record<string, unknown> {
  return asObject(readJson(join(configDir, "environments", `${env}.json`)));
}

// ── ADR-012: placement + off-site peers ───────────────────────────────

// Classify a placementState into what the reader actually cares about. The
// legacy v0.2 values are folded in so a config that has not yet been through
// the module's migrating update still reports honestly:
//   node:<name> | local → local     (a datastore exists here)
//   external | remote-only → external (a datastore exists elsewhere)
//   shim → shim                     (no datastore anywhere)
//   null/unknown → unresolved
export function classifyPlacement(state: string | null): PlacementKind {
  if (!state) return "unresolved";
  if (state.startsWith("node:")) return "local";
  switch (state) {
    case "local":
      return "local";
    case "shim":
      return "shim";
    case "external":
    case "remote-only":
      return "external";
    default:
      return "unresolved";
  }
}

// Read the backup module's placement (ADR-012 §2.1) from backup.json.
export function readPlacement(configDir: string): Placement {
  const b = readJson(join(configDir, "backup.json")) ?? {};
  const placementState = asString(b.placementState);
  const kind = classifyPlacement(placementState);
  // The resolved node lives in the state itself (node:<name>); `.node` is only
  // the operator's discovery constraint, so it is a back-compat fallback for a
  // legacy `local` state that has not been migrated yet.
  const node = placementState?.startsWith("node:")
    ? placementState.slice("node:".length)
    : kind === "local"
      ? asString(b.node)
      : null;
  return {
    placementState,
    kind,
    node,
    pbsUrl: asString(b.pbsUrl) ?? "backup.mgmt.internal",
    pbsStorageName: asString(b.pbsStorageName) ?? "tappaas_backup",
    pushTarget: asString(b.pushTarget),
  };
}

// List the off-site peers (ADR-012 §1.4) from the config dir:
//   pull-<n>     we pull a copy of their backups
//   remote-<n>   they pull ours — where our off-site copies live
//   receive-<n>  they push theirs into ours
// Prompt-not-store means these files carry host/namespace only, never a
// credential.
export function listPeers(configDir: string): Peer[] {
  if (!existsSync(configDir)) return [];
  const prefixes: Array<[string, PeerRole]> = [
    ["pull-", "pull"],
    ["remote-", "remote"],
    ["receive-", "receive"],
  ];
  const out: Peer[] = [];
  for (const f of readdirSync(configDir)) {
    if (!f.endsWith(".json")) continue;
    const b = f.slice(0, -".json".length);
    for (const [prefix, role] of prefixes) {
      if (!b.startsWith(prefix)) continue;
      const j = readJson(join(configDir, f)) ?? {};
      out.push({
        name: b.slice(prefix.length),
        role,
        remoteHost: asString(j.remoteHost),
        namespace: asString(j.namespace),
      });
      break;
    }
  }
  return out.sort((a, b) => a.role.localeCompare(b.role) || a.name.localeCompare(b.name));
}
