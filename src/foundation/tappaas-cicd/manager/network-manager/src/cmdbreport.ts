// cmdbreport.ts — what network-manager reports to the CMDB (ADR-040 D4):
// zones from zones.json, and what the firewall already answers through the
// opnsense controller's read verbs: DHCP leases (`dns-manager leases --json`),
// host entries (`dns-manager list --json`: reservations and DNS names), the
// reverse proxy (`caddy-manager list --json`) and the admin VPN's peers
// (`network-manager wgvpn peers`). A source that does not answer is named and
// its part left out; nothing is polled that a verb did not already read.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { CmdbQuery, cmdbQuery } from "../../../lib/ts/src/cmdb";
import { CmdbBatch, ipv4In, ipv4Offset } from "../../../lib/ts/src/cmdb-reporter";
import { ExecResult, captureResult } from "../../../lib/ts/src/exec";
import { zoneEnvironments } from "./serves";
import { moduleOfLocation, moduleSourceOf } from "../../../lib/ts/src/instance";
import { Zone, ZonesDoc } from "./types";

export const SOURCE = "network-manager";

export interface Lease {
  ip?: string | null;
  mac?: string | null;
  hostname?: string;
  zone?: string;
  expire?: string | number | null;
}
export interface HostEntry {
  host?: string;
  domain?: string;
  ip?: string | string[];
  hardware_addr?: string;
  description?: string;
}
export interface CaddyDoc {
  domains: { uuid: string; domain: string; description?: string; enabled?: boolean }[];
  handlers: {
    uuid: string;
    domain_uuid: string;
    upstream_domain: string;
    upstream_port: string | number;
    description?: string;
    enabled?: boolean;
    directive?: string;
    upstream_tls?: boolean;
    access_list_uuid?: string;
    forward_auth?: boolean;
    path?: string;
  }[];
  accessLists: { uuid: string; name: string; client_ips?: string[]; invert?: boolean }[];
}
export interface VpnPeer {
  name: string;
  publicKey?: string;
  tunneladdress?: string;
  endpoint?: string;
}

export interface NetSources {
  zones: ZonesDoc;
  configDir: string;
  leases: Lease[] | null;
  hosts: HostEntry[] | null;
  caddy: CaddyDoc | null;
  peers: VpnPeer[] | null;
  errors: { source: string; error: string }[];
}

export type Runner = (bin: string, args: string[]) => ExecResult;

const bin = (env: string, dflt: string): string => process.env[env] ?? dflt;

/** Ask the firewall what the read verbs already ask it. */
export function collectNetSources(zones: ZonesDoc, configDir: string, run: Runner = captureResult): NetSources {
  const errors: NetSources["errors"] = [];
  const json = <T>(source: string, b: string, args: string[]): T | null => {
    const r = run(b, args);
    if (!r.ran) {
      errors.push({ source, error: `${b} not found` });
      return null;
    }
    try {
      if (r.rc !== 0) throw new Error();
      return JSON.parse(r.stdout) as T;
    } catch {
      errors.push({ source, error: `exit ${r.rc}: ${(r.stderr || r.stdout).trim().split("\n").slice(-1)[0] ?? "no JSON"}` });
      return null;
    }
  };
  const dns = bin("NM_DNS_MANAGER_BIN", "dns-manager");
  return {
    zones,
    configDir,
    leases: json<Lease[]>("dns-manager leases", dns, ["leases", "--json", "--no-ssl-verify"]),
    hosts: json<HostEntry[]>("dns-manager list", dns, ["list", "--json", "--no-ssl-verify"]),
    caddy: json<CaddyDoc>("caddy-manager list", bin("NM_CADDY_MANAGER_BIN", "caddy-manager"), ["list", "--json", "--no-ssl-verify"]),
    peers: json<VpnPeer[]>("wgvpn peers", bin("NM_WGVPN_BIN", "network-manager-wgvpn"), ["peers"]),
    errors,
  };
}

/** A zone and the environments it serves. */
export function putZone(b: CmdbBatch, name: string, z: Zone): string {
  const enabled = /^(active|mandatory)$/i.test(String(z.state ?? ""));
  const v4 = typeof z.ip === "string" && /^\d+\.\d+\.\d+\.\d+\/\d+$/.test(z.ip) ? z.ip : undefined;
  const start = v4 && enabled ? ipv4Offset(v4, Number(z["DHCP-start"] ?? 50)) : undefined;
  const end = v4 && enabled ? ipv4Offset(v4, Number(z["DHCP-end"] ?? 250)) : undefined;
  const ref = b.put("zone", name, {
    vlan: typeof z.vlantag === "number" ? z.vlantag : undefined,
    subnet: z.ip,
    ipv6Subnet: typeof z.ipv6Subnet === "number" ? String(z.ipv6Subnet) : undefined,
    tier: typeof z.tier === "number" ? String(z.tier) : undefined,
    dhcp: start && end ? { start, end } : undefined,
    description: typeof z.description === "string" ? z.description : undefined,
    state: typeof z.state === "string" && z.state ? z.state : undefined,
    type: typeof z.type === "string" && z.type ? z.type : undefined,
    bridge: typeof z.bridge === "string" && z.bridge ? z.bridge : undefined,
    desired: { file: "zones.json", key: name },
  });
  for (const env of zoneEnvironments(z)) b.relate("serves", ref, { class: "environment", name: env });
  return ref;
}

function zoneOfIp(zones: ZonesDoc, ip: string): string | undefined {
  for (const [name, z] of zones.zones) if (typeof z.ip === "string" && ipv4In(ip, z.ip)) return name;
  return undefined;
}

function leaseUntil(e: Lease["expire"]): string | undefined {
  if (e === null || e === undefined || e === "") return undefined;
  const n = Number(e);
  if (Number.isFinite(n) && n > 0) return new Date(n * 1000).toISOString();
  return String(e);
}

function putAddress(b: CmdbBatch, s: NetSources, ip: string, attrs: Record<string, unknown>): void {
  const ref = b.put("address", ip, { ip, family: ip.includes(":") ? "ipv6" : "ipv4", ...attrs });
  const zone = ip.includes(":") ? undefined : zoneOfIp(s.zones, ip);
  if (zone) b.relate("member-of", ref, b.has(`zone:${zone}`) ? `zone:${zone}` : { class: "zone", name: zone });
}

/** The module a TAPPaaS proxy route was installed for ("TAPPaaS: <module>"). */
export function routeModule(description: string | undefined): string | undefined {
  const m = /^TAPPaaS:\s*([A-Za-z0-9_-]+)\s*$/.exec(description ?? "");
  return m ? m[1] : undefined;
}

function provides(configDir: string, module: string): string[] {
  const f = join(configDir, `${module}.json`);
  if (!existsSync(f)) return [];
  try {
    const v = (JSON.parse(readFileSync(f, "utf8")) as { provides?: unknown }).provides;
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function zonesOfCidrs(zones: ZonesDoc, cidrs: string[]): string[] {
  const out = new Set<string>();
  for (const c of cidrs) {
    for (const [name, z] of zones.zones) {
      if (typeof z.ip !== "string") continue;
      const [net] = c.split("/");
      if (z.ip === c || (c.includes("/") && ipv4In(net, z.ip) && Number(c.split("/")[1]) >= Number(z.ip.split("/")[1]))) out.add(name);
    }
  }
  return [...out].sort();
}

/** The catalog name of the module an instance belongs to (its source
 *  directory's name), or the instance's name when its config says none. */
export function catalogModule(configDir: string, instance: string): string {
  try {
    const raw = JSON.parse(readFileSync(join(configDir, `${instance}.json`), "utf8")) as Record<string, unknown>;
    const src = moduleSourceOf(raw);
    return src ? moduleOfLocation(src) : instance;
  } catch {
    return instance;
  }
}

/** One proxy route per Caddy handler; its host is a public DNS name. Both
 *  carry the module the route was declared by. */
export function putRoutes(b: CmdbBatch, s: NetSources, caddy: CaddyDoc): void {
  const domains = new Map(caddy.domains.map((d) => [d.uuid, d]));
  const acls = new Map(caddy.accessLists.map((a) => [a.uuid, a]));
  for (const h of caddy.handlers) {
    const host = domains.get(h.domain_uuid)?.domain;
    if (!host) continue;
    const path = h.path ?? "";
    const acl = h.access_list_uuid ? acls.get(h.access_list_uuid) : undefined;
    const module = routeModule(h.description ?? domains.get(h.domain_uuid)?.description);
    const catalog = module ? catalogModule(s.configDir, module) : undefined;
    const ref = b.put("proxy-route", `${host}${path}`, {
      host,
      path: path || undefined,
      target: `${h.upstream_tls ? "https" : "http"}://${h.upstream_domain}:${String(h.upstream_port)}`,
      gate: h.forward_auth === true,
      allowedZones: acl && !acl.invert ? zonesOfCidrs(s.zones, acl.client_ips ?? []) : undefined,
      description: h.description || undefined,
      module: catalog,
    });
    b.put("dns-name", host, { fqdn: host, public: true, module: catalog });
    if (module) for (const p of provides(s.configDir, module)) b.relate("serves", ref, { class: "service", name: `${module}:${p}` });
  }
}

export function putPeer(b: CmdbBatch, p: VpnPeer): string {
  return b.put("vpn-peer", p.name, {
    publicKey: p.publicKey || undefined,
    endpoint: p.endpoint || undefined,
    allowedIps: p.tunneladdress ? [p.tunneladdress] : undefined,
  });
}

export function buildNetworkReport(s: NetSources): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  for (const [name, z] of s.zones.zones) putZone(b, name, z);
  for (const h of s.hosts ?? []) {
    const ips = (Array.isArray(h.ip) ? h.ip : [h.ip]).filter((x): x is string => typeof x === "string" && x !== "");
    const mac = h.hardware_addr ? h.hardware_addr.toLowerCase() : undefined;
    for (const ip of ips) putAddress(b, s, ip, mac ? { reservation: mac } : {});
    if (h.host && h.domain) {
      const fqdn = `${h.host}.${h.domain}`;
      b.put("dns-name", fqdn, { fqdn, target: ips[0], public: false });
    }
  }
  for (const l of s.leases ?? []) {
    if (!l.ip) continue;
    putAddress(b, s, l.ip, { leaseUntil: leaseUntil(l.expire), reservation: undefined });
  }
  if (s.caddy) putRoutes(b, s, s.caddy);
  for (const p of s.peers ?? []) putPeer(b, p);
  return b;
}

/** Whether every source that can have written this live object answered. A
 *  report writes only what it sees and the CMDB's expiry never ends a CI, so
 *  endUnseen ends what the sources stopped showing, and a source that did not
 *  answer must end nothing of its kind. An internal dns-name is a host entry's,
 *  a public one Caddy's. An address with a reservation is a host entry's, with
 *  only a leaseUntil a lease's; with both, or neither (a host entry without a
 *  MAC, a lease without an expiry), it can be either's and needs both reads.
 *  What this report does not write (no `public`, no `ip`) or an operator
 *  recorded is not ended. */
function sourcesAnswered(s: NetSources, o: Record<string, unknown>): boolean {
  if (o.recorded === true) return false;
  const a = (o.attributes ?? {}) as Record<string, unknown>;
  if (o.class === "dns-name") {
    if (a.public === false) return s.hosts !== null;
    return a.public === true && s.caddy !== null;
  }
  if (typeof a.ip !== "string") return false;
  const reserved = typeof a.reservation === "string";
  const leased = typeof a.leaseUntil === "string";
  return (s.hosts !== null || (leased && !reserved)) && (s.leases !== null || (reserved && !leased));
}

/** End the live dns-names and addresses the batch no longer has. Only this
 *  report writes those two classes. A CMDB that cannot be read ends nothing and
 *  the report goes out as it is; the next run ends what this one could not. */
export function endUnseen(
  b: CmdbBatch,
  s: NetSources,
  query: (q: CmdbQuery) => Record<string, unknown>[] = cmdbQuery,
  env: Record<string, string | undefined> = process.env,
): void {
  if ((env.TAPPAAS_CMDB ?? "").toLowerCase() === "off") return;
  let live: Record<string, unknown>[];
  try {
    live = ["dns-name", "address"].flatMap((c) => query({ class: c, includeEnded: false }));
  } catch (e) {
    process.stderr.write(`[Warning] report: the CMDB could not be read, nothing ended: ${(e as Error).message.split("\n")[0]}\n`);
    return;
  }
  for (const o of live) {
    const cls = String(o.class);
    const name = String(o.name);
    if (!b.has(`${cls}:${name}`) && sourcesAnswered(s, o)) b.end(cls, name);
  }
}

// ── report --discover (ADR-040 D15) ───────────────────────────────────
// What `opnsense-firewall discover` answers. Rules, aliases, NAT, routes,
// certificates, packages and the interfaces no zone has go on the network
// module's CI under `firewall`; what belongs to a zone, on the zone.
export const FIREWALL_MODULE = "network";

export interface DiscoverRule {
  uuid: string;
  position: number;
  sequence: number | null;
  [k: string]: unknown;
}
export interface DiscoverDoc {
  version?: string | null;
  packages?: unknown[];
  interfaces?: { identifier?: string; device?: string | null; tag?: number | null; ipv4?: string | null; description?: string; enabled?: boolean }[];
  vlans?: { tag?: number | null; device?: string | null; parent?: string | null; description?: string }[];
  rules?: DiscoverRule[];
  aliases?: unknown[];
  nat?: unknown[];
  dhcpRanges?: { interface?: string; start_addr?: string; end_addr?: string; [k: string]: unknown }[];
  dhcpHosts?: unknown[];
  leases?: unknown[];
  dnsOverrides?: { fqdn?: string; target?: string; enabled?: boolean }[];
  wireguard?: { name?: string; publicKey?: string; tunneladdress?: string; endpoint?: string; lastHandshake?: unknown }[];
  routes?: unknown[];
  certificates?: unknown[];
  errors?: { section: string; error: string }[];
}

export function collectDiscover(run: Runner = captureResult): { doc: DiscoverDoc | null; error?: string } {
  const b = bin("NM_OPNSENSE_FIREWALL_BIN", "opnsense-firewall");
  const r = run(b, ["discover", "--no-ssl-verify"]);
  if (!r.ran) return { doc: null, error: `${b} not found` };
  try {
    if (r.rc !== 0) throw new Error();
    return { doc: JSON.parse(r.stdout) as DiscoverDoc };
  } catch {
    return { doc: null, error: `exit ${r.rc}: ${(r.stderr || r.stdout).trim().split("\n").slice(-1)[0] ?? "no JSON"}` };
  }
}

export function buildNetworkDiscover(doc: DiscoverDoc, zones: ZonesDoc): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  const zoneOf = (i: { tag?: number | null; ipv4?: string | null }): string | undefined => {
    for (const [name, z] of zones.zones) {
      if (i.tag && z.vlantag === i.tag) return name;
      if (i.ipv4 && z.ip === i.ipv4) return name;
    }
    return undefined;
  };
  const free: unknown[] = [];
  for (const i of doc.interfaces ?? []) {
    const zone = zoneOf(i);
    if (!zone) {
      free.push(i);
      continue;
    }
    const range = (doc.dhcpRanges ?? []).find((r) => r.interface === i.identifier);
    b.put("zone", zone, {
      interface: { identifier: i.identifier, device: i.device, tag: i.tag, ipv4: i.ipv4, enabled: i.enabled },
      dhcp: range?.start_addr && range.end_addr ? { start: range.start_addr, end: range.end_addr } : undefined,
    });
  }
  // A VLAN the firewall carries that no zone declares.
  const undeclared = (doc.vlans ?? []).filter((v) => !zoneOf({ tag: v.tag }));
  for (const o of doc.dnsOverrides ?? []) if (o.fqdn) b.put("dns-name", o.fqdn, { fqdn: o.fqdn, target: o.target || undefined });
  for (const p of doc.wireguard ?? []) {
    if (!p.name) continue;
    b.put("vpn-peer", p.name, {
      publicKey: p.publicKey || undefined,
      endpoint: p.endpoint || undefined,
      allowedIps: p.tunneladdress ? [p.tunneladdress] : undefined,
      lastHandshake: p.lastHandshake === null || p.lastHandshake === undefined ? undefined : String(p.lastHandshake),
    });
  }
  b.put("vm", FIREWALL_MODULE, {
    osVersion: doc.version ?? undefined,
    firewall: firewallAttribute(doc, free, undeclared),
  });
  return b;
}

// The sections of the pass that make up `firewall`, by the name `errors` uses.
const FIREWALL_SECTIONS = ["interfaces", "vlans", "rules", "aliases", "nat", "dhcpRanges", "dhcpHosts", "routes", "certificates", "firmware"];

/** Canonical JSON: object keys sorted at every depth. */
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v !== null && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(",")}}`;
  }
  return JSON.stringify(v) ?? "null";
}

/** One section in a fixed order: by uuid, else name or identifier, the whole
 *  entry breaking ties (routes have no key of their own). */
function sorted(list: unknown[] | undefined, drop: string[] = []): unknown[] {
  const keyOf = (e: unknown): string => {
    const o = (e ?? {}) as Record<string, unknown>;
    const k = o.uuid ?? o.name ?? o.identifier ?? o.tag ?? o.device;
    return k === undefined || k === null ? "" : String(k);
  };
  const out = (list ?? []).map((e) => {
    if (e === null || typeof e !== "object" || drop.length === 0) return e;
    const o = { ...(e as Record<string, unknown>) };
    for (const k of drop) delete o[k];
    return o;
  });
  return out
    .map((e) => ({ e, k: keyOf(e), c: canonical(e) }))
    .sort((a, b) => (a.k < b.k ? -1 : a.k > b.k ? 1 : a.c < b.c ? -1 : a.c > b.c ? 1 : 0))
    .map((x) => x.e);
}

/** The network module's `firewall` attribute: the same value on every pass
 *  over a firewall that did not change. Every section is sorted by its key
 *  (uuid, else name), not by the order the API lists it in. A rule keeps its
 *  `position` and `sequence`: computed from the sequence, they are the live
 *  evaluation order and move only when the rules change. A NAT entry's
 *  `position` is dropped: it is the entry's place in the stored model, not the
 *  order the firewall applies them in, so it carries nothing the uuid order
 *  does not. A pass in which a section of it was not answered leaves
 *  `firewall` out: an empty section in its place would show as the rules
 *  gone, and back on the next pass; the CMDB keeps the last full one. */
export function firewallAttribute(doc: DiscoverDoc, free: unknown[], undeclared: unknown[]): Record<string, unknown> | undefined {
  if ((doc.errors ?? []).some((e) => FIREWALL_SECTIONS.includes(e.section))) return undefined;
  return {
    interfaces: sorted(free),
    vlans: sorted(undeclared),
    rules: sorted(doc.rules),
    aliases: sorted(doc.aliases),
    nat: sorted(doc.nat, ["position"]),
    dhcpRanges: sorted(doc.dhcpRanges),
    dhcpHosts: sorted(doc.dhcpHosts),
    routes: sorted(doc.routes),
    certificates: sorted(doc.certificates),
    packages: sorted(doc.packages),
  };
}
