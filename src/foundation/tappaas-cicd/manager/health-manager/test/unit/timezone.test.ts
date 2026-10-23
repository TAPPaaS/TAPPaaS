// timezone.test.ts — the site-timezone gate (#837): site.json's timezone
// against what the nodes and the guests run, and the fix each row names.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkLanUplink, checkPulse, checkQuorum, checkSiteTimezone } from "../../src/checks";
import { parseLanUplink } from "../../src/client";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

function configDir(site: Record<string, unknown>, modules: Record<string, Record<string, unknown>>): string {
  const dir = mkdtempSync(join(tmpdir(), "hm-tz-"));
  writeFileSync(join(dir, "site.json"), JSON.stringify(site));
  for (const [name, cfg] of Object.entries(modules)) writeFileSync(join(dir, `${name}.json`), JSON.stringify(cfg));
  return dir;
}

const site = { name: "s", locations: { rodovre: { country: "DK", timezone: "Europe/Copenhagen" } }, primaryLocation: "rodovre" };
const mods = {
  nextcloud: { vmid: 340, vmname: "nextcloud", zone0: "rossen" },
  gone: { vmid: 999, vmname: "gone", zone0: "rossen", status: "archived" },
};

{
  const c = new FakeClusterClient();
  c.nodes = ["tappaas1", "tappaas3"];
  c.zones.set("tappaas1", "Europe/Copenhagen");
  c.zones.set("tappaas3", "Europe/Amsterdam");
  c.zones.set("nextcloud.rossen.internal", "Europe/Copenhagen");
  c.zones.set("gone.rossen.internal", "UTC");
  const r = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r.status === "warn", "a node on another zone warns");
  check(r.rows?.length === 1 && r.rows[0].text.includes("node tappaas3") && r.rows[0].text.includes("next cluster update sets Europe/Copenhagen"),
    `the node is named with the command that fixes it (got: ${r.rows?.map((x) => x.text).join(" | ")})`);
  check(r.detail.includes("location modify rodovre --timezone"), "…and the way to fix the site instead: its primary location");
}
{
  const c = new FakeClusterClient();
  c.zones.set("tappaas1", "Europe/Copenhagen");
  c.zones.set("nextcloud.rossen.internal", "UTC");
  const r = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r.status === "warn" && !!r.rows?.[0].text.startsWith("nextcloud") && !!r.rows?.[0].text.includes("next update"),
    "a guest on another zone warns, saying its next update fixes it");
}
{
  const c = new FakeClusterClient();
  c.zones.set("tappaas1", "Europe/Copenhagen");
  c.zones.set("nextcloud.rossen.internal", "Europe/Copenhagen");
  const r = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r.status === "pass" && r.detail.includes("2 node(s)/guest(s)"), `all on the site's zone pass (got: ${r.detail})`);
}
{
  const c = new FakeClusterClient();
  const r = checkSiteTimezone(c, configDir({ name: "s" }, mods), "tappaas1");
  check(r.status === "warn" && r.detail.includes("no timezone on its primary location"), "a site.json without a timezone warns");
  const old = checkSiteTimezone(new FakeClusterClient(), configDir({ name: "s", location: { country: "DK", timezone: "UTC" } }, mods), "tappaas1");
  check(old.status === "skip", "a site.json migration 0019 has not reached still has its timezone");
  const r2 = checkSiteTimezone(c, configDir(site, mods), "tappaas1");
  check(r2.status === "skip", "nothing answered: skip, never pass");
}

// #835: the quorum gate rides along here (same kind of cluster fact).
{
  const c = new FakeClusterClient();
  check(checkQuorum(c).status === "skip", "quorum: nothing answered — skip");
  c.quorumState = { expectedVotes: 2, qdevice: false };
  check(checkQuorum(c).status === "warn" && checkQuorum(c).detail.includes("QDevice"), "two votes, no QDevice: warned");
  c.quorumState = { expectedVotes: 3, qdevice: true };
  check(checkQuorum(c).status === "pass", "two nodes and a QDevice: pass");
  c.quorumState = { expectedVotes: 3, qdevice: false };
  check(checkQuorum(c).status === "pass", "three nodes: pass");
}

// #40: the lan-uplink gate.
{
  const c = new FakeClusterClient();
  c.nodes = ["tappaas1", "tappaas2"];
  check(checkLanUplink(c).status === "skip", "lan-uplink: nothing could be read — skip");
  c.uplinks.set("tappaas1", { mode: "active-backup", ports: ["tg0", "ge0"], findings: [] });
  c.uplinks.set("tappaas2", { mode: "single", ports: ["eno1"], findings: [{ level: "info", text: "no uplinks declared — the next cluster update records this layout" }] });
  const ok = checkLanUplink(c);
  check(ok.status === "pass" && ok.detail.includes("tappaas1 active-backup (tg0+ge0)"), "lan-uplink: a bond and an advisory — pass, with the layout");
  check(ok.rows?.length === 1 && ok.rows[0].status === "skip", "lan-uplink: an advisory is a row, not a warning");
  c.uplinks.set("tappaas2", { mode: "single", ports: ["eno1"], findings: [{ level: "warn", text: "fencing is armed and lan has one port (eno1)" }] });
  const w = checkLanUplink(c);
  check(w.status === "warn" && (w.rows ?? []).some((r) => r.status === "warn" && r.text.startsWith("tappaas2") && r.text.includes("fencing")), "lan-uplink: fencing armed on one port — warn, by node");
  const p = parseLanUplink({
    live: { lan: { mode: "lacp", members: [{ name: "tg0" }, { name: "tg1" }] } },
    findings: [{ level: "warn", text: "no LACP partner" }, { level: "info", text: "x" }, { level: "warn" }],
  });
  check(p.mode === "lacp" && p.ports.join(",") === "tg0,tg1" && p.findings.length === 2 && p.findings[0].level === "warn",
    "lan-uplink.sh's JSON parses: mode, ports, findings (a finding without text dropped)");
}

// ADR-031: the pulse gate.
{
  const c = new FakeClusterClient();
  const dir = configDir(site, {});
  check(checkPulse(c, dir).status === "skip", "pulse: no backup node — skip");
  writeFileSync(join(dir, "backup.json"), JSON.stringify({ node: "tappaas3" }));
  writeFileSync(join(dir, "site.json"), JSON.stringify({ ...site, hardware: { nodes: [{ name: "tappaas3" }] } }));
  writeFileSync(join(dir, "tappaas3.json"), JSON.stringify({ kind: "machine", moduleSource: "/x/pvehost" }));
  check(checkPulse(c, dir).status === "skip", "pulse: the node does not answer — skip");
  c.pulseState = { timer: "inactive", targets: [] };
  check(checkPulse(c, dir).status === "warn" && checkPulse(c, dir).detail.includes("not running"), "pulse: timer not running — warn");
  c.pulseState = { timer: "active", targets: [{ id: "uplink", state: "up" }, { id: "buddy-rasmus", state: "DOWN" }] };
  check(checkPulse(c, dir).status === "warn" && checkPulse(c, dir).detail.includes("buddy-rasmus"), "pulse: a target down — warn, named");
  c.pulseState = { timer: "active", targets: [{ id: "uplink", state: "up" }, { id: "pbs", state: "failing" }] };
  check(checkPulse(c, dir).status === "pass", "pulse: all answering (one failing, not yet down) — pass");
  check(checkPulse(c, dir).status === "pass", "a cluster node is a kind: machine module too — still checked");
  writeFileSync(join(dir, "backup.json"), JSON.stringify({ node: "nas1" }));
  writeFileSync(join(dir, "nas1.json"), JSON.stringify({ kind: "machine", address: "10.0.0.50", moduleSource: "/x/debianhost" }));
  check(checkPulse(c, dir).status === "pass", "pulse: a debianhost backup node is checked by its address");
  writeFileSync(join(dir, "nas1.json"), JSON.stringify({ kind: "machine", address: "203.0.113.7", moduleSource: "/x/satellite" }));
  check(checkPulse(c, dir).status === "skip", "pulse: a satellite backup node — skip");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
