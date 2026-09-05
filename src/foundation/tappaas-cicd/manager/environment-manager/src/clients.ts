// clients.ts — the real NetworkClient + ModuleClient implementations.
//
// CliNetworkClient shells out to `network-manager` (the network plane owner,
// TS, ADR-007 P4). CliModuleClient enumerates deployed module configs on disk
// and shells out to `module-manager` per module — exactly as people-manager
// shells out to authentik-manager. NO plane/module logic is reimplemented here:
// these are thin FFI boundaries.

import { existsSync, readFileSync, readdirSync, writeFileSync } from "fs";
import { basename, join } from "path";
import { captureResult, stream } from "../../../lib/ts/src/exec";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { DnsTlsClient, ModuleClient, NetworkClient, NetworkUnreachable, WildcardDnsState } from "./types";

// Re-exported: NetworkUnreachable now lives in types.ts (the client boundary
// contract) so the pure reconcile engine can distinguish "binary missing" from
// "target ran and failed" — see #454.
export { NetworkUnreachable };

// Resolved per call, not at import time, so a test can point either binary at a
// stub after this module is loaded.
const NETWORK_MANAGER_BIN = (): string => process.env.NETWORK_MANAGER_BIN ?? "network-manager";
const MODULE_MANAGER_BIN = (): string => process.env.MODULE_MANAGER_BIN ?? "module-manager";
const UNBOUND_MANAGER_BIN = (): string => process.env.UNBOUND_MANAGER_BIN ?? "unbound-manager";
const ACME_MANAGER_BIN = (): string => process.env.ACME_MANAGER_BIN ?? "acme-manager";
const ACME_SETUP_BIN = (): string => process.env.ACME_SETUP_BIN ?? "acme-setup.sh";

// A cert this close to expiry (or already expired) is treated by reconcile as
// "needs (re)issuing", not "issued" (#548). 30 days mirrors os-acme-client's
// own renewal timing for a 90-day Let's Encrypt cert (renewInterval 60 = renew
// at ~30 days remaining), so the reconcile backstop and the auto-renew cron
// (#547) agree on when a cert is due.
export const CERT_RENEW_WINDOW_DAYS = 30;

// Pure decision extracted for unit testing: given `acme-manager status` output,
// the process exit code, and the current time (unix seconds), return the refid
// of a VALID issued cert, or undefined when no cert is configured OR the cert
// is expired / within the renewal window. Expiry is read from the `notAfter`
// line (the Trust store's real notAfter), never inferred from statusCode which
// stays 200 past expiry (#548). notAfter==0/absent means "unknown" → the refid
// is trusted (we do NOT force a needless reissue on missing data, matching
// #540's rule of not acting on an undatable status).
export function refidFromAcmeStatus(
  stdout: string,
  rc: number,
  nowSec: number,
): string | undefined {
  if (rc !== 0) return undefined; // "no certificate '*.<d>' configured"
  let refid: string | undefined;
  let notAfter = 0;
  for (const line of stdout.split("\n")) {
    const r = /^\s*certRefId\s*:\s*(\S+)/.exec(line);
    if (r && r[1]) refid = r[1];
    const n = /^\s*notAfter\s*:\s*(\d+)/.exec(line);
    if (n && n[1]) notAfter = parseInt(n[1], 10);
  }
  if (!refid) return undefined;
  if (notAfter > 0 && notAfter - nowSec <= CERT_RENEW_WINDOW_DAYS * 86400) {
    return undefined; // expired or within the renewal window → plan a renewal
  }
  return refid;
}

// Run + capture via the shared exec helper, mapping a spawn failure (binary
// missing on PATH) to the manager-specific NetworkUnreachable so the reconcile
// verb can die with its "unreachable" message.
function run(bin: string, args: string[]): string {
  const r = captureResult(bin, args);
  if (!r.ran) {
    throw new NetworkUnreachable(`${bin} ${args[0] ?? ""}: ${r.stderr}`);
  }
  if (r.rc !== 0) {
    throw new Error(`${bin} ${args.join(" ")} failed (exit ${r.rc}): ${r.stderr.trim()}`);
  }
  return r.stdout;
}

export class CliNetworkClient implements NetworkClient {
  zoneExists(zone: string): boolean {
    // network-manager exists <name> — exit 0 if present, non-zero otherwise.
    const r = captureResult(NETWORK_MANAGER_BIN(), ["exists", zone]);
    if (!r.ran) throw new NetworkUnreachable(`${NETWORK_MANAGER_BIN()} exists: ${r.stderr}`);
    return r.rc === 0;
  }

  zoneType(zone: string): string | undefined {
    // network-manager show <zone> --json — the zone object, or non-zero if absent.
    const r = captureResult(NETWORK_MANAGER_BIN(), ["show", zone, "--json"]);
    if (!r.ran) throw new NetworkUnreachable(`${NETWORK_MANAGER_BIN()} show: ${r.stderr}`);
    if (r.rc !== 0) return undefined;
    try {
      const o = JSON.parse(r.stdout) as Record<string, unknown>;
      return typeof o.type === "string" ? o.type : undefined;
    } catch {
      return undefined;
    }
  }

  createServiceZone(zone: string): void {
    // ADR-014 D1/D5: author via the `service` archetype so the new zone lands
    // tier-correct (type/typeId/tier + access-to seed) rather than with bare
    // defaults. --no-activate keeps zone authoring separate from plane
    // convergence: the caller's own reconcile pass converges it, so we do not
    // trigger a second whole-system pass here (#461).
    run(NETWORK_MANAGER_BIN(), ["add", zone, "--archetype", "service", "--no-activate"]);
  }

  reconcileNetwork(apply: boolean): void {
    // network-manager reconcile [--apply] — converges all planes/zones.
    const args = ["reconcile"];
    if (apply) args.push("--apply");
    run(NETWORK_MANAGER_BIN(), args);
  }
}

// CONFIG_DIR root for deployed module config discovery (the flat
// <config>/<module>.json files, each carrying an `environment` field — see
// module-fields.json). Tests inject a fixture dir.
export class CliModuleClient implements ModuleClient {
  constructor(private configDir: string) {}

  modulesForEnvironment(env: string): string[] {
    const out: string[] = [];
    if (!existsSync(this.configDir)) return out;
    for (const f of readdirSync(this.configDir)) {
      if (!f.endsWith(".json")) continue;
      const path = join(this.configDir, f);
      let raw: unknown;
      try {
        raw = JSON.parse(readFileSync(path, "utf8"));
      } catch {
        continue; // skip non-module / malformed JSON at the config root
      }
      if (raw && typeof raw === "object") {
        const o = raw as Record<string, unknown>;
        // A deployed module config carries an AUTHORITATIVE `environment` field,
        // set at install time (foundation → mgmt, apps → the default env) and
        // site.json,
        // zones.json etc. do not have it.
        if (typeof o.environment === "string" && o.environment === env) {
          out.push(basename(f, ".json"));
        }
      }
    }
    return out.sort();
  }

  moduleDeployed(module: string): boolean {
    // A deployed module has a flat <config>/<module>.json. Used to reconcile the
    // mgmt-zone identity module on a default-env domain change without failing
    // on systems where identity was never installed (#474).
    return existsSync(join(this.configDir, `${module}.json`));
  }

  reconcileModule(module: string, apply: boolean): void {
    // module-manager reconcile <module> [--apply] — VERB FIRST (#454). The
    // module-first form this used to build was an assumption made before
    // module-manager was ported; the shipped CLI dispatches on argv[0], so it
    // exited 1 with "Unknown verb: <module>" and stalled the --deep cascade at
    // its first module. The unit test below pins the argument vector.
    //
    // PREVIEW (no --apply) runs module-manager's read-only inspect, whose
    // dependency-service check is ON by default (#458) — opt out here: a --deep
    // preview walks EVERY consuming module, and one firewall round-trip per
    // dependency per module is not what a preview should cost. The full picture
    // comes from `module-manager reconcile <module>` on the single module.
    const args = ["reconcile", module];
    args.push(apply ? "--apply" : "--no-services");
    run(MODULE_MANAGER_BIN(), args);
  }
}

// Derive a zone's OPNsense gateway IP — the first host of its subnet, <net>.1 —
// from zones.json (e.g. "10.3.10.0/24" → "10.3.10.1"). Mirrors the bash
// zone_gateway_ip (common-install-routines.sh): the firewall interface ON THE
// CLIENT'S OWN SUBNET is self-traffic and crosses no inter-zone rule (#504).
// Returns undefined when the zone (or its subnet) is absent from zones.json.
function zoneGatewayIp(configDir: string, zone: string): string | undefined {
  if (!zone) return undefined;
  const zonesFile = join(configDir, "zones.json");
  if (!existsSync(zonesFile)) return undefined;
  let z: Record<string, unknown>;
  try {
    z = JSON.parse(readFileSync(zonesFile, "utf8")) as Record<string, unknown>;
  } catch {
    return undefined;
  }
  const entry = z[zone];
  const ip = entry && typeof entry === "object" ? (entry as Record<string, unknown>).ip : undefined;
  if (typeof ip !== "string" || ip === "") return undefined;
  const octets = ip.split("/")[0].split(".");
  if (octets.length < 3) return undefined;
  return `${octets.slice(0, 3).join(".")}.1`;
}

// CliDnsTlsClient — the wildcard DNS + cert-refid runtime-state boundary (#537).
//
// DNS is materialized by shelling `unbound-manager` (split-horizon overrides on
// the OPNsense resolver); the cert refid is READ non-interactively via
// `acme-manager status` and PERSISTED to config/cert-refids.json; issuance (when
// no cert exists yet and creds are on disk) is delegated to scripts/acme-setup.sh
// — the one credential-bearing step. NO ACME/DNS logic is reimplemented here:
// thin FFI, exactly like CliNetworkClient.
export class CliDnsTlsClient implements DnsTlsClient {
  // configDir defaults to the resolved config root; tests inject a temp dir so
  // cert-refids.json / zones.json reads and writes stay offline.
  constructor(private configDir: string = defaultConfigDir()) {}

  private certRefidsPath(): string {
    return join(this.configDir, "cert-refids.json");
  }

  wildcardDnsState(domain: string, zone: string): WildcardDnsState {
    // Desired target: the env's own service-zone gateway, else the dmz gateway
    // (ADR-005 §6, #504). undefined ⇒ neither could be derived.
    let gatewayZone = zone;
    let gatewayIp = zoneGatewayIp(this.configDir, zone);
    if (!gatewayIp) {
      gatewayZone = "dmz";
      gatewayIp = zoneGatewayIp(this.configDir, "dmz");
    }

    // Current overrides. `unbound-manager list` prints a header row then
    // `HOST DOMAIN TYPE VALUE DESCRIPTION` (whitespace-aligned columns).
    let currentTarget: string | undefined;
    const collidingHosts: string[] = [];
    const r = captureResult(UNBOUND_MANAGER_BIN(), ["--no-ssl-verify", "list"]);
    if (!r.ran) throw new NetworkUnreachable(`${UNBOUND_MANAGER_BIN()} list: ${r.stderr}`);
    if (r.rc === 0) {
      const lines = r.stdout.split("\n").slice(1); // drop the header row
      for (const line of lines) {
        const cols = line.trim().split(/\s+/);
        if (cols.length < 4) continue;
        const [host, dom, type, value] = cols;
        if (dom !== domain || !type.startsWith("A")) continue;
        if (host === "*") currentTarget = value;
        else collidingHosts.push(host);
      }
    }
    return {
      gatewayIp: gatewayIp ?? undefined,
      gatewayZone: gatewayIp ? gatewayZone : undefined,
      currentTarget,
      collidingHosts,
    };
  }

  registerWildcard(domain: string, gatewayIp: string, zone: string, envName: string): void {
    // Prune colliding per-service overrides first — a wildcard `redirect` zone
    // permits local-data only at the apex, so a stray host.<domain> makes
    // unbound-checkconf fatal and takes cluster DNS down (#474). The wildcard
    // supersedes them.
    const st = this.wildcardDnsState(domain, zone);
    for (const host of st.collidingHosts) {
      const d = captureResult(UNBOUND_MANAGER_BIN(), ["--no-ssl-verify", "delete", host, domain]);
      if (!d.ran) throw new NetworkUnreachable(`${UNBOUND_MANAGER_BIN()} delete: ${d.stderr}`);
      // A delete that fails (already gone) is non-fatal — the add below is what
      // matters; mirror acme-setup's `|| true` tolerance.
    }
    run(UNBOUND_MANAGER_BIN(), [
      "--no-ssl-verify",
      "add",
      "*",
      domain,
      gatewayIp,
      "--description",
      `TAPPaaS: ${envName} wildcard -> Caddy (${zone})`,
    ]);
  }

  issuedCertRefid(domain: string): string | undefined {
    // `acme-manager status --domain <d>` prints `certRefId : <refid>` and
    // `notAfter : <unix>` for an issued cert and exits non-zero when none is
    // configured. No DNS-API creds needed — it just queries OPNsense.
    const r = captureResult(ACME_MANAGER_BIN(), ["--no-ssl-verify", "status", "--domain", domain]);
    if (!r.ran) throw new NetworkUnreachable(`${ACME_MANAGER_BIN()} status: ${r.stderr}`);
    return refidFromAcmeStatus(r.stdout, r.rc, Math.floor(Date.now() / 1000));
  }

  private readCertRefids(): Record<string, string> {
    const p = this.certRefidsPath();
    if (!existsSync(p)) return {};
    try {
      const o = JSON.parse(readFileSync(p, "utf8"));
      return o && typeof o === "object" ? (o as Record<string, string>) : {};
    } catch {
      return {};
    }
  }

  recordedCertRefid(envName: string): string | undefined {
    const v = this.readCertRefids()[envName];
    return typeof v === "string" && v !== "" ? v : undefined;
  }

  writeCertRefid(envName: string, refid: string): void {
    const map = this.readCertRefids();
    map[envName] = refid;
    writeFileSync(this.certRefidsPath(), JSON.stringify(map, null, 2) + "\n");
  }

  acmeCredsAvailable(): boolean {
    // acme-setup.sh reads ~/.acme-dns-credentials.txt; $HOME resolves the same
    // path without depending on os.homedir (the repo's `types: []` node shim does
    // not declare it).
    const home = process.env.HOME ?? "";
    return home !== "" && existsSync(join(home, ".acme-dns-credentials.txt"));
  }

  issueWildcardCert(envName: string): string {
    // Delegate issuance to acme-setup.sh (the sole credential-bearing step); it
    // runs non-interactively when ~/.acme-dns-credentials.txt is present, and
    // itself registers the wildcard DNS + writes cert-refids.json. Stream its
    // (multi-minute) progress to the operator's terminal.
    const rc = stream(ACME_SETUP_BIN(), ["--environment", envName]);
    if (rc !== 0) {
      throw new Error(`${ACME_SETUP_BIN()} --environment ${envName} failed (exit ${rc})`);
    }
    // acme-setup.sh wrote the refid; read it back rather than re-parsing output.
    const refid = this.recordedCertRefid(envName);
    if (!refid) {
      throw new Error(
        `${ACME_SETUP_BIN()} reported success but cert-refids.json['${envName}'] is still empty`,
      );
    }
    return refid;
  }
}
