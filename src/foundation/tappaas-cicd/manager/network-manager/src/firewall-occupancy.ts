// firewall-occupancy.ts — ask the firewall what it carries, for the collision
// check (#862). The one I/O step; occupancy.ts is pure.
//
// `opnsense-firewall segments --json` (opnsense-controller) lists every VLAN
// device and assigned interface. A firewall that cannot be asked — not there
// yet on a fresh install, down, no credentials — is SAID and the caller
// proceeds as before #862, checking zones.json only: null is never "empty".
import { spawnSync } from "child_process";
import { configEnv } from "../../../lib/ts/src/exec";
import { Occupancy, occupancyFrom } from "./occupancy";

// Read at call time so a test can point it at a stub.
export function firewallBin(): string {
  return process.env.NM_OPNSENSE_FIREWALL_BIN ?? "opnsense-firewall";
}

export function readFirewallOccupancy(log: { warn: (m: string) => void }): Occupancy | null {
  const bin = firewallBin();
  const said = (why: string) =>
    log.warn(
      `the firewall could not be asked what it carries (${bin} segments: ${why}) — ` +
        `VLAN tags and subnets are checked against zones.json only`,
    );
  const r = spawnSync(bin, ["segments", "--json", "--no-ssl-verify"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: configEnv(),
    timeout: 60_000,
  });
  if (r.error) {
    said(r.error.message);
    return null;
  }
  if (r.status !== 0) {
    const last = (r.stderr ?? "").trim().split("\n").filter(Boolean).pop();
    said(last ?? `rc ${r.status}`);
    return null;
  }
  try {
    return occupancyFrom(JSON.parse(r.stdout ?? "") as Parameters<typeof occupancyFrom>[0]);
  } catch (e) {
    said(`unreadable listing: ${(e as Error).message}`);
    return null;
  }
}
