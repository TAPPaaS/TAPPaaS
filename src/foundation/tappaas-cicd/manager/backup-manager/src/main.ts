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
//   modify <module> [flags]        write the module .backup layer (decision 7)
//   add <module> / delete <module> wire / un-wire the module into the shared
//                                  PBS job (dependsOn backup:vm)
//
// Exit codes: ok=0, error=1.

import {
  defaultConfigDir,
  listModules,
  listPeers,
  moduleArchived,
  moduleOptedIntoVmBackup,
  moduleVmid,
  readPlacement,
  resolvePolicy,
} from "./config";
import { BackupControllerUnreachable, CliClient } from "./client";
import { addToBackupJob, modifyBackup, ModifyOpts, removeFromBackupJob } from "./modify";
import { applyPlan, computePlan, jobBucketIndex } from "./reconcile";
import { restoreList, restoreListAll, restoreRun, moduleScriptDir } from "./restore";
import {
  PeerKind,
  PeerSpec,
  findPeer,
  findPeers,
  normalizeKind,
  peerScript,
  removePeerConfig,
  writePeerConfig,
} from "./peers";
import { validate } from "./validate";
import { placeText } from "./offsite";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { existsSync } from "fs";
import { stream } from "../../../lib/ts/src/exec";
import { GN, CL, die, guarded, info, warn } from "../../../lib/ts/src/cli";
import { BackupPolicyStatus, Client, JobStatus, ScheduleBucket } from "./types";

const VERSION = "0.1.0";

export const HELP: HelpSpec = {
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
    {
      usage: "restore restore <module> [--node N] [--storage S] [--backup-id ID] [--target-vmid ID]",
      name: "restore restore",
      hidden: ["-n N", "-s S", "-b ID", "-t ID"],
      options: [
        ["--node N", "Restore onto this node (default: the module's node)."],
        ["--storage S", "Target storage pool."],
        ["--backup-id ID", "The snapshot to restore (default: the latest; see 'restore list')."],
        ["--target-vmid ID", "Restore as a new VM id instead of over the module's own."],
      ],
    },
    { usage: "restore list-all", name: "restore list-all" },
    { usage: "placement", name: "placement", note: "(where PBS lives for this site)" },
    {
      usage: "key list|export <dest>|import <src>",
      verb: "key",
      name: "key",
      note: "(the backup encryption keys, and the copy you keep off the machine)",
    },
    { usage: "peers", name: "peers", note: "(the off-site PBS relationships this site has)" },
    {
      usage: "peer add pull|remote|receive <name> [--host H] [--store S] [--namespace NS] "
        + "[--schedule SPEC] [--group-filter F] [--auth-id ID] [--propagate] "
        + "[--country CC] [--city C] [--facility F] [--force]",
      name: "peer add",
      options: [
        ["--host H", "peer add pull: the PBS we pull from."],
        ["--store S", "peer add pull: its datastore name (default tappaas_backup)."],
        ["--namespace NS", "peer add: pull/receive — where the data lands here. remote — what they may read (default: the root namespace, our VM backups)."],
        ["--schedule SPEC", "peer add pull: when to pull (default 04:00)."],
        ["--group-filter F", "peer add pull: replicate only part of the source."],
        ["--auth-id ID", "peer add remote: the login they pull with (we create it)."],
        ["--propagate", "peer add remote: let the read grant reach child namespaces. Off by default — on the root that would expose fs/ (config + secrets) and other peers' data."],
        ["--country CC", "peer add: the country the peer's PBS is in (ISO code) — the evidence its copy is off-site (#609)."],
        ["--city C", "peer add: its city — needed to tell it apart from a Site in the same country."],
        ["--facility F", "peer add: its building or data centre — needed when it shares the Site's city."],
        ["--config-only", "peer add: write the config, skip onboarding (no PBS contact)."],
        ["--force", "peer add: overwrite an existing peer config."],
      ],
    },
    {
      usage: "peer delete pull|remote|receive <name> [--purge] [--config-only]",
      name: "peer delete",
      options: [
        ["--purge", "peer delete: also delete the data in the peer's namespace."],
        ["--config-only", "peer delete: remove the config only (no PBS contact)."],
      ],
    },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $CONFIG_DIR or /home/tappaas/config)."],
    ["--json", "Machine output (JSON) for list/show/resolve/placement/peers."],
    ["--pbs HOST", "Act on a different PBS (e.g. an off-site satellite) instead of this site's."],
  ],
  notes: [
    `Verbs:
  validate    Check the backup configuration is sound: every module resolves to a
              valid retention and a supported schedule, residency rules hold, and
              the site actually has somewhere to back up to.
  list        Every deployed module with its effective policy — enabled, retention,
              residency, and whether it is in the backup job. Start here.
  show        The same, for one module.
  resolve     One module's fully resolved policy as JSON, including which schedule
              it lands on. Use it to answer "why is this module backed up like that?"
  modify      Change a module's own backup policy (enabled / retention / exclude).
              Site and environment defaults are edited with site-manager and
              environment-manager; this is the per-module layer.
  add         Opt a module into VM backup, and delete opts it back out. A module
  delete      that has opted into neither is not backed up — which is deliberate
              for hardware and test modules.
  reconcile   Make the running PBS match the resolved policies: job membership and
              schedules. Previews by default; --apply commits.
  restore     Recover a module — 'restore list <module>' shows its snapshots,
              'restore restore <module>' restores it, 'restore list-all' shows
              everything stored. Options after the module name are passed to
              restore.sh (--node, --storage, --backup-id, --target-vmid).
  placement   Where this site's PBS lives, and whether a datastore is realized at
              all. A 'shim' means modules install but nothing is being backed up yet.
  peers       Off-site relationships: PBS instances this site pulls from, receives
              pushes from, or pushes to. 'peer add' and 'peer delete' create and
              remove them.
  peer        Set up a relationship with another PBS, credentials included:
                pull <name>     we pull a copy of THEIR backups into ours
                remote <name>   they pull OURS — this is where our off-site
                                copies live. We grant a read-only login and
                                hold nothing on them, so their copy cannot be
                                erased from here.
                receive <name>  they push THEIR backups into ours, for a system
                                that has no PBS of its own
              pull and remote are the same movement from opposite ends: to keep
              a copy of our data with a buddy, we add 'remote' and they add
              'pull'.
              There is no verb for sending our backups to an external PBS: a
              site with no local datastore configures that as PLACEMENT
              (placementState external + pbsUrl on the backup module), and a
              TAPPaaS PBS never pushes to another PBS.
              'peer add' writes the config then onboards it, prompting for the
              credential — never written to the config. 'peer delete' needs the
              KIND too, since one name can hold two relationships at once.
  key         The client-side encryption keys. 'key export <dest>' writes them to
              removable media — without a copy off this machine, a full-site restore
              has nothing to decrypt with. 'key import <src>' loads them onto a
              rebuilt mothership.

Recovering a system is documented per scenario in the backup module's RESTORE.md.`,
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
  // modify flags (undefined = not given, so the field is left unchanged).
  enabled?: boolean;
  retention?: string;
  exclude?: string[];
  // peer flags
  host?: string;
  store?: string;
  namespace?: string;
  schedule?: string;
  groupFilter?: string;
  authId?: string;
  country?: string;
  city?: string;
  facility?: string;
  propagate: boolean;
  configOnly: boolean;
  purge: boolean;
  force: boolean;
  rest: string[];
}
// Peer flags that take a value. Collected generically so adding one is a
// single-line change here rather than another else-if arm.
const PEER_VALUE_FLAGS = new Set([
  "--host", "--store", "--namespace", "--schedule", "--group-filter", "--auth-id",
  "--country", "--city", "--facility",
]);

function parseOpts(args: string[]): Opts {
  const peerFlags: Record<string, string> = {};
  let propagate = false;
  let configOnly = false;
  let purge = false;
  let force = false;
  let configDir = defaultConfigDir();
  let json = false;
  let apply = false;
  let environment: string | null = null;
  let disabledOnly = false;
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
      // ADR-012 P7: --pbs is handled by the entry-point argv pre-scan (it
      // feeds the CliClient endpoint). Consume flag+value here so it never
      // leaks into `rest`, but there is nothing to store.
      const v = args[i + 1];
      if (!v) die("--pbs requires a PBS endpoint (host) argument");
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
    } else if (PEER_VALUE_FLAGS.has(a)) {
      const v = args[i + 1];
      if (!v) die(`${a} requires a value`);
      peerFlags[a] = v;
      i++;
    } else if (a === "--propagate") {
      propagate = true;
    } else if (a === "--config-only") {
      configOnly = true;
    } else if (a === "--purge") {
      purge = true;
    } else if (a === "--force") {
      force = true;
    } else {
      rest.push(a);
    }
  }
  return {
    configDir, json, apply, environment, disabledOnly, enabled, retention, exclude,
    host: peerFlags["--host"],
    store: peerFlags["--store"],
    namespace: peerFlags["--namespace"],
    schedule: peerFlags["--schedule"],
    groupFilter: peerFlags["--group-filter"],
    authId: peerFlags["--auth-id"],
    country: peerFlags["--country"],
    city: peerFlags["--city"],
    facility: peerFlags["--facility"],
    propagate, configOnly, purge, force,
    rest,
  };
}

// ── list / show: every module's resolved policy (+ PBS-job membership) ─
//
// #627: `IN-PBS-JOB` used to be `moduleInPbsJob()` — the module's DECLARATION,
// never the job. The two diverge in both directions, and the false-true one is
// the dangerous half: an archived module keeps its backup:vm declaration after
// delete-service.sh correctly drops its destroyed VM from the job, so the
// column claimed coverage for a guest that cannot be snapshotted. Membership is
// now read from the managed bucket jobs, with the declaration kept as its own
// column so the gap between "asked for backup" and "is backed up" is visible
// instead of collapsed into one boolean.

// Ask the controller for job membership once per command, and degrade to the
// declaration rather than to a confident `false` — an unreachable PBS is
// unknown coverage, and reporting it as "not backed up" is its own false alarm.
function readJobStatus(client: Client): JobStatus | null {
  try {
    const job = client.jobStatus();
    return job.reachable ? job : null;
  } catch (e) {
    // The controller missing from PATH is the offline case, not a crash: `list`
    // stays usable in a bare checkout and in the offline test suite.
    if (e instanceof BackupControllerUnreachable) return null;
    throw e;
  }
}

function statusFor(
  configDir: string,
  module: string,
  job: JobStatus | null,
  idx: Map<string, ScheduleBucket>,
): BackupPolicyStatus {
  const optedIn = moduleOptedIntoVmBackup(configDir, module);
  const archived = moduleArchived(configDir, module);
  if (!job) {
    return {
      ...resolvePolicy(configDir, module),
      optedIn,
      archived,
      inPbsJob: optedIn,
      jobBucket: null,
      membershipSource: "declaration",
    };
  }
  const vmid = moduleVmid(configDir, module);
  const jobBucket = vmid ? idx.get(vmid) ?? null : null;
  return {
    ...resolvePolicy(configDir, module),
    optedIn,
    archived,
    inPbsJob: jobBucket !== null,
    jobBucket,
    membershipSource: "job",
  };
}

function policiesFor(configDir: string, client: Client): BackupPolicyStatus[] {
  const job = readJobStatus(client);
  const idx = job ? jobBucketIndex(job) : new Map<string, ScheduleBucket>();
  return listModules(configDir).map((module) => statusFor(configDir, module, job, idx));
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
      " " +
      pad("OPTED-IN", 8) +
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
        pad(String(r.optedIn), 8) +
        " " +
        membershipCell(r),
    );
  }
  // Say which source the column speaks for. A declaration-sourced table looks
  // identical to a job-sourced one, and that is exactly how #627 went unnoticed.
  if (rows.some((r) => r.membershipSource === "declaration")) {
    warn(
      "PBS / cluster not reachable — IN-PBS-JOB shows the DECLARATION, not job " +
        "membership (backup-controller job-status when it is back)",
    );
  }
}

// The IN-PBS-JOB cell. Membership carries the bucket that holds it, because
// "which job" is the next question an operator asks; a non-member says why when
// the reason is known, so an archived module reads as intended state rather
// than as drift. A declaration-sourced value is marked `?` — unknown, not read.
function membershipCell(r: BackupPolicyStatus): string {
  if (r.membershipSource === "declaration") return `${r.inPbsJob}?`;
  if (r.inPbsJob) return `true (${r.jobBucket})`;
  if (r.archived) return "false (archived)";
  return "false";
}

function cmdList(opts: Opts, client: Client): void {
  let rows = policiesFor(opts.configDir, client);
  if (opts.disabledOnly) rows = rows.filter((r) => !r.enabled);
  if (opts.json) {
    info(JSON.stringify(rows, null, 2));
    return;
  }
  printTable(rows);
}

function cmdShow(opts: Opts, client: Client): void {
  const module = opts.rest[0];
  if (!module) die("show: <module> required");
  const job = readJobStatus(client);
  const pol: BackupPolicyStatus = statusFor(
    opts.configDir,
    module,
    job,
    job ? jobBucketIndex(job) : new Map(),
  );
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
  if (pl.kind === "shim") {
    warn(
      "backup placement is a SHIM (no datastore) — modules install but are NOT backed up until promoted: update-module.sh backup",
    );
  } else if (pl.kind === "external") {
    info(`  ok: placement external — clients push to the PBS at '${pl.pbsUrl}'`);
  } else if (pl.kind === "unresolved") {
    warn(
      "backup placement is UNRESOLVED (no placementState) — run 'update-module.sh backup' to resolve it",
    );
  }
  for (const w of res.warnings) warn(w);
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
  info(`placementState: ${pl.placementState ?? "(unresolved)"}`);
  info(`kind:           ${pl.kind}${pl.node ? ` (node ${pl.node})` : ""}`);
  info(`pbsUrl:         ${pl.pbsUrl}`);
  info(`pbsStorageName: ${pl.pbsStorageName}`);
  if (pl.pushTarget) info(`pushTarget:     ${pl.pushTarget}  (deprecated — see pbsUrl)`);
}

// ── peer CRUD (ADR-012 §1.4) ──────────────────────────────────────────
//
// The manager owns the config; the module's onboarding script owns the live PBS
// work and the credential prompt. Splitting it the other way — reimplementing
// namespace/user/ACL/sync-job calls in TypeScript — would duplicate tested bash
// for no gain, and would put a credential through this process.
function cmdPeer(opts: Opts): number {
  const sub = opts.rest[0];
  if (sub === "add") return cmdPeerAdd(opts);
  if (sub === "delete" || sub === "remove") return cmdPeerDelete(opts);
  die("peer: expected 'add <kind> <name>' or 'delete <name>'");
  return 1;
}

function cmdPeerAdd(opts: Opts): number {
  const kindArg = opts.rest[1];
  const name = opts.rest[2];
  if (!kindArg || !name) die("peer add: expected <kind> <name>, kind = pull | remote | receive");
  const kind = normalizeKind(kindArg);
  if (!kind) die(`peer add: unknown kind '${kindArg}' — use pull | remote | receive`);
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name)) {
    die(`peer add: '${name}' is not a usable peer name (letters, digits, - and _)`);
  }

  const k = kind as PeerKind;
  // Say what cannot work now, rather than at onboarding when a credential has
  // already been typed.
  if (k === "pull" && !opts.host) {
    die("peer add pull: --host is required (the PBS we pull from)");
  }
  if (k === "remote" && !opts.authId) {
    die("peer add remote: --auth-id is required (the login they will pull with, " +
        "e.g. buddy@pbs — we create it and grant it read-only access)");
  }

  const spec: PeerSpec = {
    name,
    host: opts.host,
    store: opts.store,
    namespace: opts.namespace,
    schedule: opts.schedule,
    groupFilter: opts.groupFilter,
    authId: opts.authId,
    propagate: opts.propagate,
  };
  if (opts.country) {
    if (!/^[A-Za-z]{2}$/.test(opts.country)) die(`peer add: --country takes an ISO 3166-1 alpha-2 code (e.g. DE), not '${opts.country}'`);
    spec.physicalLocation = { country: opts.country.toUpperCase() };
    if (opts.city) spec.physicalLocation.city = opts.city;
    if (opts.facility) spec.physicalLocation.facility = opts.facility;
  } else if (opts.city || opts.facility) {
    die("peer add: --city and --facility need --country (the place is recorded from the country down)");
  } else if (k !== "receive") {
    warn(`no --country: nothing will show this ${k} peer is off-site (validate warns until physicalLocation is recorded, #609)`);
  }
  const file = writePeerConfig(opts.configDir, k, spec, opts.force);
  info(`${GN}✓${CL} wrote ${file}`);

  if (opts.configOnly) {
    info(`  --config-only: not onboarded. Run 'backup-manager peer add ${kindArg} ${name}' again`);
    info(`  without it, or onboard by hand, when the PBS is reachable.`);
    return 0;
  }

  const dir = moduleScriptDir(opts.configDir);
  const script = peerScript(dir, k, "onboard");
  if (!existsSync(script)) {
    warn(`config written, but ${script} was not found — the peer is NOT onboarded.`);
    warn(`Check config/backup.json .moduleSource points at the backup module.`);
    return 1;
  }
  info(`Onboarding — you will be prompted for the credential (it is never stored in the config).`);
  const rc = stream(script, [name]);
  if (rc !== 0) {
    warn(`Onboarding failed (rc ${rc}). The config remains at ${file};`);
    warn(`fix the cause and re-run, or 'backup-manager peer delete ${name}' to drop it.`);
  }
  return rc;
}

function cmdPeerDelete(opts: Opts): number {
  // The kind is REQUIRED, not inferred. One name can hold two relationships —
  // a backup buddy is typically both a pull and a receive — so guessing would
  // sooner or later tear down the wrong half of a working pair.
  const kindArg = opts.rest[1];
  const name = opts.rest[2];
  if (!kindArg || !name) {
    const stray = opts.rest[1] && !normalizeKind(opts.rest[1]) ? opts.rest[1] : null;
    if (stray) {
      const existing = findPeers(opts.configDir, stray);
      if (existing.length > 0) {
        die(
          `peer delete: say which relationship — '${stray}' exists as ` +
            `${existing.map((e) => e.kind).join(" and ")}. ` +
            `Try: backup-manager peer delete ${existing[0].kind} ${stray}`,
        );
      }
    }
    die("peer delete: expected <kind> <name>, kind = pull | remote | receive");
  }
  const kind = normalizeKind(kindArg);
  if (!kind) die(`peer delete: unknown kind '${kindArg}' — use pull | remote | receive`);
  const hit = findPeer(opts.configDir, kind as PeerKind, name);
  if (!hit) {
    const other = findPeers(opts.configDir, name);
    if (other.length > 0) {
      die(
        `peer delete: '${name}' is not a ${kindArg} peer — it exists as ` +
          `${other.map((o) => o.kind).join(" and ")}.`,
      );
    }
    die(`peer delete: no peer named '${name}'`);
  }

  // Offboard FIRST, while the config that describes the relationship still
  // exists — the script reads it to know what to tear down.
  const dir = moduleScriptDir(opts.configDir);
  const script = peerScript(dir, hit.kind, "offboard");
  let rc = 0;
  if (opts.configOnly) {
    info("  --config-only: the PBS side is left exactly as it is.");
  } else if (existsSync(script)) {
    rc = stream(script, opts.purge ? [name, "--purge"] : [name]);
    if (rc !== 0) {
      warn(`Offboarding reported rc ${rc}; the config is left in place so you can retry.`);
      return rc;
    }
  } else {
    warn(`${script} not found — removing the config only; the PBS side is untouched.`);
  }
  const removed = removePeerConfig(opts.configDir, kind as PeerKind, name);
  info(`${GN}✓${CL} removed ${removed.file}`);
  if (!opts.purge) info("  Data in its namespace was kept (--purge deletes it).");
  return rc;
}

function cmdPeers(opts: Opts): void {
  const peers = listPeers(opts.configDir);
  if (opts.json) {
    info(JSON.stringify(peers, null, 2));
    return;
  }
  if (peers.length === 0) {
    info("No peers configured. Add one with: backup-manager peer add pull|remote|receive <name>");
    return;
  }
  const pad = (s: string, n: number): string => (s.length >= n ? s : s + " ".repeat(n - s.length));
  info(pad("NAME", 20) + " " + pad("ROLE", 9) + " " + pad("HOST", 28) + " " + pad("NAMESPACE", 20) + " LOCATION");
  for (const p of peers) {
    info(
      pad(p.name, 20) + " " + pad(p.role, 9) + " " + pad(p.remoteHost ?? "-", 28) + " " +
        pad(p.namespace ?? "-", 20) + " " + placeText(p.physicalLocation),
    );
  }
}

function cmdReconcile(opts: Opts, client: Client): void {
  let job: JobStatus;
  try {
    job = client.jobStatus();
  } catch {
    // Controller unreachable → preview against an empty/offline job.
    job = { jobId: null, vmids: [], storage: null, buckets: [], reachable: false };
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
  if (!job.reachable) {
    // The plan was computed against an offline (empty) job snapshot — applying
    // it would blindly re-add every wired module and fail on the first
    // controller call anyway. Refuse cleanly instead.
    die(
      "reconcile --apply refused: PBS / cluster not reachable, so the live job " +
        "state is unknown. Re-run without --apply to preview, or retry when PBS is up.",
    );
  }
  if (plan.actions.length === 0) {
    info(`${GN}Nothing to do — PBS already matches resolved policies.${CL}`);
    return;
  }
  const res = applyPlan(client, plan);
  info("");
  if (res.failures.length > 0) {
    for (const f of res.failures) warn(`failed ${f.target} — ${f.message}`);
    die(`applied ${res.applied} of ${res.total} action(s); ${res.failures.length} failed`);
  }
  info(`${GN}Applied ${res.applied} action(s).${CL}`);
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
      return restoreListAll(opts.configDir);
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
  if (argv.length === 0) {
    usage();
    return 0;
  }
  // #644: --help in any position prints that verb's help and runs nothing
  // (`key export <dest> --help` used to write the keys); an option the verb
  // does not take is refused.
  const gate = checkArgs(HELP, argv);
  if (gate !== undefined) return gate;
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));

  return guarded(() => {
    switch (cmd) {
      case "validate":
        cmdValidate(opts);
        return 0;
      case "list":
        cmdList(opts, client);
        return 0;
      case "show":
        cmdShow(opts, client);
        return 0;
      case "resolve":
        cmdResolve(opts);
        return 0;
      case "key": {
        // The escrow sits inside the system a full-site DR is rebuilding, so it
        // cannot be the only copy of a key: without an off-system copy, an
        // encrypted off-site backup is unrecoverable (§2.5.1).
        const sub = opts.rest[0] ?? "list";
        const arg = opts.rest[1];
        if (sub === "list") client.keyList();
        else if (sub === "export") {
          if (!arg) die("key export: <dest> required (a directory on removable media)");
          client.keyExport(arg);
        } else if (sub === "import") {
          if (!arg) die("key import: <src> required (the directory holding exported keys)");
          client.keyImport(arg);
        } else die(`key: expected 'list' | 'export <dest>' | 'import <src>', got '${sub}'`);
        return 0;
      }
      case "placement":
        cmdPlacement(opts);
        return 0;
      case "peers":
        cmdPeers(opts);
        return 0;
      case "peer":
        return cmdPeer(opts);
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
  });
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
