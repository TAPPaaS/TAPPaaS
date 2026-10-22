// backup-manager — TAPPaaS backup-policy cascade manager (ADR-007 verb-alignment
// #3, TypeScript first-pass port of backup-manager.sh / backup-status.sh /
// validate-backup.sh / backup-restore.sh + lib-cascade.sh).
//
// Owns the Site → Environment → Module backup-policy CASCADE (the entity = the
// resolved backup `job`/`policy`). Read-only over config; delegates live PBS
// operations to the `pbs-controller` bin via CliClient (src/client.ts) — NO
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
import { restoreList, restoreListAll, restoreRun, moduleScriptDir, shapeRuns } from "./restore";
import {
  PeerKind,
  PeerSpec,
  findPeer,
  findPeers,
  normalizeKind,
  peerConfigPath,
  peerScript,
  readPeerConfig,
  removePeerConfig,
  isEmail,
  setPeerContact,
  writePeerConfig,
} from "./peers";
import { validate } from "./validate";
import {
  Tunnel,
  asTunnel,
  buddyPool,
  isTunnelRole,
  nextServe,
  overlaps,
  slash30Error,
  tunnelHosts,
  tunnelsInUse,
  zoneNets,
} from "./tunnel";
import { basename, join } from "path";
import { KeyTarget, keyTarget, keysUsb } from "./keys";
import { placeText } from "./offsite";
import { placementFinishReset, placementReset, placementUseExternal, ResetDeps } from "./placement-reset";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { existsSync, readFileSync } from "fs";
import { spawnSync } from "child_process";
import { stream } from "../../../lib/ts/src/exec";
import { GN, CL, RD, die, guarded, info, warn } from "../../../lib/ts/src/cli";
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
      usage: "modify <module> [--enabled true|false] [--retention SPEC] [--exclude a,b]", effect: { noPreview: "changes the module's backup policy in its config and the PBS job" },
      name: "modify",
      options: [
        ["--enabled B", "modify: set module backup.enabled (true|false)."],
        ["--retention SPEC", "modify: set module backup.retention (e.g. 90d, 1y)."],
        ["--exclude a,b", "modify: set module backup.exclude (comma-separated)."],
      ],
    },
    { usage: "add <module>", effect: { noPreview: "wires the module's guest into the shared PBS job" }, name: "add", note: "(wire into the shared PBS job)" },
    { usage: "backup <module>...", effect: { noPreview: "takes each module's backup now, through its PBS job" }, name: "backup", note: "(take each module's backup now, through its job — #759)" },
    { usage: "delete <module>", effect: { noPreview: "un-wires the module from the shared PBS job; its backups stay" }, name: "delete", note: "(un-wire from the shared PBS job)" },
    {
      usage: "purge <module|vmid> [--yes]", effect: { noPreview: "deletes every backup of the module from PBS" },
      name: "purge",
      note: "(erase a removed guest's restore points + start GC — #789)",
      options: [["--yes", "purge: do not ask; without it you type the VMID to confirm."]],
    },
    {
      usage: "reconcile [--apply]",
      name: "reconcile",
      options: [["--apply", "reconcile: commit changes (default = preview)."]],
    },
    { usage: "restore list <module>", name: "restore list" },
    {
      usage: "restore restore <module> [--from M|VMID] [--node N] [--storage S] [--backup-id ID] [--target-vmid ID] [--yes]", effect: { noPreview: "restores the module's guest from a PBS backup" },
      name: "restore restore",
      hidden: ["-n N", "-s S", "-b ID", "-t ID"],
      options: [
        ["--node N", "Restore onto this node (default: the module's node)."],
        ["--storage S", "Target storage pool."],
        ["--backup-id ID", "The snapshot to restore (default: the latest; see 'restore list')."],
        ["--target-vmid ID", "Restore as a new VM id instead of over the module's own."],
        ["--from M|VMID", "Restore ANOTHER guest's backup into this module's guest, replacing its disks and keeping its network identity (RESTORE.md §2)."],
        ["--yes", "Overwrite the module's own guest without asking — for a script or an agent with no terminal."],
      ],
    },
    {
      usage: "restore list-all [--json]", name: "restore list-all", effect: "read",
      note: "(everything stored; --json: each guest's last backup and last verify, per namespace and job)",
      options: [["--json", "restore list-all: per guest and per target, the last backup (in its job's interval or late) and the last verify with its outcome."]],
    },
    { usage: "placement", effect: "read", name: "placement", note: "(where PBS lives for this site)" },
    {
      usage: "placement reset [--peer NAME] [--yes] [--no-update]", effect: { noPreview: "moves PBS back to a node of this site" }, destructive: true,
      name: "placement reset",
      note: "(leave an external PBS for a local one — ADR-012 §2.3, #607)",
      options: [
        ["--peer NAME", "placement reset: the pull-peer name the old PBS gets (default former-<its host>)."],
        ["--yes", "placement reset / finish-reset: do not ask for confirmation."],
        ["--no-update", "placement reset: stop after the config — then NOTHING is backed up until 'update-module.sh backup' runs."],
      ],
    },
    {
      usage: "placement use-external <url> [--datastore D] [--namespace NS] [--fingerprint FP]", effect: { noPreview: "points the site's backups at an external PBS" },
      name: "placement use-external",
      note: "(back up to a PBS this site already runs, provisioning nothing — #456)",
      options: [
        ["--datastore D", "placement use-external: its datastore (default: pbsStorageName, tappaas_backup)."],
        ["--namespace NS", "placement use-external: the namespace on it to push into."],
        ["--fingerprint FP", "placement use-external: its TLS fingerprint, when its certificate is self-signed."],
      ],
    },
    {
      usage: "placement finish-reset [--yes]", effect: { noPreview: "finishes moving PBS back to this site" }, destructive: true,
      name: "placement finish-reset",
      note: "(drop the old PBS's <name>_former storage entry, once its history is pulled and a restore worked)",
      options: [["--yes", "placement finish-reset: do not ask for confirmation."]],
    },
    {
      usage: "key list | export|import --usb [--node N] | export|import --file DIR", effect: { noPreview: "exports or imports the PBS encryption keys" }, readWhen: ["list"], destructive: ["import"],
      verb: "key",
      name: "key",
      note: "(the backup encryption keys, and the copy you keep off the machine)",
      options: [
        ["--usb", "key export|import: a USB stick in a node — encrypted with a password, verified, ejected."],
        ["--node N", "key export|import --usb: the node holding the stick (default tappaas1)."],
        ["--format", "key export --usb: erase the stick even if it is a key stick written before (default: rewrite only its keys, keep everything else on it)."],
        ["--file DIR", "key export|import: a directory — the keys UNENCRYPTED; guard what holds them."],
      ],
    },
    { usage: "coverage <module> [--json]", name: "coverage", note: "(every backup job covering the module's VM — TAPPaaS's own and any other, #554)" },
    { usage: "peers", name: "peers", note: "(the off-site PBS relationships this site has)" },
    {
      usage: "peer add pull|remote|receive <name> [--host H] [--store S] [--namespace NS] "
        + "[--port P] [--remote-namespace NS] [--max-depth N] "
        + "[--schedule SPEC] [--group-filter F] [--auth-id ID] [--propagate] "
        + "[--country CC] [--city C] [--building B] [--contact EMAIL] "
        + "[--tunnel serve|dial] [--tunnel-net CIDR] [--listen-port P] [--endpoint H:P] [--peer-key K] [--mtu N] [--force]", effect: { noPreview: "adds an off-site PBS relationship (a buddy, a remote, a receiver)" },
      name: "peer add",
      options: [
        ["--host H", "peer add pull: the PBS we pull from."],
        ["--store S", "peer add pull: its datastore name (default tappaas_backup)."],
        ["--port P", "peer add pull: its PBS API port (default 8007)."],
        ["--remote-namespace NS", "peer add pull: the namespace to pull FROM (default its root)."],
        ["--max-depth N", "peer add pull: how many namespace levels below it to sync (0 = that namespace only; default all)."],
        ["--namespace NS", "peer add: pull/receive — where the data lands here. remote — what they may read (default: the root namespace, our VM backups)."],
        ["--schedule SPEC", "peer add pull: when to pull (default 04:00)."],
        ["--group-filter F", "peer add pull: replicate only part of the source."],
        ["--auth-id ID", "peer add remote: the login they pull with (we create it)."],
        ["--propagate", "peer add remote: let the read grant reach child namespaces. Off by default — on the root that would expose fs/ (config + secrets) and other peers' data."],
        ["--country CC", "peer add: the country the peer's PBS is in (ISO code) — the evidence its copy is off-site (#609)."],
        ["--city C", "peer add: its city — needed to tell it apart from a Site in the same country."],
        ["--building B", "peer add: its building or data centre — needed when it shares the Site's city."],
        ["--tunnel serve|dial", "peer add: carry this pull over its own WireGuard tunnel (#796, BUDDY.md). The pulled site serves (remote), the puller dials (pull)."],
        ["--tunnel-net CIDR", "peer add: the tunnel's /30. serve: default the next free /30 of zones.json buddy.ip (10.255.2.0/24). dial: the serving side's."],
        ["--listen-port P", "peer add remote --tunnel serve: UDP port to listen on (default the next free from 51830)."],
        ["--endpoint H:P", "peer add pull --tunnel dial: the serving side's public address (or its satellite's) and port."],
        ["--peer-key K", "peer add: the other side's WireGuard public key. serve may add it later: re-run with --force."],
        ["--contact EMAIL", "peer add: the other site's operator — mailed by the pulse when their PBS stops answering (ADR-031)."],
        ["--mtu N", "peer add: tunnel MTU (e.g. 1340 through a satellite relay; default OPNsense's)."],
        ["--config-only", "peer add: write the config, skip onboarding (no PBS contact)."],
        ["--force", "peer add: overwrite an existing peer config (keeps its tunnel /30 and port unless given)."],
      ],
    },
    {
      usage: "peer modify pull|remote <name> --contact EMAIL", effect: { noPreview: "changes a buddy's contact" },
      name: "peer modify",
      options: [["--contact EMAIL", "peer modify: the other site's operator, mailed by the pulse (ADR-031); '' clears it."]],
    },
    { usage: "pulse", name: "pulse", note: "(ADR-031: what the backup node's pulse watches — buddies, uplink, firewall, mothership, PBS — and since when each is down)" },
    { usage: "peer check pull|remote <name>", effect: "read", name: "peer check", note: "(the buddy tunnel's live state: instance, key, handshake, PBS reach)" },
    {
      usage: "peer delete pull|remote|receive <name> [--purge] [--config-only]", effect: { noPreview: "removes the off-site relationship (--purge also its data)" },
      name: "peer delete",
      options: [
        ["--purge", "peer delete: also delete the data in the peer's namespace."],
        ["--config-only", "peer delete: remove the config only (no PBS contact)."],
      ],
    },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $CONFIG_DIR or /home/tappaas/config)."],
    ["--json", "Machine output (JSON) for list/show/resolve/placement/peers/restore list-all."],
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
  backup      Take a module's backup NOW — before a risky change, or after a key
              rotation, when the next scheduled one is a day away. It goes through
              the TAPPaaS job that covers the module (its storage, mode and
              compression) on the node the guest runs on, waits, and names the
              snapshot. A module no job covers is refused: 'add' it first.
  reconcile   Make the running PBS match the resolved policies: job membership and
              schedules. Previews by default; --apply commits.
  restore     Recover a module — 'restore list <module>' shows its snapshots,
              'restore restore <module>' restores it, 'restore list-all' shows
              everything stored (--json: each guest's last backup and last
              verify, and whether it is within its job's interval). Options after the module name are passed to
              restore.sh (--node, --storage, --backup-id, --target-vmid);
              --from <module|vmid> restores another guest's backup INTO this
              module's guest (onto a system that never had it, RESTORE.md §2).
  placement   Where this site's PBS lives, and whether a datastore is realized at
              all. A 'shim' means modules install but nothing is being backed up yet.
              'placement reset' leaves an external PBS for a local one: the old PBS is
              kept as a pull peer and its storage as <name>_former, so no backup is
              lost; 'placement finish-reset' drops that storage once the history
              is pulled and a test restore worked (#607).
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
  key         The client-side encryption keys. Without a copy off this machine, a
              full-site restore has nothing to decrypt with. 'key export --usb' writes
              them to a USB stick in a node (tappaas1, or --node), encrypted with a
              password you choose, reads them back to check, and ejects it — make two
              sticks, kept apart. 'key import --usb' brings them back onto a rebuilt
              mothership. --file <dir> is the same, unencrypted, to a directory.

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
  building?: string;
  contact?: string; // ADR-031 D5: the other site's operator
  peer?: string;
  datastore?: string;
  fingerprint?: string;
  tunnel?: string;
  tunnelNet?: string;
  listenPort?: string;
  endpoint?: string;
  peerKey?: string;
  mtu?: string;
  port?: string;
  remoteNamespace?: string;
  maxDepth?: string;
  yes: boolean;
  noUpdate: boolean;
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
  "--country", "--city", "--building", "--peer", "--datastore", "--fingerprint",
  "--tunnel", "--tunnel-net", "--listen-port", "--endpoint", "--peer-key", "--mtu",
  "--port", "--remote-namespace", "--max-depth", "--contact",
]);

function parseOpts(args: string[]): Opts {
  const peerFlags: Record<string, string> = {};
  let propagate = false;
  let configOnly = false;
  let purge = false;
  let yes = false;
  let noUpdate = false;
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
    } else if (a === "--yes" || a === "-y") {
      yes = true;
    } else if (a === "--no-update") {
      noUpdate = true;
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
    building: peerFlags["--building"],
    contact: peerFlags["--contact"],
    peer: peerFlags["--peer"],
    datastore: peerFlags["--datastore"],
    fingerprint: peerFlags["--fingerprint"],
    tunnel: peerFlags["--tunnel"],
    tunnelNet: peerFlags["--tunnel-net"],
    listenPort: peerFlags["--listen-port"],
    endpoint: peerFlags["--endpoint"],
    peerKey: peerFlags["--peer-key"],
    mtu: peerFlags["--mtu"],
    port: peerFlags["--port"],
    remoteNamespace: peerFlags["--remote-namespace"],
    maxDepth: peerFlags["--max-depth"],
    yes, noUpdate,
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
        "membership (pbs-controller job-status when it is back)",
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
// The real terminal for placement reset: scripts stream to it, and the
// confirmation is read from /dev/tty (sync, like every TS manager's loop).
const RESET_DEPS: ResetDeps = {
  run: (bin, args) => {
    const rc = stream(bin, args);
    return rc === -1 ? 1 : rc; // killed by a signal
  },
  confirm: (q) => {
    const r = spawnSync("bash", ["-c", 'printf "%s" "$1" > /dev/tty; IFS= read -r v < /dev/tty || exit 1; printf "%s" "$v"', "--", q], {
      encoding: "utf8",
    });
    if (r.status !== 0) die("cannot ask for confirmation (non-interactive session?) — pass --yes");
    return /^y(es)?$/i.test((r.stdout ?? "").trim());
  },
  info,
  warn,
};

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
  if (sub === "check") return cmdPeerCheck(opts);
  if (sub === "modify") return cmdPeerModify(opts);
  die("peer: expected 'add <kind> <name>', 'delete <kind> <name>' or 'check <kind> <name>'");
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
  const tunnel = peerTunnel(opts, k, name);
  if (k === "pull" && !opts.host && !tunnel) {
    die("peer add pull: --host is required (the PBS we pull from), or --tunnel dial");
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
    remoteNamespace: opts.remoteNamespace,
    port: intFlag("--port", opts.port, 1, 65535),
    maxDepth: intFlag("--max-depth", opts.maxDepth, 0, 7),
    ...(tunnel ? { tunnel } : {}),
  };
  if (opts.contact !== undefined) {
    if (k === "receive") die("peer add receive: --contact is for a buddy whose PBS we pull or who pulls ours");
    if (!isEmail(opts.contact)) die(`peer add: --contact takes one e-mail address, not '${opts.contact}'`);
    spec.contact = opts.contact;
  }
  if (k !== "pull" && (opts.port || opts.remoteNamespace || opts.maxDepth)) {
    die(`peer add ${k}: --port, --remote-namespace and --max-depth describe a pull`);
  }
  if (opts.country) {
    if (!/^[A-Za-z]{2}$/.test(opts.country)) die(`peer add: --country takes an ISO 3166-1 alpha-2 code (e.g. DE), not '${opts.country}'`);
    spec.physicalLocation = { country: opts.country.toUpperCase() };
    if (opts.city) spec.physicalLocation.city = opts.city;
    if (opts.building) spec.physicalLocation.building = opts.building;
  } else if (opts.city || opts.building) {
    die("peer add: --city and --building need --country (the place is recorded from the country down)");
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
  const rc = stream(script, [name], scriptEnv(opts));
  if (rc !== 0) {
    warn(`Onboarding failed (rc ${rc}). The config remains at ${file};`);
    warn(`fix the cause and re-run, or 'backup-manager peer delete ${name}' to drop it.`);
  }
  return rc;
}

function intFlag(flag: string, v: string | undefined, lo: number, hi: number): number | undefined {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isInteger(n) || n < lo || n > hi) die(`peer add: ${flag} takes ${lo}–${hi}, not '${v}'`);
  return n;
}

// The onboarding scripts read the peer config from $CONFIG_DIR; hand them the
// one this run was given (--config-dir), not the process default.
function scriptEnv(opts: Opts): { env: Record<string, string> } {
  return { env: { CONFIG_DIR: opts.configDir, TAPPAAS_CONFIG: opts.configDir } };
}

const WG_KEY = /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/;

// The tunnel a `peer add` asks for (#796), or undefined for none. Dies on
// anything onboarding could not make work, before a credential is typed.
// With --force an existing tunnel's /30 and port are kept unless given again —
// the other site already holds them.
function peerTunnel(opts: Opts, k: PeerKind, name: string): Tunnel | undefined {
  const prev = opts.force ? asTunnel(readPeerConfig(opts.configDir, k, name)?.tunnel) : null;
  const role = opts.tunnel ?? prev?.role;
  const given = opts.tunnelNet || opts.listenPort || opts.endpoint || opts.peerKey || opts.mtu;
  if (!role) {
    if (given) die("peer add: --tunnel-net, --listen-port, --endpoint, --peer-key and --mtu need --tunnel serve|dial");
    return undefined;
  }
  if (!isTunnelRole(role)) die(`peer add: --tunnel takes serve or dial, not '${role}'`);
  if (k === "receive") die("peer add receive: a receive peer pushes to us and has no tunnel (BUDDY.md)");
  const want = k === "pull" ? "dial" : "serve";
  if (role !== want) {
    die(`peer add ${k}: the ${k} side ${want}s its tunnel — the site whose data is pulled serves it (BUDDY.md). Use --tunnel ${want}`);
  }
  const file = basename(peerConfigPath(opts.configDir, k, name));
  const t: Tunnel = { role, net: opts.tunnelNet ?? prev?.net ?? "" };
  const peerKey = opts.peerKey ?? prev?.peerKey;
  if (peerKey) {
    if (!WG_KEY.test(peerKey)) die(`peer add: --peer-key '${peerKey}' is not a WireGuard public key (44 base64 characters)`);
    t.peerKey = peerKey;
  }
  const mtu = opts.mtu !== undefined ? Number(opts.mtu) : prev?.mtu;
  if (mtu !== undefined) {
    if (!Number.isInteger(mtu) || mtu < 1280 || mtu > 1500) die(`peer add: --mtu takes 1280–1500, not '${opts.mtu}'`);
    t.mtu = mtu;
  }
  if (role === "serve") {
    const next = nextServe(opts.configDir, file);
    if (!t.net) {
      if (!next.net) die(`peer add: no free /30 left in the buddy pool ${buddyPool(opts.configDir)} — widen zones.json buddy.ip or pass --tunnel-net`);
      t.net = next.net as string;
    }
    const port = opts.listenPort !== undefined ? Number(opts.listenPort) : prev?.listenPort ?? next.port;
    if (!Number.isInteger(port) || port < 1 || port > 65535) die(`peer add: --listen-port takes 1–65535, not '${opts.listenPort}'`);
    t.listenPort = port;
  } else {
    const ep = opts.endpoint ?? prev?.endpoint;
    if (!t.net || !ep || !t.peerKey) {
      die("peer add pull --tunnel dial: --tunnel-net, --endpoint and --peer-key are required — " +
          "the serving side's 'peer add remote … --tunnel serve' prints all three");
    }
    if (!/^[^\s:]+:\d{1,5}$/.test(ep as string)) die(`peer add: --endpoint takes host:port, not '${ep}'`);
    t.endpoint = ep;
  }
  const bad = slash30Error(t.net);
  if (bad) die(`peer add: ${bad}`);
  for (const u of tunnelsInUse(opts.configDir)) {
    if (u.file !== file && overlaps(u.tunnel.net, t.net)) {
      const free = nextServe(opts.configDir, file).net;
      die(`peer add: tunnel ${t.net} is already used by ${u.file}.` +
          (role === "dial"
            ? ` Ask the serving side to re-run its 'peer add remote' with --tunnel-net ${free ?? "<a free /30>"} --force.`
            : ` Pick another with --tunnel-net (free: ${free ?? "none"}).`));
    }
    if (role === "serve" && u.file !== file && u.tunnel.listenPort === t.listenPort) {
      die(`peer add: listen port ${t.listenPort} is already used by ${u.file} — pass another --listen-port`);
    }
  }
  for (const z of zoneNets(opts.configDir)) {
    if (overlaps(z.ip, t.net)) die(`peer add: tunnel ${t.net} overlaps zone '${z.zone}' (${z.ip}) — pick another /30`);
  }
  const h = tunnelHosts(t.net);
  info(`  tunnel ${role} ${t.net}: ${h.serve} serves PBS :8007, ${h.dial} dials` +
       (t.listenPort ? ` · udp/${t.listenPort}` : "") + (t.endpoint ? ` · endpoint ${t.endpoint}` : ""));
  return t;
}

// `peer check <kind> <name>` (#796): the live state of a peer's buddy tunnel —
// the OPNsense instance, its key, the handshake, and (dialing side) whether the
// far PBS answers through it. Read-only.
function cmdPeerCheck(opts: Opts): number {
  const kind = normalizeKind(opts.rest[1] ?? "");
  const name = opts.rest[2];
  if (!kind || kind === "receive" || !name) die("peer check: expected pull|remote <name>");
  const cfg = readPeerConfig(opts.configDir, kind as PeerKind, name as string);
  if (!cfg) die(`peer check: no ${kind} peer named '${name}'`);
  const t = asTunnel(cfg?.tunnel);
  if (!t) die(`peer check: ${kind} peer '${name}' has no tunnel — it reaches ${String(cfg?.remoteHost || "its PBS")} directly`);
  const script = join(moduleScriptDir(opts.configDir), "scripts", "tunnel-check.sh");
  if (!existsSync(script)) die(`peer check: ${script} not found`);
  return stream(script, [(t as Tunnel).role, name as string, (t as Tunnel).net], scriptEnv(opts));
}

// `peer modify <kind> <name> --contact EMAIL` (ADR-031 D5): who the pulse mails at
// the other site. Config only; the next backup update gives it to the pulse.
function cmdPeerModify(opts: Opts): number {
  const kind = normalizeKind(opts.rest[1] ?? "");
  const name = opts.rest[2];
  if (!kind || kind === "receive" || !name) die("peer modify: expected pull|remote <name> --contact EMAIL");
  if (opts.contact === undefined) die("peer modify: nothing to change — --contact EMAIL ('' clears it)");
  const c = opts.contact as string;
  if (c !== "" && !isEmail(c)) die(`peer modify: --contact takes one e-mail address, not '${c}'`);
  const f = setPeerContact(opts.configDir, kind as PeerKind, name as string, c);
  info(`${GN}✓${CL} ${f}: contact ${c || "cleared"} — the pulse has it after the next backup update`);
  return 0;
}

// `pulse` (ADR-031 D8): the backup node's pulse, as it sees things now.
function cmdPulse(opts: Opts): number {
  const backup = JSON.parse(readFileSync(join(opts.configDir, "backup.json"), "utf8")) as Record<string, unknown>;
  const node = typeof backup.node === "string" ? backup.node : "";
  if (!node) die("pulse: no backup node recorded (backup.json .node)");
  // A cluster node by name; a debianhost machine by its recorded address.
  let host = node.includes(".") ? node : `${node}.mgmt.internal`;
  try {
    const site = JSON.parse(readFileSync(join(opts.configDir, "site.json"), "utf8")) as { hardware?: { nodes?: { name?: string }[] } };
    const isNode = (site.hardware?.nodes ?? []).some((n) => n.name === node);
    const m = JSON.parse(readFileSync(join(opts.configDir, `${node}.json`), "utf8")) as Record<string, unknown>;
    if (!isNode && typeof m.address === "string" && m.address) host = m.address;
  } catch { /* the name as it is */ }
  info(`The pulse on ${node}`);
  const timer = spawnSync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", `root@${host}`,
    "systemctl is-active tappaas-pulse.timer; /usr/local/sbin/tappaas-pulse --status"], { encoding: "utf8" });
  if (timer.status !== 0 && !timer.stdout) die(`pulse: ${node} did not answer, or has no pulse (the backup update installs it)`);
  const [state, ...rows] = (timer.stdout ?? "").split("\n");
  info(`  timer: ${state === "active" ? `${GN}active${CL}` : `${RD}${state || "not installed"}${CL}`}`);
  for (const r of rows) if (r.trim()) info(`  ${r}`);
  return state === "active" ? 0 : 1;
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
    rc = stream(script, opts.purge ? [name, "--purge"] : [name], scriptEnv(opts));
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

// `coverage <module>` (#554): which cluster backup jobs back the module's VM up.
// The managed jobs are only part of the answer: a job TAPPaaS did not create can
// cover the same VM, and before #554 nothing could show that. Two enabled jobs
// is a finding (backed up twice); none is a finding (not backed up).
function cmdCoverage(opts: Opts, client: Client): number {
  const module = opts.rest[0];
  if (!module) die("coverage: <module> required");
  const jobs = client.coverage(module);
  if (jobs === null) {
    if (opts.json) info(JSON.stringify({ reachable: false, module }));
    else warn(`PBS / cluster not reachable — cannot tell which jobs cover ${module}`);
    return 0;
  }
  if (opts.json) {
    info(JSON.stringify({ reachable: true, module, jobs }, null, 2));
    return 0;
  }
  const pad = (s: string, n: number): string => (s.length >= n ? s : s + " ".repeat(n - s.length));
  info(pad("JOB", 22) + " " + pad("HOW", 9) + " " + pad("OWNER", 12) + " " + pad("STORAGE", 16) + " SCHEDULE");
  for (const j of jobs) {
    info(
      pad(j.jobId, 22) + " " + pad(j.how, 9) + " " + pad(j.managed ? "TAPPaaS" : "not TAPPaaS", 12) + " " +
        pad(j.storage, 16) + " " + j.schedule + (j.enabled ? "" : "  (disabled)"),
    );
  }
  const on = jobs.filter((j) => j.enabled).length;
  if (on === 0) warn(`no enabled job covers ${module}`);
  if (on > 1) warn(`${on} enabled jobs cover ${module} — it is backed up more than once (#554)`);
  return 0;
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
  info(pad("NAME", 20) + " " + pad("ROLE", 9) + " " + pad("HOST", 28) + " " + pad("NAMESPACE", 20) + " " +
    pad("TUNNEL", 26) + " LOCATION");
  for (const p of peers) {
    info(
      pad(p.name, 20) + " " + pad(p.role, 9) + " " + pad(p.remoteHost ?? "-", 28) + " " +
        pad(p.namespace ?? "-", 20) + " " + pad(p.tunnel ?? "-", 26) + " " + placeText(p.physicalLocation),
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
      // --yes is read as a global flag; restore.sh needs it to overwrite the
      // module's own guest with no terminal to ask on (#829).
      return restoreRun(deps, module, [...opts.rest.slice(2), ...(opts.yes ? ["--yes"] : [])]);
    }
    case "list-all": {
      if (!opts.json) return restoreListAll(opts.configDir);
      const vmids = new Map<string, string>();
      for (const m of listModules(opts.configDir)) {
        const v = moduleVmid(opts.configDir, m);
        if (v && !vmids.has(v)) vmids.set(v, m);
      }
      info(JSON.stringify(shapeRuns(client.runs(), (v) => vmids.get(v) ?? null, Math.floor(Date.now() / 1000))));
      return 0;
    }
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

// purge <module|vmid> [--yes] (#789): erase a guest's restore points — for a
// module that is gone (module-manager delete --remove leaves them in the
// datastore) or archived, when its data must be erased, not just stopped. The
// controller owns every check that matters (no deployed module owns the VMID, no
// job lists it, the cluster answered) and refuses with --yes too; here the
// operator sees the plan and types the VMID, or passes --yes.
function cmdPurge(opts: Opts, client: Client): number {
  const arg = opts.rest[0];
  if (!arg) die("purge: <module|vmid> required");
  let vmid = arg;
  if (!/^[0-9]+$/.test(arg)) {
    const v = moduleVmid(opts.configDir, arg);
    if (!v) die(`purge: no config for module '${arg}' — pass its VMID instead (the config goes with delete --remove)`);
    vmid = v!;
    if (!moduleArchived(opts.configDir, arg)) {
      die(`purge: '${arg}' is deployed — delete it first (module-manager delete ${arg} --remove), then purge ${vmid}`);
    }
  }
  const plan = client.purge(vmid, false);
  const size = plan.bytes >= 1 << 30 ? `${(plan.bytes / (1 << 30)).toFixed(1)} GiB` : `${Math.round(plan.bytes / (1 << 20))} MiB`;
  info(`vm/${vmid} on ${plan.store}: ${plan.snapshots} restore point(s), ${size} referenced`);
  if (plan.refused.length > 0) {
    for (const r of plan.refused) warn(`  refused: ${r}`);
    die(`purge ${vmid}: refused — nothing deleted`);
  }
  if (plan.snapshots === 0) {
    info("  nothing to purge");
    return 0;
  }
  if (!opts.yes) {
    const r = spawnSync("bash", ["-c", 'printf "%s" "$1" > /dev/tty; IFS= read -r v < /dev/tty || exit 1; printf "%s" "$v"', "--",
      `  This permanently deletes ${plan.snapshots} restore point(s) of vm/${vmid}. Type ${vmid} to confirm: `], { encoding: "utf8" });
    if (r.status !== 0) die("purge: cannot ask for confirmation (non-interactive session?) — pass --yes");
    if ((r.stdout ?? "").trim() !== vmid) die("purge: not confirmed — nothing deleted");
  }
  const res = client.purge(vmid, true);
  if (!res.purged) die(`purge ${vmid}: not purged${res.refused.length ? ` (${res.refused.join("; ")})` : ""}`);
  info(`${GN}purge: deleted vm/${vmid} (${res.snapshots} restore point(s)); garbage collection started — the space is free when it finishes${CL}`);
  return 0;
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
      case "backup": {
        const modules = opts.rest;
        if (modules.length === 0) die("backup: <module>... required");
        // Every name must be a module with a guest here, before anything runs:
        // a typo in the third of four names should not cost the first three.
        const missing = modules.filter((m) => !moduleVmid(opts.configDir, m));
        if (missing.length) die(`backup: no module with a vmid: ${missing.join(", ")}`);
        return client.backupNow(modules);
      }
      case "key": {
        // The escrow sits inside the system a full-site DR is rebuilding, so it
        // cannot be the only copy of a key: without an off-system copy, an
        // encrypted off-site backup is unrecoverable (§2.5.1).
        const sub = opts.rest[0] ?? "list";
        if (sub === "list") {
          client.keyList();
          return 0;
        }
        if (sub !== "export" && sub !== "import") {
          die(`key: expected 'list' | 'export --usb|--file DIR' | 'import --usb|--file DIR', got '${sub}'`);
        }
        const target = keyTarget(sub as "export" | "import", opts.rest.slice(1));
        if ("error" in target) die(target.error);
        const t = target as KeyTarget;
        if (t.kind === "usb") return keysUsb(sub as "export" | "import", t.node, opts.configDir, undefined, t.format);
        if (sub === "export") client.keyExport(t.dir);
        else client.keyImport(t.dir);
        return 0;
      }
      case "placement": {
        const sub = opts.rest[0];
        if (sub === undefined) {
          cmdPlacement(opts);
          return 0;
        }
        const ro = {
          configDir: opts.configDir,
          moduleDir: moduleScriptDir(opts.configDir),
          peer: opts.peer,
          yes: opts.yes,
          noUpdate: opts.noUpdate,
        };
        if (sub === "reset") return placementReset(ro, RESET_DEPS);
        if (sub === "finish-reset") return placementFinishReset(ro, RESET_DEPS);
        if (sub === "use-external") {
          return placementUseExternal(
            { configDir: opts.configDir, moduleDir: ro.moduleDir, url: opts.rest[1] ?? "",
              datastore: opts.datastore, namespace: opts.namespace, fingerprint: opts.fingerprint },
            RESET_DEPS,
          );
        }
        die(`placement: expected no argument, 'reset', 'finish-reset' or 'use-external', got '${sub}'`);
        return 1;
      }
      case "coverage":
        return cmdCoverage(opts, client);
      case "peers":
        cmdPeers(opts);
        return 0;
      case "peer":
        return cmdPeer(opts);
      case "pulse":
        return cmdPulse(opts);
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
      case "purge":
        return cmdPurge(opts, client);
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
  // exitCode, not exit(): exit() ends the process before a large write to a pipe
  // has drained, cutting --json output at 65536 bytes (found with health-manager, #788).
  process.exitCode = run(argv, client);
}
