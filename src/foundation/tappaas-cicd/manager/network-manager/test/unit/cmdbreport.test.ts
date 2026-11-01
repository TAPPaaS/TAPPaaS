// cmdbreport.test.ts — `network-manager report` (ADR-040 D4): the payload
// built from fixture zones and the firewall's read verbs (a fake runner), the
// CLI's `report --json` with no firewall, and a changing verb's report carrying
// the console's job id (spooled: no CMDB in the test).
//
// Run: NM_FIXTURE_DIR=<network-manager>/test/fixtures NM_MAIN=<dist>/main.js node cmdbreport.test.js

import { spawnSync } from "child_process";
import { copyFileSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { CmdbObject, CmdbReport } from "../../../../lib/ts/src/cmdb";
import { pruneRefused } from "../../../../lib/ts/src/cmdb-reporter";
import { DiscoverDoc, NetSources, buildNetworkDiscover, buildNetworkReport, collectDiscover, collectNetSources, endUnseen, routeModule } from "../../src/cmdbreport";
import { loadZones } from "../../src/zones";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const FIX = join(process.env.NM_FIXTURE_DIR ?? "test/fixtures", "cmdb-report");
const MAIN = process.env.NM_MAIN ?? "";
const read = (f: string): string => readFileSync(join(FIX, f), "utf8");

const fake = (bin: string, args: string[]) => {
  const out =
    bin === "dns-manager" && args[0] === "leases" ? read("leases.json")
    : bin === "dns-manager" && args[0] === "list" ? read("hosts.json")
    : bin === "caddy-manager" ? read("caddy.json")
    : bin === "network-manager-wgvpn" ? read("peers.json")
    : null;
  return out === null ? { rc: 1, stdout: "", stderr: "", ran: false } : { rc: 0, stdout: out, stderr: "", ran: true };
};

const s = collectNetSources(loadZones(join(FIX, "zones.json")), FIX, fake);
const r = buildNetworkReport(s).report();
const obj = (cls: string, name: string): CmdbObject | undefined => r.objects!.find((o) => o.class === cls && o.name === name);
const rel = (type: string, from: string, to: unknown): boolean =>
  r.relations!.some((x) => x.type === type && x.from === from && JSON.stringify(x.to) === JSON.stringify(to));

console.log("== network-manager report: the payload ==");
check(r.source === "network-manager" && r.kind === "observation", "an observation from network-manager");
check(s.errors.length === 0, "every fixture source answered");
check(obj("zone", "srv")?.attributes?.vlan === 200 && obj("zone", "srv")?.attributes?.subnet === "10.2.0.0/24", "zone srv: vlan and subnet");
check(JSON.stringify(obj("zone", "srv")?.attributes?.dhcp) === JSON.stringify({ start: "10.2.0.100", end: "10.2.0.250" }), "zone srv: the DHCP range, with its own DHCP-start");
check(obj("zone", "guest")?.attributes?.dhcp === undefined, "an inactive zone has no DHCP range");
check(typeof obj("zone", "srv")?.attributes?.state === "string", "a zone carries its state, for the topology");
check(obj("zone", "mgmt")?.attributes?.tier === "0" && obj("zone", "mgmt")?.attributes?.ipv6Subnet === "0", "tier and ipv6Subnet are strings, as the metamodel declares");
check(rel("serves", "zone:srv", { class: "environment", name: "home" }), "zone srv serves environment home (by name)");
check(rel("serves", "zone:guest", { class: "environment", name: "work" }), "a zone serving several environments serves each");
const a20 = obj("address", "10.0.0.20")?.attributes ?? {};
check(a20.reservation === "aa:bb:cc:00:00:20" && a20.family === "ipv4", "a reserved address carries the reservation's MAC, lowercased");
check(typeof a20.leaseUntil === "string" && String(a20.leaseUntil).startsWith("2026-"), "…and the lease's end, merged into the same address");
check(r.objects!.filter((o) => o.class === "address" && o.name === "10.0.0.20").length === 1, "one address per IP");
check(rel("member-of", "address:10.0.0.50", "zone:mgmt"), "an address is a member of the zone its IP is in");
check(obj("dns-name", "tappaas1.mgmt.internal")?.attributes?.target === "10.0.0.20" && obj("dns-name", "tappaas1.mgmt.internal")?.attributes?.public === false, "a host entry is an internal DNS name");
const route = obj("proxy-route", "cloud.example.org")?.attributes ?? {};
check(route.target === "http://nextcloud.srv.internal:80" && route.gate === true, "a proxy route: its target and identity gate");
check(JSON.stringify(route.allowedZones) === JSON.stringify(["mgmt"]), "…the zones its access list allows");
check(obj("dns-name", "cloud.example.org")?.attributes?.public === true, "a proxied host is a public DNS name");
check(rel("serves", "proxy-route:cloud.example.org", { class: "service", name: "nextcloud:fileservice" }), "the route serves <module>:<service> from the module's provides");
check(routeModule("TAPPaaS: nextcloud") === "nextcloud" && routeModule("manual") === undefined, "a route's module is read from its TAPPaaS description");
const peer = obj("vpn-peer", "lars-mac")?.attributes ?? {};
check(peer.publicKey === "PUBKEY=" && JSON.stringify(peer.allowedIps) === JSON.stringify(["10.255.1.2/32"]) && peer.endpoint === undefined, "an admin VPN peer: key and allowed IPs, no empty endpoint");

console.log("== report --discover: what the firewall holds ==");
const dd = collectDiscover((_b, a) => ({ rc: a[0] === "discover" ? 0 : 1, stdout: read("discover.json"), stderr: "", ran: true }));
check(dd.doc !== null, "opnsense-firewall discover is read");
const dr = buildNetworkDiscover(dd.doc as DiscoverDoc, loadZones(join(FIX, "zones.json"))).report();
const dobj = (cls: string, name: string): CmdbObject | undefined => dr.objects!.find((o) => o.class === cls && o.name === name);
type Fw = { rules: { uuid: string; position: number }[]; aliases: { uuid: string }[]; nat: unknown[]; routes: unknown[]; certificates: unknown[]; packages: unknown[]; interfaces: { identifier: string }[]; vlans: { tag: number }[] };
const net = dobj("vm", "network")?.attributes ?? {};
const fw = net.firewall as Fw;
check(net.osVersion === "25.7.1", "the network module's CI carries the OPNsense version");
check(fw.rules.map((x) => `${x.uuid}@${x.position}`).join() === "r-1@1,r-2@2,r-3@3", "every rule by UUID, with its live position");
check(fw.aliases[0]?.uuid === "a-1" && fw.nat.length === 1 && fw.routes.length === 1 && fw.certificates.length === 1 && fw.packages.length === 1, "aliases, NAT, routes, certificates and packages sit under firewall");
check(fw.interfaces.map((x) => x.identifier).join() === "opt9" && fw.vlans.map((x) => x.tag).join() === "777", "an interface and a VLAN no zone declares go under firewall");
const srv = dobj("zone", "srv")?.attributes ?? {};
check((srv.interface as { device: string }).device === "vlan0.200" && JSON.stringify(srv.dhcp) === JSON.stringify({ start: "10.2.0.120", end: "10.2.0.200" }), "a zone's interface and live DHCP range go on the zone");
check(dobj("zone", "mgmt") !== undefined && !dr.objects!.some((o) => o.class === "zone" && o.name === "hand made"), "a zone is matched by tag or subnet; no zone is invented");
check(dobj("vpn-peer", "lars-mac")?.attributes?.lastHandshake === "42", "a WireGuard peer's last handshake");
check(dobj("dns-name", "cloud.example.org")?.attributes?.target === "10.6.0.1", "a DNS override is a dns-name");
check(collectDiscover(() => ({ rc: -1, stdout: "", stderr: "", ran: false })).doc === null, "no firewall: no discover report, the plain one stands");

console.log("== report --discover: the firewall attribute is the same on every pass ==");
{
  const zones = loadZones(join(FIX, "zones.json"));
  const one = JSON.parse(read("discover.json")) as DiscoverDoc;
  // The same firewall read again: every section listed in another order, the
  // NAT entries at other places in the model.
  const two = JSON.parse(read("discover.json")) as DiscoverDoc;
  one.nat = [
    { uuid: "n-2", kind: "source", position: 1, enabled: true, description: "out", target: "" },
    { uuid: "n-1", kind: "port-forward", position: 2, enabled: true, description: "web", target: "10.6.0.5" },
  ];
  two.nat = [
    { uuid: "n-1", kind: "port-forward", position: 1, enabled: true, description: "web", target: "10.6.0.5" },
    { uuid: "n-2", kind: "source", position: 2, enabled: true, description: "out", target: "" },
  ];
  one.routes = [...(one.routes ?? []), { destination: "10.9.0.0/16", gateway: "10.0.0.2", interface: "vtnet0", flags: "UGS" }];
  two.routes = [{ destination: "10.9.0.0/16", gateway: "10.0.0.2", interface: "vtnet0", flags: "UGS" }, ...(two.routes ?? [])];
  for (const k of ["rules", "aliases", "dhcpHosts", "certificates", "packages", "interfaces", "vlans"] as const) {
    (two as Record<string, unknown>)[k] = [...((two as Record<string, unknown[]>)[k] ?? [])].reverse();
  }
  two.aliases = [{ uuid: "a-0", name: "tm_x", type: "host", enabled: true, content: "x.srv.internal" }, ...(two.aliases ?? [])];
  one.aliases = [...(one.aliases ?? []), { uuid: "a-0", name: "tm_x", type: "host", enabled: true, content: "x.srv.internal" }];
  const fwOf = (d: DiscoverDoc): unknown => buildNetworkDiscover(d, zones).report().objects!.find((o) => o.class === "vm" && o.name === "network")?.attributes?.firewall;
  const a = fwOf(one) as { nat: Record<string, unknown>[]; rules: { uuid: string; position: number }[]; aliases: { uuid: string }[] };
  check(JSON.stringify(a) === JSON.stringify(fwOf(two)), "two passes listing the same firewall in another order give the same attribute");
  check(a.nat.map((n) => n.uuid).join() === "n-1,n-2" && a.nat.every((n) => !("position" in n)), "NAT by uuid, without its place in the model");
  check(a.nat[0].enabled === true && a.nat[0].target === "10.6.0.5" && a.nat[0].kind === "port-forward" && a.nat[0].description === "web", "a NAT entry keeps what defines it");
  check(a.rules.map((r) => `${r.uuid}@${r.position}`).join() === "r-1@1,r-2@2,r-3@3" && a.aliases[0].uuid === "a-0", "rules by uuid with their live position, aliases by uuid");
  const partial = JSON.parse(read("discover.json")) as DiscoverDoc;
  partial.nat = [];
  partial.errors = [{ section: "nat", error: "timeout" }];
  const net = buildNetworkDiscover(partial, zones).report().objects!.find((o) => o.class === "vm" && o.name === "network")?.attributes ?? {};
  check(!("firewall" in net) && net.osVersion === "25.7.1", "a pass that missed a section leaves firewall out, not emptied");
}

console.log("== delivery: a refusal drops what it names ==");
console.log("== network-manager report: ends what the sources stopped showing ==");
{
  const live = [
    { class: "dns-name", name: "tappaas1.mgmt.internal", attributes: { public: false } }, // still a host entry
    { class: "dns-name", name: "gone.mgmt.internal", attributes: { public: false } },
    { class: "dns-name", name: "gone.example.org", attributes: { public: true } },
    { class: "dns-name", name: "override.example.org", attributes: { fqdn: "override.example.org" } }, // no `public`: discover's
    { class: "dns-name", name: "kept.mgmt.internal", recorded: true, attributes: { public: false } },
    { class: "address", name: "10.0.0.20", attributes: { ip: "10.0.0.20", reservation: "aa:bb:cc:00:00:20" } }, // still reserved
    { class: "address", name: "10.0.0.50", attributes: { ip: "10.0.0.50", leaseUntil: "2026-01-01T00:00:00.000Z" } }, // still leased
    { class: "address", name: "10.0.0.91", attributes: { ip: "10.0.0.91", reservation: "aa:bb:cc:00:00:91" } },
    { class: "address", name: "10.0.0.92", attributes: { ip: "10.0.0.92", leaseUntil: "2026-01-01T00:00:00.000Z" } },
    { class: "address", name: "10.0.0.93", attributes: { ip: "10.0.0.93" } }, // a host entry without a MAC
    { class: "address", name: "10.0.0.94", attributes: { ip: "10.0.0.94", reservation: "aa:bb:cc:00:00:94", leaseUntil: "2026-01-01T00:00:00.000Z" } },
    { class: "address", name: "10.0.0.95", attributes: {} }, // nothing of this report's
  ];
  const query = (q: { class?: string }) => live.filter((o) => o.class === q.class);
  const ended = (src: NetSources): string[] => {
    const b = buildNetworkReport(src);
    endUnseen(b, src, query, {});
    return b.report().objects!.filter((o) => o.end).map((o) => `${o.class}:${o.name}`).sort();
  };
  const hostNames = ["dns-name:gone.mgmt.internal"];
  const leaseOnly = ["address:10.0.0.92"];
  check(
    JSON.stringify(ended(s)) === JSON.stringify(["address:10.0.0.91", "address:10.0.0.92", "address:10.0.0.93", "address:10.0.0.94", "dns-name:gone.example.org", ...hostNames]),
    "every read answered: what is gone is ended, and only that",
  );
  check(!ended(s).some((n) => /tappaas1|10\.0\.0\.20|10\.0\.0\.50/.test(n)), "nothing the batch has is ended");
  check(!ended(s).some((n) => /override|kept|10\.0\.0\.95/.test(n)), "no `public`, no `ip` or recorded by an operator: not ended");
  check(JSON.stringify(ended({ ...s, hosts: null })) === JSON.stringify([...leaseOnly, "dns-name:gone.example.org"]), "no host read: nothing host-derived ends, a lease's address still does");
  check(JSON.stringify(ended({ ...s, leases: null })) === JSON.stringify(["address:10.0.0.91", "dns-name:gone.example.org", ...hostNames]), "no lease read: a reservation's address and the names end, what a lease may hold does not");
  check(JSON.stringify(ended({ ...s, caddy: null })).includes("gone.example.org") === false, "no Caddy read: no public name ends");
  const b = buildNetworkReport(s);
  const before = b.objects.length;
  endUnseen(b, s, () => { throw new Error("cmdb-controller is not running"); }, {});
  check(b.objects.length === before, "a CMDB that cannot be read ends nothing and leaves the batch as it was");
  endUnseen(b, s, query, { TAPPAAS_CMDB: "off" });
  check(b.objects.length === before, "TAPPAAS_CMDB=off does not read it");
}

const refused: CmdbReport = {
  source: "t",
  objects: [{ ref: "a", class: "zone", name: "a" }, { ref: "b", class: "address", name: "b", attributes: { x: { ref: "a" } } }, { ref: "c", class: "zone", name: "c" }],
  relations: [{ type: "serves", from: "a", to: { class: "environment", name: "e" } }, { type: "serves", from: "c", to: { class: "service", name: "gone" } }],
};
const p1 = pruneRefused(refused, [{ at: "relations[1] (serves)", error: "no live service named gone" }]);
check(p1 !== null && p1.report.relations!.length === 1 && p1.report.objects!.length === 3, "an unresolved relation is dropped, the objects kept");
const p2 = pruneRefused(refused, [{ at: "objects[0] (zone a)", error: "bad" }]);
check(p2 !== null && p2.report.objects!.map((o) => o.name).join() === "c" && p2.report.relations!.length === 1, "a dropped object takes what references it");
check(pruneRefused(refused, [{ at: "", error: "?" }]) === null, "a refusal naming nothing is not pruned");

if (MAIN) {
  console.log("== the CLI ==");
  const tmp = mkdtempSync(join(tmpdir(), "nm-cmdb-"));
  try {
    copyFileSync(join(FIX, "zones.json"), join(tmp, "zones.json"));
    const env = {
      ...process.env,
      TAPPAAS_CONFIG: tmp,
      NM_DNS_MANAGER_BIN: "/nonexistent/dns-manager",
      NM_CADDY_MANAGER_BIN: "/nonexistent/caddy-manager",
      NM_WGVPN_BIN: "/nonexistent/wgvpn",
      CMDB_SOCKET: join(tmp, "no.sock"),
      TAPPAAS_JOB_ID: "job-42",
      TAPPAAS_ACTOR: "tester",
      TAPPAAS_CMDB: "",
    };
    const nm = (...a: string[]) => spawnSync("node", [MAIN, ...a, "--zones", join(tmp, "zones.json")], { encoding: "utf8", env });
    const rep = nm("report", "--json");
    let doc: CmdbReport | null = null;
    try { doc = JSON.parse(String(rep.stdout)) as CmdbReport; } catch { doc = null; }
    check(rep.status === 0 && doc !== null, "report --json exits 0 with JSON on stdout when the firewall does not answer");
    check(doc !== null && doc.objects!.filter((o) => o.class === "zone").length === 3 && !doc.objects!.some((o) => o.class === "address"), "…the zones, and nothing of the firewall's");
    check(/dns-manager leases.*left out/.test(String(rep.stderr)), "…and names what it left out on stderr");
    check(String(rep.stderr).split("\n").filter((l) => /nothing ended/.test(l)).length === 1, "…and says on one line that an unreadable CMDB ended nothing");
    const disc = nm("report", "--json", "--discover");
    check(disc.status === 0 && Array.isArray(JSON.parse(String(disc.stdout))), "report --json --discover prints an array, the plain report only when the firewall does not answer");
    const en = nm("enable", "guest");
    check(en.status === 0, "enable guest exits 0 with no CMDB");
    const spool = join(tmp, ".cmdb-spool");
    const files = (() => { try { return readdirSync(spool).filter((f) => f.endsWith(".json")); } catch { return []; } })();
    const ch = files.length ? (JSON.parse(readFileSync(join(spool, files[0]), "utf8")) as CmdbReport) : null;
    check(files.length === 1 && ch !== null, "the change was spooled");
    check(ch?.kind === "change" && ch.job === "job-42" && ch.actor === "tester" && ch.verb === "network-manager enable", "the change carries the verb, the console's job id and the actor");
    check(ch?.objects?.[0]?.class === "zone" && ch.objects[0].name === "guest", "…and the zone it touched");
    const off = spawnSync("node", [MAIN, "disable", "guest", "--zones", join(tmp, "zones.json")], { encoding: "utf8", env: { ...env, TAPPAAS_CMDB: "off" } });
    check(off.status === 0 && readdirSync(spool).filter((f) => f.endsWith(".json")).length === 1, "TAPPAAS_CMDB=off sends nothing");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
