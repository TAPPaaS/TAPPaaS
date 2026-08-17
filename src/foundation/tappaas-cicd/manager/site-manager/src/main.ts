// site-manager — TAPPaaS Site manager (ADR-007 P2, all-managers-to-TS #3).
//
// The Site is the umbrella over a whole TAPPaaS installation (site-wide
// identity, location, hardware nodes + storage pools, backup, update schedule,
// module repositories). It is a SINGLETON: exactly one config/site.json.
//
// Entity model (the entity is the first arg):
//   site       (SINGLETON) → show | modify
//   node                   → list | add | delete
//   repository             → list | add | modify | delete | reconcile
// Plus top-level lifecycle verbs:
//   add        create the site singleton (= create-site.sh: cluster discovery)
//   validate   validate site.json well-formed (= validate-site.sh)
//   reconcile  converge config → live (site.json + repositories;
//              with --deep: cascade to people + network + environments)
//
// TS owns config CRUD (site modify, node …) + validate + reconcile; the heavy
// git/cluster I/O stays in the still-live bash tools, invoked as thin
// delegations: `add` → create-site.sh; `repository add`/`delete` →
// repository.sh; `validate` → validate-site.sh. The transitional migration
// scripts (migrate-configuration*) are NOT ported and NOT wired here.
//
// Exit codes: ok=0, error=1.

import { defaultConfigDir, defaultSchemaDir, loadRaw, loadSite, writeSite } from "./config";
import { CliSiteClient } from "./client";
import { HelpSpec, renderHelp } from "../../../lib/ts/src/help";
import { DieError, GN, RD, YW, CL, die, guarded, info, warn } from "../../../lib/ts/src/cli";
import { applyPlan, computePlan } from "./reconcile";
import { adoptNode, provisionNode } from "./provision";
import { Site, SiteClient, SiteNode } from "./types";

const VERSION = "0.1.0";

const HELP: HelpSpec = {
  name: "site-manager",
  version: VERSION,
  tagline: "TAPPaaS Site manager (ADR-007 P2)",
  verbs: [
    { usage: "site show [--json]" },
    { usage: "site modify --<field> <value> [...]" },
    { usage: "node list [--json]" },
    { usage: "node add <N> [--pxe] [--boot-disk <d>] [--mac <m>] [--wan-port <if>|--no-wan] [--pool <p>] [--ttl <s>] [--config-only]",
      options: [
        ["(default)", "Adopt a Proxmox already installed at the node's designated mgmt IP: join the cluster + capture."],
        ["--pxe", "Bare machine: PXE-install first, then join + capture. Omit --boot-disk to be asked on the NODE console; WAN port + pools are asked here."],
        ["--config-only", "Only write the site.json entry (no machine contact)."],
      ] },
    { usage: "node delete <name>" },
    { usage: "node reconcile [--apply]",
      options: [["--apply", "Register nodes that joined the cluster (default is preview)."]] },
    { usage: "repository list [--json]", note: "(alias: repo)" },
    { usage: "repository add <url> [--branch <b>] [--managed full|tracked] [--catalog <p>]" },
    { usage: "repository modify <name> [--url <u>] [--branch <b>]",
      options: [["--url <u>", "Re-point the repo at a new forge/URL in place (e.g. github.com→codeberg.org)."],
                ["--branch <b>", "Switch the checked-out branch."]] },
    { usage: "repository delete <name> [--force]",
      options: [["--force", "Forward to repository.sh remove --force."]] },
    { usage: "repository reconcile [--apply]",
      options: [["--apply", "Commit (default is preview)."]] },
    { usage: "add --name <site-code> [--organization <org>] [create-site options]" },
    { usage: "validate [FILE] [--schema-dir PATH]" },
    { usage: "reconcile [--apply] [--deep]",
      options: [
        ["--apply", "Commit (default is preview)."],
        ["--deep", "Cascade people → network → (every) environment."],
      ] },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $TAPPAAS_CONFIG or /home/tappaas/config)."],
    ["--json", "Machine-readable output for list/show."],
  ],
  notes: [
    "Owns config/site.json (the Site singleton). add (create-site.sh), repository\n" +
      "add/modify/delete (repository.sh) are thin delegations to the still-live bash\n" +
      "tools; validate wraps validate-site.sh. TS owns config CRUD + validate + reconcile.",
    "site modify fields:\n" +
      "  --displayName --owner --email --automaticReboot --snapshotRetention\n" +
      "  --backupTarget --backupOffsite\n" +
      "  --locationCountry --locationTimezone --locationLocale\n" +
      "  --networkIsp --networkPublicIp",
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

// ── option parsing ─────────────────────────────────────────────────────
interface Opts {
  configDir: string;
  siteFile?: string;
  schemaDir: string;
  apply: boolean;
  deep: boolean;
  force: boolean;
  json: boolean;
  // generic --key value capture for `site modify` / `node add` / `repository add`.
  flags: Map<string, string>;
  boolFlags: Set<string>;
  rest: string[];
}

// Flags that take NO value (everything else with a value is captured generically).
const NOARG = new Set(["--apply", "--deep", "--force", "--json",
  "--pxe", "--provision", "--config-only", "--yes", "--no-wan"]);

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    schemaDir: defaultSchemaDir(),
    apply: false,
    deep: false,
    force: false,
    json: false,
    flags: new Map(),
    boolFlags: new Set(),
    rest: [],
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--config-dir") {
      const v = args[i + 1];
      if (!v) die("--config-dir requires a path argument");
      o.configDir = v;
      i++;
    } else if (a === "--schema-dir") {
      const v = args[i + 1];
      if (!v) die("--schema-dir requires a path argument");
      o.schemaDir = v;
      i++;
    } else if (a === "--apply") {
      o.apply = true;
    } else if (a === "--deep") {
      o.deep = true;
    } else if (a === "--force") {
      o.force = true;
    } else if (a === "--json") {
      o.json = true;
    } else if (a.startsWith("--")) {
      // generic flag. If the next token is a value (not another flag), capture it.
      const next = args[i + 1];
      if (NOARG.has(a) || next === undefined || next.startsWith("--")) {
        o.boolFlags.add(a);
      } else {
        // allow repeated --pool: store last; node add reads rest for pools.
        o.flags.set(a, next);
        i++;
      }
    } else {
      o.rest.push(a);
    }
  }
  return o;
}

function siteFileOf(o: Opts): string {
  return o.siteFile ?? `${o.configDir.replace(/\/$/, "")}/site.json`;
}

// ── `site` (singleton) ─────────────────────────────────────────────────
function cmdSite(o: Opts): void {
  const sub = o.rest[0];
  if (!sub) die("site: expected 'show' or 'modify'");
  const siteFile = siteFileOf(o);

  if (sub === "show") {
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    // --json → the exact on-disk document; default → a concise human summary
    // (consistent with `node list` / `repository list`).
    if (o.json) {
      info(JSON.stringify(raw, null, 2));
      return;
    }
    const site: Site = loadSite(siteFile);
    const loc = site.location ?? ({} as Site["location"]);
    const net = site.network ?? {};
    const sched = Array.isArray(site.updateSchedule) ? site.updateSchedule : [];
    const schedStr = sched.length
      ? [sched[0], sched[1], sched[2] != null ? `@ ${String(sched[2]).padStart(2, "0")}:00` : null]
          .filter((x) => x != null && x !== "")
          .join(" ")
      : "(unset)";
    const nodes = site.hardware?.nodes ?? [];
    const repos = site.repositories ?? [];
    const orgs = site.organizations ?? [];
    const lbl = (k: string): string => `${GN}${(k + ":").padEnd(15)}${CL}`;
    info(`${lbl("Site")}${site.name}${site.displayName && site.displayName !== site.name ? ` (${site.displayName})` : ""}`);
    info(`${lbl("Owner")}${site.owner || "(unset)"}`);
    info(`${lbl("Email")}${site.email || "(unset)"}`);
    info(`${lbl("Version")}${site.version || "(unset)"}`);
    info(`${lbl("Location")}${[loc.country, loc.timezone, loc.locale].filter(Boolean).join(" / ") || "(unset)"}`);
    info(`${lbl("Network")}publicIp=${net.publicIp ?? "(unset)"}  isp=${net.isp ?? "(none)"}`);
    info(`${lbl("Update")}${schedStr}  (auto-reboot: ${site.automaticReboot ? "yes" : "no"}, keep ${site.snapshotRetention ?? "?"})`);
    info(`${lbl("Nodes")}${nodes.length ? nodes.map((n) => `${n.name} [${n.storagePools.join(", ")}]`).join("  ") : "(none)"}`);
    info(`${lbl("Repositories")}${repos.length ? repos.map((r) => `${r.name}${r.branch ? "@" + r.branch : ""}`).join("  ") : "(none)"}`);
    info(`${lbl("Orgs")}${orgs.length ? orgs.join(", ") : "(none)"}`);
    info(`${lbl("Backup")}${site.backup ? JSON.stringify(site.backup) : "(none)"}`);
    return;
  }

  if (sub === "modify") {
    const raw = loadRaw(siteFile);
    if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
    let changed = 0;
    // The approved editable surface: scalar site-wide fields, mapped to schema
    // paths. The discovery-derived hardware.nodes[] and the repositories/
    // organizations lists are NOT modifiable here — each has its own CRUD
    // (node …, repository …) or its own manager. (Environments are not a site
    // field at all — they are the config/environments/*.json files.)
    const setStr = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      setDeep(raw, path, v);
      changed++;
    };
    const setBool = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      if (v !== "true" && v !== "false") die(`${flag} must be true|false`);
      setDeep(raw, path, v === "true");
      changed++;
    };
    const setInt = (flag: string, path: string[]): void => {
      const v = o.flags.get(flag);
      if (v === undefined) return;
      const n = parseInt(v, 10);
      if (!Number.isInteger(n)) die(`${flag} must be an integer`);
      setDeep(raw, path, n);
      changed++;
    };

    setStr("--displayName", ["displayName"]);
    setStr("--owner", ["owner"]);
    setStr("--email", ["email"]);
    setBool("--automaticReboot", ["automaticReboot"]);
    setInt("--snapshotRetention", ["snapshotRetention"]);
    setStr("--backupTarget", ["backup", "target"]);
    setStr("--backupOffsite", ["backup", "offsite"]);
    setStr("--locationCountry", ["location", "country"]);
    setStr("--locationTimezone", ["location", "timezone"]);
    setStr("--locationLocale", ["location", "locale"]);
    setStr("--networkIsp", ["network", "isp"]);
    setStr("--networkPublicIp", ["network", "publicIp"]);

    if (changed === 0) die("site modify: no recognised --<field> given (see --help)");
    writeSite(siteFile, raw);
    info(`${GN}✓${CL} site.json updated (${changed} field(s)) — run 'validate' to confirm`);
    return;
  }

  die(`site ${sub}: unknown subcommand (expected 'show' | 'modify')`);
}

// Set raw[path...] = value, creating intermediate objects.
function setDeep(obj: Record<string, unknown>, path: string[], value: unknown): void {
  let cur = obj;
  for (let i = 0; i < path.length - 1; i++) {
    const k = path[i];
    if (typeof cur[k] !== "object" || cur[k] === null) cur[k] = {};
    cur = cur[k] as Record<string, unknown>;
  }
  cur[path[path.length - 1]] = value;
}

// ── `node` CRUD + reconcile (hardware.nodes[]) ─────────────────────────
function cmdNode(o: Opts, client: SiteClient): void {
  const sub = o.rest[0];
  if (!sub) die("node: expected 'list' | 'add' | 'delete' | 'reconcile'");
  const siteFile = siteFileOf(o);

  if (sub === "reconcile") {
    // Capture cluster membership into site.json (docs/design/
    // node-provisioning.md N1): the scoped node slice of `reconcile`, exactly
    // as `repository reconcile` is the repo slice.
    const site: Site = loadSite(siteFile);
    const plan = computePlan(site, client, {
      deep: false,
      apply: o.apply,
      siteFile,
      scope: "nodes",
    });
    printPlan(plan, o.apply);
    if (o.apply && plan.actions.length > 0) {
      const res = applyPlan(client, plan);
      info("");
      for (const f of res.failures) warn(`${f.target} failed: ${f.error}`);
      info(`${GN}Applied ${res.applied} action(s) — declare storage pools for new nodes before installing modules on them.${CL}`);
    }
    return;
  }

  if (sub === "list") {
    const site: Site = loadSite(siteFile);
    if (o.json) {
      info(JSON.stringify(site.hardware.nodes, null, 2));
    } else if (site.hardware.nodes.length === 0) {
      info("(no nodes)");
    } else {
      for (const n of site.hardware.nodes) {
        info(`${n.name}\t[${n.storagePools.join(", ")}]`);
      }
    }
    return;
  }

  if (sub === "add") {
    const name = o.flags.get("--name") ?? o.rest[1];
    if (!name) die("node add: expected --name <N> (or positional name)");
    if (!/^[A-Za-z0-9_-]+$/.test(name)) die(`node add: invalid name '${name}'`);
    // --pool may be given multiple times; parseOpts keeps only the last, so we
    // also accept trailing positionals after the name as pools.
    const pools = collectPools(o, name);
    if (o.boolFlags.has("--config-only")) {
      // Just declare the node in site.json (no machine contact).
      const raw = loadRaw(siteFile);
      if (Object.keys(raw).length === 0) die(`site.json not found: ${siteFile}`);
      const hw = (raw.hardware ?? (raw.hardware = {})) as Record<string, unknown>;
      const nodes = (Array.isArray(hw.nodes) ? hw.nodes : (hw.nodes = [])) as SiteNode[];
      if (nodes.some((n) => n.name === name)) die(`node '${name}' already exists`);
      nodes.push({ name, storagePools: pools });
      writeSite(siteFile, raw);
      info(`${GN}✓${CL} node '${name}' added (pools: ${pools.join(", ") || "none"})`);
      return;
    }
    if (o.boolFlags.has("--provision")) {
      warn("--provision is deprecated — use --pxe");
    }
    const opts = {
      name,
      bootDisk: o.flags.get("--boot-disk"),
      macs: o.flags.get("--mac") ? [o.flags.get("--mac") as string] : [],
      pools,
      wanPort: o.boolFlags.has("--no-wan") ? "" : o.flags.get("--wan-port"),
      ttlSeconds: Number(o.flags.get("--ttl") ?? 7200),
      yes: o.boolFlags.has("--yes"),
    };
    if (o.boolFlags.has("--pxe") || o.boolFlags.has("--provision")) {
      // Bare machine: PXE install → join → capture (design N3).
      provisionNode(opts);
    } else {
      // Default: a Proxmox was installed by hand at the node's designated
      // mgmt IP — verify and run the join pipeline over ssh.
      adoptNode(opts);
    }
    return;
  }

  if (sub === "delete") {
    const name = o.rest[1];
    if (!name) die("node delete: expected <name>");
    const raw = loadRaw(siteFile);
    const hw = (raw.hardware ?? {}) as Record<string, unknown>;
    const nodes = (Array.isArray(hw.nodes) ? hw.nodes : []) as SiteNode[];
    const next = nodes.filter((n) => n.name !== name);
    if (next.length === nodes.length) die(`node '${name}' not found`);
    hw.nodes = next;
    raw.hardware = hw;
    writeSite(siteFile, raw);
    info(`${GN}✓${CL} node '${name}' deleted`);
    return;
  }

  die(`node ${sub}: unknown subcommand`);
}

function collectPools(o: Opts, name: string): string[] {
  const pools: string[] = [];
  const single = o.flags.get("--pool");
  if (single) pools.push(single);
  // positionals after the node name (rest[0]=node, rest[1]=name?) are pools.
  for (const r of o.rest.slice(1)) {
    if (r !== name) pools.push(r);
  }
  return Array.from(new Set(pools));
}

// ── `repository` CRUD + reconcile ──────────────────────────────────────
function cmdRepository(o: Opts, client: SiteClient): void {
  const sub = o.rest[0];
  if (!sub) die("repository: expected 'list' | 'add' | 'modify' | 'delete' | 'reconcile'");
  const siteFile = siteFileOf(o);

  if (sub === "list") {
    const site = loadSite(siteFile);
    if (o.json) {
      info(JSON.stringify(site.repositories, null, 2));
    } else if (site.repositories.length === 0) {
      info("(no repositories)");
    } else {
      for (const r of site.repositories) {
        info(`${r.name}\t${r.url}\t${r.branch ?? "stable"}\t${r.managed ?? "full"}`);
      }
    }
    return;
  }

  // Rebuild "--key value" pairs from parsed flags for the bash delegations
  // (parseOpts captures valued flags into o.flags, so o.rest holds positionals
  // only — forwarding o.rest alone would silently drop --url/--branch/etc.).
  const fwdFlags = (keys: string[]): string[] => {
    const out: string[] = [];
    for (const k of keys) {
      const v = o.flags.get(k);
      if (v !== undefined) out.push(k, v);
    }
    return out;
  };

  if (sub === "add") {
    // Thin delegation: repository.sh still owns URL validation, git clone +
    // checkout, catalog validation, and the VMID/name conflict scan, and writes
    // the site.json .repositories entry. Forward <url> + its valued flags.
    const url = o.rest[1];
    if (!url) die("repository add: expected <url>");
    const rc = client.repositoryAdd([url, ...fwdFlags(["--branch", "--managed", "--catalog"])]);
    if (rc !== 0) throw new DieError(`repository.sh add exited ${rc}`);
    return;
  }

  if (sub === "modify") {
    const name = o.rest[1];
    if (!name) die("repository modify: expected <name> [--url <url>] [--branch <branch>]");
    // Thin delegation: repository.sh modify re-points origin (forge migration:
    // github.com -> codeberg.org) and/or switches branch on the live checkout,
    // then edits site.json. Forward <name> + --url/--branch.
    const flags = fwdFlags(["--url", "--branch"]);
    if (flags.length === 0) die("repository modify: expected --url and/or --branch");
    const rc = client.repositoryModify([name, ...flags]);
    if (rc !== 0) throw new DieError(`repository.sh modify exited ${rc}`);
    return;
  }

  if (sub === "delete") {
    const name = o.rest[1];
    if (!name) die("repository delete: expected <name>");
    // Thin delegation: repository.sh remove checks installed-module dependents,
    // rm -rf's the clone, and edits site.json. --force forwards through.
    const rc = client.repositoryRemove(name, o.force);
    if (rc !== 0) throw new DieError(`repository.sh remove exited ${rc}`);
    return;
  }

  if (sub === "reconcile") {
    // repository reconcile = converge repositories[] to live clones (the (1)
    // own-concern half of `reconcile`, scoped to repos). Reuses the engine with
    // deep=false; we still emit only the repo actions. Descriptive per-repo
    // output so the operator sees WHAT was checked, not just an action count.
    const site = loadSite(siteFile);
    const plan = computePlan(site, client, {
      deep: false,
      apply: o.apply,
      siteFile,
      scope: "repositories",
    });
    info("");
    info(
      `Reconciling ${site.repositories.length} repository(ies) from site.json → live git clones` +
        `${o.apply ? "" : " (preview)"}:`,
    );
    for (const w of plan.warnings) warn(w);
    for (const repo of site.repositories) {
      const br = repo.branch ?? "stable";
      const act = plan.actions.find((a) => a.target.startsWith(`repository ${repo.name} `));
      if (!act) {
        info(`  ${GN}✓${CL} ${repo.name} @ ${br} — present, on the declared branch`);
      } else if (act.kind === "clone-repo") {
        info(`  ${YW}+${CL} ${repo.name} @ ${br} — ${o.apply ? "cloning" : "not cloned; would clone"} ${repo.url}`);
      } else {
        // checkout-repo target: "repository <name> → checkout <branch> (was <cur>)"
        const detail = act.target.replace(`repository ${repo.name} → `, "");
        info(`  ${YW}⟳${CL} ${repo.name} — ${o.apply ? "" : "would "}${detail}`);
      }
    }
    info("");
    if (plan.actions.length === 0) {
      info(`${GN}Converged — every repository is present and on its declared branch. Nothing to do.${CL}`);
    } else if (o.apply) {
      const res = applyPlan(client, plan);
      for (const f of res.failures) warn(`${f.target} failed: ${f.error}`);
      info(`${GN}Applied ${res.applied} action(s).${CL}`);
    } else {
      info(`${plan.actions.length} change(s) needed — re-run with --apply to perform them.`);
    }
    return;
  }

  die(`repository ${sub}: unknown subcommand`);
}

// ── top-level lifecycle verbs ──────────────────────────────────────────

// `validate` — validate site.json (= validate-site.sh).
function cmdValidate(o: Opts, client: SiteClient): void {
  const siteFile = o.rest[0] ?? siteFileOf(o);
  const errs = client.validateSite(siteFile);
  if (errs.length === 0) {
    info(`${GN}✓${CL} site.json valid: ${siteFile}`);
    return;
  }
  for (const e of errs) console.error(`${RD}[Error]${CL} VALIDATION: ${e}`);
  die(`site.json has ${errs.length} validation error(s)`);
}

// `reconcile` — converge site config → live (+ --deep cascade). Returns the
// exit code: 1 when any action (notably a cascade) failed to converge.
function cmdReconcile(o: Opts, client: SiteClient): number {
  const siteFile = siteFileOf(o);
  const site = loadSite(siteFile);
  const plan = computePlan(site, client, { deep: o.deep, apply: o.apply, siteFile });
  printPlan(plan, o.apply);
  if (!o.apply || plan.actions.length === 0) return 0;

  const res = applyPlan(client, plan);
  info("");
  // A cascade that ran and failed is named here rather than swallowed: the
  // whole point is that `Applied N action(s)` must stop being printed over a
  // run where nothing converged.
  for (const f of res.failures) warn(`${f.target} failed: ${f.error}`);
  if (res.failures.length > 0) {
    info(
      `${RD}Applied ${res.applied} action(s); ${res.failures.length} failed.${CL}`,
    );
    return 1;
  }
  info(`${GN}Applied ${res.applied} action(s).${CL}`);
  return 0;
}

function printPlan(plan: { actions: { kind: string; target: string }[]; warnings: string[] }, apply: boolean): void {
  info("");
  info(`Plan: ${plan.actions.length} action(s), ${plan.warnings.length} warning(s)`);
  for (const w of plan.warnings) warn(w);
  for (const a of plan.actions) info(`  ${apply ? "" : "[preview] would "}${a.kind}: ${a.target}`);
  if (!apply) {
    info("");
    info("(preview — pass --apply to commit)");
  } else if (plan.actions.length === 0) {
    info(`${GN}Nothing to do — already converged.${CL}`);
  }
}

// `add` — create the site singleton (= create-site.sh). Thin delegation: the
// cluster-discovery write (ssh pvesh node/pool discovery, tz/locale detection,
// version-from-git, Proxmox email discovery, force-preserve-on-rerun) stays in
// create-site.sh. We forward the args verbatim so its full flag set
// (--name/--organization/--domain/--branch/--upstream-git/--email/--primary-node/
// --schedule/--weekday/--hour/--config-dir/--force) keeps working unchanged.
function cmdAdd(args: string[], client: SiteClient): void {
  const rc = client.createSite(args);
  if (rc !== 0) throw new DieError(`create-site.sh exited ${rc}`);
}

// ── dispatch ───────────────────────────────────────────────────────────
export function run(argv: string[], client: SiteClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const o = parseOpts(argv.slice(1));

  return guarded(() => {
    switch (cmd) {
      case "site":
        cmdSite(o);
        return 0;
      case "node":
        cmdNode(o, client);
        return 0;
      case "repository":
      case "repo":
        cmdRepository(o, client);
        return 0;
      case "add":
        // create-site.sh has its own flag set — forward raw args, not parsed.
        cmdAdd(argv.slice(1), client);
        return 0;
      case "validate":
        cmdValidate(o, client);
        return 0;
      case "reconcile":
        return cmdReconcile(o, client);
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  const client = new CliSiteClient();
  process.exit(run(process.argv.slice(2), client));
}
