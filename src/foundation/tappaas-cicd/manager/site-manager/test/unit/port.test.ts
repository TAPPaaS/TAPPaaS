// port.test.ts — where a new node is cabled (ADR-037 D4): the port argument, the
// trunk a hand-configured port needs, and which MAC behind the port is the machine.

import { manualPortText, newMacs, nodeTrunkVlans, parseSwitchPort } from "../../src/port";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) passed++;
  else {
    failed++;
    console.error(`  FAIL: ${msg}`);
  }
}

const p = parseSwitchPort("USW Pro XG 10 PoE:1");
check(p?.switch === "USW Pro XG 10 PoE" && p?.port === "1", "a switch name with spaces");
check(parseSwitchPort("crs-a:sfp-sfpplus3")?.port === "sfp-sfpplus3", "a MikroTik port name");
check(parseSwitchPort("a:b:7")?.switch === "a:b", "the port is after the last colon");
check(parseSwitchPort("nocolon") === null && parseSwitchPort(":1") === null && parseSwitchPort("sw:") === null, "no switch or no port: refused");

const zones = {
  mgmt: { state: "Manual", vlantag: 0 }, srv: { state: "Active", vlantag: 200 }, dmz: { state: "Mandatory", vlantag: 610 },
  old: { state: "Inactive", vlantag: 999 }, iot: { state: "Active", vlantag: 410 }, _meta: { state: "Active", vlantag: 5 },
};
check(nodeTrunkVlans(zones).join(",") === "200,410,610", "the active and mandatory zones' VLANs, sorted; mgmt untagged");
check(manualPortText([200, 610]).includes("untagged") && manualPortText([200, 610]).includes("VLAN 200, 610"), "the hand configuration says both");

check(newMacs(["02:AA:00:00:00:01", "02:aa:00:00:00:02"], ["02:aa:00:00:00:02"], []).join() === "02:aa:00:00:00:01",
  "a MAC that was there before the boot is not the machine");
check(newMacs(["02:aa:00:00:00:01", "c8:ff:bf:05:0d:30"], [], ["C8:FF:BF:05:0D:30"]).join() === "02:aa:00:00:00:01",
  "a cluster node's MAC is never the machine");
check(newMacs([], ["x"], []).length === 0, "nothing new: none");

console.log(`port: ${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
