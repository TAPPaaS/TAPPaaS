// backup-manager — TAPPaaS backup-policy cascade manager (ADR-007 verb-alignment
// #3, TypeScript first-pass port of backup-manager.sh / backup-status.sh /
// validate-backup.sh / backup-restore.sh + lib-cascade.sh).
//
// Owns the Site → Environment → Module backup-policy CASCADE (the entity = the
// resolved backup `job`/`policy`). Read-only over config; delegates live PBS
// operations to the `backup-controller` bin via CliClient (src/client.ts) — NO
// PBS API is reimplemented here.
//
// Standardized verbs (ADR-007):
//   validate                       config is well-formed + internally consistent
//   list                           every module's effective policy (= backup-status)
//   show <module>                  one module's effective policy (= backup-status one)
//   reconcile [--apply]            converge policies → PBS (= backup-manager.sh)
//   restore list|restore|list-all  SPECIAL verb — recovery (= backup-restore.sh)
//   resolve <module>               print one resolved policy (cascade primitive)
//
// add/modify/delete are PARKED — see TODO(question 1/2): the policy is a
// CASCADE, not a stored object; what those verbs write is unresolved.
//
// Exit codes: ok=0, error=1.

import {
  defaultConfigDir,
  listModules,
  listPeers,
  moduleInPbsJob,
  readPlacement,
  resolvePolicy,
} from "./config";
import { CliClient } from "./client";
import { addToBackupJob, modifyBackup, ModifyOpts, removeFromBackupJob } from "./modify";
import { applyPlan, computePlan } from "./reconcile";
import { restoreList, restoreListAll, restoreRun } from "./restore";
import { validate } from "./validate";
import { HelpSpec, renderHelp } from "./help";
import { BackupPolicyStatus, Client } from "./types";

const VERSION = "0.1.0";

const YW = "\x1b[01;33m";
const RD = "\x1b[01;31m";
const GN = "\x1b[1;92m";
const CL = "\x1b[0m";

function info(msg: string): void {
  console.log(msg);
}
function warn(msg: string): void {
  console.log(`${YW}[Warning]${CL} ${msg}`);
}
class DieError extends Error {}
function die(msg: string): never {
  console.error(`${RD}[Error]${CL} ${msg}`);
  throw new DieError(msg);
}

const HELP: HelpSpec = {
  name: "backup-manager",
  version: VERSION,
  tagline: "TAPPaaS backup-policy cascade manager",
  verbs: [
    { usage: "validate" },
    {
      usage: "list [--disabled-only]",
      name: "list",
      options: [["--disabled-only", "list: only modules with backup disabled."]],
    },
    { usage: "show <module>", name: "show" },
    {
      usage: "resolve <module> [--environment ENV]",
      name: "resolve",
      options: [["--environment ENV", "resolve: override the module's recorded .environment."]],
    },
    {
      usage: "modify <module> [--enabled true|false] [--retention SPEC] [--exclude a,b]",
      name: "modify",
      options: [
        ["--enabled B", "modify: set module backup.enabled (true|false)."],
        ["--retention SPEC", "modify: set module backup.retention (e.g. 90d, 1y)."],
        ["--exclude a,b", "modify: set module backup.exclude (comma-separated)."],
      ],
    },
    { usage: "add <module>", name: "add", note: "(wire into the shared PBS job)" },
    { usage: "delete <module>", name: "delete", note: "(un-wire from the shared PBS job)" },
    {
      usage: "reconcile [--apply]",
      name: "reconcile",
      options: [["--apply", "reconcile: commit changes (default = preview)."]],
    },
    { usage: "restore list <module>", name: "restore list" },
    { usage: "restore restore <module> [opts...]", name: "restore restore" },
    { usage: "restore list-all", name: "restore list-all" },
    { usage: "placement", name: "placement", note: "(ADR-012 — backup placement/state)" },
    { usage: "peers", name: "peers", note: "(ADR-012 — off-site pull/receive/push peers)" },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $CONFIG_DIR or /home/tappaas/config)."],
    ["--json", "Machine output (JSON) for list/show/resolve/placement/peers."],
    ["--pbs HOST", "ADR-012 P7: target a non-local PBS (e.g. a satellite) for controller ops."],
  ],
  notes: [
    `Verbs:
  validate    Backup hierarchy is well-formed + internally consistent.
  list        Effective backup policy for every deployed module (was backup-status).
  show        One module's effective policy (was backup-status <module>).
  resolve     Cascade-resolve + print one module's policy (JSON).
  modify      Write the module's .backup {enabled,retention,exclude} (atomic).
  add/delete  Wire / un-wire the module into the shared PBS job (dependsOn backup:vm).
  reconcile   Converge resolved policies → PBS (preview by default; --apply commits).
  restore     SPECIAL — recovery action; delegates to foundation restore.sh / controller.`,
  ],
};
function usage(): void {
  info(renderHelp(HELP));
}

interface Opts {
  configDir: string;
  json: boolean;
  apply: boolean;
  environment: string | null;
  disabledOnly: boolean;
  pbsEndpoint: string | null; // ADR-012 P7: target a non-local PBS (satellite)
  // modify flags (undefined = not given, so the field is left unchanged).
  enabled?: boolean;
  retention?: string;
  exclude?: string[];
  rest: string[];
}
function parseOpts(args: string[]): Opts {
  let configDir = defaultConfigDir();
  let json = false;
  let apply = false;
  let environment: string | null = null;
  let disabledOnly = false;
  let pbsEndpoint: string | null = null;
  let enabled: boolean | undefined;
  let retention: string | undefined;
  let exclude: string[] | undefined;
  const rest: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--json") {
      json = true;
    } else if (a === "--apply") {
      apply = true;
    } else if (a === "--disabled-only") {
      disabledOnly = true;
    } else if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      configDir = v;
      i++;
    } else if (a === "--environment") {
      const v = args[i + 1];
      if (!v) die("--environment requires a name argument");
      environment = v;
      i++;
    } else if (a === "--pbs") {
      const v = args[i + 1];
      if (!v) die("--pbs requires a PBS endpoint (host) argument");
      pbsEndpoint = v;
      i++;
    } else if (a === "--enabled") {
      const v = args[i + 1];
      if (v !== "true" && v !== "false") die("--enabled requires 'true' or 'false'");
      enabled = v === "true";
      i++;
    } else if (a === "--retention") {
      const v = args[i + 1];
      if (!v) die("--retention requires a value (e.g. 90d)");
      retention = v;
      i++;
    } else if (a === "--exclude") {
      const v = args[i + 1];
      if (v === undefined) die("--exclude requires a comma-separated value");
      exclude = v === "" ? [] : v.split(",").map((s) => s.trim()).filter((s) => s.length > 0);
      i++;
    } else {
      rest.push(a);
    }
  }
  return { configDir, json, apply, environment, disabledOnly, pbsEndpoint, enabled, retention, exclude, rest };
}

// ── list / show: every module's resolved policy (+ PBS-job wiring) ─────
function policiesFor(configDir: string): BackupPolicyStatus[] {
  return listModules(configDir).map((module) => ({
    ...resolvePolicy(configDir, module),
    inPbsJob: moduleInPbsJob(configDir, module),
  }));
}

function printTable(rows: BackupPolicyStatus[]): void {
  if (rows.length === 0) {
    info("No deployed modules found.");
    return;
  }
  const pad = (s: string, n: number): string => (s.length >= n ? s : s + " ".repeat(n - s.length));
  info(
    pad("MODULE", 28) +
      " " +
      pad("ENVIRONMENT", 12) +
      " " +
      pad("ENABLED", 8) +
      " " +
      pad("RETENTION", 10) +
      " " +
      pad("RESIDENCY", 9) +
      " IN-PBS-JOB",
  );
  for (const r of rows) {
    info(
      pad(r.module, 28) +
        " " +
        pad(r.environment ?? "-", 12) +
        " " +
        pad(String(r.enabled), 8) +
        " " +
        pad(r.retention, 10) +
        " " +
        pad(r.residency, 9) +
        " " +
        String(r.inPbsJob),
    );
  }
}

function cmdList(opts: Opts): void {
  let rows = policiesFor(opts.configDir);
  if (opts.disabledOnly) rows = rows.filter((r) => !r.enabled);
  if (opts.json) {
    info(JSON.stringify(rows, null, 2));
    return;
  }
  printTable(rows);
}

function cmdShow(opts: Opts): void {
  const module = opts.rest[0];
  if (!module) die("show: <module> required");
  const pol: BackupPolicyStatus = {
    ...resolvePolicy(opts.configDir, module),
    inPbsJob: moduleInPbsJob(opts.configDir, module),
  };
  if (opts.json) {
    info(JSON.stringify(pol, null, 2));
    return;
  }
  printTable([pol]);
}

function cmdResolve(opts: Opts): void {
  const module = opts.rest[0];
  if (!module) die("resolve: <module> required");
  const pol = resolvePolicy(opts.configDir, module, opts.environment ?? undefined);
  // resolve mirrors the bash: always JSON (it's the cascade primitive).
  info(JSON.stringify(pol, null, 2));
}

function cmdValidate(opts: Opts): void {
  const res = validate(opts.configDir);
  for (const o of res.oks) info(`  ok: ${o}`);
  // ADR-012: surface placement so a datastore-less shim is visible, not silent.
  const pl = readPlacement(opts.configDir);
  if (pl.placementState === "shim") {
    warn(
      "backup placement is a SHIM (no datastore) — modules install but are NOT backed up until promoted: update-module.sh backup",
    );
  } else if (pl.placementState === "remote-only") {
    info(`  ok: placement remote-only (off-site push${pl.pushTarget ? ` via '${pl.pushTarget}'` : ""})`);
  }
  for (const e of res.errors) console.error(`  ERROR: ${e}`);
  info("");
  if (res.errors.length > 0) {
    console.error(`validate-backup: ${res.errors.length} error(s) found`);
    die(`backup hierarchy has ${res.errors.length} error(s)`);
  }
  info(`${GN}validate-backup: hierarchy consistent${CL}`);
}

// ── placement / peers (ADR-012) ───────────────────────────────────────
function cmdPlacement(opts: Opts): void {
  const pl = readPlacement(opts.configDir);
  if (opts.json) {
    info(JSON.stringify(pl, null, 2));
    return;
  }
  info(`placement:      ${pl.placement}`);
  info(`placementState: ${pl.placementState ?? "(unset/legacy → local)"}`);
  info(`pbsStorageName: ${pl.pbsStorageName}`);
  info(`pushTarget:     ${pl.pushTarget ?? "-"}`);
}

function cmdPeers(opts: Opts): void {
  const peers = listPeers(opts.configDir);
  if (opts.json) {
    info(JSON.stringify(peers, null, 2));
    return;
  }
  if (peers.length === 0) {
    info("No off-site peers configured (remote-/external-/push-<name>.json).");
    return;
  }
  const pad = (s: string, n: number): string => (s.length >= n ? s : s + " ".repeat(n - s.length));
  info(pad("NAME", 20) + " " + pad("ROLE", 9) + " " + pad("HOST", 28) + " NAMESPACE");
  for (const p of peers) {
    info(
      pad(p.name, 20) + " " + pad(p.role, 9) + " " + pad(p.remoteHost ?? "-", 28) + " " + (p.namespace ?? "-"),
    );
  }
}

function cmdReconcile(opts: Opts, client: Client): void {
  let job;
  try {
    job = client.jobStatus();
  } catch {
    // Controller unreachable → preview against an empty/offline job.
    job = { jobId: null, vmids: [], storage: null, reachable: false };
  }
  const plan = computePlan(opts.configDir, job);

  info(`Plan: ${plan.actions.length} action(s), ${plan.warnings.length} warning(s)`);
  for (const w of plan.warnings) warn(w);
  for (const a of plan.actions) {
    info(`  ${opts.apply ? "" : "[preview] would "}${a.kind}: ${a.target}`);
  }

  if (!opts.apply) {
    info("");
    info("(preview — re-run with --apply to commit; default is preview)");
    return;
  }
  if (plan.actions.length === 0) {
    info(`${GN}Nothing to do — PBS already matches resolved policies.${CL}`);
    return;
  }
  const n = applyPlan(client, plan);
  info("");
  info(`${GN}Applied ${n} action(s).${CL}`);
}

function cmdRestore(opts: Opts, client: Client): number {
  const sub = opts.rest[0];
  const deps = { client, configDir: opts.configDir };
  switch (sub) {
    case "list": {
      const module = opts.rest[1];
      if (!module) die("restore list: <module> required");
      return restoreList(deps, module);
    }
    case "restore": {
      const module = opts.rest[1];
      if (!module) die("restore restore: <module> required");
      return restoreRun(deps, module, opts.rest.slice(2));
    }
    case "list-all":
      return restoreListAll();
    default:
      die("restore: expected 'list <module>', 'restore <module>', or 'list-all'");
  }
}

// ── modify / add / delete: write the module .backup layer (decision 7) ─
function cmdModify(opts: Opts): void {
  const module = opts.rest[0];
  if (!module) die("modify: <module> required");
  if (opts.enabled === undefined && opts.retention === undefined && opts.exclude === undefined) {
    die("modify: at least one of --enabled / --retention / --exclude is required");
  }
  const changes: ModifyOpts = {
    enabled: opts.enabled,
    retention: opts.retention,
    exclude: opts.exclude,
  };
  try {
    const backup = modifyBackup(opts.configDir, module, changes);
    info(`${GN}modify: wrote ${module}.json .backup${CL}`);
    info(JSON.stringify(backup, null, 2));
    info("(run 'reconcile --apply' to converge the change to PBS)");
  } catch (e) {
    die(`modify ${module}: ${(e as Error).message}`);
  }
}

function cmdAdd(opts: Opts): void {
  const module = opts.rest[0];
  if (!module) die("add: <module> required");
  try {
    const changed = addToBackupJob(opts.configDir, module);
    info(
      changed
        ? `${GN}add: wired ${module} into the shared PBS job (dependsOn backup:vm)${CL}`
        : `add: ${module} is already wired into the PBS job (no change)`,
    );
    if (changed) info("(run 'reconcile --apply' to add its VM to the live job)");
  } catch (e) {
    die(`add ${module}: ${(e as Error).message}`);
  }
}

function cmdDelete(opts: Opts): void {
  const module = opts.rest[0];
  if (!module) die("delete: <module> required");
  try {
    const changed = removeFromBackupJob(opts.configDir, module);
    info(
      changed
        ? `${GN}delete: un-wired ${module} from the shared PBS job${CL}`
        : `delete: ${module} was not wired into the PBS job (no change)`,
    );
  } catch (e) {
    die(`delete ${module}: ${(e as Error).message}`);
  }
}

export function run(argv: string[], client: Client): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));

  try {
    switch (cmd) {
      case "validate":
        cmdValidate(opts);
        return 0;
      case "list":
        cmdList(opts);
        return 0;
      case "show":
        cmdShow(opts);
        return 0;
      case "resolve":
        cmdResolve(opts);
        return 0;
      case "placement":
        cmdPlacement(opts);
        return 0;
      case "peers":
        cmdPeers(opts);
        return 0;
      case "reconcile":
        cmdReconcile(opts, client);
        return 0;
      case "restore":
        return cmdRestore(opts, client);
      // CRUD writes the module .backup layer (decision 7): modify sets
      // {enabled,retention,exclude}; add/delete manage dependsOn backup:vm.
      case "modify":
        cmdModify(opts);
        return 0;
      case "add":
        cmdAdd(opts);
        return 0;
      case "delete":
        cmdDelete(opts);
        return 0;
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  } catch (e) {
    if (e instanceof DieError) return 1;
    throw e;
  }
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const argv = process.argv.slice(2);
  // ADR-012 P7: pre-scan for --pbs so the CliClient targets the chosen PBS
  // (local by default, or a satellite/remote when an endpoint is given).
  const ei = argv.indexOf("--pbs");
  const endpoint = ei >= 0 ? argv[ei + 1] : undefined;
  const client = new CliClient(endpoint);
  process.exit(run(argv, client));
}
