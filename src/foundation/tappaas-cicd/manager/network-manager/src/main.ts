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
// Commands:
//   network-manager zone list
//   network-manager zone exists <name>
//   network-manager zone get <name>
//   network-manager zone add <name> [--from-zone S] [--type T --typeId N]
//                                    [--vlan V] [--variant X] [--no-activate] [--check]
//   network-manager zone delete <name> [--check]
//   network-manager reconcile [--apply] [--only <plane>]
//
// Exit codes: ok=0, error/drift-after-apply=1.

import { CliPlaneClient } from "./planes";
import { reconcileAll } from "./reconcile";
import { Plane, PLANE_ORDER, PlaneClient, ReconcileReport } from "./types";
import { defaultZonesFile, getZone, listZoneNames, loadZones, zoneExists } from "./zones";
import { addZone, deleteZone } from "./zonelifecycle";

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

function usage(): void {
  info(`network-manager ${VERSION} — TAPPaaS network owner + orchestrator (ADR-007 P4 / ADR-008)

Usage:
  network-manager zone list
  network-manager zone exists <name>
  network-manager zone get <name>
  network-manager zone add <name> [options]
  network-manager zone delete <name> [--check]
  network-manager reconcile [--apply] [--only <plane>]

zone add options:
  --from-zone <src>   inherit type/typeId/bridge/access-to/pinhole from <src>
  --type <T>          zone type (default: Service)
  --typeId <N>        numeric type band (default: 2)
  --vlan <tag>        explicit VLAN tag (else auto-allocated 60-99 in band)
  --variant <name>    tag the zone with this variant (metadata)
  --no-activate       author zones.json only; skip the all-plane reconcile
  --check             dry-run: show actions, mutate nothing

reconcile options:
  --apply             converge all planes (default is dry-run / report only)
  --only <plane>      one plane: opnsense | proxmox | switch | ap

common:
  --zones-file <f>    default \$TAPPAAS_CONFIG/zones.json
  -h, --help          Show this help

Exit code is non-zero if any plane reports an error (or proxmox still drifts
after --apply).`);
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
        o.zonesFile = next();
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
function cmdZone(opts: Opts): void {
  const sub = opts.rest[0];
  if (!sub) die("zone: expected 'list' | 'exists' | 'get' | 'add' | 'delete'");

  if (sub === "list") {
    const doc = loadZones(opts.zonesFile);
    info(JSON.stringify(listZoneNames(doc), null, 2));
    return;
  }
  if (sub === "exists") {
    const name = opts.rest[1];
    if (!name) die("zone exists: expected <name>");
    const doc = loadZones(opts.zonesFile);
    const present = zoneExists(doc, name);
    info(String(present));
    if (!present) throw new DieError(`zone '${name}' not found`);
    return;
  }
  if (sub === "get") {
    const name = opts.rest[1];
    if (!name) die("zone get: expected <name>");
    const doc = loadZones(opts.zonesFile);
    const z = getZone(doc, name);
    if (!z) die(`zone '${name}' not found in ${opts.zonesFile}`);
    const out: Record<string, unknown> = { ...z };
    delete out.name;
    info(JSON.stringify(out, null, 2));
    return;
  }
  if (sub === "add") {
    cmdZoneAdd(opts);
    return;
  }
  if (sub === "delete") {
    cmdZoneDelete(opts);
    return;
  }
  die(`zone ${sub}: unknown subcommand`);
}

function cmdZoneAdd(opts: Opts, client: PlaneClient = new CliPlaneClient()): void {
  const name = opts.rest[1];
  if (!name) die("zone add: expected <name>");
  const dtag = opts.check ? " [dry-run]" : "";
  info(`zone-add '${name}'${opts.fromZone ? ` (from ${opts.fromZone})` : ""}${dtag}`);
  const res = addZone(client, opts.zonesFile, name, {
    fromZone: opts.fromZone,
    type: opts.type,
    typeId: opts.typeId,
    vlan: opts.vlan,
    variant: opts.variant,
    dryRun: opts.check,
    noActivate: opts.noActivate,
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
  const name = opts.rest[1];
  if (!name) die("zone delete: expected <name>");
  const dtag = opts.check ? " [dry-run]" : "";
  info(`zone-delete '${name}'${dtag}`);
  const res = deleteZone(client, opts.zonesFile, name, { dryRun: opts.check });
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

// ── reconcile command ──────────────────────────────────────────────────
function cmdReconcile(opts: Opts, client: PlaneClient = new CliPlaneClient()): void {
  // Validate zones.json is readable before touching any plane.
  loadZones(opts.zonesFile);
  const report = reconcileAll(client, {
    apply: opts.apply,
    only: opts.only,
    zonesFile: opts.zonesFile,
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

export function run(argv: string[], client?: PlaneClient): number {
  if (argv.length === 0 || argv[0] === "-h" || argv[0] === "--help") {
    usage();
    return 0;
  }
  const cmd = argv[0];
  const opts = parseOpts(argv.slice(1));
  try {
    switch (cmd) {
      case "zone":
        // route add/delete through the injected client (tests), reads use none
        if (opts.rest[0] === "add") {
          cmdZoneAdd(opts, client ?? new CliPlaneClient());
        } else if (opts.rest[0] === "delete") {
          cmdZoneDelete(opts, client ?? new CliPlaneClient());
        } else {
          cmdZone(opts);
        }
        return 0;
      case "reconcile":
        cmdReconcile(opts, client ?? new CliPlaneClient());
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
  process.exit(run(process.argv.slice(2)));
}

// Re-export for tests.
export { warn };
