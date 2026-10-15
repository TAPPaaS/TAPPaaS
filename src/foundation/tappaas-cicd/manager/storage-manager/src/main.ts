// storage-manager — TAPPaaS storage control plane (ADR-029 v0.9). Owns
// config/shares.json and changes it one share at a time; the start of a control
// plane that can grow beyond NFS and beyond PVE hosts.
//
// Every changing verb: lock → change → validate the WHOLE resulting file → write
// atomically → converge the share (its server's hook, then its alias, through the
// storage module's lib/nfs-converge.sh) → notify the consumers it changed. A verb
// that fails validation writes nothing. --check prints the result instead.
//
// Exit codes: ok=0, error=1.

import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { CL, GN, YW, die, guarded, info, requireOperator, warn } from "../../../lib/ts/src/cli";
import { stream } from "../../../lib/ts/src/exec";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { NfsFinding, SharesDoc, checkShares, shareAlias, sharesOf } from "../../../lib/ts/src/nfs-shares";
import { Store } from "./store";
import { AddSpec, Result, addShare, deleteShare, grant, modifyShare, revoke } from "./verbs";
import { join } from "path";

const VERSION = "0.1.0";

export const HELP: HelpSpec = {
  name: "storage-manager",
  version: VERSION,
  tagline: "TAPPaaS storage control plane — NFS shares in config/shares.json (ADR-029)",
  verbs: [
    { usage: "validate", note: "(config/shares.json, against the deployed instances)" },
    {
      usage: "nfs show [<share>] [--server <instance>] [--json]",
      name: "nfs show",
      options: [["--server I", "nfs show: only the shares on this server."], ["--json", "nfs show: the declarations as JSON."]],
    },
    {
      usage:
        "nfs share add <name> --server <instance> (--pool <p> [--quota <q>] --backup true|false [--backup-exclude a,b] [--prop k=v]... | --path <p> [--version v] [--v3-ports mountd,nlockmgr,statd]) [--check]",
      name: "nfs share add",
      options: [
        ["--server I", "The module instance that carries the share."],
        ["--pool P", "A managed Host's ZFS pool."],
        ["--quota Q", "ZFS quota (e.g. 4T)."],
        ["--backup B", "true|false — required for a managed share (ADR-029 D9)."],
        ["--backup-exclude L", "Patterns relative to the share root, comma-separated."],
        ["--prop K=V", "ZFS property: recordsize, compression, atime (repeatable)."],
        ["--path P", "A registered, unmanaged server's exported path."],
        ["--version V", "4.2 (default), 4.1, 4.0 or 3 — a registered server's NFS version."],
        ["--v3-ports L", "mountd,nlockmgr,statd — required with --version 3."],
        ["--check", "Show the result; change nothing."],
      ],
    },
    {
      usage: "nfs share modify <name> --set <field>=<value>... [--check]",
      name: "nfs share modify",
      options: [["--set F=V", "quota, backup.enabled, backup.exclude, properties.<k> (repeatable)."], ["--check", "Show the result; change nothing."]],
    },
    { usage: "nfs share delete <name> [--check]", name: "nfs share delete", options: [["--check", "Show the result; change nothing."]], note: "(unshared; data kept)" },
    {
      usage: "nfs share purge <name> --server <instance> --yes",
      name: "nfs share purge",
      options: [["--server I", "The server holding the orphan."], ["--yes", "Confirm: the data is destroyed."]],
      note: "(destroys an orphan's dataset)",
    },
    { usage: "nfs grant <share> <consumer> ro|rw [--check]", name: "nfs grant", options: [["--check", "Show the result; change nothing."]] },
    { usage: "nfs revoke <share> <consumer> [--check]", name: "nfs revoke", options: [["--check", "Show the result; change nothing."]] },
    {
      usage: "nfs converge [<share> [--notify]] [--server <instance>]",
      name: "nfs converge",
      options: [["--server I", "nfs converge: one server's shares."], ["--notify", "nfs converge <share>: also run its consumers' storage:nfs update (a migration, with their consent)."]],
      note: "(re-apply the declarations)",
    },
  ],
  notes: [
    "Shares are declared once, in config/shares.json, and changed only here. A consumer mounts a share by name ('storage:nfs'); the server that carries it builds it through its NFS server hook, and the share alias nfs-<name>.mgmt.internal follows it.",
  ],
};

function opt(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}
function opts(args: string[], name: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) if (args[i] === name && args[i + 1] !== undefined) out.push(args[++i]);
  return out;
}
function positional(args: string[], skip: number, valued: string[]): string[] {
  const out: string[] = [];
  for (let i = skip; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      if (valued.includes(args[i])) i++;
      continue;
    }
    out.push(args[i]);
  }
  return out;
}

function report(findings: NfsFinding[]): number {
  let errors = 0;
  for (const f of findings) {
    if (f.severity === "error") {
      errors++;
      console.error(`\x1b[01;31m[Error]\x1b[0m ${f.message}`);
    } else warn(f.message);
  }
  return errors;
}

function converge(store: Store, args: string[]): number {
  const dir = store.storageDir();
  if (!dir) die("the storage module is not registered (no config/storage.json with a moduleSource) — register it first: install-module.sh storage");
  return stream(join(dir, "lib", "nfs-converge.sh"), args);
}

// change — the shared sequence of every changing verb.
function change(store: Store, check: boolean, fn: (doc: SharesDoc) => Result, after: (doc: SharesDoc) => number): number {
  return store.withLock(() => {
    const r = fn(store.load());
    if ("refused" in r) die(r.refused);
    const errors = report(checkShares(r.doc, store.read, store.hasHook).filter((f) => f.severity === "error" || !check));
    if (errors) die(`config/shares.json would not be valid — nothing was changed`);
    if (check) {
      info(`[check] ${r.summary}`);
      info(JSON.stringify(sharesOf(r.doc), null, 2));
      return 0;
    }
    store.save(r.doc);
    info(`${GN}✓${CL} ${r.summary}`);
    return after(r.doc);
  });
}

function show(store: Store, args: string[]): number {
  const shares = sharesOf(store.load());
  const only = positional(args, 2, ["--server"])[0];
  const server = opt(args, "--server");
  const picked = Object.entries(shares).filter(([n, s]) => (!only || n === only) && (!server || s.server === server));
  if (only && picked.length === 0) die(`share ${only} is not declared`);
  if (args.includes("--json")) {
    console.log(JSON.stringify(Object.fromEntries(picked), null, 2));
    return 0;
  }
  if (picked.length === 0) {
    info("no shares declared");
    return 0;
  }
  for (const [name, s] of picked) {
    const where = s.pool ? `${s.server}:${s.pool}${s.quota ? ` quota ${s.quota}` : ""}` : `${s.server}:${s.path} (registered, v${s.version ?? "4.2"})`;
    info(`${GN}${name}${CL}  ${where}  → ${shareAlias(name)}`);
    const grants = Object.entries(s.grants ?? {});
    const mounted = new Set(store.mountedBy(name));
    for (const [c, a] of grants) info(`    ${c} ${a}${mounted.has(c) ? "  (mounts it)" : store.read(c) ? "" : `  ${YW}(not deployed)${CL}`}`);
    if (!grants.length) info("    (no grants — mountable by nobody)");
    if (!s.pool) {
      // A registered server's export table is the operator's: say what it must carry (D2a).
      info(`    the server's export table must carry, for ${s.path}: root_squash, all_squash to one owner, and each granted consumer's address rw|ro as above`);
    }
  }
  return 0;
}

export function run(argv: string[]): number {
  const args = argv;
  if (args.length === 0 || args[0] === "help" || args[0] === "--help" || args[0] === "-h") {
    info(renderHelp(HELP));
    return 0;
  }
  if (args[0] === "--version" || args[0] === "version") {
    info(`storage-manager ${VERSION}`);
    return 0;
  }
  const rc = checkArgs(HELP, args);
  if (rc !== undefined) return rc;
  const store = new Store(defaultConfigDir());
  const check = args.includes("--check");
  const verb = args.slice(0, 3).join(" ");

  if (args[0] === "validate") {
    const errors = report(checkShares(store.load(), store.read, store.hasHook));
    if (errors) return 1;
    info(`${GN}✓${CL} config/shares.json valid (${Object.keys(sharesOf(store.load())).length} share(s))`);
    return 0;
  }
  if (args[0] !== "nfs") die(`unknown verb '${args[0]}' — see 'storage-manager --help'`);
  if (args[1] === "show") return show(store, args);
  requireOperator();

  if (verb.startsWith("nfs share add")) {
    const [name] = positional(args, 3, ["--server", "--pool", "--quota", "--backup", "--backup-exclude", "--prop", "--path", "--version", "--v3-ports"]);
    if (!name) die("nfs share add <name> --server <instance> ...");
    const server = opt(args, "--server") ?? die("--server is required");
    if (!store.read(server)) die(`${server} is not a module instance (no config/${server}.json)`);
    const backup = opt(args, "--backup");
    if (backup !== undefined && backup !== "true" && backup !== "false") die("--backup is true or false");
    const props: Record<string, string> = {};
    for (const kv of opts(args, "--prop")) {
      const i = kv.indexOf("=");
      if (i <= 0) die(`--prop ${kv}: write key=value`);
      props[kv.slice(0, i)] = kv.slice(i + 1);
    }
    const v3 = opt(args, "--v3-ports");
    let v3Ports: AddSpec["v3Ports"];
    if (v3) {
      const [m, n, s] = v3.split(",").map(Number);
      if (![m, n, s].every((x) => Number.isInteger(x) && x > 0)) die("--v3-ports mountd,nlockmgr,statd — three port numbers");
      v3Ports = { mountd: m, nlockmgr: n, statd: s };
    }
    const spec: AddSpec = {
      server,
      pool: opt(args, "--pool"),
      quota: opt(args, "--quota"),
      backup: backup === undefined ? undefined : backup === "true",
      backupExclude: opt(args, "--backup-exclude")?.split(",").filter(Boolean),
      properties: Object.keys(props).length ? props : undefined,
      path: opt(args, "--path"),
      version: opt(args, "--version"),
      v3Ports,
    };
    return change(store, check, (d) => addShare(d, name, spec, store.managed(server)), () => converge(store, ["share", name, "--notify"]));
  }
  if (verb.startsWith("nfs share modify")) {
    const [name] = positional(args, 3, ["--set"]);
    if (!name) die("nfs share modify <name> --set <field>=<value>...");
    const sets = opts(args, "--set").map((kv): [string, string] => {
      const i = kv.indexOf("=");
      if (i <= 0) die(`--set ${kv}: write field=value`);
      return [kv.slice(0, i), kv.slice(i + 1)];
    });
    if (!sets.length) die("nothing to change — give --set <field>=<value>");
    return change(store, check, (d) => modifyShare(d, name, sets), () => converge(store, ["share", name]));
  }
  if (verb.startsWith("nfs share delete")) {
    const [name] = positional(args, 3, []);
    if (!name) die("nfs share delete <name>");
    const server = sharesOf(store.load())[name]?.server ?? "";
    return change(store, check, (d) => deleteShare(d, name, store.mountedBy(name)), () => converge(store, ["drop", name, server]));
  }
  if (verb.startsWith("nfs share purge")) {
    const [name] = positional(args, 3, ["--server"]);
    const server = opt(args, "--server");
    if (!name || !server) die("nfs share purge <name> --server <instance> --yes");
    if (sharesOf(store.load())[name]) die(`share ${name} is still declared — 'nfs share delete ${name}' first; purge only destroys an orphan`);
    if (!args.includes("--yes")) die(`purging destroys share ${name}'s data on ${server} — add --yes to confirm`);
    return converge(store, ["purge", name, server]);
  }
  if (verb.startsWith("nfs grant")) {
    const [share, consumer, access] = positional(args, 2, []);
    if (!share || !consumer || !access) die("nfs grant <share> <consumer> ro|rw");
    if (!store.read(consumer)) warn(`${consumer} is not deployed — the grant takes effect when it is`);
    return change(store, check, (d) => grant(d, share, consumer, access), () => converge(store, ["share", share, "--notify-only", consumer]));
  }
  if (verb.startsWith("nfs revoke")) {
    const [share, consumer] = positional(args, 2, []);
    if (!share || !consumer) die("nfs revoke <share> <consumer>");
    return change(store, check, (d) => revoke(d, share, consumer, store.mountedBy(share).includes(consumer)), () => converge(store, ["share", share]));
  }
  if (args[1] === "converge") {
    const [name] = positional(args, 2, ["--server"]);
    const server = opt(args, "--server");
    if (name) return converge(store, ["share", name, ...(args.includes("--notify") ? ["--notify"] : [])]);
    if (server) return converge(store, ["server", server]);
    return converge(store, ["all"]);
  }
  die(`unknown verb 'storage-manager ${args.slice(0, 3).join(" ")}' — see 'storage-manager --help'`);
}

if (require.main === module) {
  process.exit(guarded(() => run(process.argv.slice(2))));
}
