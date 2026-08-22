// network-manager — TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008).
//
// The single FRONT DOOR for the network. Owns zones.json (CRUD + delta) and
// reconciles all four planes by calling the plane-controller bins (opnsense via
// zone-manager, proxmox via proxmox-manager, switch via switch-controller, ap
// via ap-manager). It does NOT reimplement any plane's logic — it is a thin
// orchestration boundary, exactly as people-manager shells out to
// authentik-manager. This is `zone-reconcile` + `zone-controller.sh` ported to
// TS, with the #335/#372/#373 fix: it calls the on-PATH bins (NOT the stale
// firewall/scripts/ paths) and ALWAYS reconciles the switch plane on add/delete.
//
// Commands (the `zone` keyword is an optional, legacy prefix — `add` == `zone add`):
//   network-manager list
//   network-manager exists <name>
//   network-manager show <name>            (alias: get)
//   network-manager add <name> [--from-zone S] [--type T --typeId N]
//                              [--vlan V] [--variant X] [--no-activate] [--check]
//   network-manager delete <name> [--check]
//   network-manager enable|disable|manual <name> [--force]   (was zone-state.sh)
//   network-manager reconcile [--apply] [--only <plane>]
//   network-manager init [<profile>] --name <N> [--from <tpl>] [--out <f>] [--force]
//   network-manager retire [--apply]
//   network-manager merge [--diff] [--config-dir <dir>] [--template <tpl>]
//   network-manager distribute [--zones <file>] [--dry-run]
//
// Exit codes: ok=0, error/drift-after-apply=1.

import { dirname, join } from "path";
import { CliPlaneClient } from "./planes";
import { reconcileAll } from "./reconcile";
import { Plane, PLANE_ORDER, PlaneClient, ReconcileReport } from "./types";
import {
  changeZoneState,
  defaultConfigDir,
  defaultOrigFile,
  defaultRenameFile,
  defaultTemplateFile,
  defaultZonesFile,
  getZone,
  listZoneNames,
  loadZones,
  readSiteName,
  saveZones,
  zoneExists,
} from "./zones";
import { addZone, deleteZone } from "./zonelifecycle";
import { existsSync } from "fs";
import { initProfile, parseTemplate, profileNames, renameTemplateFile, zonesInit } from "./zonesinit";
import { RETIRED_ZONES, retireZones, saveRetired } from "./retire";
import { zonesCheck, occupiedZones } from "./zonescheck";
import { archetypeByName, archetypeNames, zoneTier } from "./archetypes";
import {
  SERVES_ALLOWED_TYPES,
  effectiveFileFor,
  environmentZone,
  refreshEffective,
} from "./serves";
import { distributeZones, shouldAutoDistribute } from "./distribute";
import { runZonesMerge } from "./zonesmerge";
import { HelpSpec, renderHelp } from "../../../lib/ts/src/help";
import { CL, DieError, GN, RD, YW, die, guarded, info, warn } from "../../../lib/ts/src/cli";
import { writeJsonAtomic } from "../../../lib/ts/src/config-io";

const VERSION = "0.1.0";

const HELP: HelpSpec = {
  name: "network-manager",
  version: VERSION,
  tagline: "TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008)",
  verbs: [
    {
      usage: "list [--state S] [--type T] [--tier N] [--json]",
      name: "list (filtered zone view — ADR-014 D4)",
      options: [
        ["--state <S>", "Active | Inactive | Manual | Mandatory | Disabled"],
        ["--type <T>", "Management | Service | Client | IoT | Guest | DMZ | Overlay | WAN"],
        ["--tier <N>", "trust rank 0-6 (see ZONES.md)"],
        ["--json", "emit the matching zone names as a JSON array"],
      ],
      note:
        "`--type Client|IoT` adds tier + serves columns. Enabling/disabling a zone\n" +
        "is `enable|disable|manual <name>` — `list --state Inactive` is how you find\n" +
        "the candidates.",
    },
    { usage: "exists <name>" },
    { usage: "show <name> [--json]", note: "(alias: get)" },
    {
      usage: "add <name> [options]",
      name: "add",
      options: [
        ["--archetype <A>", "tier-correct preset (ADR-014 D5) — one of:\n" +
          "                control, service, trusted-client, guest, dmz,\n" +
          "                iot-local, iot-cloud, iot-cams, iot-untrust.\n" +
          "                Stamps type/typeId/tier/isolated + the access-to seed."],
        ["--serves <env>", "bind the new Client/IoT/Guest zone to an environment"],
        ["--from-zone <src>", "inherit type/typeId/bridge/access-to/pinhole from <src>"],
        ["--type <T>", "zone type (default: Service)"],
        ["--typeId <N>", "numeric type band (default: 2)"],
        ["--vlan <tag>", "explicit VLAN tag (else auto-allocated 60-99 in band)"],
        ["--variant <name>", "tag the zone with this variant (metadata)"],
        ["--no-activate", "author zones.json only; skip the all-plane reconcile"],
        ["--check", "dry-run: show actions, mutate nothing"],
      ],
    },
    { usage: "delete <name> [--check]" },
    {
      usage: "bind <zone> --environment <env> | --unbind",
      name: "bind (link a Client/IoT/Guest zone to an environment — ADR-014 D2)",
      options: [
        ["--environment <env>", "the environment whose service zone this zone consumes"],
        ["--unbind", "clear the link"],
      ],
      note:
        "Sets the zone's `serves` field. The access-to / pinhole-allowed-from edges\n" +
        "are DERIVED from it on every reconcile (into zones.effective.json), so they\n" +
        "survive the install-time srv→<environment> rename — this is what closes #424.\n" +
        "zones.json itself stays purely authored.",
    },
    {
      usage: "enable|disable|manual <name> [--force]",
      name:
        "enable|disable|manual (atomic zone state change; was zone-state.sh —\n" +
        "enable→Active, disable→Inactive, manual→Manual; mutates zones.json only,\n" +
        "apply with `network-manager reconcile --apply` when ready)",
      options: [
        ["--force", 'allow leaving the "Mandatory" state (refused by default)'],
      ],
    },
    {
      usage: "reconcile [--apply] [--only <plane>]",
      name: "reconcile",
      options: [
        ["--apply", "converge all planes (default is dry-run / report only)"],
        ["--only <plane>", "one plane: opnsense | proxmox | switch | ap"],
      ],
    },
    {
      usage: "init [<profile>] --name <N> [--from <tpl>] [--out <f>] [--force]",
      note: "(alias: zones-init)",
      name: "init (install-time profile bundles; offline, additive, idempotent)",
      options: [
        ["<profile>", "core (default) — mgmt, wan, overlays, <N>, home, guest, dmz\n" +
          "                iot          — iotLocal, iotCloud, iotCams, iotUntrust\n" +
          "                Profiles compose: `init core` then later `init iot`."],
        ["--name <N>", "TAPPaaS system name; renames srv→<N> (home/guest are kept\n                as site-local role zones) and parameterises the distributed template"],
        ["--from <tpl>", "source template (default: zones.json shipped with the bin)"],
        ["--out <f>", "output file (default: $TAPPAAS_CONFIG/zones.json)"],
        ["--force", "re-stamp this profile's zones from the template (default:\n                existing zones always win — a re-run is non-destructive, #427)"],
      ],
    },
    {
      usage: "retire [--apply]",
      name: "retire (remove zones a release stopped shipping — ADR-014 D7)",
      options: [
        ["--apply", "commit (default is a dry-run listing)"],
      ],
      note:
        "Removes " + RETIRED_ZONES.join(", ") + " —\n" +
        "but ONLY where the zone is not Active/Mandatory/Manual AND hosts no\n" +
        "installed module. Anything else is kept and reported. References to a\n" +
        "retired zone are stripped from every other zone. `work` and `srv` are\n" +
        "never retired.",
    },
    {
      usage: "merge [--diff] [--config-dir <dir>] [--template <tpl>]",
      note: "(alias: zones-merge)",
      name:
        "merge (rename-aware 3-way reconciliation; ADR-007 Design A;\n" +
        "replaces apply-zones-merge.sh — re-bases the repo template into THIS install's\n" +
        "renamed namespace, then 3-way-merges zones.json vs zones.json.orig vs\n" +
        "zones.rename.json; does NOT distribute by itself)",
      options: [
        ["--config-dir <dir>", "config dir holding site.json + the three zones files\n                      (default $TAPPAAS_CONFIG)"],
        ["--template <tpl>", "repo zones.json template (default: shipped template)"],
        ["--from <tpl>", "alias for --template"],
        ["--diff", "show what would change; write nothing"],
      ],
    },
    {
      usage: "validate [--zones <file>] [--config-dir <dir>] [--strict] [--effective]",
      note: "(alias: zones-check)",
      name: "zones-check (offline consistency audit; read-only; run at update)",
      options: [
        ["--zones <file>", "zones.json to check (default $TAPPAAS_CONFIG/zones.json)"],
        ["--config-dir <dir>", "installed module configs to cross-check (default $TAPPAAS_CONFIG)"],
        ["--strict", "promote warnings to errors"],
        ["--effective", "audit the RENDERED graph (serves links resolved) — the\n                      document the planes actually receive, not the authored file"],
      ],
    },
    {
      usage: "distribute [--zones <file>] [--dry-run]",
      note: "(alias: zones-distribute)",
      name:
        "distribute (push the live zones.json to every Proxmox node so\n" +
        "node-side tooling can resolve a zone's VLAN — N3; runs automatically after a\n" +
        "live zones.json write, this is the manual entry point)",
      options: [
        ["--zones <file>", "zones.json to push (default $TAPPAAS_CONFIG/zones.json)"],
        ["--dry-run", "list the node targets that WOULD receive it; no scp"],
        ["--no-distribute", "(on zone add/delete/init) skip the auto-push"],
      ],
    },
  ],
  common: [["--zones-file <f>", "default $TAPPAAS_CONFIG/zones.json"]],
  notes: [
    "The `zone` keyword is an optional, legacy prefix — `add` and `zone add` are equivalent.",
    "Exit code is non-zero if any plane reports an error (or proxmox still drifts\nafter --apply).",
  ],
};

function usage(): void {
  info(renderHelp(HELP));
}

interface Opts {
  zonesFile: string;
  rest: string[];
  apply: boolean;
  only?: Plane;
  check: boolean;
  noActivate: boolean;
  fromZone?: string;
  type?: string;
  typeId?: string;
  vlan?: number;
  variant?: string;
  // zones-init
  name?: string;
  from?: string;
  out?: string;
  force: boolean;
  // zones-check
  configDir: string;
  strict: boolean;
  // zones-distribute + auto-distribute opt-out
  dryRun: boolean;
  noDistribute: boolean;
  // zones-merge
  diff: boolean;
  // read commands: structured vs human output
  json: boolean;
  // list filters (ADR-014 D4). `type` is shared with `add` — harmless, the two
  // verbs never run together.
  state?: string;
  tier?: number;
  // validate --effective
  effective: boolean;
  // bind
  environment?: string;
  unbind: boolean;
  // add --archetype / --serves (ADR-014 D5 / D2)
  archetype?: string;
  serves?: string;
}

function isPlane(s: string): s is Plane {
  return (PLANE_ORDER as string[]).includes(s);
}

function parseOpts(args: string[]): Opts {
  const o: Opts = {
    zonesFile: defaultZonesFile(),
    rest: [],
    apply: false,
    check: false,
    noActivate: false,
    force: false,
    configDir: defaultConfigDir(),
    strict: false,
    dryRun: false,
    noDistribute: false,
    diff: false,
    json: false,
    unbind: false,
    effective: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = (): string => {
      const v = args[i + 1];
      if (v === undefined) die(`${a} requires an argument`);
      i++;
      return v;
    };
    switch (a) {
      case "--zones-file":
      case "--zones":
        o.zonesFile = next();
        break;
      case "--config-dir":
        o.configDir = next();
        break;
      case "--strict":
        o.strict = true;
        break;
      case "--effective":
        o.effective = true;
        break;
      case "--apply":
        o.apply = true;
        break;
      case "--only": {
        const p = next();
        if (!isPlane(p)) die("--only must be one of: opnsense, proxmox, switch, ap");
        o.only = p;
        break;
      }
      case "--check":
        o.check = true;
        break;
      case "--no-activate":
        o.noActivate = true;
        break;
      case "--from-zone":
        o.fromZone = next();
        break;
      case "--type":
        o.type = next();
        break;
      case "--typeId":
        o.typeId = next();
        break;
      case "--vlan": {
        const v = parseInt(next(), 10);
        if (!Number.isInteger(v)) die("--vlan must be numeric");
        o.vlan = v;
        break;
      }
      case "--variant":
        o.variant = next();
        break;
      case "--state":
        o.state = next();
        break;
      case "--environment":
      case "--env":
        o.environment = next();
        break;
      case "--unbind":
        o.unbind = true;
        break;
      case "--archetype":
        o.archetype = next();
        break;
      case "--serves":
        o.serves = next();
        break;
      case "--tier": {
        const t = parseInt(next(), 10);
        if (!Number.isInteger(t)) die("--tier must be numeric");
        o.tier = t;
        break;
      }
      case "--name":
        o.name = next();
        break;
      case "--from":
      case "--template":
        o.from = next();
        break;
      case "--diff":
        o.diff = true;
        break;
      case "--json":
        o.json = true;
        break;
      case "--out":
        o.out = next();
        break;
      case "--force":
        o.force = true;
        break;
      case "--dry-run":
        o.dryRun = true;
        break;
      case "--no-distribute":
        o.noDistribute = true;
        break;
      // accepted-for-symmetry no-arg flags from zone-controller.sh:
      case "--no-ssl-verify":
        break;
      default:
        o.rest.push(a);
    }
  }
  return o;
}

// ── zone read commands ────────────────────────────────────────────────
function cmdZone(sub: string, opts: Opts): void {
  // Read verbs: list / show (alias get) / exists. Mutating verbs (add / delete)
  // are dispatched top-level. There is intentionally no free-form `modify` — a
  // zone's state + access-to graph are governed by the lifecycle (add/delete)
  // and the install/update transforms (init, merge) with their invariants (mgmt
  // access, occupancy guard); a naive field-editor would bypass them. (ADR-007 #5.)

  if (sub === "list") {
    const doc = loadZones(opts.zonesFile);
    // ADR-014 D4: filter the existing view. The capability to enable/disable a
    // zone already existed; what was missing was a way to SEE which zones are
    // defined-but-off, or which client zones belong to which environment.
    const names = listZoneNames(doc).filter((n) => {
      const z = getZone(doc, n);
      if (opts.state !== undefined && String(z?.state ?? "") !== opts.state) return false;
      if (opts.type !== undefined && String(z?.type ?? "") !== opts.type) return false;
      if (opts.tier !== undefined && zoneTier(z?.tier) !== opts.tier) return false;
      return true;
    });
    // Default is human-readable (name + state + vlan); --json emits the name
    // array (was always-JSON — the flag is now meaningful, matching site/people).
    if (opts.json) {
      info(JSON.stringify(names, null, 2));
      return;
    }
    if (names.length === 0) {
      const filtered = opts.state !== undefined || opts.type !== undefined || opts.tier !== undefined;
      info(filtered ? "(no zones match the filter)" : "(no zones)");
      return;
    }
    // Client/IoT rows answer "which environment does this belong to?", so show
    // tier + serves for them (ADR-014 D4). Also shown whenever --tier was used.
    const showTrust =
      opts.tier !== undefined || (opts.type !== undefined && ["Client", "IoT", "Guest"].includes(opts.type));
    for (const n of names) {
      const z = getZone(doc, n);
      const state = z?.state ?? "";
      const vlan = typeof z?.vlantag === "number" && z.vlantag > 0 ? `vlan ${z.vlantag}` : "";
      let line = `${n.padEnd(16)} ${String(state).padEnd(9)} ${vlan.padEnd(9)}`;
      if (showTrust) {
        const t = zoneTier(z?.tier);
        const iso = z?.isolated === true ? " isolated" : "";
        line += ` ${(t === undefined ? "tier -" : `tier ${t}`).padEnd(7)}` +
          ` ${(typeof z?.serves === "string" && z.serves ? `serves ${z.serves}` : "").padEnd(18)}${iso}`;
      }
      info(line.trimEnd());
    }
    return;
  }
  if (sub === "exists") {
    const name = opts.rest[0];
    if (!name) die("exists: expected <name>");
    const doc = loadZones(opts.zonesFile);
    const present = zoneExists(doc, name);
    info(String(present));
    if (!present) throw new DieError(`zone '${name}' not found`);
    return;
  }
  if (sub === "show" || sub === "get") {
    const name = opts.rest[0];
    if (!name) die(`${sub}: expected <name>`);
    const doc = loadZones(opts.zonesFile);
    const z = getZone(doc, name);
    if (!z) die(`zone '${name}' not found in ${opts.zonesFile}`);
    const out: Record<string, unknown> = { ...z };
    delete out.name;
    if (opts.json) {
      info(JSON.stringify(out, null, 2));
    } else {
      info(`${GN}zone ${name}${CL}`);
      for (const [k, v] of Object.entries(out)) {
        const s = Array.isArray(v)
          ? v.length ? v.join(", ") : "(none)"
          : v === "" || v == null ? "(unset)" : String(v);
        info(`  ${k}: ${s}`);
      }
    }
    return;
  }
  die(`${sub}: unknown subcommand`);
}

function cmdZoneAdd(opts: Opts, client: PlaneClient = new CliPlaneClient()): void {
  const name = opts.rest[0];
  if (!name) die("add: expected <name>");

  // ADR-014 D5: --archetype is the high-level path; --type/--typeId/--from-zone
  // are the low-level escapes. Mixing them is ambiguous about which wins, so
  // refuse rather than silently preferring one.
  if (opts.archetype) {
    const a = archetypeByName(opts.archetype);
    if (!a) {
      die(`add: unknown archetype '${opts.archetype}' (known: ${archetypeNames().join(", ")})`);
    }
    const clash = [
      opts.fromZone ? "--from-zone" : "",
      opts.type ? "--type" : "",
      opts.typeId ? "--typeId" : "",
    ].filter(Boolean);
    if (clash.length > 0) {
      die(
        `add: --archetype cannot be combined with ${clash.join(", ")} — the archetype ` +
          `already defines type/typeId/tier/isolated. Drop the archetype to author by hand.`,
      );
    }
    if (opts.serves && !SERVES_ALLOWED_TYPES.has((a as { type: string }).type)) {
      die(
        `add: --serves is only meaningful for a Client, IoT or Guest zone; ` +
          `archetype '${opts.archetype}' creates a ${(a as { type: string }).type} zone.`,
      );
    }
  } else if (opts.serves) {
    die("add: --serves requires --archetype (or bind the zone afterwards with `bind`)");
  }
  if (opts.serves) {
    const svc = environmentZone(dirname(opts.zonesFile), opts.serves);
    if (svc === undefined) {
      die(`add: environment '${opts.serves}' has no readable environments/${opts.serves}.json with a '.network.zone'`);
    }
  }

  const dtag = opts.check ? " [dry-run]" : "";
  const via = opts.archetype
    ? ` (archetype ${opts.archetype})`
    : opts.fromZone
      ? ` (from ${opts.fromZone})`
      : "";
  info(`zone-add '${name}'${via}${dtag}`);
  const res = addZone(client, opts.zonesFile, name, {
    fromZone: opts.fromZone,
    type: opts.type,
    typeId: opts.typeId,
    vlan: opts.vlan,
    variant: opts.variant,
    archetype: opts.archetype,
    serves: opts.serves,
    dryRun: opts.check,
    noActivate: opts.noActivate,
    noDistribute: opts.noDistribute,
  });
  if (res.dryRun) {
    info(`  [dry-run] would author zone '${name}' (vlan ${res.vlantag}) + reconcile all planes`);
    info(name);
    return;
  }
  info(`  ${GN}✓${CL} authored zone '${name}' (vlan ${res.vlantag})`);
  if (opts.noActivate) {
    info(`Zone '${name}' authored (activation skipped: --no-activate)`);
    info(name);
    return;
  }
  printReport(res.report);
  info(name);
  if (res.report.failed.length > 0) {
    throw new DieError(`planes not in sync: ${res.report.failed.join(", ")}`);
  }
}

function cmdZoneDelete(opts: Opts, client: PlaneClient = new CliPlaneClient()): void {
  const name = opts.rest[0];
  if (!name) die("delete: expected <name>");
  const dtag = opts.check ? " [dry-run]" : "";
  info(`zone-delete '${name}'${dtag}`);
  const res = deleteZone(client, opts.zonesFile, name, {
    dryRun: opts.check,
    noDistribute: opts.noDistribute,
  });
  if (res.dryRun) {
    info(`  [dry-run] would disable + reconcile all planes, then delete '${name}' (vlan ${res.vlantag})`);
    return;
  }
  printReport(res.report);
  info(`  ${GN}✓${CL} zone '${name}' deleted`);
  if (res.report.failed.length > 0) {
    throw new DieError(`planes not in sync: ${res.report.failed.join(", ")}`);
  }
}

// ── zone state verbs (enable/disable/manual — was zone-state.sh, #209) ─
// Atomically flip a zone's `state` in zones.json with the transition guards
// (unknown zone; leaving "Mandatory" needs --force). Deliberately does NOT
// reconcile the planes — the operator applies when ready (same contract as
// zone-state.sh, which printed the zone-manager command instead of running it).
function cmdZoneState(verb: string, opts: Opts): void {
  const name = opts.rest[0];
  if (!name) die(`${verb}: expected <zone-name>`);
  const doc = loadZones(opts.zonesFile);
  const res = changeZoneState(doc, name, verb, opts.force);
  if (!res.changed) {
    info(`${name}: state already ${res.to} — no change`);
    return;
  }
  saveZones(opts.zonesFile, doc);
  info(`${name}: ${res.from} → ${GN}${res.to}${CL}`);
  info("");
  info("  To apply on the planes, run:");
  info(`    network-manager reconcile --apply`);
}

// ── bind / unbind (ADR-014 D2) ─────────────────────────────────────────
// Authors the `serves` link on a Client/IoT/Guest zone. Deliberately does NOT
// reconcile: like enable/disable, it mutates zones.json and tells the operator
// how to apply. The effective document IS re-rendered so `show`/`validate` and
// any module install see the new resolution immediately.
function cmdBind(opts: Opts): void {
  const name = opts.rest[0];
  if (!name) die("bind: expected <zone> --environment <env> | --unbind");
  if (!opts.unbind && !opts.environment) {
    die("bind: expected --environment <env> (or --unbind to clear the link)");
  }
  if (opts.unbind && opts.environment) {
    die("bind: --environment and --unbind are mutually exclusive");
  }

  const doc = loadZones(opts.zonesFile);
  const z = getZone(doc, name);
  if (!z) die(`bind: zone '${name}' not found in ${opts.zonesFile}`);
  const type = typeof z.type === "string" ? z.type : "";
  if (!SERVES_ALLOWED_TYPES.has(type)) {
    die(
      `bind: zone '${name}' is type ${type || "(unset)"} — only Client, IoT and Guest ` +
        `zones consume an environment. A Service zone IS an environment's zone; ` +
        `bind its clients to the environment instead.`,
    );
  }

  const configDir = dirname(opts.zonesFile);
  const before = typeof z.serves === "string" ? z.serves : "";

  if (opts.unbind) {
    if (!before) {
      info(`${name}: no 'serves' link — no change`);
      return;
    }
    delete z.serves;
    const rawZone = doc.raw[name] as Record<string, unknown>;
    delete rawZone.serves;
    saveZones(opts.zonesFile, doc);
    info(`${name}: serves '${before}' → ${GN}(cleared)${CL}`);
  } else {
    const env = opts.environment as string;
    // Resolve up front so a typo is caught here, not three commands later.
    const svc = environmentZone(configDir, env);
    if (svc === undefined) {
      die(
        `bind: environment '${env}' has no readable ${join(configDir, "environments", `${env}.json`)} ` +
          `with a '.network.zone' — create it first (\`environment-manager add ${env}\`).`,
      );
    }
    if (!zoneExists(doc, svc)) {
      die(`bind: environment '${env}' names service zone '${svc}', which is not defined in zones.json`);
    }
    if (before === env) {
      info(`${name}: already serves '${env}' — no change`);
      return;
    }
    z.serves = env;
    (doc.raw[name] as Record<string, unknown>).serves = env;
    saveZones(opts.zonesFile, doc);
    info(`${name}: serves ${before ? `'${before}' → ` : ""}${GN}'${env}'${CL} (service zone '${svc}')`);
  }

  // Re-render and show what the link derives, so the operator sees the effect
  // rather than having to reason about it.
  const eff = refreshEffective(opts.zonesFile);
  const mine = eff.edges.filter((e) => e.zone === name);
  for (const e of mine) {
    for (const a of e.added) info(`  derived: ${a}`);
  }
  for (const err of eff.errors) warn(`  ${err}`);
  info("");
  info("  To apply on the planes, run:");
  info(`    network-manager reconcile --apply`);
}

// ── reconcile command ──────────────────────────────────────────────────
function cmdReconcile(opts: Opts, client: PlaneClient = new CliPlaneClient()): void {
  // Validate zones.json is readable before touching any plane.
  loadZones(opts.zonesFile);

  // ADR-014 D-C4: resolve every `serves` link into zones.effective.json and hand
  // THAT to the planes. zones.json stays purely authored. A broken link is fatal
  // here (unlike on a zone add) — reconcile is the verb that converges the
  // firewall, so a link that cannot resolve would silently drop an edge.
  const eff = refreshEffective(opts.zonesFile);
  if (eff.errors.length > 0) {
    for (const e of eff.errors) warn(e);
    die(`unresolved 'serves' link(s): ${eff.errors.length} — fix the binding(s) and re-run`);
  }
  for (const e of eff.edges) {
    info(`serves: ${e.zone} → environment '${e.environment}' (zone '${e.serviceZone}')`);
    for (const a of e.added) info(`  ${a}`);
  }

  const report = reconcileAll(client, {
    apply: opts.apply,
    only: opts.only,
    zonesFile: opts.zonesFile,
    effectiveFile: effectiveFileFor(opts.zonesFile),
  });
  printReport(report);
  if (report.failed.length > 0) {
    die(`Planes not in sync: ${report.failed.join(", ")}`);
  }
  if (report.apply) {
    info(`${GN}All planes converged.${CL}`);
  } else {
    info(`${GN}All planes reported (dry-run). Re-run with --apply to converge.${CL}`);
  }
}

function printReport(report: ReconcileReport): void {
  for (const r of report.results) {
    const tag =
      r.status === "in-sync"
        ? `${GN}✓${CL}`
        : r.status === "error"
          ? `${RD}✗${CL}`
          : `${YW}!${CL}`;
    info(`  ${tag} ${r.message} (rc=${r.rc})`);
  }
}

// ── zones-init command (install-time template transform; offline) ──────
function cmdZonesInit(opts: Opts): void {
  const name = opts.name;
  if (!name) die("init: --name <N> is required");
  const from = opts.from ?? defaultTemplateFile();
  const out = opts.out ?? defaultZonesFile();

  let template: Record<string, unknown>;
  try {
    template = parseTemplate(from);
  } catch (e) {
    die((e as Error).message);
  }

  // ADR-014 D7: `init <profile>`. The profile defaults to `core` so the legacy
  // call shape (`init --name <N>`, still used by install.sh's older revisions)
  // keeps working and means "the minimal coherent install".
  const profile = opts.rest[0] ?? "core";
  const known = profileNames(template);
  if (!known.includes(profile)) {
    die(`init: unknown profile '${profile}' (known: ${known.join(", ") || "none"})`);
  }

  // The existing document, if any. Profiles are ADDITIVE: existing zones win, so
  // a re-run can never rebuild a live file from template defaults (#427).
  let existing: Record<string, unknown> = {};
  if (existsSync(out)) {
    try {
      existing = parseTemplate(out); // strict raw-object parser (reused)
    } catch (e) {
      warn(
        `  init: could not read existing '${out}' (${(e as Error).message}) — ` +
          `treating this as a fresh install`,
      );
    }
  }

  let result;
  try {
    result = initProfile(template, existing, name, profile, opts.force);
  } catch (e) {
    die((e as Error).message);
  }

  writeJsonAtomic(out, result.raw);
  info(
    `  ${GN}✓${CL} init ${profile}: wrote '${out}' ` +
      `(default zone '${name}'; home/guest kept as site-local role zones)`,
  );
  if (result.renamedFromSrv) {
    info(`  init: carried the existing 'srv' zone forward as '${name}' (config preserved)`);
  }
  if (result.added.length) {
    info(`  init: added ${result.added.length} zone(s): ${result.added.join(", ")}`);
  } else {
    info(`  init: profile '${profile}' already applied — no zone added (idempotent)`);
  }
  if (result.granted.length) {
    info(`  init: granted reach needed by this profile:`);
    for (const g of result.granted) info(`      ${g}`);
  }
  const untouched = result.preserved.filter((z) => !result.added.includes(z));
  if (untouched.length) {
    info(
      `  init: ${untouched.length} pre-existing zone(s) PRESERVED as-is ` +
        `(config/state kept, not rebuilt from template)`,
    );
  }

  // Design A 3-file seeding. zones.json (current) carries the additive result;
  // zones.rename.json / zones.json.orig are seeded from the FULL renamed template
  // — the merge source/baseline must contain every zone the release ships,
  // whichever profiles are installed, or a field fix would never be adopted.
  // For a non-live --out the siblings are seeded relative to that path's
  // directory so tests stay self-contained and never touch live config.
  let fullRenamed: Record<string, unknown>;
  try {
    fullRenamed = zonesInit(template, name, true, occupiedZones(opts.configDir)).raw;
  } catch (e) {
    die((e as Error).message);
  }
  const outDir = dirname(out);
  const renameFile = out === defaultZonesFile() ? defaultRenameFile() : join(outDir, "zones.rename.json");
  const origFile = out === defaultZonesFile() ? defaultOrigFile() : join(outDir, "zones.json.orig");
  writeJsonAtomic(renameFile, fullRenamed);
  writeJsonAtomic(origFile, fullRenamed);
  info(`  ${GN}✓${CL} init: seeded '${renameFile}' (renamed source) and '${origFile}' (merge baseline)`);

  // Render the effective document so a `serves`-bound shipped zone resolves
  // immediately. Non-fatal: on the install path the environments do not exist
  // yet (install.sh runs `init` BEFORE `environment-manager add`), so the links
  // legitimately do not resolve for another few seconds.
  try {
    refreshEffective(out);
  } catch {
    /* the environment set is not written yet — merge/reconcile render it later */
  }

  if (profile === "core") {
    info("");
    info("  IoT segments are opt-in. To add them:");
    info(`    network-manager init iot --name ${name}`);
  }

  // N3: push the freshly-written live zones.json to the Proxmox nodes. Skipped
  // for a non-live --out (e.g. a temp/test path), --no-distribute, or
  // NM_NO_DISTRIBUTE=1 — so test runs to /tmp never SSH.
  if (shouldAutoDistribute(out, opts.noDistribute)) {
    distributeZones(out, { info, warn });
  }
}

// ── retire command (ADR-014 D7 / F3) ─────────────────────────────────
// Remove the zones a release stopped shipping, under the occupancy + liveness
// guard. Dry-run by default; --apply commits. Does not reconcile.
function cmdRetire(opts: Opts): number {
  const doc = loadZones(opts.zonesFile);
  const res = retireZones(doc, opts.configDir, opts.apply);

  const shown = res.items.filter((i) => i.verdict !== "absent");
  if (shown.length === 0) {
    info(`retire: none of the retired zone set is present in '${opts.zonesFile}' — nothing to do`);
    return 0;
  }

  info(`retire: ${opts.apply ? "applying" : "dry-run"} against '${opts.zonesFile}'`);
  for (const i of shown) {
    if (i.verdict === "retired") {
      info(`  ${GN}✓${CL} ${i.zone} — ${opts.apply ? "removed" : "would remove"} (${i.detail})`);
      for (const t of i.strippedFrom) {
        info(`      ${opts.apply ? "stripped" : "would strip"} the reference in '${t}'`);
      }
    } else {
      warn(`  ${i.zone} — KEPT: ${i.detail}`);
    }
  }

  if (!opts.apply) {
    info("");
    info(`  ${res.retired.length} zone(s) would be retired, ${res.kept.length} kept.`);
    info("  Re-run with --apply to commit.");
    return 0;
  }

  if (res.changed) {
    saveRetired(opts.zonesFile, doc);
    try {
      refreshEffective(opts.zonesFile);
    } catch {
      /* non-fatal: reconcile re-renders */
    }
    info("");
    info(`  ${GN}Retired ${res.retired.length} zone(s).${CL}`);
    info("  To apply on the planes, run:");
    info("    network-manager reconcile --apply");
    if (shouldAutoDistribute(opts.zonesFile, opts.noDistribute)) {
      distributeZones(opts.zonesFile, { info, warn });
    }
  } else {
    info("");
    info("  Nothing eligible — no change written.");
  }
  return 0;
}

// ── zones-distribute command (push the live zones.json to every node — N3) ──
// Manual entry point for the same push that runs automatically after a live
// zones.json write. Returns the distribute rc (non-zero only when nodes exist
// and NONE accepted the push; a node being down is warned, not fatal).
function cmdZonesDistribute(opts: Opts): number {
  const res = distributeZones(opts.zonesFile, { dryRun: opts.dryRun, info, warn });
  return res.rc;
}

// ── zones-check command (offline consistency audit; read-only) ────────
// Returns the check exit code (0 ok / warnings-only; 1 on hard errors).
function cmdZonesCheck(opts: Opts): number {
  return zonesCheck(
    {
      zonesFile: opts.zonesFile,
      configDir: opts.configDir,
      strict: opts.strict,
      effective: opts.effective,
    },
    info,
  );
}

// ── zones-merge command (rename-aware 3-way reconciliation; Design A) ──
// Re-bases the repo template into THIS installation's renamed namespace
// (zones.rename.json), 3-way-merges current vs orig vs that renamed source, then
// writes merged → zones.json and advances zones.json.orig. Does NOT distribute
// (callers/reconcile handle distribution), matching apply-zones-merge.sh.
// Returns the merge exit code (0 success).
function cmdZonesMerge(opts: Opts): number {
  const cfg = opts.configDir;
  let name: string;
  try {
    name = readSiteName(cfg);
  } catch (e) {
    die((e as Error).message);
  }
  // Occupancy guard: never inactivate a legacy zone still hosting deployed
  // modules. Same cross-check zones-init uses, so the renamed source preserves
  // a live service's Active state through the merge's state-pin.
  const keepActive = occupiedZones(cfg);
  const template = opts.from ?? defaultTemplateFile();
  const rc = runZonesMerge(
    {
      current: join(cfg, "zones.json"),
      orig: join(cfg, "zones.json.orig"),
      rename: join(cfg, "zones.rename.json"),
      template,
      name,
      keepActive,
      diff: opts.diff,
      configDir: cfg,
    },
    { info, warn },
    (tpl, n, ka) => renameTemplateFile(tpl, n, ka).raw,
  );
  // The merge rewrote the AUTHORED zones.json; re-render the effective document
  // so the planes and any module install see the current resolution.
  if (rc === 0 && !opts.diff) {
    try {
      refreshEffective(join(cfg, "zones.json"));
    } catch (e) {
      warn(`merge: could not render zones.effective.json (${(e as Error).message})`);
    }
  }
  return rc;
}

export function run(argv: string[], client?: PlaneClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  // `zone` is an OPTIONAL, legacy prefix — the whole manager is about zones, so
  // `zone add x` and `add x` are equivalent. Strip a leading bare `zone`.
  let args = argv;
  if (args[0] === "zone") {
    args = args.slice(1);
    if (args.length === 0) {
      usage();
      return 0;
    }
  }
  const cmd = args[0];
  const opts = parseOpts(args.slice(1));
  return guarded(() => {
    switch (cmd) {
      case "list":
      case "exists":
      case "show":
      case "get": // alias of show
        cmdZone(cmd, opts);
        return 0;
      case "add":
        cmdZoneAdd(opts, client ?? new CliPlaneClient());
        return 0;
      case "delete":
        cmdZoneDelete(opts, client ?? new CliPlaneClient());
        return 0;
      case "enable":
      case "disable":
      case "manual":
        cmdZoneState(cmd, opts);
        return 0;
      case "bind":
        cmdBind(opts);
        return 0;
      case "reconcile":
        cmdReconcile(opts, client ?? new CliPlaneClient());
        return 0;
      case "init": // primary verb; zones-init kept as fall-through alias
      case "zones-init":
        cmdZonesInit(opts);
        return 0;
      case "retire":
        return cmdRetire(opts);
      case "merge": // primary verb; zones-merge kept as fall-through alias
      case "zones-merge":
        return cmdZonesMerge(opts);
      case "validate": // ADR-007 #4: the standard verb name for the config gate
      case "zones-check":
        return cmdZonesCheck(opts);
      case "distribute": // primary verb; zones-distribute kept as fall-through alias
      case "zones-distribute":
        return cmdZonesDistribute(opts);
      default:
        usage();
        die(`Unknown command: ${cmd}`);
    }
  });
}

// Entry point (only when run directly, not when imported by tests).
if (require.main === module) {
  process.exit(run(process.argv.slice(2)));
}
