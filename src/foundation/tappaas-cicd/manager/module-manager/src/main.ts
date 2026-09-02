// module-manager — TAPPaaS module lifecycle manager (ADR-007 #3 verb alignment).
//
// Presents the STANDARDIZED verbs on entity `module`:
//
//   module add <module>      = install-module.sh   (create + provision)
//   module modify <module>   = update-module.sh    (change config + re-apply)
//   module delete <module>   = delete-module.sh    (archive/remove)
//   module list              = enumerate deployed module configs    [NEW, TS]
//   module show <module>     = one deployed module config in detail [NEW, TS]
//   module resolve <module>  = DESIRED state: config + schema defaults [ADR-020]
//   module drift <module>    = DESIRED vs ACTUAL, per service           [ADR-020]
//   module validate [<m>]    = tier/source lint (all, or one)        [TS port]
//   module reconcile <m>     = re-apply this module's config → VM/service [leaf]
//   module test <module>     = test-module.sh
//   module snapshot-vm <m>   = snapshot-vm.sh  (special VM op — stays)
//
// CONFIG-layer verbs (list/show/validate) are pure TS reading config/*.json.
// LIFECYCLE verbs (add/modify/delete/test/snapshot-vm) delegate to the existing
// bash scripts via the injected ModuleClient (the heavy cluster logic stays in
// bash until each script's own retire step — module-manager is a thin
// orchestrator like network-manager). `reconcile` (both the default inspect and
// --apply converge) is NATIVE TS since Phase 7.3 (src/inspect.ts /
// src/reconcile.ts).
//
// Exit codes: ok=0, error / non-zero child rc = that rc (1 for config errors).

import { readFileSync } from "fs";
import { join } from "path";
import { CliModuleClient } from "./client";
import {
  classifyModuleResolution,
  defaultConfigDir,
  listModules,
  loadModule,
} from "./config";
import { HelpSpec, renderHelp, renderVerbHelp } from "../../../lib/ts/src/help";
import { CL, GN, RD, YW, die, guarded, info, preflightGuard, warn } from "../../../lib/ts/src/cli";
import {
  AddOptions,
  DeleteOptions,
  ModifyOptions,
  ModuleClient,
  ReconcileOptions,
  SnapshotAction,
  TestOptions,
} from "./types";
import { loadModuleFields } from "../../../lib/ts/src/desired";
import { cmdDrift } from "./converge";
import { cmdResolve } from "./resolve";
import { realServiceFs } from "./services";
import { validateModules } from "./validate";

const VERSION = "0.1.0";

const HELP: HelpSpec = {
  name: "module-manager",
  version: VERSION,
  tagline: "TAPPaaS module lifecycle manager (ADR-007 #3)",
  verbs: [
    {
      usage: "list [--diff] [--services] [--resolution] [--json]",
      name: "list",
      options: [
        ["--diff", "Per-module three-way (released/desired/running) drift rollup across every module."],
        ["--services", "--diff: also check each module's dependency-service state (one firewall/API round-trip per dependency — OFF by default across the fleet)."],
        ["--resolution", "Which path locates each module's source directory (.location / repository catalog / neither). Offline; flags modules nothing can resolve."],
      ],
    },
    { usage: "show <module> [--json]", name: "show" },
    {
      usage: "drift <module> [--service <provider:service>] [--json]",
      name: "drift",
      options: [
        ["--service P:S", "One coordinate (e.g. cluster:vm). Default: every dependency that ships a field manifest."],
        ["--json", "The drift RECORD — with --service, exactly what 'update-service.sh --apply-drift' consumes."],
      ],
    },
    {
      usage: "resolve <module> [--json]",
      name: "resolve",
      options: [
        [
          "--json",
          "The resolved document as JSON — what the converge consumes (ADR-020 D1).",
        ],
      ],
    },
    {
      usage: "validate [<module>] [--allow-fork]",
      name: "validate",
      options: [["--allow-fork", "Permit forked/non-canonical module sources (relax tier/source lint)."]],
    },
    {
      usage: "add <module> [--environment ENV] [--allow-fork] [--force] [--reinstall] [--<field> <value>]...",
      name: "add",
      options: [
        ["--environment ENV", "Target environment to install into (default: foundation→mgmt, else the org env)."],
        ["--allow-fork", "Permit forked/non-canonical module sources."],
        ["--force", "Proceed despite warnings / overwrite an existing deployment."],
        ["--reinstall", "Reinstall even if the module is already deployed."],
        ["--<field> <value>", "Override any config field, passed through to install-module.sh."],
      ],
    },
    {
      usage: "modify <module> [--environment ENV] [--force] [--no-snapshot] [--debug] [--silent]",
      name: "modify",
      options: [
        ["--environment ENV", "Target environment to modify."],
        ["--force", "Proceed despite warnings during the re-apply."],
        ["--no-snapshot", "Skip the pre-change VM snapshot."],
        ["--debug", "Verbose diagnostic output."],
        ["--silent", "Suppress non-essential output."],
      ],
    },
    {
      usage: "delete <module> [--archive|--remove] [--vmid ID] [--environment ENV] [--yes] [--force]",
      name: "delete",
      options: [
        ["--archive", "Archive the module config (default; mutually exclusive with --remove)."],
        ["--remove", "Fully remove the module config (mutually exclusive with --archive)."],
        ["--vmid ID", "Target a specific VM id."],
        ["--environment ENV", "Target environment to delete from."],
        ["--yes", "Skip the VM-destroy confirmation prompt, for automation (also -y)."],
        ["--force", "Proceed despite warnings; also implies --yes + --remove."],
      ],
    },
    {
      usage: "reconcile <module> [--apply] [--environment ENV] [--no-snapshot] [--no-services]",
      name: "reconcile",
      options: [
        ["--apply", "Converge the module's config → VM/service. Default is a read-only three-way (released/desired/running) drift INSPECT."],
        ["--environment ENV", "Target environment to reconcile."],
        ["--no-snapshot", "Skip any pre-change VM snapshot (--apply; leaf re-apply is idempotent)."],
        ["--no-services", "INSPECT only: skip the dependency-service drift check (declared firewall/NAT/discovery state), which is ON by default."],
      ],
    },
    {
      usage: "test <module> [--deep] [--vmid ID] [--zone0 ZONE]",
      name: "test",
      options: [
        ["--deep", "Run the deep/regression test suite, not just the smoke test."],
        ["--vmid ID", "Target a specific VM id."],
        ["--zone0 ZONE", "Override the primary network zone under test."],
      ],
    },
    {
      usage: "snapshot-vm <module> [--list|--cleanup N|--restore N]",
      name: "snapshot-vm",
      options: [
        ["--list", "List existing VM snapshots (default action is to create one)."],
        ["--cleanup N", "Prune snapshots, keeping the N most recent."],
        ["--restore N", "Restore the VM by rolling back N snapshot steps."],
      ],
    },
  ],
  common: [
    ["--config-dir DIR", "Config root (default: $TAPPAAS_CONFIG or /home/tappaas/config)."],
    ["--json", "Machine-readable output (list / show / validate)."],
  ],
  notes: [
    "The 'module' entity keyword is OPTIONAL (module is the only entity), so both\n" +
      "'module-manager list' and 'module-manager module list' work.",
    `Verbs map (ADR-007 verb alignment):
  add=install-module  modify=update-module  delete=delete-module
  test=test-module    validate=tier/source lint
  resolve=desired state (config + schema defaults), the one resolver (ADR-020)
  drift=that desired state vs the live guest, per service (ADR-020)
  reconcile=inspect drift (default) / --apply=leaf re-apply (was health show vm)
  list [--diff] reads config/*.json (+ live drift with --diff). snapshot-vm is special.`,
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

// ── option parsing ─────────────────────────────────────────────────────
interface Opts {
  configDir: string;
  json: boolean;
  diff: boolean;
  apply: boolean;
  // `drift --service <provider:service>`: ONE coordinate. Distinct from the
  // boolean --services/--no-services below, which toggle the dependency-service
  // CHECK on inspect — an unfortunate near-collision of names, kept because both
  // spellings are already established.
  service?: string;
  // Dependency-service drift check (#458). TRI-STATE: undefined = the verb's
  // default (on for `reconcile <module>`, off for the `list --diff` rollup),
  // true = --services, false = --no-services.
  services?: boolean;
  // lifecycle flags
  environment?: string;
  allowFork: boolean;
  force: boolean;
  reinstall: boolean;
  noSnapshot: boolean;
  debug: boolean;
  silent: boolean;
  yes: boolean;
  deep: boolean;
  vmid?: string;
  zone0?: string;
  archive: boolean;
  remove: boolean;
  // list --resolution: which of the three tracking paths locates each module (#460)
  resolution: boolean;
  // snapshot-vm sub-action
  snapList: boolean;
  snapCleanup?: number;
  snapRestore?: number;
  // positionals + unrecognised --field/value pairs (passthrough to add)
  rest: string[];
  passthrough: string[];
}

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    configDir: defaultConfigDir(),
    json: false,
    diff: false,
    apply: false,
    allowFork: false,
    force: false,
    reinstall: false,
    noSnapshot: false,
    debug: false,
    silent: false,
    yes: false,
    deep: false,
    archive: false,
    remove: false,
    resolution: false,
    snapList: false,
    rest: [],
    passthrough: [],
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = (): string => {
      const v = args[i + 1];
      if (v === undefined) die(`${a} requires an argument`);
      i++;
      return v;
    };
    if (a === "--config-dir") {
      o.configDir = next();
    } else if (a === "--environment" || a === "--variant") {
      if (a === "--variant") warn(`--variant is deprecated; treating as --environment (ADR-007 P5)`);
      o.environment = next();
    } else if (a === "--vmid") {
      o.vmid = next();
    } else if (a === "--zone0") {
      o.zone0 = next();
    } else if (a === "--cleanup") {
      o.snapCleanup = parseIntStrict(next(), "--cleanup");
    } else if (a === "--restore") {
      o.snapRestore = parseIntStrict(next(), "--restore");
    } else if (a === "--json") {
      o.json = true;
    } else if (a === "--diff") {
      o.diff = true;
    } else if (a === "--apply") {
      o.apply = true;
    } else if (a === "--allow-fork") {
      o.allowFork = true;
    } else if (a === "--force") {
      o.force = true;
    } else if (a === "--reinstall") {
      o.reinstall = true;
    } else if (a === "--no-snapshot") {
      o.noSnapshot = true;
    } else if (a === "--service") {
      o.service = next();
    } else if (a === "--services") {
      o.services = true;
    } else if (a === "--no-services") {
      o.services = false;
    } else if (a === "--debug") {
      o.debug = true;
    } else if (a === "--silent") {
      o.silent = true;
    } else if (a === "--yes" || a === "-y") {
      o.yes = true;
    } else if (a === "--deep") {
      o.deep = true;
    } else if (a === "--archive") {
      o.archive = true;
    } else if (a === "--remove") {
      o.remove = true;
    } else if (a === "--resolution") {
      o.resolution = true;
    } else if (a === "--list") {
      o.snapList = true;
    } else if (a.startsWith("--")) {
      // An unrecognised --<field>; for `add` these are JSON-field overrides that
      // pass straight through to install-module.sh / copy-update-json.sh. Capture
      // it AND its following value (when the next token is not another flag).
      o.passthrough.push(a);
      const v = args[i + 1];
      if (v !== undefined && !v.startsWith("-")) {
        o.passthrough.push(v);
        i++;
      }
    } else {
      o.rest.push(a);
    }
  }
  return o;
}

function parseIntStrict(s: string, flag: string): number {
  const n = parseInt(s, 10);
  if (!Number.isInteger(n)) die(`${flag} requires an integer (got '${s}')`);
  return n;
}

// list --resolution — which of the three INDEPENDENT tracking paths locates
// each deployed module's source directory (#460). Offline: config/*.json plus
// the repository catalogs, no cluster.
//
// site-fields.json described repositories[] as THE way modules are located,
// but install-module.sh takes the current directory first and records it as
// .location, so a module installed from an unregistered path is located by
// .location alone. A module reachable by neither used to be invisible until
// some operation finally needed its directory — this reports it up front, and
// exits non-zero so a caller can gate on it.
function cmdListResolution(opts: Opts): number {
  const mods = listModules(opts.configDir);
  const rows = mods.map((m) => classifyModuleResolution(opts.configDir, m.name));
  const unresolvable = rows.filter((r) => r.path === "unresolvable" || r.path === "broken-location");

  if (opts.json) {
    info(JSON.stringify({ modules: rows, unresolvable: unresolvable.map((r) => r.module) }, null, 2));
    return unresolvable.length > 0 ? 1 : 0;
  }

  if (rows.length === 0) {
    info(`(no deployed modules in ${opts.configDir})`);
    return 0;
  }

  const headers = ["NAME", "RESOLVES VIA", "TIER", "TIER SRC", "CATALOG REPO", "DIRECTORY"];
  const body = rows.map((r) => [
    r.module,
    r.path,
    r.tier ?? "-",
    r.tierSource ?? "-",
    r.catalogRepo ?? "-",
    r.dir ?? "-",
  ]);
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...body.map((row) => row[i].length)),
  );
  const line = (cells: string[]): string =>
    cells.map((c, i) => c.padEnd(widths[i])).join("  ").trimEnd();
  info(line(headers));
  info(line(widths.map((w) => "-".repeat(w))));
  for (const row of body) info(line(row));

  const counts = new Map<string, number>();
  for (const r of rows) counts.set(r.path, (counts.get(r.path) ?? 0) + 1);
  console.log("");
  info(
    [...counts.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([k, v]) => `${k}: ${v}`)
      .join("   "),
  );

  // Two distinct failures, reported separately: a recorded-but-gone directory
  // is a repairable checkout problem; "unresolvable" means no mechanism has
  // ever been able to find this module's source.
  const broken = rows.filter((r) => r.path === "broken-location");
  const none = rows.filter((r) => r.path === "unresolvable");
  if (broken.length > 0) {
    console.log("");
    warn(
      `${broken.length} module(s) record a .location that no longer exists: ` +
        broken.map((r) => `${r.module} (${r.dir})`).join(", "),
    );
    warn("The checkout moved or was removed — restore it, or re-install the module.");
  }
  if (none.length > 0) {
    console.log("");
    warn(
      `${none.length} module(s) cannot be located by any tracking path: ` +
        none.map((r) => r.module).join(", "),
    );
    warn(
      "No .location recorded and no repository catalog entry. Any operation needing " +
        "the source directory will fail at that point rather than here (#460).",
    );
  }
  return unresolvable.length > 0 ? 1 : 0;
}

// ── CONFIG-layer verbs (pure TS over config/*.json) ────────────────────
// The DEFAULT `list` is now a SUPERSET of the (removed) `health-manager list vm`
// (a live running-guest-vs-config overview) PLUS module-manager's own config
// columns. It merges config/*.json with the LIVE cluster (client.clusterResources
// — best-effort, [] when unreachable) into one table:
//   NAME  ENV  ZONE  NODE  VMID  RUN STATE  DEV STATUS
// where NODE/RUN STATE come from the live guest (matched by vmid) when the VM is
// running, and fall back to the config node / "-" otherwise. DEV STATUS is the
// module's maturity from its JSON (Development | Testing | Production). Proxmox
// TEMPLATES that are running-but-not-in-config are folded into the table with
// RUN STATE "template" (they are expected infra); genuine orphan VMs are flagged
// in a note below, as are CONFIGURED modules whose VM is not running. If the live
// query yields nothing it degrades to the CONFIG-ONLY table (RUN STATE "-") with a
// single warning, still exit 0.
function cmdList(opts: Opts, client: ModuleClient): number {
  if (opts.resolution) return cmdListResolution(opts);
  if (opts.diff) return cmdListDiff(opts, client);
  const mods = listModules(opts.configDir);

  // LIVE cluster state (best-effort). clusterResources() never throws — it
  // returns [] when the cluster is unreachable (e.g. a dev checkout).
  const guests = client.clusterResources();
  const live = guests.length > 0;
  const byVmid = new Map<number, (typeof guests)[number]>();
  for (const g of guests) byVmid.set(g.vmid, g);

  // Resolve, per config module, its live guest (by vmid) → RUN STATE + ACTUAL
  // node when running (else the config node / "-").
  const resolved = mods.map((m) => {
    const g = m.vmid != null ? byVmid.get(m.vmid) : undefined;
    const run = g ? (g.template ? "template" : g.status) : m.vmid != null && live ? "stopped" : "-";
    return { m, running: run, node: g ? g.node : m.node ?? "-" };
  });

  // Orphan guests = running guests whose vmid is in NO module config. Templates
  // are EXPECTED infrastructure → folded into the main table; the rest are
  // genuine anomalies → flagged in a note.
  const configVmids = new Set(mods.map((m) => m.vmid).filter((v): v is number => v != null));
  const orphanGuests = guests.filter((g) => !configVmids.has(g.vmid));
  const templateGuests = orphanGuests.filter((g) => g.template).sort((a, b) => a.vmid - b.vmid);
  const trueOrphans = orphanGuests.filter((g) => !g.template).sort((a, b) => a.vmid - b.vmid);

  // Configured modules (with a vmid) whose VM is not running.
  const notRunning = resolved.filter(
    (r) => r.m.vmid != null && live && !byVmid.has(r.m.vmid),
  );

  if (opts.json) {
    // Machine-readable: KEEP the existing summary fields (the cascade parses
    // these); ADDITIVELY surface the live running/actual-node + the orphans.
    const summary = resolved.map((r) => ({
      name: r.m.name,
      vmname: r.m.vmname ?? null,
      vmid: r.m.vmid ?? null,
      node: r.m.node ?? null,
      zone0: r.m.zone0 ?? null,
      tier: r.m.tier ?? null,
      status: r.m.status ?? null,
      environment: r.m.environment ?? null,
      // Additive live fields (null when the cluster query was unavailable).
      running: live ? r.running : null,
      actualNode: r.m.vmid != null && byVmid.has(r.m.vmid) ? r.node : null,
    }));
    const out: Record<string, unknown> = { modules: summary };
    if (live) {
      out.orphans = orphanGuests.map((g) => ({
        vmid: g.vmid, name: g.name, node: g.node, status: g.status, template: !!g.template,
      }));
    }
    // Back-compat: the top-level shape historically WAS the module array. Keep
    // that when there is no live data to add, so existing parsers don't break.
    info(JSON.stringify(live ? out : summary, null, 2));
    return 0;
  }

  if (mods.length === 0 && templateGuests.length === 0) {
    info(`(no deployed modules in ${opts.configDir})`);
    if (!live) info(`${YW}[Warning]${CL} live cluster query unavailable — showing config only`);
    return 0;
  }

  // Column-aligned table. Columns: NAME ENV ZONE NODE VMID RUN STATE DEV STATUS.
  const headers = ["NAME", "ENV", "ZONE", "NODE", "VMID", "RUN STATE", "DEV STATUS"];
  const modRows = resolved.map((r) => [
    r.m.name,
    r.m.environment ?? "-",
    r.m.zone0 ?? "-",
    r.node,
    r.m.vmid != null ? String(r.m.vmid) : "-",
    r.running,
    r.m.status ?? "-",
  ]);
  // Template guests fold in as rows (no config → env/zone/dev status "-").
  const tmplRows = templateGuests.map((g) => [g.name, "-", "-", g.node, String(g.vmid), "template", "-"]);
  const rows = [...modRows, ...tmplRows].sort((a, b) => a[0].localeCompare(b[0]));
  const w = headers.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i].length)));
  const fmt = (cells: string[]): string => cells.map((c, i) => c.padEnd(w[i])).join("  ").trimEnd();
  info(`${GN}${fmt(headers)}${CL}`);
  for (const r of rows) info(fmt(r));

  if (!live) {
    info(`${YW}[Warning]${CL} live cluster query unavailable — showing config only`);
    return 0;
  }

  // Configured-but-not-running note (one line per module).
  for (const r of notRunning) {
    info(`${YW}[Note]${CL} ${r.m.name} (vmid ${r.m.vmid}) is configured but not running`);
  }

  // Genuine orphans (non-template running VMs in no module config).
  if (trueOrphans.length > 0) {
    info("");
    info(`${YW}Unexpected VMs (running, not in any module config):${CL}`);
    for (const g of trueOrphans) info(`  ${g.vmid}  ${g.name}  ${g.node}  (${g.status})`);
  }
  return 0;
}

// list --diff — the per-module three-way (Released/Desired/Actual) drift rollup.
// Iterates every deployed module config and runs the same read-only inspect that
// `reconcile <module>` (no --apply) runs — the native TS src/inspect.ts (the
// Phase 7.3 port of the retired inspect-vm.sh) — printing its table per module
// (with a config-only fallback for non-VM modules). This is what used to be
// `health-manager list vm --diff`. Returns non-zero if ANY module's inspect
// exits non-zero (e.g. an unreachable node), so the rollup surfaces failures.
function cmdListDiff(opts: Opts, client: ModuleClient): number {
  const mods = listModules(opts.configDir);
  if (mods.length === 0) {
    info(`(no deployed modules in ${opts.configDir})`);
    return 0;
  }
  info(`${GN}Per-module three-way drift (Released[git] / Desired[~/config] / Actual[running VM]):${CL}`);
  // Dependency-service checks are OFF by default here: one firewall/API
  // round-trip per dependency per module does not belong in a fleet rollup. Say
  // so once, rather than letting every module's report look fully covered (#458).
  const checkServices = opts.services === true;
  if (!checkServices) {
    info(
      `${YW}(dependency-service state NOT checked — pass --services to include it, at one check per dependency per module)${CL}`,
    );
  }
  let worst = 0;
  for (const m of mods) {
    info("");
    info(`${GN}── ${m.name} ──${CL}`);
    const rc = client.inspect(m.name, { checkServices });
    if (rc !== 0) worst = rc;
  }
  return worst;
}

function cmdShow(opts: Opts): number {
  const name = opts.rest[0];
  if (!name) die("show: expected <module>");
  const m = loadModule(opts.configDir, name);
  if (!m) die(`module '${name}' not found in ${opts.configDir}`);
  // The full deployed config IS the JSON, so --json and the human view share the
  // same (pretty-printed, authoritative, machine-parseable) body.
  info(JSON.stringify(m.raw, null, 2));
  return 0;
}

// resolve — the DESIRED-state document (ADR-020 D1). `show` prints the deployed
// config verbatim; `resolve` prints what that config MEANS once the schema
// defaults a module does not declare are filled in, which is the value the
// converge will actually use. The difference between the two is exactly the
// class of bug #550 was: a field that reads "-" in the config but converges to
// 'host' on the cluster.
function cmdResolveVerb(opts: Opts): number {
  const name = opts.rest[0];
  if (!name) die("resolve: expected <module>");
  return cmdResolve(name, { configDir: opts.configDir, json: opts.json });
}

// drift — DESIRED (resolve) vs ACTUAL (the provider's report-service.sh), diffed
// by the one differ (ADR-020 D7). `reconcile <module>` renders a three-way
// report for a human; this renders the two-way record a SERVICE applies, and
// with --service --json it IS that record: `update-service.sh --apply-drift`
// reads exactly this. Same computation either way — that is the point.
function cmdDriftVerb(opts: Opts): number {
  const name = opts.rest[0];
  if (!name) die("drift: expected <module>");
  return cmdDrift(name, { configDir: opts.configDir, json: opts.json, service: opts.service });
}

// The repositories site.json declares, for validateSourceLocation. Returns []
// when site.json is absent or malformed: the check then reports nothing rather
// than reporting everything, because "no declarations" is not evidence that a
// module's source is undeclared.
function readDeclaredRepositories(
  configDir: string,
): { name: string; path: string; branch: string }[] {
  try {
    const raw = JSON.parse(readFileSync(join(configDir, "site.json"), "utf8")) as {
      repositories?: { name?: string; path?: string; branch?: string }[];
    };
    return (raw.repositories ?? [])
      .filter((r) => typeof r.path === "string" && r.path !== "")
      .map((r) => ({ name: r.name ?? "", path: r.path as string, branch: r.branch ?? "" }));
  } catch {
    return [];
  }
}

function cmdValidate(opts: Opts): number {
  const name = opts.rest[0];
  let mods;
  if (name) {
    const m = loadModule(opts.configDir, name);
    if (!m) die(`module '${name}' not found in ${opts.configDir}`);
    mods = [m];
  } else {
    mods = listModules(opts.configDir);
  }
  // realServiceFs supplies the dependsOn reference-integrity probe (#495
  // follow-up): reconcile/modify skip an unservable dependency silently, so
  // validate is the one place that reports it.
  const report = validateModules(mods, {
    allowFork: opts.allowFork,
    fs: realServiceFs(opts.configDir),
    repos: readDeclaredRepositories(opts.configDir),
    // module-fields.json drives the ADR-020 field-manifest lint: the schema's
    // `usedBy` is what says which fields a provider service owns, so it is what
    // manifest coverage is measured against.
    schema: loadModuleFields(opts.configDir),
  });
  if (opts.json) {
    info(JSON.stringify(report, null, 2));
    return report.errors > 0 ? 1 : 0;
  }
  for (const f of report.findings) {
    if (f.severity === "error") {
      console.error(`${RD}[Error]${CL} ${f.module}: ${f.message}`);
    } else {
      warn(`${f.module}: ${f.message}`);
    }
  }
  if (report.errors > 0) {
    die(`validate FAILED: ${report.errors} error(s), ${report.warnings} warning(s) across ${mods.length} module(s)`);
  }
  info(`${GN}validate ok${CL} (${mods.length} module(s), ${report.warnings} warning(s))`);
  return 0;
}

// ── LIFECYCLE verbs (delegate to bash via the ModuleClient) ────────────
function cmdAdd(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("add: expected <module>");
  const a: AddOptions = {
    environment: opts.environment,
    allowFork: opts.allowFork,
    force: opts.force,
    reinstall: opts.reinstall,
    passthrough: addFieldOverrides(opts),
  };
  return client.add(module, a);
}

// `add` takes `--<field> <value>` JSON overrides, which parseArgs collects into
// opts.passthrough for every flag it does not recognise. Two schema fields are
// ALSO recognised flags — `--vmid` and `--zone0`, both defined for `test`
// (and `--vmid` for `delete`) — so the parser consumed them and the override was
// silently dropped: no error, the install simply used the authored value. That
// cost two failed nextcloud installs before it was spotted (#495 follow-up).
// Of the 71 fields in module-fields.json these are the only two affected;
// `--environment`/`--variant` also shadow fields but are re-forwarded explicitly
// by client.add(), so they already reach install-module.sh.
//
// NOTE: this special-cases the two known collisions. A future option whose name
// matches a schema field would reintroduce the same silent drop — parsing the
// option set per-verb would fix the whole class.
function addFieldOverrides(opts: Opts): string[] {
  const passthrough = [...opts.passthrough];
  if (opts.vmid !== undefined) passthrough.push("--vmid", opts.vmid);
  if (opts.zone0 !== undefined) passthrough.push("--zone0", opts.zone0);
  return passthrough;
}

function cmdModify(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("modify: expected <module>");
  const m: ModifyOptions = {
    environment: opts.environment,
    force: opts.force,
    noSnapshot: opts.noSnapshot,
    debug: opts.debug,
    silent: opts.silent,
  };
  return client.modify(module, m);
}

function cmdDelete(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("delete: expected <module>");
  if (opts.archive && opts.remove) die("delete: --archive and --remove are mutually exclusive");
  const d: DeleteOptions = {
    environment: opts.environment,
    mode: opts.remove ? "remove" : opts.archive ? "archive" : undefined,
    vmid: opts.vmid,
    yes: opts.yes,
    force: opts.force,
  };
  return client.delete(module, d);
}

function cmdTest(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("test: expected <module>");
  const t: TestOptions = { deep: opts.deep, vmid: opts.vmid, zone0: opts.zone0 };
  return client.test(module, t);
}

// reconcile — DEFAULT (no --apply) is a READ-ONLY three-way drift INSPECT:
// Released[git/source] / Desired[~/config] / Actual[running VM], PLUS the state
// the module's dependsOn providers hold outside the VM (firewall/NAT/discovery),
// checked via each provider's read-only test-service.sh (#458; --no-services
// opts out). This is the inspect that used to live in `health-manager show vm
// <module>` (and in the retired inspect-vm.sh; now native TS in src/inspect.ts,
// Phase 7.3); for a non-VM module (no vmid) the field diff falls back to
// config-only Released-vs-Desired (there is no running VM) and the
// dependency-service section carries the substance. Detected drift still exits
// 0 — a check that could not RUN exits 1.
//
// WITH --apply it is the LEAF re-apply (current config → VM/service). Per ADR-007
// that is distinct from `modify`: reconcile re-applies the EXISTING config
// (idempotent converge), while modify CHANGES the config first then applies. It
// is the leaf the `reconcile --deep` cascade (site → environment → module)
// depends on, so it must be idempotent.
//
// The converge is native TS (src/reconcile.ts, the Phase 7.3 port of the retired
// reconcile-module.sh) — a purpose-built lighter converge that re-runs the
// module's dependency *-service.sh applies + the module's own
// update.sh/install.sh ONLY: NO snapshot, NO pre/post tests, NO 3-way merge, NO
// updateTime bump. (update-module.sh / `module modify` does all of those.)
function cmdReconcile(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("reconcile: expected <module>");
  if (!opts.apply) {
    // Read-only three-way drift report (inspect-vm.sh). No config change. The
    // dependency-service check is ON here — one explicit module, and without it
    // a policy-only module's report covers almost nothing (#458). --no-services
    // opts out (what the fleet rollup and the --deep preview cascade pass).
    return client.inspect(module, { checkServices: opts.services !== false });
  }
  const r: ReconcileOptions = {
    environment: opts.environment,
    debug: opts.debug,
    silent: opts.silent,
  };
  return client.reconcile(module, r);
}

function cmdSnapshot(opts: Opts, client: ModuleClient): number {
  const module = opts.rest[0];
  if (!module) die("snapshot-vm: expected <module>");
  let action: SnapshotAction;
  if (opts.snapList) {
    action = { kind: "list" };
  } else if (opts.snapCleanup !== undefined) {
    action = { kind: "cleanup", keep: opts.snapCleanup };
  } else if (opts.snapRestore !== undefined) {
    action = { kind: "restore", steps: opts.snapRestore };
  } else {
    action = { kind: "create" };
  }
  return client.snapshot(module, action);
}

// ── dispatch ───────────────────────────────────────────────────────────
// Entity-first form: `module-manager module <verb> ...`. The `module` entity
// keyword is optional (it is the only entity) so `module-manager list` also
// works — matching how people-manager/network-manager keep the common verbs
// reachable.
function dispatch(verb: string, opts: Opts, client: ModuleClient): number {
  switch (verb) {
    case "list":
      return cmdList(opts, client);
    case "show":
      return cmdShow(opts);
    case "resolve":
      return cmdResolveVerb(opts);
    case "drift":
      return cmdDriftVerb(opts);
    case "validate":
      return cmdValidate(opts);
    case "add":
      return cmdAdd(opts, client);
    case "modify":
      return cmdModify(opts, client);
    case "delete":
      return cmdDelete(opts, client);
    case "reconcile":
      return cmdReconcile(opts, client);
    case "test":
      return cmdTest(opts, client);
    case "snapshot-vm":
      return cmdSnapshot(opts, client);
    default:
      usage();
      die(`Unknown verb: ${verb}`);
  }
}

export function run(argv: string[], client: ModuleClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  // Allow an optional leading `module` entity keyword.
  let rest = argv;
  if (rest[0] === "module") rest = rest.slice(1);
  if (rest.length === 0) {
    usage();
    return 0;
  }
  const verb = rest[0];
  // #534: a help request must NEVER mutate state, and must be honoured in ANY
  // flag position. The argv[0] check above only catches a LEADING flag; placed
  // after a verb (`modify <module> --help`) the flag used to fall through to
  // parseOpts, which drops -h/--help into passthrough (or a positional for -h),
  // and the verb then ran as a real write. Intercept it here — BEFORE
  // preflightGuard and dispatch — and print that verb's usage. A bare help
  // token (e.g. `module --help`) falls back to the full help via renderVerbHelp.
  if (rest.some((a) => a === "-h" || a === "--help")) {
    info(renderVerbHelp(HELP, verb));
    return 0;
  }
  // guarded() maps THROWN errors the standard way (DieError → 1, already
  // printed; any other Error → a clean `[Error] <msg>` + 1). Child exit codes
  // are RETURNED by dispatch(), not thrown, so they propagate unchanged.
  return guarded(() => {
    preflightGuard(); // #533: refuse root; self-heal config/repo ownership
    const opts = parseOpts(rest.slice(1));
    return dispatch(verb, opts, client);
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  process.exit(run(process.argv.slice(2), new CliModuleClient()));
}

// Re-export for tests.
export { warn };
