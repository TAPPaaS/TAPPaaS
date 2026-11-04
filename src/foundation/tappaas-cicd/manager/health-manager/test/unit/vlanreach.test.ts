// vlanreach.test.ts — the internet gate and `vlan-reach`: which VLANs are probed,
// who reached whom, the instructions when a VLAN does not cross, and the probe
// taken down whatever happened. The nodes are a fake remote.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkInternet } from "../../src/internet";
import { Remote, activeVlans, missingPairs, reachInstructions, reachLines, runVlanReach } from "../../src/vlanreach";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

// ── internet ──
check(checkInternet(() => ({ ok: true, why: "" })).status === "pass", "internet: the repository host answers — pass");
const off = checkInternet(() => ({ ok: false, why: "Could not resolve host" }));
check(off.status === "fail" && /codeberg\.org: Could not resolve host/.test(off.detail) && /firewall's WAN/.test(off.detail), "internet: nothing answers — fail, naming what was tried and where to look");
check(checkInternet((u) => ({ ok: u.includes("nixos"), why: "timeout" })).status === "pass", "internet: one of the two is enough");

// ── which VLANs ──
const zones = {
  _comment: "x",
  mgmt: { vlantag: 0, state: "Mandatory" },
  srv: { vlantag: 210, state: "Active" },
  home: { vlantag: 410, state: "Active" },
  lab: { vlantag: 330, state: "Inactive" },
};
check(activeVlans(zones).map((v) => `${v.vid}:${v.zone}`).join() === "210:srv,410:home", "the active zones with a tag of their own, in VLAN order (not mgmt, not an inactive one)");

// ── who reaches whom ──
const addr = new Map([["tappaas1", "fe80::1"], ["tappaas2", "fe80::2"], ["tappaas3", "fe80::3"]]);
const seen = new Map([["tappaas1", ["fe80::1", "fe80::2"]], ["tappaas2", ["fe80::1", "fe80::2", "fe80::9"]], ["tappaas3", ["fe80::3"]]]);
check(missingPairs(["tappaas1", "tappaas2", "tappaas3"], addr, seen).map((m) => `${m.from}>${m.to}`).join() === "tappaas1>tappaas3,tappaas2>tappaas3,tappaas3>tappaas1,tappaas3>tappaas2", "a node not answered is not reached, both ways; a guest's address is ignored");

// ── a run over two nodes ──
const dir = mkdtempSync(join(tmpdir(), "hm-vr-"));
writeFileSync(join(dir, "zones.json"), JSON.stringify(zones));
for (const [n, mac] of [["tappaas1", "aa:01"], ["tappaas2", "aa:02"]]) {
  writeFileSync(join(dir, `${n}.json`), JSON.stringify({ kind: "machine", moduleSource: "/x/pvehost", address: `${n}.mgmt.internal`, uplinks: { lan: { ports: [mac] } } }));
}
const calls: string[] = [];
const fake = (split: boolean): Remote => (node, script) => {
  const phase = script.includes("ip link add") ? "up" : script.includes("ping -6") ? "ping" : "down";
  calls.push(`${node.name}:${phase}`);
  const me = node.name === "tappaas1" ? "fe80::1" : "fe80::2";
  if (phase === "up") return { rc: 0, ran: true, stderr: "", stdout: `${node.name === "tappaas1" ? "SELF 410\n" : ""}ADDR 210 ${me}\nADDR 410 ${me}\n` };
  if (phase === "ping") return { rc: 0, ran: true, stderr: "", stdout: `SEEN 210 fe80::1 fe80::2\nSEEN 410 ${split ? me : "fe80::1 fe80::2"}\n` };
  return { rc: 0, ran: true, stderr: "", stdout: "DOWN\n" };
};
let r = runVlanReach(dir, fake(false));
check(r.ok && r.vlans.length === 2 && r.vlans.every((v) => v.missing.length === 0), "two nodes, both VLANs carried: ok");
check(calls.filter((c) => c.endsWith(":down")).length === 2, "…and the probe taken down on both");
calls.length = 0;
r = runVlanReach(dir, fake(true));
check(!r.ok && r.vlans.find((v) => v.vid === 410)!.missing.length === 2 && r.vlans.find((v) => v.vid === 210)!.missing.length === 0, "VLAN 410 split between the switches: not ok, that VLAN only");
const lines = reachLines(r);
check(lines.some((l) => /^✗ VLAN 410 \(home\): tappaas1 does not reach tappaas2/.test(l)) && lines.some((l) => /^✓ VLAN 210 \(srv\)/.test(l)), "…the lines say which VLAN, and that the other is fine");
const how = reachInstructions(r);
check(/^Carry VLAN 410 \(home\) tagged/.test(how[0]) && how.some((l) => /tappaas1: LAN port aa:01/.test(l)) && /bring the switches under management/.test(how[how.length - 1]), "…the instructions: the VLAN, each node's LAN port, and the easier way");

// the probe comes down even when ping fails mid-way
calls.length = 0;
const broken: Remote = (node, script) => {
  if (script.includes("ping -6")) throw new Error("ssh died");
  return fake(false)(node, script);
};
let threw = false;
try {
  runVlanReach(dir, broken);
} catch {
  threw = true;
}
check(threw && calls.filter((c) => c.endsWith(":down")).length === 2, "a failure mid-probe still takes the probe down on every node");

// one node: nothing to cross
const one = mkdtempSync(join(tmpdir(), "hm-vr1-"));
writeFileSync(join(one, "zones.json"), JSON.stringify(zones));
writeFileSync(join(one, "tappaas1.json"), JSON.stringify({ kind: "machine", moduleSource: "/x/pvehost", address: "tappaas1.mgmt.internal" }));
calls.length = 0;
const r1 = runVlanReach(one, fake(false));
check(r1.ok && calls.length === 0 && /one node/.test(reachLines(r1)[0]), "one node: ok, nothing probed");

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
