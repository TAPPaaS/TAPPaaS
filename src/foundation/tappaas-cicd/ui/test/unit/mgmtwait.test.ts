// mgmtwait.test.ts — the console waits for its mgmt address at start instead
// of settling on loopback (a network restart started it first, 2026-11-08).

import { mgmtWaitMs, waitForMgmtAddress } from "../../src/main";
import { check, done } from "./check";

// A fake clock: sleep advances it; the address appears at a given time.
function clock(appearsAt: number | null) {
  let t = 0;
  const sleeps: number[] = [];
  return {
    sleeps,
    now: () => t,
    sleep: async (ms: number) => {
      sleeps.push(ms);
      t += ms;
    },
    find: (net: string) => (net === "10.0.0.0/24" && appearsAt !== null && t >= appearsAt ? "10.0.0.144" : null),
  };
}

async function main(): Promise<void> {
  {
    const c = clock(0);
    const a = await waitForMgmtAddress("10.0.0.0/24", 120_000, c);
    check(a === "10.0.0.144" && c.sleeps.length === 0, "the address is up: taken at once, no wait");
  }
  {
    const c = clock(5_500);
    const a = await waitForMgmtAddress("10.0.0.0/24", 120_000, c);
    check(a === "10.0.0.144", "the address comes up after 5.5s: taken");
    check(c.now() === 6_000 && c.sleeps.every((s) => s === 1000), "…looked for once a second, served from the first look that found it");
  }
  {
    const c = clock(null);
    const a = await waitForMgmtAddress("10.0.0.0/24", 10_000, { ...c, intervalMs: 3000 });
    check(a === null, "the address never comes: null, so serve fails instead of serving on loopback");
    check(c.now() === 10_000 && c.sleeps.join(",") === "3000,3000,3000,1000", "…after the bound and not a moment longer");
  }
  {
    const c = clock(null);
    const a = await waitForMgmtAddress("10.0.0.0/24", 0, c);
    check(a === null && c.sleeps.length === 0, "a zero wait: one look, then null");
  }
  {
    const t0 = Date.now();
    const a = await waitForMgmtAddress("192.0.2.0/24", 50, { intervalMs: 20, find: () => null });
    check(a === null && Date.now() - t0 >= 45 && Date.now() - t0 < 1000, "the real timer: bounded");
  }
  check(mgmtWaitMs({}) === 120_000, "default wait: 120s");
  check(mgmtWaitMs({ CONSOLE_MGMT_WAIT: "30" }) === 30_000 && mgmtWaitMs({ CONSOLE_MGMT_WAIT: "0" }) === 0, "CONSOLE_MGMT_WAIT in seconds");
  check(mgmtWaitMs({ CONSOLE_MGMT_WAIT: "soon" }) === 120_000 && mgmtWaitMs({ CONSOLE_MGMT_WAIT: "-5" }) === 120_000, "an unusable value: the default");
  done("mgmtwait");
}

void main();
