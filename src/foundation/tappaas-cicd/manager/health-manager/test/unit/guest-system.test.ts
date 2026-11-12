// guest-system.test.ts — the guest-system gate (ADR-050 P2): a NixOS guest
// runs, and will boot, only systems update-os.sh recorded for it; a guest with
// no record yet, or that does not answer, is not judged; a record of earlier
// systems keeps TAPPaaS's own rollback clean; the finding is a security
// condition.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { checkGuestSystem, knownSystems } from "../../src/checks";
import { GATES } from "../../src/assess-sources";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const sys = (h: string): string => `/nix/store/${h.padEnd(32, "a")}-nixos-system-guest-26.05.20261101.abc`;
const A = sys("aaa"), B = sys("bbb"), C = sys("ccc"), X = sys("xxx");

const dir = mkdtempSync(join(tmpdir(), "hm-guestsys-"));
const cfg = (name: string, c: Record<string, unknown>): void => writeFileSync(join(dir, `${name}.json`), JSON.stringify(c));
cfg("nextcloud", { vmid: 340, vmname: "nextcloud", zone0: "rossen" });
cfg("immich", { vmid: 330, vmname: "immich", zone0: "rossen" });
cfg("karakeep", { vmid: 360, vmname: "karakeep", zone0: "rossen" });
cfg("litellm", { vmid: 310, vmname: "litellm", zone0: "rossen" });
cfg("jellyfin", { vmid: 320, vmname: "jellyfin", zone0: "rossen" });
cfg("site", { name: "s" });
mkdirSync(join(dir, ".guest-systems"));
const rec = (vm: string, ...paths: string[]): void => writeFileSync(join(dir, ".guest-systems", vm), paths.join("\n") + "\n");
rec("nextcloud", A, B);
rec("immich", A, B);
rec("karakeep", B);
rec("jellyfin", C);

const c = new FakeClusterClient();
c.systems.set("nextcloud.rossen.internal", { booted: A, current: B, profile: B }); // switched, kernel pending: fine
c.systems.set("immich.rossen.internal", { booted: B, current: A, profile: A }); // TAPPaaS's rollback to A: fine
c.systems.set("karakeep.rossen.internal", { booted: B, current: X, profile: X }); // nixos-rebuild switch by hand
c.systems.set("litellm.rossen.internal", { booted: X, current: X, profile: X }); // no record yet: not judged
// jellyfin: recorded, but does not answer: not judged

console.log("guest-system gate");
check(knownSystems(join(dir, ".guest-systems"), "nextcloud")?.has(A) === true, "the record is read");
check(knownSystems(join(dir, ".guest-systems"), "../etc") === null, "a name that is not a vmname is never a path");
const r = checkGuestSystem(c, dir, "tappaas1");
check(r.status === "fail", `a hand-made system fails the gate (${r.status})`);
check(r.rows?.length === 1 && r.rows[0].subject?.name === "karakeep", "only that guest is named");
check(!!r.rows?.[0].text.includes("not a system TAPPaaS built"), "and the row says why");
check(r.judged?.map((s) => s.name).sort().join(",") === "immich,karakeep,nextcloud", "guests without a record or an answer are not judged");
c.systems.set("karakeep.rossen.internal", { booted: X, current: B, profile: B });
check(checkGuestSystem(c, dir, "tappaas1").status === "pass", "back on a recorded system after the next update: pass");
c.systems.set("karakeep.rossen.internal", { booted: B, current: X, profile: B });
check(checkGuestSystem(c, dir, "tappaas1").status === "fail", "an activated system that is not the profile nor the booted one (nixos-rebuild test) fails");
check(checkGuestSystem(new FakeClusterClient(), dir, "tappaas1").status === "skip", "nothing answers: skip");
check(GATES["guest-system"]?.type === "security", "its finding is a security condition");

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
