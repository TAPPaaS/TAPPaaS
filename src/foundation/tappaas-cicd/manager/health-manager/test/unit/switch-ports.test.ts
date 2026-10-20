// switch-ports.test.ts — the switch-ports gate (#853): a port with no record
// that is not parked, and a port the switch sets otherwise than its record, are
// WARN rows on that port. Offline: switchPortsResult over list-ports rows shaped
// as hrossen's, and checkSwitchPorts against a fake switch-manager.

import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { SwitchPortRow, checkSwitchPorts, switchPortsResult } from "../../src/checks";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const SW = "USW Pro XG 10 PoE";
const ACTIVE = [200, 299, 310, 410, 420, 430, 510, 610];
const row = (port: string, o: Partial<SwitchPortRow>): SwitchPortRow => ({
  port, type: null, zone: null, mode: "trunk", nativeVlan: 0, taggedVlans: ACTIVE, desired: null,
  drift: "unmanaged", add: [], remove: [], lagLead: null, parked: false, link: null, disabled: false, ...o,
});
const trunk = { mode: "trunk", nativeVlan: 0, taggedVlans: ACTIVE };
const park = { mode: "access", nativeVlan: 410, taggedVlans: [] };

// hrossen after #853/#854: 2, 3 node trunks; 11+12 a LAG (12 follows 11); 1 parked
// and set; 4 parked, not yet pushed; 8 unrecorded with a link; 10 disabled.
const ports: SwitchPortRow[] = [
  row("1", { parked: true, zone: "iotLocal", mode: "access", nativeVlan: 410, taggedVlans: [], desired: park, drift: "in-sync", link: "down" }),
  row("2", { type: "node", desired: trunk, drift: "in-sync", link: "up" }),
  row("3", { type: "node", desired: trunk, drift: "drift", add: [430], link: "up" }),
  row("4", { parked: true, zone: "iotLocal", nativeVlan: 0, desired: park, drift: "drift", link: "down" }),
  row("8", { link: "up" }),
  row("10", { disabled: true, link: "down" }),
  row("11", { type: "node", desired: trunk, drift: "in-sync", link: "up" }),
  row("12", { type: "node", desired: trunk, drift: "in-sync", lagLead: "11", link: "up" }),
];
// The read after the sweep (#860): nine hours before "now".
const NOW = Date.parse("2026-10-19T12:00:00Z");
const READ = "2026-10-19T03:00:00Z";
const r = switchPortsResult([{ switch: SW, lastRead: READ, ports }], NOW);
const on = (p: string) => (r.rows ?? []).filter((x) => x.subject?.kind === "port" && x.subject.name === `${SW}:${p}`);
check(r.name === "switch-ports" && r.status === "warn", "a port to park or to set is a WARN, never a FAIL");
check(on("8").length === 1 && /no record and not parked \(a link is up\)/.test(on("8")[0].text), "an unrecorded port that is not parked is named, with its link");
check(/update-port 'USW Pro XG 10 PoE' 8 --park/.test(on("8")[0].text), "…and the verb that parks it");
check(on("4").length === 1 && /parked in iotLocal \(access vlan 410\), the switch has trunk native 0/.test(on("4")[0].text), "a parked port the switch does not have parked");
check(on("3").length === 1 && /its trunk wants \+430/.test(on("3")[0].text), "a trunk set otherwise than its record");
check(on("1").length === 0 && on("2").length === 0, "a parked port as recorded, and a trunk in sync, are no finding");
check(on("10").length === 0, "a disabled port is no finding");
check(on("12").length === 0, "a LAG member following its lead is no finding (#854)");
check(r.rows!.every((x) => x.status === "warn"), "every row is a warn");
check(/1 port\(s\) unrecorded and not parked, 2 set otherwise than recorded/.test(r.detail), "the line counts both kinds");

const ok = switchPortsResult([{ switch: SW, lastRead: READ, ports: [ports[0], ports[1], ports[7]] }], NOW);
check(ok.status === "pass" && /3 port\(s\) on 1 switch\(es\) as recorded, 1 parked, read 9 h ago/.test(ok.detail), "all as recorded: pass, with the parked count and the read's age");

// #860: the gate judges the switch as last read — an old read, or none, is a finding.
const sw = (x: { kind: string; name: string } | undefined) => x?.kind === "switch" && x.name === SW;
const stale = switchPortsResult([{ switch: SW, lastRead: "2026-10-18T06:00:00Z", ports: [ports[0], ports[1]] }], NOW);
check(stale.status === "warn" && (stale.rows ?? []).some((x) => sw(x.subject) && /last read 30 h ago/.test(x.text)), "a read 30 h old is a WARN on the switch");
check(/1 switch\(es\) not read in 26 h/.test(stale.detail), "…counted in the line");
const never = switchPortsResult([{ switch: SW, ports: [ports[0]] }], NOW);
check(never.status === "warn" && (never.rows ?? []).some((x) => sw(x.subject) && /never read/.test(x.text) && /interrogate --no-park/.test(x.text)), "a switch never read is a WARN, with the verb that reads it");
const fresh = switchPortsResult([{ switch: SW, lastRead: "2026-10-19T11:30:00Z", ports: [ports[0]] }], NOW);
check(fresh.status === "pass" && /read 30 min ago/.test(fresh.detail), "a read half an hour old: pass");
check(switchPortsResult([]).status === "skip", "no switch in the inventory: skip");
check(switchPortsResult({}).status === "skip", "not a switch list: skip");

// The gate runs switch-manager list-ports --json over the config dir it is given.
const d = mkdtempSync(join(tmpdir(), "hm-sw-"));
const bin = join(d, "switch-manager");
writeFileSync(join(d, "out.json"), JSON.stringify([{ switch: SW, lastRead: new Date().toISOString(), ports }]));
writeFileSync(bin, `#!/bin/sh\necho "$CONFIG_DIR $*" > "${d}/argv"\ncat "${d}/out.json"\n`);
chmodSync(bin, 0o755);
process.env.SWITCH_CONTROLLER_BIN = bin;
const live = checkSwitchPorts("/some/config");
check(live.status === "warn" && (live.rows ?? []).length === 3, "checkSwitchPorts reads the controller's rows");
check(readFileSync(join(d, "argv"), "utf8").trim() === "/some/config list-ports --json", "…with list-ports --json, over the given config dir");
process.env.SWITCH_CONTROLLER_BIN = join(d, "missing");
check(checkSwitchPorts("/some/config").status === "skip", "no switch-manager: skip");

console.log(`\nswitch-ports: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
