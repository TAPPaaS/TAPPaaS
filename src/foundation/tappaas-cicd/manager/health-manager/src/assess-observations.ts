// assess-observations.ts — ADR-041 step 2: what the managers' reports let `assess`
// judge beyond the gates. Pure over the CMDB's objects and relations, as
// fromThresholds: the managers observe, this judges, and no plane is asked.
//
// One judgement per class; the README's "What judges which class" is the map.
// `ended` holds the CIs retired: their relations are gone, their attributes stay.

import { CmdbItem, SiteIndex } from "./assess-model";
import { DAY, Finding, ok, timeOf } from "./assess-sources";
import { ConditionStatus, ConditionType } from "../../../lib/ts/src/health-rules";

export const RESTORE_STALE_DAYS = 3;
export const PEER_STALE_DAYS = 3;

// The reasons of this source: only it takes them back (assess.ts ownerOf).
export const OBSERVATION_REASONS = [
  "unseen", "role-port-down", "link-slow", "asset-faulty",
  "address-holder-unseen", "address-holder-retired", "address-no-ci",
  "dns-no-target", "dns-target-unknown", "dns-target-unseen", "dns-target-retired",
  "route-target-unknown", "route-target-unseen", "route-target-retired",
  "zone-interface-disabled", "zone-no-interface", "zone-vlan-uncarried", "vlan-undeclared",
  "ssid-no-zone", "ssid-not-broadcast",
  "software-no-node", "software-node-unseen", "version-off-pin",
  "gc-failed", "restore-point-stale", "peer-stale", "share-consumer-gone",
];

const NODES = ["vm", "lxc", "machine", "device"];
const ASSETS = new Set(["server", "network-device", "appliance", "passive-device", "other-device"]);
const SOFTWARE = new Set(["app", "service", "controller", "manager"]);
// Their colour is their members' (derive.ts), or a judgement below.
const NOT_LIFECYCLE = new Set(["port", "address", "dns-name", "proxy-route", "location", "room", "rack", "node", ...ASSETS, ...SOFTWARE]);

// Mbit/s of a D9 speed word, for ordering them.
const MBPS: Record<string, number> = { "100m": 100, "1g": 1000, "2.5g": 2500, "5g": 5000, "10g": 10000, "25g": 25000 };

type Obj = Record<string, unknown>;
const list = (v: unknown): Obj[] => (Array.isArray(v) ? (v as Obj[]) : []);
const text = (v: unknown): string => (typeof v === "string" ? v : "");
const isIp = (s: string): boolean => /^\d+\.\d+\.\d+\.\d+$/.test(s) || s.includes(":");
const unseen = (o: CmdbItem): boolean => o.attributes.stage === "unseen";
const named = (o: CmdbItem): string => `${o.class} ${o.name}`;

function addressesOf(o: CmdbItem): string[] {
  const a = o.attributes;
  return [...(Array.isArray(a.addresses) ? (a.addresses as string[]) : []), text(a.managementAddress)].filter(Boolean);
}

// Who answers on an address: a node's own, else the node a private name points
// it at (<node>.<zone>.internal).
function holdersOf(idx: SiteIndex, ended: CmdbItem[]): { live: Map<string, CmdbItem>; retired: Map<string, CmdbItem> } {
  const live = new Map<string, CmdbItem>();
  const retired = new Map<string, CmdbItem>();
  for (const o of idx.objects) if (NODES.includes(o.class)) for (const ip of addressesOf(o)) live.set(ip, o);
  for (const o of idx.objects) {
    if (o.class !== "dns-name" || o.attributes.public === true) continue;
    const node = idx.named(o.name.split(".")[0], NODES);
    const ip = text(o.attributes.target);
    if (node && ip && !live.has(ip)) live.set(ip, node);
  }
  for (const o of ended) for (const ip of addressesOf(o)) retired.set(ip, o);
  return { live, retired };
}

// Every MAC the CMDB can place: a NIC's, a port's, what a port or an AP sees.
function macsKnown(idx: SiteIndex): Set<string> {
  const out = new Set<string>();
  const put = (m: unknown): void => void (typeof m === "string" && m && out.add(m.toLowerCase()));
  for (const o of idx.objects) {
    const a = o.attributes;
    put(a.mac);
    for (const n of [...list(a.nics), ...list(a.seen), ...list(a.clients)]) put(n.mac);
  }
  return out;
}

type Add = (o: CmdbItem, type: ConditionType, status: ConditionStatus, reason: string, message: string) => void;

function judgePort(o: CmdbItem, idx: SiteIndex, cabled: Map<string, { speed: string | null; others: string[] }>, add: Add): void {
  const a = o.attributes;
  const cable = cabled.get(o.id);
  if (!cable) {
    // A recorded port is mostly a free one: only a declared use expects a link.
    if (typeof a.link !== "string") return;
    const expected = typeof a.role === "string";
    add(o, "operational", expected && a.link === "down" ? "warning" : "ok", "role-port-down", `${o.name}: ${expected ? `role ${String(a.role)}` : "no cable"}, link ${a.link}`);
    return;
  }
  const now = MBPS[text(a.linkSpeed)];
  if (a.link === "down" || !now) return;
  const ends = [text(a.speed), ...cable.others.map((id) => text(idx.byId.get(id)?.attributes.speed))].map((s) => MBPS[s]).filter(Boolean);
  const want = MBPS[cable.speed ?? ""] ?? (ends.length ? Math.min(...ends) : 0);
  if (!want) return;
  add(o, "operational", now < want ? "warning" : "ok", "link-slow", `${o.name}: ${text(a.linkSpeed)}${now < want ? `, the cable carries ${want} Mbit/s` : ""}`);
}

function judgeAddress(o: CmdbItem, h: ReturnType<typeof holdersOf>, macs: Set<string>, nowMs: number, add: Add): void {
  const a = o.attributes;
  const ip = text(a.ip) || o.name;
  const by = h.live.get(ip);
  const op = (status: ConditionStatus, reason: string, message: string): void => add(o, "operational", status, reason, message);
  if (by) return op(unseen(by) ? "warning" : "ok", "address-holder-unseen", `${ip}: ${named(by)}`);
  const until = timeOf(a.leaseUntil, nowMs);
  const leased = until !== null && until > nowMs;
  const was = h.retired.get(ip);
  if (was && !leased) return op("warning", "address-holder-retired", `${ip}: ${named(was)} is retired`);
  const mac = text(a.reservation).toLowerCase();
  if (mac) return op(macs.has(mac) ? "ok" : "warning", "address-no-ci", `${ip}: reserved for ${mac}${macs.has(mac) ? "" : ", which nothing in the CMDB has"}`);
  op("ok", "ok", `${ip}: ${leased ? "leased" : "no CI holds it"}`); // a lease names no MAC yet, so a client's is not told from a guest's
}

function judgeDns(o: CmdbItem, idx: SiteIndex, h: ReturnType<typeof holdersOf>, add: Add): void {
  const target = text(o.attributes.target);
  const dns = (status: ConditionStatus, reason: string, message: string): void => add(o, "operational", status, reason, message);
  if (!target) return dns("warning", "dns-no-target", `${o.name}: no target`);
  if (o.attributes.public === true) return dns("ok", "ok", `${o.name} → ${target}`); // the WAN's, which no address object holds
  if (!isIp(target)) return dns(idx.named(target.split(".")[0], NODES) || idx.named(target, ["dns-name"]) ? "ok" : "warning", "dns-target-unknown", `${o.name} → ${target}`);
  const by = h.live.get(target);
  if (by && unseen(by)) return dns("warning", "dns-target-unseen", `${o.name} → ${target}: ${named(by)}`);
  if (!by && h.retired.has(target)) return dns("warning", "dns-target-retired", `${o.name} → ${target}: ${named(h.retired.get(target)!)} is retired`);
  dns(by || idx.named(target, ["address"]) ? "ok" : "warning", "dns-target-unknown", `${o.name} → ${target}`);
}

function judgeRoute(o: CmdbItem, idx: SiteIndex, h: ReturnType<typeof holdersOf>, ended: CmdbItem[], add: Add): void {
  const target = text(o.attributes.target);
  const host = /^\w+:\/\/([^:/]+|\[[^\]]+\])/.exec(target)?.[1] ?? target;
  const label = host.split(".")[0];
  const node = isIp(host) ? h.live.get(host) : idx.named(label, NODES);
  const route = (status: ConditionStatus, reason: string, message: string): void => add(o, "operational", status, reason, message);
  if (node) return route(unseen(node) ? "warning" : "ok", "route-target-unseen", `${o.name} → ${named(node)}`);
  const was = ended.find((x) => x.name === label && NODES.includes(x.class));
  if (was) return route("warning", "route-target-retired", `${o.name} → ${named(was)} is retired`);
  route(idx.named(host, ["dns-name", "address"]) ? "ok" : "warning", "route-target-unknown", `${o.name} → ${host}`);
}

function judgeZones(idx: SiteIndex, add: Add): void {
  const zones = idx.objects.filter((o) => o.class === "zone");
  // A first report has no firewall read yet: no zone can be missing from it.
  const read = zones.some((z) => z.attributes.interface);
  const devices = idx.objects.filter((o) => o.class === "device" && Array.isArray(o.attributes.vlans));
  const carried = new Set(devices.flatMap((d) => list(d.attributes.vlans).map((v) => v.tag)));
  for (const z of zones) {
    const a = z.attributes;
    const nic = a.interface as { enabled?: unknown; device?: unknown } | undefined;
    const active = Boolean(a.dhcp);
    const op = (status: ConditionStatus, reason: string, message: string): void => add(z, "operational", status, reason, message);
    if (nic && nic.enabled === false && active) op("critical", "zone-interface-disabled", `${z.name}: active, its interface ${text(nic.device)} is disabled`);
    else if (!nic && active && read) op("warning", "zone-no-interface", `${z.name}: active, the firewall has no interface for it`);
    else if (active && typeof a.vlan === "number" && a.vlan > 0 && devices.length && !carried.has(a.vlan)) op("warning", "zone-vlan-uncarried", `${z.name}: VLAN ${a.vlan} is on no switch`);
    else op("ok", "ok", `${z.name}: ${active || nic ? "active" : "declared, not active"}`);
  }
  // VLAN 1 is every switch's own default.
  for (const d of devices) {
    const extra = list(d.attributes.vlans).filter((v) => v.declared === false && v.tag !== 1).map((v) => v.tag);
    add(d, "drift", extra.length ? "warning" : "ok", "vlan-undeclared", extra.length ? `${d.name}: VLAN ${extra.join(", ")} in no zone` : "");
  }
}

function judgeSsid(o: CmdbItem, idx: SiteIndex, add: Add): void {
  const zone = text(o.attributes.zone);
  const on = Array.isArray(o.attributes.broadcastOn) ? o.attributes.broadcastOn : [];
  if (zone && !idx.named(zone, ["zone"])) add(o, "operational", "warning", "ssid-no-zone", `${o.name}: zone ${zone} does not exist`);
  else add(o, "operational", on.length ? "ok" : "warning", "ssid-not-broadcast", `${o.name}: ${on.length ? `on ${on.join(", ")}` : "no access point broadcasts it"}`);
}

function judgeSoftware(o: CmdbItem, idx: SiteIndex, add: Add): void {
  const runs = idx.relations.filter((r) => r.type === "runs-on" && r.from.id === o.id).map((r) => idx.byId.get(r.to.id)).filter((x): x is CmdbItem => x !== undefined);
  const gone = runs.find(unseen);
  if (!runs.length) add(o, "operational", "warning", "software-no-node", `${o.name}: on no node`);
  else if (unseen(o) || gone) add(o, "operational", "warning", "software-node-unseen", `${o.name}: ${gone ? `${named(gone)} is unseen` : "unseen"}`);
  else add(o, "operational", "ok", "ok", `${o.name} on ${runs[0].name}`);
  const pin = text((o.attributes.release as { version?: unknown } | undefined)?.version);
  const version = text(o.attributes.version);
  if (pin && version && version !== "unknown") add(o, "maintenance", version === pin ? "ok" : "warning", "version-off-pin", `${o.name}: ${version}, released ${pin}`);
}

function judgeDatastore(o: CmdbItem, idx: SiteIndex, nowMs: number, add: Add): void {
  const gc = o.attributes.gc as { "last-run-state"?: unknown } | undefined;
  const state = text(gc?.["last-run-state"]);
  if (state) add(o, "maintenance", state === "OK" ? "ok" : "warning", "gc-failed", `${o.name}: garbage collection ${state}`);
  const vmid = new Map(idx.objects.filter((x) => x.class === "vm" || x.class === "lxc").map((x) => [String(x.attributes.vmid), x]));
  for (const g of list(o.attributes.restorePoints)) {
    // A group whose guest is gone only waits for pruning: no one's protection.
    const guest = g.type === "host" ? idx.named(text(g.id), NODES) : vmid.get(text(g.id));
    const t = timeOf(g.newest, nowMs);
    if (!guest || t === null) continue;
    const days = (nowMs - t) / DAY;
    add(guest, "backup", days > RESTORE_STALE_DAYS ? "warning" : "ok", "restore-point-stale", `newest restore point ${days.toFixed(0)} day(s) old`);
  }
}

/** What the CMDB's observations say, class by class. */
export function fromObservations(idx: SiteIndex, ended: CmdbItem[], nowMs: number): Finding[] {
  const out: Finding[] = [];
  const add: Add = (o, type, status, reason, message) => {
    out.push({ object: o.id, type, status, reason: ok(status, reason), message, owner: "observations" });
  };
  const holders = holdersOf(idx, ended);
  const macs = macsKnown(idx);
  const cabled = new Map<string, { speed: string | null; others: string[] }>();
  for (const r of idx.relations) {
    if (r.type !== "connects" || r.to.class !== "port") continue;
    const speed = text(r.attributes?.linkSpeed) || null;
    for (const [me, other] of [[r.from.id, r.to.id], [r.to.id, r.from.id]]) {
      const had = cabled.get(me);
      cabled.set(me, { speed: speed ?? had?.speed ?? null, others: [...(had?.others ?? []), other] });
    }
  }
  judgeZones(idx, add);
  for (const o of idx.objects) {
    const a = o.attributes;
    if (o.class === "port") judgePort(o, idx, cabled, add);
    else if (o.class === "address") judgeAddress(o, holders, macs, nowMs, add);
    else if (o.class === "dns-name") judgeDns(o, idx, holders, add);
    else if (o.class === "proxy-route") judgeRoute(o, idx, holders, ended, add);
    else if (SOFTWARE.has(o.class)) judgeSoftware(o, idx, add);
    else if (ASSETS.has(o.class)) add(o, "maintenance", a.faulty === true ? "warning" : "ok", "asset-faulty", a.faulty === true ? `${o.name}: faulty${a.faultNote ? `: ${text(a.faultNote)}` : ""}` : "");
    if (o.class === "ssid") judgeSsid(o, idx, add);
    if (o.class === "datastore") judgeDatastore(o, idx, nowMs, add);
    if (o.class === "backup-peer" && a.lastSeen) {
      const t = timeOf(a.lastSeen, nowMs);
      if (t !== null) add(o, "backup", (nowMs - t) / DAY > PEER_STALE_DAYS ? "warning" : "ok", "peer-stale", `last synced ${((nowMs - t) / DAY).toFixed(0)} day(s) ago`);
    }
    if (o.class === "share") {
      const lost = list(a.grants).map((g) => text(g.consumer)).filter((c) => c && !idx.named(c, NODES));
      add(o, "operational", lost.length ? "warning" : "ok", "share-consumer-gone", lost.length ? `${o.name}: grants ${lost.join(", ")}, no such node` : `${o.name}: every consumer exists`);
    }
    // Whatever else reports at all: seen within its class's expiry, or not.
    if (!NOT_LIFECYCLE.has(o.class)) add(o, "operational", unseen(o) ? "warning" : "ok", "unseen", unseen(o) ? `${o.name}: no source has reported it within its expiry` : "");
  }
  return out;
}
