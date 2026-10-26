// zoneverbs.test.ts — the verbs a zone's card offers (web/src/zoneverbs.ts),
// per state, over hrossen's zones (test/fixtures/zones.json), and the bind
// rule against network-manager's own.

import { readFileSync } from "fs";
import { join } from "path";
import { ENVIRONMENT_TYPES } from "../../../manager/network-manager/src/types";
import { BIND_TYPES, CardVerbs, cardVerbs, ZoneVerbZone } from "../../web/src/zoneverbs";
import { check, done } from "./check";

const FIX = process.env.CONSOLE_FIXTURES ?? "test/fixtures";
const zones = JSON.parse(readFileSync(join(FIX, "zones.json"), "utf8")) as ZoneVerbZone[];
const of = (n: string): CardVerbs => cardVerbs(zones.find((z) => z.name === n)!);
const set = (v: CardVerbs): string => [...v.states, v.bind ? "bind" : "", v.addLike ? "add" : "", v.delete ? "delete" : ""].filter(Boolean).join(" ");

// Manual: outside the enable/disable lifecycle, kept by its own module.
for (const n of ["netbird", "edge", "admin", "buddy", "wan", "mgmt"]) {
  check(of(n).manual && of(n).states.length === 0 && !of(n).delete && !of(n).addLike, `${n} (Manual): no Enable/Disable, no Delete, no Add one like it`);
}
check(of("mgmt").bind && !of("wan").bind && !of("netbird").bind, "…bind only where network-manager binds (mgmt yes; WAN, overlays no)");
check(cardVerbs({ name: "x", type: "Overlay", state: "Active" }).manual, "an overlay or the WAN is manual whatever its record says");

// The lifecycle states.
check(set(of("rossen")) === "disable bind add delete", "Active: Disable, Bind, Add one like it, Delete");
check(zones.every((z) => !cardVerbs(z).states.includes("manual")), "no zone's card offers Manual: that verb stays on the command line");
check(set(of("work")) === "enable bind add delete", "Inactive: Enable, Bind, Add one like it, Delete");
check(set(of("iotUntrust")) === "enable bind add delete", "Disabled: Enable, as Inactive");
check(set(of("dmz")) === "bind add", "Mandatory: no state verb, no Delete");
check(!of("rossen").manual && !of("dmz").manual, "no manual note on lifecycle zones");

// bind: the types network-manager bind accepts.
check([...BIND_TYPES].sort().join() === [...ENVIRONMENT_TYPES].sort().join(), "BIND_TYPES is network-manager's ENVIRONMENT_TYPES");

done("zoneverbs");
