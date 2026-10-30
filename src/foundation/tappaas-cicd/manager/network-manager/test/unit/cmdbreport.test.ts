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
import { buildNetworkReport, collectNetSources, routeModule } from "../../src/cmdbreport";
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

console.log("== delivery: a refusal drops what it names ==");
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
