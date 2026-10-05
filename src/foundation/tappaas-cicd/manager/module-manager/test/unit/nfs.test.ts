// nfs.test.ts — module-manager validate's storage:nfs check (ADR-029 v0.9): a
// consumer's mounts against config/shares.json. The share model's own rules are
// tested with storage-manager, which owns the file (lib/ts/src/nfs-shares.ts).
import { validateNfs } from "../../src/validate";
import type { ModuleConfig, ValidateFinding } from "../../src/types";
import type { ServiceFs } from "../../src/services";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

const configs: Record<string, Record<string, unknown>> = {
  shares: { nfs: { shares: { media: { server: "tappaas1", pool: "tankb1", backup: { enabled: true }, grants: { jellyfin: "rw", viewer: "ro" } } } } },
  tappaas1: { kind: "machine", management: "managed", zone0: "mgmt" },
};
const fs = { readConfig: (i: string) => configs[i] ?? null } as unknown as ServiceFs;
const run = (name: string, cfg: Record<string, unknown>): ValidateFinding[] => {
  const out: ValidateFinding[] = [];
  validateNfs({ name, raw: cfg } as unknown as ModuleConfig, fs, out);
  return out;
};
const consumer = (mounts: unknown[], deps = ["cluster:vm", "network:rules", "storage:nfs"]) => ({
  zone0: "srvHome", dependsOn: deps, config: { "storage:nfs": { mounts } },
});

check(run("jellyfin", consumer([{ path: "/media", share: "media", access: "rw" }])).length === 0, "a granted mount passes");
check(run("viewer", consumer([{ path: "/m", share: "media", access: "rw" }])).some((f) => f.severity === "error" && f.message.includes("only ro")),
  "rw against an ro grant is an error on the consumer");
{
  const f = run("jellyfin", consumer([{ path: "/m", share: "nope" }]));
  check(f.length === 1 && f[0].severity === "warning" && f[0].message.includes("pending"), "an undeclared share is a pending warning");
}
check(run("jellyfin", consumer([{ path: "/m", share: "tappaas1:media" }])).some((f) => f.severity === "error"), "the withdrawn <instance>:<name> form is an error");
check(run("x", {}).length === 0, "a module without mounts gets nothing");
{
  const none: ValidateFinding[] = [];
  validateNfs({ name: "jellyfin", raw: consumer([{ path: "/m", share: "nope" }]) } as unknown as ModuleConfig, {} as ServiceFs, none);
  check(none.length === 0, "without the config reader the check is skipped, not failed");
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
