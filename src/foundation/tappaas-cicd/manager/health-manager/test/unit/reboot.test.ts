// reboot.test.ts — the pending-reboot gate and the reboot verb (#730).
//
// A guest waiting for a reboot used to be visible only in the journal of the
// run that skipped it. The gate derives it on the guest (booted system vs the
// system profile), so nothing stored can go stale; the verb takes it through
// update-os.sh's own reboot path, resolved to where the VM actually runs.

import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { hostname, tmpdir } from "os";
import { join } from "path";
import { checkPendingReboot, runHealthGates } from "../../src/checks";
import { parsePendingReboot } from "../../src/client";
import { run } from "../../src/main";
import { PendingReboot } from "../../src/types";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const nixos = (booted: string, next: string, active = false): PendingReboot => ({
  os: "nixos", pending: booted !== next, booted, next, active,
});

function configDir(modules: Record<string, Record<string, unknown>>): string {
  const dir = mkdtempSync(join(tmpdir(), "hm-reboot-"));
  for (const [name, cfg] of Object.entries(modules)) {
    writeFileSync(join(dir, `${name}.json`), JSON.stringify(cfg));
  }
  return dir;
}

// ── the probe's line ─────────────────────────────────────────────────
console.log("parsePendingReboot");
{
  const p = parsePendingReboot("nixos 1 25.11.20260522.b77b3de 26.05.20260922.1bc55b9 0\n");
  check(p?.os === "nixos" && p.pending && p.booted.startsWith("25.11") && p.next.startsWith("26.05"),
    "a NixOS guest booted on an older system is pending, with both releases");
  check(p?.active === false && parsePendingReboot("nixos 1 25.11 26.05 1")?.active === true,
    "staged and switched are told apart");
  check(parsePendingReboot("nixos 0 26.05pre-git 26.05pre-git")?.pending === false, "booted on its profile: not pending");
  check(parsePendingReboot("debian 1")?.os === "debian", "Debian's reboot-required is read");
  check(parsePendingReboot("Welcome to the guest\nnixos 0 26.05 26.05")?.pending === false,
    "a login banner before the line is ignored");
  check(parsePendingReboot("") === null && parsePendingReboot("nixos maybe") === null,
    "anything else is unknown, never 'not pending'");
}

// ── the gate ─────────────────────────────────────────────────────────
console.log("checkPendingReboot");
{
  const dir = configDir({
    nextcloud: { vmid: 340, vmname: "nextcloud", zone0: "rossen", status: "Testing" },
    litellm: { vmid: 310, vmname: "litellm", zone0: "rossen" },
    identity: { vmid: 140, vmname: "identity", zone0: "mgmt" },
    logging: { vmid: 150, vmname: "logging", zone0: "mgmt" },
    gone: { vmid: 999, vmname: "gone", zone0: "rossen", status: "archived" },
    "site": { name: "s" },
  });
  const c = new FakeClusterClient();
  c.reboots.set("nextcloud.rossen.internal", nixos("25.11.20260522", "26.05.20260922"));
  c.reboots.set("litellm.rossen.internal", nixos("26.05pre-git", "26.05pre-git"));
  c.reboots.set("identity.mgmt.internal", nixos("26.05.20260901", "26.05.20260922", true));
  c.reboots.set("logging.mgmt.internal", nixos("25.11.20260522", "26.05.20260922", true));
  c.reboots.set("gone.rossen.internal", nixos("25.05", "26.05")); // archived: never probed

  const r = checkPendingReboot(c, dir, "tappaas1");
  check(r.status === "warn", "pending guests WARN — debt, not an outage");
  check(r.detail.startsWith("3 of 4 guest(s)"), `counts the waiting among the probed (got: ${r.detail})`);
  check(r.detail.includes("health-manager reboot <module>"), "says how to take it");
  const text = (r.rows ?? []).map((x) => x.text).join("\n");
  check(text.includes("nextcloud") && text.includes("release move 25.11 -> 26.05 staged, still running 25.11"),
    "a release move is named as one, with the release still running");
  check(text.includes("release move 25.11 -> 26.05 active, still on the 25.11 kernel"),
    "a switched release move says the new release runs, on the old kernel");
  check(text.includes("identity") && text.includes("booted 26.05.20260901, next boot 26.05.20260922"),
    "a same-release generation shows both builds");
  check(!text.includes("litellm") && !text.includes("gone"), "neither a current nor an archived guest is listed");

  const report = runHealthGates(c, { configDir: dir, defaultNode: "tappaas1", threshold: 80, memoryThreshold: 100 });
  const gate = report.checks.find((x) => x.name === "pending-reboot");
  check(gate?.status === "warn", "validate runs the gate");
  check(!report.checks.some((x) => x.name === "pending-reboot" && x.status === "fail"),
    "a pending reboot never fails validate");

  const quiet = new FakeClusterClient();
  quiet.reboots.set("litellm.rossen.internal", nixos("26.05", "26.05"));
  const ok = checkPendingReboot(quiet, dir, "tappaas1");
  check(ok.status === "pass" && ok.detail.includes("1 guest(s) booted on their current system"),
    "nothing waiting: PASS, with the population");
  check(checkPendingReboot(new FakeClusterClient(), dir, "tappaas1").status === "skip",
    "no reachable guest: SKIP, never PASS");
}

// ── the verb ─────────────────────────────────────────────────────────
console.log("reboot <module>");
{
  const bin = mkdtempSync(join(tmpdir(), "hm-reboot-bin-"));
  const args = join(bin, "args");
  const fake = join(bin, "reboot-guest.sh");
  writeFileSync(fake, `#!/usr/bin/env bash\necho "$*" > '${args}'\nexit "\${FAKE_RC:-0}"\n`);
  chmodSync(fake, 0o755);
  const prev = process.env.REBOOT_BIN;
  process.env.REBOOT_BIN = fake;

  // Pending on the first look, taken on the second — or not, when `stays`.
  class RebootingClient extends FakeClusterClient {
    looks = 0;
    stays = false;
    pendingReboot(): PendingReboot | null {
      this.looks++;
      return this.looks === 1 || this.stays ? nixos("25.11", "26.05") : nixos("26.05", "26.05");
    }
  }
  const call = (argv: string[], client: FakeClusterClient): { rc: number; out: string; err: string } => {
    const log = console.log;
    const error = console.error;
    let out = "";
    let err = "";
    console.log = (...a: unknown[]): void => { out += a.map(String).join(" ") + "\n"; };
    console.error = (...a: unknown[]): void => { err += a.map(String).join(" ") + "\n"; };
    try {
      return { rc: run(argv, client), out, err };
    } catch (e) {
      return { rc: 1, out, err: err + String(e) };
    } finally {
      console.log = log;
      console.error = error;
    }
  };
  const dir = configDir({
    nextcloud: { vmid: 340, vmname: "nextcloud", zone0: "rossen", node: "tappaas1" },
    vllm: { vmid: 312, vmname: "vllm", kind: "lxc", node: "tappaas2" },
    tappaas2: { kind: "machine" },
    self: { vmid: 130, vmname: hostname(), zone0: "mgmt", node: "tappaas1" },
  });

  const c = new RebootingClient();
  c.actualNodes.set("tappaas1/340", "tappaas3"); // HA moved it
  const ok = call(["reboot", "nextcloud", "--config-dir", dir], c);
  check(ok.rc === 0, `a pending reboot is taken (rc ${ok.rc} ${ok.err})`);
  check(existsSync(args) && readFileSync(args, "utf8").trim() === "nextcloud 340 tappaas3",
    "the driver gets the VM where it RUNS, not where it is declared");
  check(ok.out.includes("pending: booted 25.11") && ok.out.includes("nextcloud runs 26.05"),
    "before and after are both reported");

  const stuck = new RebootingClient();
  stuck.stays = true;
  const s = call(["reboot", "nextcloud", "--config-dir", dir], stuck);
  check(s.rc === 1 && s.err.includes("still boots 25.11"), "a reboot that did not take the new system fails, and says so");

  process.env.FAKE_RC = "3";
  check(call(["reboot", "nextcloud", "--config-dir", dir], new RebootingClient()).rc === 3,
    "the driver's rc is passed on (3 = locked, not rebooted)");
  delete process.env.FAKE_RC;

  const refused = (argv: string[]): boolean => {
    if (existsSync(args)) writeFileSync(args, "");
    const r = call(argv, new RebootingClient());
    return r.rc !== 0 && readFileSync(args, "utf8") === "";
  };
  check(refused(["reboot", "self", "--config-dir", dir]), "the controller is refused — it would kill the command");
  check(refused(["reboot", "vllm", "--config-dir", dir]), "a container is refused");
  check(refused(["reboot", "tappaas2", "--config-dir", dir]), "a module with no VM is refused");
  check(refused(["reboot", "nosuch", "--config-dir", dir]), "an unknown module is refused");
  check(refused(["reboot", "--config-dir", dir]), "a missing <module> is refused");

  if (prev === undefined) delete process.env.REBOOT_BIN;
  else process.env.REBOOT_BIN = prev;
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
