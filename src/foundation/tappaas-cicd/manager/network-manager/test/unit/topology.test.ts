// topology.test.ts — `network-manager topology` (ADR-034 D5) over hrossen's real
// outputs (test/fixtures/topology-hrossen, captured 2026-10-17), plus the
// reconciliation cases the fixture does not exercise. Offline: buildTopology is
// pure, and collectSources is driven by a fake runner.
//
// Run: NM_FIXTURE_DIR=<network-manager>/test/fixtures node topology.test.js

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  ApRow, HealthDoc, LagRow, ModuleRow, NodeNetwork, PeerRow, SwitchActual, SwitchList, SwitchPorts, TopoPort, TopoSources, Topology,
  buildTopology, canon, collectSources, compactPorts, lldpPort, portCompare, renderTopology, speedLabel,
} from "../../src/topology";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const FIX = join(process.env.NM_FIXTURE_DIR ?? "test/fixtures", "topology-hrossen");
const load = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;

function hrossen(): TopoSources {
  return {
    site: load<Record<string, unknown>>("site.json"),
    nodes: load<{ name: string; storagePools: string[] }[]>("node-list.json"),
    networks: {
      tappaas1: load<NodeNetwork>("network-tappaas1.json"),
      tappaas2: load<NodeNetwork>("network-tappaas2.json"),
      tappaas3: load<NodeNetwork>("network-tappaas3.json"),
    },
    switches: load<SwitchList>("switches.json"),
    ports: load<SwitchPorts[]>("switch-ports.json"),
    lags: load<LagRow[]>("lags.json"),
    accessPoints: load<ApRow[]>("access-points.json"),
    zones: load<Record<string, unknown>>("zones.json"),
    modules: load<{ modules: ModuleRow[] }>("modules.json").modules,
    peers: load<PeerRow[]>("peers.json"),
    health: load<HealthDoc>("validate.json"),
    firewall: load<Record<string, unknown>>("network.json"),
    satellites: [],
    errors: [],
  };
}

const SW = "USW Pro XG 10 PoE";
const t: Topology = buildTopology(hrossen(), new Date("2026-10-17T18:01:00Z"));
const node = (n: string) => t.nodes.find((x) => x.name === n)!;
const sw = t.switches.find((s) => s.name === SW)!;
const port = (p: string) => sw.ports.find((x) => x.port === p)!;
const uplink = (n: string, u: string) => node(n).uplinks.find((x) => x.name === u);

// ── helpers ───────────────────────────────────────────────────────────
check(canon("USW Pro XG 10 PoE") === canon("USW-Pro-XG-10-PoE"), "switch display name and LLDP name compare equal");
check(lldpPort("Port 11") === "11" && lldpPort("Gi1/0/11") === "11" && lldpPort("12") === "12", "LLDP port spellings reduce to the number");
check(speedLabel(10000) === "10G" && speedLabel(2500) === "2.5G" && speedLabel(-1) === null, "speeds read as 10G / 2.5G / unknown");

// ── nodes ─────────────────────────────────────────────────────────────
check(t.nodes.map((n) => n.name).sort().join(",") === "tappaas1,tappaas2,tappaas3", "three cluster members");
check(node("tappaas1").storagePools.join(",") === "tanka1,tankb1", "tappaas1's pools from node list");
const lan1 = uplink("tappaas1", "lan")!;
check(lan1.mode === "lacp" && lan1.bond === "lanbond", "tappaas1 lan: an LACP bond, lanbond");
check(lan1.legs.map((l) => `${l.nic}:${l.peer?.port}`).join(" ") === "nic2:12 nic3:11", "tappaas1's legs: nic2 → port 12, nic3 → port 11");
check(lan1.legs.every((l) => l.peer?.switch === SW && l.peer.known && l.peer.via === "lldp" && l.speed === "10G" && l.up), "…on the inventory's switch (LLDP name reconciled), 10G, up");
check(uplink("tappaas1", "wan")?.legs[0].nic === "nic4" && uplink("tappaas1", "wan")?.legs[0].peer?.port === "6", "tappaas1 wan: nic4 → port 6");
check(uplink("tappaas3", "wan")?.legs[0].nic === "enp3s0" && uplink("tappaas3", "wan")?.legs[0].peer?.port === "7", "tappaas3 wan: enp3s0 → port 7 (2.5G)");
check(uplink("tappaas2", "wan") === undefined, "tappaas2 has no wan uplink");
check(uplink("tappaas2", "lan")?.mode === "single" && uplink("tappaas2", "lan")?.legs[0].peer?.port === "2", "tappaas2 lan: single enp97s0 → port 2");
check(node("tappaas1").ha?.lrm === "active" && node("tappaas2").ha?.lrm === "idle", "HA LRM state per node");

// ── guests ────────────────────────────────────────────────────────────
const allGuests = t.nodes.flatMap((n) => n.guests);
const fw = node("tappaas1").guests.find((g) => g.module === "network");
check(fw?.vmid === 110 && fw.kind === "vm" && fw.state === "running", "the firewall is VM 110 on tappaas1, running");
check(node("tappaas1").roles.includes("firewall") && node("tappaas1").roles.includes("mothership"), "tappaas1 hosts the firewall and the mothership");
check(node("tappaas3").roles.includes("backup"), "tappaas3 is the backup node");
check(node("tappaas1").guests.some((g) => g.module === "logging" && g.vmid === 150), "a guest placed by HA (no declared node) sits where it runs");
check(!allGuests.some((g) => g.kind === "machine"), "machine modules are not guests");
check(allGuests.filter((g) => g.vmid !== null).length === 18, `18 VM/LXC guests across the nodes (got ${allGuests.filter((g) => g.vmid !== null).length})`);

// ── the switch ────────────────────────────────────────────────────────
check(t.switches.length === 1 && sw.ports.length === 12, "one switch, twelve ports");
check(sw.lldpName === "USW-Pro-XG-10-PoE", "the switch carries the name LLDP knows it by");
check(sw.controller === "unifi-controller" && sw.controllerAddress === "https://unifi-os.mgmt.internal:11443", "…and its controller's address");
check(port("11").role === "node-lan" && port("11").target?.name === "tappaas1" && port("11").target?.port === "nic3", "port 11: tappaas1/nic3 (node lan)");
check(port("11").seen?.node === "tappaas1" && port("11").seen?.nic === "nic3", "…and LLDP agrees");
check(port("5").role === "isp" && port("5").target?.kind === "isp" && port("5").native === 100, "port 5: the ISP hand-off, access vlan 100");
check(port("6").role === "node-wan" && port("6").target?.name === "tappaas1" && port("6").target?.port === "nic4", "port 6: tappaas1's wan (a device port)");
check(port("7").role === "node-wan" && port("7").target?.name === "tappaas3", "port 7: tappaas3's wan");
check(port("9").role === "ap" && port("9").target?.name === "Nano HD", "port 9: the AP");
check(["1", "4", "8", "10"].every((p) => port(p).role === "unmanaged" && port(p).drift === "unmanaged"), "ports 1, 4, 8, 10 unmanaged");
check(port("2").zones.includes("rossen") && port("2").zones.includes("dmz") && !port("2").zones.includes("wan"), "a node trunk carries the service and client zones, not wan");
check(port("6").zones.join(",") === "wan", "a wan port's zone is wan");
const lag = sw.lags[0];
check(sw.lags.length === 1 && lag.name === "tappaas1-lan" && lag.ports.join("+") === "11+12" && lag.formed, "LAG tappaas1-lan on 11+12, formed");
check(lag.node === "tappaas1" && lag.bond === "lanbond", "…belongs to tappaas1's lanbond");

// ── WAN path ──────────────────────────────────────────────────────────
const w = t.site.wan;
check(w.vlan === 100 && w.zone === "wan" && w.publicIp === "auto" && w.ipv6, "WAN: vlan 100, public IP auto, IPv6 on");
check(w.handoff?.port === "5" && w.handoff.switch === SW, "WAN hand-off on port 5");
check(w.firewall?.vmid === 110 && w.firewall.node === "tappaas1" && w.firewall.standby === null, "firewall VM 110 on tappaas1, no HA standby declared");
check(w.paths.length === 2 && w.paths.some((p) => p.node === "tappaas1" && p.port === "6" && p.active) && w.paths.some((p) => p.node === "tappaas3" && p.port === "7" && !p.active),
  "two wan paths: tappaas1 port 6 (active), tappaas3 port 7");

// ── access points, zones, outside ─────────────────────────────────────
check(t.accessPoints.length === 1 && t.accessPoints[0].uplink?.port === "9" && t.accessPoints[0].ssids.length === 0, "Nano HD on port 9, no SSIDs mapped");
const zoneNames = t.zones.map((z) => z.name);
for (const [z, v] of [["rossen", 200], ["test", 299], ["home", 310], ["iotLocal", 410], ["iotCloud", 420], ["iotCams", 430], ["guest", 510], ["dmz", 610]] as [string, number][]) {
  check(t.zones.find((x) => x.name === z)?.vlan === v, `zone ${z} on vlan ${v}`);
}
check(!zoneNames.some((z) => z.startsWith("_")), "documentation blocks are not zones");
const rasmus = t.outside.find((o) => o.name === "rasmus");
check(rasmus?.kind === "buddy" && rasmus.role === "remote" && rasmus.location === "Hareskov, DK", "buddy rasmus, remote, Hareskov");
check(rasmus?.state === "down", "…the pulse reports it down");

// ── findings on their objects ─────────────────────────────────────────
const fOn = (kind: string, name: string) => t.findings.filter((f) => f.on.kind === kind && f.on.name === name);
const lanF = fOn("node", "tappaas1").filter((f) => f.gate === "lan-uplink");
check(lanF.length === 2 && lanF.some((f) => /same switch/.test(f.text)), "tappaas1 carries both lan-uplink warnings");
check(lanF.every((f) => f.refs.some((r) => r.kind === "lag" && r.name === "tappaas1-lan") && f.refs.some((r) => r.kind === "port" && r.name === "11")),
  "…placed on its LAG and on ports 11 and 12");
check(fOn("module", "immich").some((f) => f.gate === "guest-memory" && f.level === "fail"), "immich's guest-memory FAIL is on immich");
check(fOn("module", "immich").every((f) => f.refs.some((r) => r.kind === "node" && r.name === "tappaas1")), "…and points at its node");
check(fOn("peer", "rasmus").some((f) => f.gate === "pulse"), "the pulse warning is on rasmus");
check(!t.findings.some((f) => f.gate === "topology"), "hrossen's sources reconcile: no topology findings");
check(t.sources.every((s) => s.ok), "every source answered");
check(renderTopology(t).some((l) => /ISP → USW Pro XG 10 PoE port 5, vlan 100/.test(l)), "the text view draws the WAN path");

// ── reconciliation the fixture does not exercise ──────────────────────
{
  // The switch spells the NIC by MAC; the node has no LLDP on it.
  const s = hrossen();
  const net = s.networks.tappaas3!;
  const eno1 = net.live.lan.members[0];
  eno1.lldp = null;
  net.live.ports = net.live.ports.map((p) => (p.name === "eno1" ? { ...p, lldp: null } : p));
  s.ports![0].ports = s.ports![0].ports.map((p) => (p.port === "3" ? { ...p, targetPort: eno1.mac.toUpperCase() } : p));
  const x = buildTopology(s);
  const leg = x.nodes.find((n) => n.name === "tappaas3")!.uplinks[0].legs[0];
  check(leg.peer?.port === "3" && leg.peer.via === "inventory", "no LLDP: the inventory's MAC spelling places the leg");
  check(x.switches[0].ports.find((p) => p.port === "3")!.target?.port === "eno1", "…and the port names the NIC as the node does");
}
{
  // LLDP sees a node on a port the inventory leaves unmanaged.
  const s = hrossen();
  const net = s.networks.tappaas2!;
  net.live.lan.members[0].lldp = { name: "USW-Pro-XG-10-PoE", port: "Port 4" };
  const x = buildTopology(s);
  check(x.findings.some((f) => f.gate === "topology" && f.on.kind === "port" && f.on.name === "4"), "a node seen on an unregistered port is a topology finding");
}
{
  // A leg on a switch nobody registered.
  const s = hrossen();
  s.networks.tappaas2!.live.lan.members[0].lldp = { name: "core-sw2", port: "7" };
  const x = buildTopology(s);
  const leg = x.nodes.find((n) => n.name === "tappaas2")!.uplinks[0].legs[0];
  check(leg.peer?.switch === "core-sw2" && leg.peer.known === false, "an unknown LLDP switch is kept by its own name");
  check(x.findings.some((f) => f.gate === "topology" && f.on.kind === "node" && f.on.name === "tappaas2"), "…and reported");
}
{
  // A port in drift.
  const s = hrossen();
  s.ports![0].ports = s.ports![0].ports.map((p) => (p.port === "2" ? { ...p, drift: "drift" as const, add: [430], remove: [] } : p));
  const x = buildTopology(s);
  check(x.findings.some((f) => f.gate === "switch-drift" && f.on.name === "2" && /add 430/.test(f.text)), "a drifting port is a switch-drift finding on that port");
}
{
  // #854: port 12 follows its lead, port 11 — the VLANs the switch reports on the
  // member itself (UniFi ignores them while the aggregate stands) are no drift.
  // An older switch-manager: no lagLead, the member drifting by its own VLANs.
  const s = hrossen();
  check(s.ports![0].ports.every((p) => p.lagLead === undefined), "the fixture is an older controller's: no lagLead");
  s.ports![0].ports = s.ports![0].ports.map((p) =>
    p.port === "12" ? { ...p, taggedVlans: [100, 200, 298, 299, 310, 410, 420, 430, 510, 610], drift: "drift" as const, add: [], remove: [100, 298] } : p);
  const x = buildTopology(s);
  const p12 = x.switches[0].ports.find((p) => p.port === "12")!;
  const p11 = x.switches[0].ports.find((p) => p.port === "11")!;
  check(p12.lagLead === "11" && p11.lagLead === null, "a LAG's member follows its lowest port when the controller does not say (#854)");
  check(p12.tagged.join(",") === p11.tagged.join(",") && p12.drift === "in-sync", "…carries the lead's VLANs and no drift");
  check(!x.findings.some((f) => f.gate === "switch-drift" && f.on.name === "12"), "…and is no switch-drift finding");
  // The controller names the lead: that one wins.
  const s2 = hrossen();
  s2.ports![0].ports = s2.ports![0].ports.map((p) => (p.port === "12" ? { ...p, lagLead: "11", taggedVlans: [100] } : p.port === "11" ? { ...p, lagLead: null } : p));
  check(buildTopology(s2).switches[0].ports.find((p) => p.port === "12")!.tagged.includes(200), "a member named by lagLead shows its lead's VLANs");
}
{
  // #853: a parked port, and validate's switch-ports finding placed on its port.
  const s = hrossen();
  s.ports![0].ports = s.ports![0].ports.map((p) =>
    p.port === "4" ? { ...p, parked: true, zone: "iotLocal", link: "down", desired: { mode: "access", nativeVlan: 410, taggedVlans: [] }, drift: "drift" as const } : p);
  s.health = { status: "warn", gates: [{ name: "switch-ports", status: "warn", detail: "", findings: [
    { status: "warn", text: "USW Pro XG 10 PoE port 4: set otherwise than its record", subject: { kind: "port", name: "USW Pro XG 10 PoE:4" } },
  ] }] };
  const x = buildTopology(s);
  const p4 = x.switches[0].ports.find((p) => p.port === "4")!;
  check(p4.role === "parked" && p4.parked && p4.link === "down", "a parked port has the parked role, and its link");
  check(x.findings.some((f) => f.gate === "switch-ports" && f.on.kind === "port" && f.on.name === "4" && f.on.switch === SW), "validate's switch-ports finding is on that port");
}
{
  // A source that does not answer leaves its part empty and is named.
  const runs: string[] = [];
  const src = collectSources({
    configDir: FIX,
    zonesFile: join(FIX, "zones.json"),
    health: null,
    wanAddressFile: join(FIX, "no-wan-address.json"),
    run: (bin, args) => {
      runs.push(`${bin} ${args.join(" ")}`);
      if (bin === "switch-manager") return { rc: 1, stdout: "", stderr: "zones.json not found", ran: true };
      if (bin === "site-manager" && args[1] === "list") return { rc: 0, stdout: readFileSync(join(FIX, "node-list.json"), "utf8"), stderr: "", ran: true };
      if (bin === "site-manager") return { rc: 0, stdout: readFileSync(join(FIX, `network-${args[3]}.json`), "utf8"), stderr: "", ran: true };
      return { rc: -1, stdout: "", stderr: "", ran: false };
    },
  });
  const x = buildTopology(src);
  check(!runs.some((r) => r.startsWith("health-manager")), "--health given (or none): validate is not run");
  check(runs.filter((r) => r.includes("network show")).length === 3, "one network show per node");
  check(x.switches.length === 0 && x.nodes.length === 3, "no switch inventory: nodes still drawn, no switches");
  check(x.sources.some((s) => s.name === "switch-manager list-ports" && !s.ok && /zones\.json not found/.test(s.error ?? "")), "the failing source is named with its error");
  check(x.sources.some((s) => s.name === "module-manager module list" && !s.ok), "a missing binary is named");
  check(x.site.name === "rossen" && x.zones.length > 0, "site.json and zones.json are read from the config dir");
  check(x.site.wan.discovered === null && x.sources.some((s) => s.name === "wan-address.json" && s.ok), "no WAN address recorded: none shown, and not an error");
}

// ── the WAN's recorded address (network update.sh → /var/lib/tappaas/wan-address.json)
check(t.site.wan.discovered === null, "hrossen's capture has no WAN address record: discovered is null");
{
  const held = { ipv4: "8.8.4.4", prefix: 24, ipv6: ["2a13:e747:a210:8200::5"], private: false, observed: "2026-10-19T03:12:00+02:00" };
  const x = buildTopology({ ...hrossen(), wanAddress: held }, new Date("2026-10-19T12:00:00Z"));
  check(x.site.wan.publicIp === "auto" && x.site.wan.discovered?.ipv4 === "8.8.4.4", "publicIp stays as site.json says (auto); the WAN's address beside it");
  check(renderTopology(x).some((l) => /public address auto; the WAN holds 8\.8\.4\.4 \(2026-10-19/.test(l)), "the text view names the address the WAN holds");
  const behind = buildTopology({ ...hrossen(), wanAddress: { ...held, ipv4: "192.168.1.20", private: true } });
  check(renderTopology(behind).some((l) => /192\.168\.1\.20 \(private: behind another router\)/.test(l)), "a private WAN address says it is behind another router");

  const dir = mkdtempSync(join(tmpdir(), "nm-wan-"));
  const run = (): { rc: number; stdout: string; stderr: string; ran: boolean } => ({ rc: -1, stdout: "", stderr: "", ran: false });
  const read = (body: string) => {
    writeFileSync(join(dir, "wan-address.json"), body);
    return collectSources({ configDir: FIX, zonesFile: join(FIX, "zones.json"), health: null, run, wanAddressFile: join(dir, "wan-address.json") });
  };
  const ok = read(JSON.stringify(held));
  check(ok.wanAddress?.ipv4 === "8.8.4.4" && ok.wanAddress.ipv6.length === 1 && ok.wanAddress.observed === held.observed, "the record is read from the state file");
  check(read(JSON.stringify({ ipv4: "", ipv6: [] })).wanAddress === null, "a record without an address reads as none");
  const bad = read("{ not json");
  check(bad.wanAddress === null && bad.errors.some((e) => e.source === "wan-address.json"), "a malformed record is named as a source that did not answer");
  rmSync(dir, { recursive: true, force: true });
}

// ── an MLAG pair (test/fixtures/topology-mlag): two MikroTik switches, a LAG
// across them to tappaas1 (crs-b's member disabled), a LAG across them up to the
// UniFi switch, which aggregates 11+12 ────────────────────────────────────────
const MFIX = join(process.env.NM_FIXTURE_DIR ?? "test/fixtures", "topology-mlag");
const mload = <T>(f: string): T => JSON.parse(readFileSync(join(MFIX, f), "utf8")) as T;
function mlagSite(): TopoSources {
  return {
    site: { name: "lab" },
    nodes: [{ name: "tappaas1", storagePools: [] }],
    networks: { tappaas1: mload<NodeNetwork>("network-tappaas1.json") },
    switches: mload<SwitchList>("switches.json"),
    ports: mload<SwitchPorts[]>("switch-ports.json"),
    lags: mload<LagRow[]>("lags.json"),
    accessPoints: [],
    zones: load<Record<string, unknown>>("zones.json"),
    modules: [],
    peers: [],
    health: null,
    firewall: null,
    satellites: [],
    actual: mload<SwitchActual>("actual.json"),
    errors: [],
  };
}
{
  const m = buildTopology(mlagSite());
  const text = renderTopology(m);
  const line = (re: RegExp): string | undefined => text.find((l) => re.test(l));
  const mport = (sw: string, p: string): TopoPort => m.switches.find((x) => x.name === sw)!.ports.find((x) => x.port === p)!;

  // node legs on two switches
  const legs = m.nodes[0].uplinks.find((u) => u.name === "lan")!.legs;
  check(legs.map((l) => `${l.nic}:${l.peer?.switch}:${l.peer?.port}:${l.peer?.via}`).join(" ") === "nic2:crs-a:sfp-sfpplus1:lldp nic3:crs-b:sfp-sfpplus1:inventory",
    "MLAG: nic2 on crs-a sfp-sfpplus1 (LLDP, port id kept whole), nic3 on crs-b sfp-sfpplus1 (inventory)");
  check(!!line(/^  tappaas1 +lan lacp lanbond nic2@10G→crs-a:sfp-sfpplus1 nic3@10G\(down\)→crs-b:sfp-sfpplus1; wan single nic4@10G→USW Pro XG 10 PoE:6$/),
    "MLAG: the node line names <switch>:<port> for each leg");
  check(!m.findings.some((f) => f.gate === "topology"), "MLAG: the fixture reconciles, no topology findings");

  // the pair and its peer link
  check(m.mlagPairs.length === 1 && m.mlagPairs[0].name === "crs-a+crs-b" && m.mlagPairs[0].switches.join(",") === "crs-a,crs-b", "MLAG: the pair crs-a + crs-b");
  check(m.mlagPairs[0].peerLink.every((x) => x.port === "peer-link" && x.members.join(",") === "sfp-sfpplus15,sfp-sfpplus16"), "MLAG: each side's peer link and its members");
  check(!!line(/^  MLAG pair crs-a \+ crs-b — peer link crs-a peer-link \(sfp-sfpplus15\+16\), crs-b peer-link \(sfp-sfpplus15\+16\)$/), "MLAG: the text view draws the pair and its peer link");
  check(!!line(/^    live state: switch-manager mlag-pair list$/), "MLAG: …and names the verb for its live state");
  const pl = mport("crs-a", "sfp-sfpplus16");
  check(pl.role === "peer-link" && pl.status === "peer-link" && pl.peerLink && pl.target?.name === "crs-b" && pl.target.port === "peer-link",
    "MLAG: a peer-link member is a peer-link port to the other switch, not unmanaged");
  check(!text.some((l) => /sfp-sfpplus1[56] +unmanaged/.test(l)), "MLAG: no peer-link member reads unmanaged");
  check(m.switches.filter((x) => x.mlagPair === "crs-a+crs-b").length === 2, "MLAG: both switches know their pair");

  // LAGs across the pair, once
  check(m.switches.every((x) => x.lags.every((l) => l.pair === null)) && m.switches.find((x) => x.name === "crs-a")!.lags.length === 0, "MLAG: no LAG across the pair is listed under a switch");
  check(text.filter((l) => /LAG tappaas1-lan/.test(l) && /^ {4}LAG/.test(l)).length === 1, "MLAG: tappaas1-lan is drawn once");
  const tl = m.mlagPairs[0].lags.find((l) => l.name === "tappaas1-lan")!;
  check(tl.mlagId === 10 && tl.ports.join(",") === "crs-a:sfp-sfpplus1,crs-b:sfp-sfpplus1" && tl.node === "tappaas1" && tl.bond === "lanbond", "MLAG: tappaas1-lan across the pair, mlag-id 10, tappaas1's lanbond");
  check(!tl.formed && tl.members.map((x) => `${x.switch}:${x.port}:${x.active}:${x.why}`).join(" ") === "crs-a:sfp-sfpplus1:true:null crs-b:sfp-sfpplus1:false:disabled",
    "MLAG: a disabled member: not formed, member state per switch");
  check(!!line(/^    LAG tappaas1-lan across crs-a \+ crs-b \(mlag-id 10\): crs-a:sfp-sfpplus1, crs-b:sfp-sfpplus1 1 of 2 members active \(crs-b:sfp-sfpplus1 disabled\) — tappaas1 lanbond$/),
    "MLAG: the text view says 1 of 2 members active, which and why");
  const ul = m.mlagPairs[0].lags.find((l) => l.name === "usw-uplink")!;
  check(ul.formed && ul.mlagId === 11 && ul.peer?.kind === "switch" && ul.peer.name === "USW Pro XG 10 PoE", "MLAG: usw-uplink across the pair is formed, up to the UniFi switch");
  check(!!line(/^    LAG usw-uplink across crs-a \+ crs-b \(mlag-id 11\): crs-a:sfp-sfpplus14, crs-b:sfp-sfpplus14 formed — switch USW Pro XG 10 PoE$/), "MLAG: …drawn under the pair");
  const cu = m.switches.find((x) => x.name === "USW Pro XG 10 PoE")!.lags[0];
  check(cu.name === "crs-uplink" && cu.formed && cu.pair === null && cu.peer?.kind === "pair" && cu.peer.name === "crs-a+crs-b", "MLAG: the UniFi LAG on 11+12 stays under its switch, up to the pair");
  check(!!line(/^    LAG crs-uplink: ports 11\+12 formed — MLAG pair crs-a \+ crs-b$/), "MLAG: …and reads so");

  // disabled ports
  const d = mport("crs-b", "sfp-sfpplus1");
  check(d.disabled && d.status === "disabled" && d.drift === "in-sync", "MLAG: a disabled port reads disabled, not in-sync");
  check(!!line(/^    sfp-sfpplus1 +node-lan  node tappaas1\/nic3 +trunk 8 +disabled  LAG tappaas1-lan$/), "MLAG: …in the text view");
  const e1 = mport("crs-a", "ether1");
  check(e1.bridged === false && e1.status === "unmanaged" && e1.role === "unmanaged", "MLAG: ether1 off the bridge stays unmanaged, not disabled");
  check(text.some((l) => /^ {4}sfp-sfpplus10  parked/.test(l)) && !text.some((l) => /sfp-sfpplus10[a-z]/.test(l)), "MLAG: port ids keep their own column");

  // LAG members down: formed is not claimed from configured members
  const s2 = mlagSite();
  s2.ports![0].ports = s2.ports![0].ports.map((p) => (p.port === "12" ? { ...p, link: "down" } : p));
  const cu2 = buildTopology(s2).switches[0].lags[0];
  check(!cu2.formed && cu2.members.find((x) => x.port === "12")?.why === "link down", "a LAG member with its link down: the LAG is not formed");
  check(renderTopology(buildTopology(s2)).some((l) => /^    LAG crs-uplink: ports 11\+12 1 of 2 members active \(12 link down\)/.test(l)), "…1 of 2 members active (12 link down)");
  const s3 = mlagSite();
  s3.lags = s3.lags!.filter((l) => !(l.switch === "crs-b" && l.name === "usw-uplink"));
  const ul3 = buildTopology(s3).mlagPairs[0].lags.find((l) => l.name === "usw-uplink")!;
  check(!ul3.formed && ul3.missing.join(",") === "crs-b", "a LAG with no member on one peer is not formed and says which");

  // JSON carries the pair and the LAGs across it
  const j = JSON.parse(JSON.stringify(m)) as Topology;
  check(j.mlagPairs[0].lags.length === 2 && j.mlagPairs[0].lags.every((l) => l.members.length === 2), "--json carries the pair and both LAGs across it");

  // a single-switch (UniFi-only) site keeps the bare port id
  check(renderTopology(t).some((l) => /^  tappaas1 +lan lacp lanbond nic2@10G→12 nic3@10G→11; wan single nic4@10G→6$/.test(l)), "one switch: the node line keeps bare port ids");
  check(t.mlagPairs.length === 0 && !renderTopology(t).some((l) => /MLAG/.test(l)), "no pair: nothing about MLAG");
  check(renderTopology(t).some((l) => /^    LAG tappaas1-lan: ports 11\+12 formed — tappaas1 lanbond$/.test(l)), "one switch: the LAG line is as before");
  check(portCompare("sfp-sfpplus2", "sfp-sfpplus10") < 0 && portCompare("2", "11") < 0, "ports order naturally");
  check(compactPorts(["sfp-sfpplus15", "sfp-sfpplus16"]) === "sfp-sfpplus15+16" && compactPorts(["11", "12"]) === "11+12", "port lists compact");
}

// ── the racks (rack-manager export) ─────────────────────────────────
check(t.racks === null && !t.sources.some((s) => s.name === "rack-manager export"), "no racks read: racks is null and not a source");
{
  const plate = (key: string, units: number, generic?: "nics" | "ports") => ({ key, vendor: "Generic", model: key, kind: "server" as const, units, width: "full" as const, rows: [], ...(generic ? { generic } : {}) });
  const catalog = [plate("generic/server-2u", 2, "nics"), { ...plate("generic/switch-1u", 1, "ports"), kind: "switch" as const }];
  const doc = {
    version: 1 as const,
    racks: { rack1: { units: 42, width: "19in" as const, numbering: "bottom-up" as const } },
    mounts: {
      tappaas1: { rack: "rack1", u: 10, height: 2, width: "full" as const, face: "front" as const, faceplate: "generic/server-2u" },
      [SW]: { rack: "rack1", u: 20, height: 1, width: "full" as const, face: "front" as const },
      tappaas7: { rack: "rack1", u: 30, height: 1, width: "full" as const, face: "front" as const },
    },
  };
  const x = buildTopology({ ...hrossen(), racks: { doc, catalog } });
  const r = x.racks!;
  check(r.racks.length === 1 && r.racks[0].mounts.length === 3, "the rack with its mounts");
  const m = r.racks[0].mounts.find((y) => y.device === SW)!;
  check(m.faceplate === "generic/switch-1u" && m.suggested && m.plate!.rows.length === 2, "an unrecorded plate: the generic switch, odd over even");
  check(r.cables.some((c) => c.to.device === "tappaas1" && c.from.port === "11" && c.lag !== null), "tappaas1's LAG legs are cables on the switch's ports");
  check(x.findings.some((f) => f.gate === "topology" && f.on.kind === "rack" && f.on.name === "rack1" && /tappaas7/.test(f.text)), "a mount whose device is gone: a finding on the rack");
  check(x.findings.some((f) => f.gate === "topology" && f.on.kind === "node" && f.on.name === "tappaas2" && /mounted in no rack/.test(f.text)), "a node mounted nowhere: a finding on it");
  check(x.findings.some((f) => f.on.kind === "ap" && f.on.name === "Nano HD"), "an access point mounted nowhere: a finding on it");
  check(renderTopology(x).some((l) => /^ {4}U20 front {2}USW Pro XG 10 PoE {2}generic\/switch-1u \(suggested\)/.test(l)), "the text view lists the mounts");
  const none = buildTopology({ ...hrossen(), racks: { doc: {}, catalog } });
  check(none.racks!.racks.length === 0 && !none.findings.some((f) => f.gate === "topology"), "an empty racks.json: no rack, no finding");
}
{
  const runs: string[] = [];
  const fake = (bin: string, args: string[]) => {
    runs.push(`${bin} ${args.join(" ")}`);
    return { rc: -1, stdout: "", stderr: "", ran: false };
  };
  const skip = collectSources({ configDir: FIX, zonesFile: join(FIX, "zones.json"), health: null, wanAddressFile: join(FIX, "none.json"), run: fake, racks: false });
  check(!runs.some((r) => r.startsWith("rack-manager")) && skip.racks === undefined, "--no-racks: rack-manager is not run");
  const asked = collectSources({ configDir: FIX, zonesFile: join(FIX, "zones.json"), health: null, wanAddressFile: join(FIX, "none.json"), run: fake });
  check(runs.includes("rack-manager export --json") && asked.racks === null, "racks read through rack-manager export");
  check(buildTopology(asked).sources.some((s) => s.name === "rack-manager export" && !s.ok), "no rack-manager: the source is named");
}

console.log(`\ntopology: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exitCode = 1;
