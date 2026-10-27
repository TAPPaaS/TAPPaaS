// port.ts — where a new node is cabled (ADR-037 D4): `node add --switch-port`.
//
// On a switch TAPPaaS manages, the port becomes a node trunk and the machine's
// MAC is learned from it once it netboots: a MAC behind the port that was not
// there before, and is no cluster node's. On a switch TAPPaaS does not manage,
// the operator configures the port by hand — what to configure is printed from
// zones.json — and gives the MAC.

import { spawnSync } from "child_process";
import * as fs from "fs";

import { GN, YW, CL, die, info, warn } from "../../../lib/ts/src/cli";
import { clusterNodes } from "../../../lib/ts/src/nodes";
import { defaultConfigDir } from "./config";

export interface SwitchPort { switch: string; port: string }

// "<switch>:<port>" — a switch name may hold spaces and colons, a port name
// does not, so the port is after the last colon. Pure.
export function parseSwitchPort(v: string): SwitchPort | null {
  const i = v.lastIndexOf(":");
  if (i <= 0 || i === v.length - 1) return null;
  return { switch: v.slice(0, i).trim(), port: v.slice(i + 1).trim() };
}

// The VLANs a node trunk carries tagged: every active zone's (Active or
// Mandatory, with a VLAN tag); mgmt is untagged. Pure.
export function nodeTrunkVlans(zones: Record<string, { state?: string; vlantag?: number }>): number[] {
  return [...new Set(Object.entries(zones)
    .filter(([k, z]) => !k.startsWith("_") && (z.state === "Active" || z.state === "Mandatory") && (z.vlantag ?? 0) > 0)
    .map(([, z]) => z.vlantag as number))].sort((a, b) => a - b);
}

// What to configure on a switch TAPPaaS does not manage. Pure.
export function manualPortText(vlans: number[]): string {
  return `the switch port the machine is cabled to must be a trunk: the mgmt network untagged (native), ` +
    `and tagged ${vlans.length ? `VLAN ${vlans.join(", ")}` : "no VLAN (no zone is active)"}`;
}

// The MACs that appeared behind the port since <before>, none of them a node's. Pure.
export function newMacs(now: string[], before: string[], nodeMacs: string[]): string[] {
  const old = new Set([...before, ...nodeMacs].map((m) => m.toLowerCase()));
  return [...new Set(now.map((m) => m.toLowerCase()))].filter((m) => !old.has(m)).sort();
}

export function printManualPortSetup(): void {
  let zones = {};
  try { zones = JSON.parse(fs.readFileSync(`${defaultConfigDir()}/zones.json`, "utf8")); } catch { /* none: no VLANs */ }
  info(`  ${YW}${manualPortText(nodeTrunkVlans(zones))}${CL}`);
}

function sm(args: string[]): { rc: number; out: string } {
  const r = spawnSync("switch-manager", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return { rc: r.status ?? 1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
}

export function nodeMacs(): string[] {
  const out: string[] = [];
  for (const n of clusterNodes(defaultConfigDir())) {
    for (const u of Object.values(n.uplinks ?? {})) {
      const ports = (u as { ports?: unknown })?.ports;
      if (Array.isArray(ports)) for (const p of ports) if (typeof p === "string") out.push(p.toLowerCase());
    }
  }
  return out;
}

export function portNeighbors(sp: SwitchPort, refresh: boolean): string[] {
  const r = sm(["port-neighbors", sp.switch, sp.port, ...(refresh ? ["--refresh"] : [])]);
  if (r.rc !== 0) return [];
  return r.out.split("\n").map((l) => l.trim().toLowerCase()).filter((l) => /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(l));
}

// Make the port the node's: a node trunk, programmed at once. Returns the MACs
// behind it before the machine boots — what newMacs() leaves out. Dies when the
// switch is not one TAPPaaS manages, or the port cannot be programmed.
export function preparePort(sp: SwitchPort, name: string): string[] {
  const list = sm(["list", "--json"]);
  let sw: { name: string; managed?: string } | undefined;
  try { sw = (JSON.parse(list.out).switches as { name: string; managed?: string }[]).find((s) => s.name === sp.switch); } catch { /* below */ }
  if (!sw) die(`--switch-port: no switch '${sp.switch}' (switch-manager list)`);
  if (sw.managed !== "auto") {
    printManualPortSetup();
    die(`--switch-port: TAPPaaS does not program '${sp.switch}' (managed: ${sw.managed ?? "?"}), so it cannot learn the MAC there — ` +
        `configure the port as above and give --mac <m> (the machine's label, BIOS or BMC)`);
  }
  const ports = sm(["list-ports", sp.switch, "--json"]);
  let cur: { type?: string | null; target?: string | null; lagLead?: string | null; lag?: string | null } | undefined;
  try { cur = (JSON.parse(ports.out)[0].ports as { port: string }[]).find((p) => p.port === sp.port) as typeof cur; } catch { /* below */ }
  if (!cur) die(`--switch-port: '${sp.switch}' has no port '${sp.port}' (switch-manager list-ports '${sp.switch}')`);
  if (cur.lag || cur.lagLead) die(`--switch-port: ${sp.switch} port ${sp.port} is in an aggregate — name a single port`);
  if (cur.type && !(cur.type === "node" && (cur.target ?? name) === name)) {
    die(`--switch-port: ${sp.switch} port ${sp.port} is a ${cur.type} port${cur.target ? ` (${cur.target})` : ""} — not taken over; free it first (switch-manager remove-port)`);
  }
  const before = portNeighbors(sp, true);
  const verb = cur.type ? "update-port" : "add-port";
  const set = sm([verb, sp.switch, sp.port, "--type", "node", "--target", name, "--apply"]);
  if (set.rc !== 0) die(`--switch-port: ${sp.switch} port ${sp.port} was not made a node trunk:\n${set.out.trim()}`);
  info(`  ${GN}✓${CL} ${sp.switch} port ${sp.port} is ${name}'s: a node trunk, on the switch`);
  return before;
}

// One look at the port: the MAC to pin, when exactly one new one is there.
export function learnMac(sp: SwitchPort, before: string[]): { mac?: string; several?: string[] } {
  const found = newMacs(portNeighbors(sp, true), before, nodeMacs());
  if (found.length === 1) return { mac: found[0] };
  if (found.length > 1) return { several: found };
  return {};
}

export function warnSeveral(sp: SwitchPort, macs: string[]): void {
  warn(`  ${macs.length} new MACs behind ${sp.switch} port ${sp.port} (${macs.join(", ")}) — none pinned; ` +
       `the install answers the one machine that asks (the only pending registration), never a cluster node`);
}
