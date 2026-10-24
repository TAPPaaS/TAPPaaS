// ipv6egress.ts — the ipv6-egress gate (#875).
//
// On hrossen IPv6 egress for every zone was broken for a day and nothing
// noticed: the ISP replaced its router, OPNsense kept the one it had recorded,
// and IPv4 carried everything else. Two halves, both read-only:
//
//   the firewall   `ipv6-manager wan --json` (ssh to the firewall): an IPv6
//                  default route, its router answering on the WAN, the router
//                  OPNsense records and the WAN_DHCP6 gateway naming the same
//                  one, rtsold running, a delegated prefix
//   the egress     a public IPv6 address answering from inside the site — an
//                  HTTP HEAD over IPv6 from this (cicd) VM when it holds a
//                  global address, else a ping from a guest in a Service zone
//                  with IPv6. Never from the firewall: pf lets the firewall
//                  itself reach fe80::/10 only, so its own ping always fails.
//
//   site.json ipv6 off                          skip
//   both halves fine                            pass
//   the firewall half fine, nothing probed      pass, says so
//   anything else                               warn, with the cause
//
// WARN, never FAIL: IPv4 still carries the site (dual-stack clients fall back).

import { spawnSync } from "child_process";
import { join } from "path";
import { ssh } from "../../../lib/ts/src/cluster";
import { isManaged, loadConfigModules, readModuleJson } from "./config";
import { configField, guestTarget } from "./checks";
import { CheckResult, CheckRow, CheckSubject } from "./types";

// What ipv6-manager wan --json prints (opnsense-controller wan6.WanState).
export interface Wan6 {
  wanif: string;
  recorded: string;
  route: string;
  gateway: string;
  prefix: string;
  address: string;
  rtsold: boolean;
  routerAnswers: boolean;
}

export interface EgressProbe {
  from: string;        // "cicd" or the guest's module name
  to: string;          // the public address that answered, or the first tried
  ok: boolean;
  noAddress?: boolean; // the probing host holds no global IPv6 address
}

export interface EgressInput {
  ipv6: boolean;
  wan: Wan6 | null;
  wanError?: string;
  probe: EgressProbe | null;
}

// Two well-run anycast resolvers: one answering is egress.
export const PUBLIC_V6 = ["2606:4700:4700::1111", "2001:4860:4860::8888"];
export const RELEARN = "configctl interface reconfigure wan on the firewall, then the network module's update";

const FIREWALL: CheckSubject = { kind: "module", name: "network" };
const UPLINK: CheckSubject = { kind: "site", name: "uplink" };

export function ipv6EgressResult(i: EgressInput): CheckResult {
  const name = "ipv6-egress";
  if (!i.ipv6) return { name, status: "skip", detail: "IPv6 is off (site.json ipv6)" };
  const rows: CheckRow[] = [];
  const fw = (text: string) => rows.push({ status: "warn", text, subject: FIREWALL });
  const w = i.wan;
  if (!w) {
    fw(`the firewall's IPv6 WAN could not be read (ipv6-manager wan)${i.wanError ? `: ${i.wanError}` : ""}`);
  } else if (!w.wanif) {
    fw("the firewall has no WAN interface assigned");
  } else {
    // The router is the incident's cause, so one row says all of it and names the verb.
    if (!w.route) {
      fw(`no IPv6 default route on the firewall${w.recorded ? ` (OPNsense records router ${w.recorded})` : ""} — re-learn the WAN's router: ${RELEARN}`);
    } else if (!w.routerAnswers) {
      fw(`the IPv6 default route's router ${w.route} does not answer on ${w.wanif} — the ISP's router has changed; re-learn it: ${RELEARN}`);
    } else if (w.recorded !== w.route || w.gateway !== w.route) {
      fw(`the route is via ${w.route}, OPNsense records ${w.recorded || "none"} and WAN_DHCP6 names ${w.gateway || "none"} — the next WAN event sets the recorded one; ${RELEARN}`);
    }
    if (!w.rtsold) fw(`rtsold is not running: a new router on the WAN is never learned — ${RELEARN}`);
    if (!w.prefix) fw("no delegated IPv6 prefix on the WAN: the zones have no IPv6 to route");
  }
  const p = i.probe;
  if (p && !p.ok) {
    rows.push({
      status: "warn",
      subject: UPLINK,
      text: p.noAddress
        ? `${p.from} holds no global IPv6 address — its zone's advertisements: network-manager reconcile, or the network module's update`
        : `no public IPv6 address answered from ${p.from} (${PUBLIC_V6.join(", ")})`,
    });
  }
  const route = w?.route ? `default route via ${w.route}` : "";
  if (rows.length === 0) {
    const egress = p ? `${p.to} answers from ${p.from}` : "egress not probed (no global IPv6 on cicd, no Service-zone guest answered)";
    return { name, status: "pass", detail: `${route}, prefix ${w?.prefix}; ${egress}` };
  }
  return {
    name,
    status: "warn",
    detail: `IPv6 egress ${p?.ok ? "answers but the firewall is not as recorded" : "fails"}: ${rows.map((r) => r.text).join("; ")}`,
    rows,
  };
}

// ── the reads ─────────────────────────────────────────────────────────

const IPV6_MANAGER_BIN = process.env.IPV6_MANAGER_BIN ?? "ipv6-manager";

function readWan(): { wan: Wan6 | null; error?: string } {
  const r = spawnSync(IPV6_MANAGER_BIN, ["wan", "--json"], { encoding: "utf8", timeout: 90_000 });
  if (r.error || r.status !== 0) {
    return { wan: null, error: (r.error?.message ?? r.stderr ?? "").trim().split("\n").pop() };
  }
  try {
    return { wan: JSON.parse(r.stdout ?? "") as Wan6 };
  } catch {
    return { wan: null, error: "not JSON" };
  }
}

// From this VM, when it holds a global IPv6 address: any HTTP answer is egress.
function probeLocal(): EgressProbe | null {
  const a = spawnSync("ip", ["-6", "-o", "addr", "show", "scope", "global"], { encoding: "utf8" });
  if (a.error || !(a.stdout ?? "").trim()) return null;
  for (const to of PUBLIC_V6) {
    const r = spawnSync("curl", ["-6", "-sS", "-o", "/dev/null", "-I", "--max-time", "6", `http://[${to}]/`], { encoding: "utf8" });
    if (r.status === 0) return { from: "cicd", to, ok: true };
  }
  return { from: "cicd", to: PUBLIC_V6[0], ok: false };
}

// The Service zones that run IPv6 (zones.json: type Service, an ipv6Subnet, live).
export function serviceV6Zones(zones: Record<string, unknown>): string[] {
  return Object.entries(zones)
    .filter(([k, z]) => !k.startsWith("_") && z && typeof z === "object")
    .filter(([, z]) => {
      const o = z as Record<string, unknown>;
      return o.type === "Service" && o.ipv6Subnet !== undefined && o.ipv6Subnet !== null &&
        (o.state === "Active" || o.state === "Mandatory");
    })
    .map(([k]) => k);
}

// From a guest: the first of up to three in a Service zone with IPv6 that answers ssh.
function probeGuest(configDir: string, defaultNode: string): EgressProbe | null {
  const zones = serviceV6Zones(readModuleJson(join(configDir, "zones.json")) ?? {});
  const guests = loadConfigModules(configDir, defaultNode)
    .filter(isManaged)
    .filter((m) => {
      const z0 = configField(readModuleJson(join(configDir, `${m.module}.json`)) ?? {}, "zone0");
      return typeof z0 === "string" && zones.includes(z0);
    })
    .map((m) => m.module)
    .sort();
  const pings = PUBLIC_V6.map((a) => `ping -6 -c 2 -W 3 ${a} >/dev/null 2>&1 && echo "ok ${a}"`).join(" || ");
  let tried = 0;
  for (const g of guests) {
    if (tried >= 3) break;
    const target = guestTarget(configDir, g);
    if (!target) continue;
    tried++;
    const r = ssh("tappaas", target, `echo "addr $(ip -6 -o addr show scope global | wc -l)"; ${pings} || echo fail`);
    if (!r.ran || r.rc === 255) continue; // unreachable: try the next
    const out = r.stdout;
    const ok = /^ok (\S+)/m.exec(out);
    if (ok) return { from: g, to: ok[1], ok: true };
    return { from: g, to: PUBLIC_V6[0], ok: false, noAddress: /^addr 0$/m.test(out) };
  }
  return null;
}

export function checkIpv6Egress(configDir: string, defaultNode: string): CheckResult {
  const site = readModuleJson(join(configDir, "site.json")) ?? {};
  if (site.ipv6 !== true) return ipv6EgressResult({ ipv6: false, wan: null, probe: null });
  const { wan, error } = readWan();
  const probe = probeLocal() ?? probeGuest(configDir, defaultNode);
  return ipv6EgressResult({ ipv6: true, wan, wanError: error, probe });
}
