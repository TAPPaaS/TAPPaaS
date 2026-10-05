// nfs.test.ts — the pvehost:nfs cross-module check (ADR-029 v0.8).
//
// The same rules the service scripts enforce at install time
// (pvehost/lib/nfs-lib.sh, pinned by test-nfs-lib.sh), here as `validate`
// findings: share names found across the Site, the pending mount, the two-key
// check, subdir, the firewall path, the wan refusal.
//
// Offline: configs come from an in-memory lister and reader.

import { checkExports, checkMounts, isPublicIpv4, parseShareRef, shareAlias, shareServers, unusedGrants } from "../../src/nfs";
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
const has = (fs: { message: string }[], needle: string): boolean => fs.some((f) => f.message.includes(needle));
const errors = (fs: { severity: string }[]): number => fs.filter((f) => f.severity === "error").length;

const configs: Record<string, Record<string, unknown>> = {
  tappaas1: {
    kind: "machine", management: "managed", zone0: "mgmt", address: "tappaas1.mgmt.internal",
    nfs: { exports: [{ name: "media", pool: "tankb1", backup: { enabled: true }, owner: { uid: 64000, gid: 64000 },
      grants: [{ consumer: "jellyfin", access: "rw" }, { consumer: "viewer", access: "ro" }, { consumer: "ghost" }] }] },
  },
  nas1: {
    kind: "machine", management: "unmanaged", zone0: "home", address: "nas1.home.internal",
    nfs: { exports: [{ name: "video", path: "/volume1/video", grants: [{ consumer: "jellyfin" }] }] },
  },
  edge: { kind: "machine", management: "unmanaged", zone0: "wan", nfs: { exports: [{ name: "outside", path: "/x", grants: [{ consumer: "jellyfin" }] }] } },
  jellyfin: { zone0: "srvHome", dependsOn: ["cluster:vm", "network:rules", "pvehost:nfs"] },
  viewer: { zone0: "srvHome", dependsOn: ["cluster:vm", "pvehost:nfs"] },
};
const read = (i: string): Record<string, unknown> | null => configs[i] ?? null;
const list = (): string[] => Object.keys(configs);
const mounts = (name: string, ms: unknown[], extra: Record<string, unknown> = {}) =>
  checkMounts(name, { ...configs[name], ...extra, config: { "pvehost:nfs": { mounts: ms } } }, list, read);

// ── share references (D2, v0.8) ──
check(JSON.stringify(parseShareRef("media")) === JSON.stringify({ kind: "named", share: "media" }), "ref: a share name");
check((parseShareRef("nas.lan:/v") as { kind: string }).kind === "literal", "ref: literal");
check(typeof parseShareRef("tappaas1:media") === "string", "ref: the withdrawn <instance>:<name> form refused");
check(typeof parseShareRef("Media") === "string", "ref: bad name refused");
check(shareAlias("media") === "nfs-media.mgmt.internal", "alias name");

// ── finding a share (D2, D2b) ──
check(JSON.stringify(shareServers("media", list, read)) === '["tappaas1"]', "find: a node's share");
check(JSON.stringify(shareServers("video", list, read)) === '["nas1"]', "find: a NAS's share");
check(shareServers("nope", list, read).length === 0, "find: an undeclared share has no server");

// ── export shape and uniqueness (D4, D2a, D2) ──
check(errors(checkExports("tappaas1", configs.tappaas1, list, read)) === 0, "export: a complete managed export passes");
{
  const dup: Record<string, Record<string, unknown>> = { ...configs, tappaas2: configs.tappaas1 };
  const l2 = (): string[] => Object.keys(dup);
  const r2 = (i: string): Record<string, unknown> | null => dup[i] ?? null;
  check(has(checkExports("tappaas2", dup.tappaas2, l2, r2), "also declared by tappaas1"), "export: a name another server declares refused (Site-unique)");
  check(has(checkMounts("jellyfin", { ...configs.jellyfin, config: { "pvehost:nfs": { mounts: [{ path: "/m", share: "media" }] } } }, l2, r2), "declared by tappaas1, tappaas2"), "mount: a share declared twice refused");
}
check(has(checkExports("n", { nfs: { exports: [{ name: "m", pool: "tankb1" }] } }), "no default"), "export: backup.enabled has no default");
check(has(checkExports("n", { nfs: { exports: [{ name: "m", backup: { enabled: false } }] } }), "pool is required"), "export: pool required on managed");
check(has(checkExports("n", { nfs: { exports: [{ name: "m", pool: "p", backup: { enabled: false }, owner: { uid: 1000, gid: 1000 } }] } }), "owner must be"), "export: owner outside the range refused");
check(has(checkExports("n", { nfs: { exports: [{ name: "m", pool: "p", backup: { enabled: false }, properties: { mountpoint: "/x" } }] } }), "property mountpoint"), "export: unknown property refused");
check(errors(checkExports("nas1", configs.nas1)) === 0, "export: a registered server's descriptor passes");
check(has(checkExports("n", { management: "unmanaged", nfs: { exports: [{ name: "v", path: "/v", backup: { enabled: true } }] } }), "backup is not allowed"), "export: backup refused on an unmanaged server");
check(has(checkExports("n", { management: "unmanaged", nfs: { exports: [{ name: "v", path: "/v", version: "3" }] } }), "v3Ports"), "export: NFSv3 without pinned ports refused");

// ── mounts: pending, the two-key check, subdir (D3, D11, D15) ──
check(errors(mounts("jellyfin", [{ path: "/media", share: "media", subdir: "jellyfin", access: "rw" }])) === 0, "mount: granted rw, with network:rules, passes");
{
  const f = mounts("jellyfin", [{ path: "/m", share: "nope" }]);
  check(errors(f) === 0 && has(f, "pending"), "mount: an undeclared share is pending — a warning, never an error");
}
check(has(mounts("viewer", [{ path: "/m", share: "media", access: "rw" }], { dependsOn: ["pvehost:nfs", "network:rules"] }), "only ro"), "mount: rw against an ro grant refused");
check(has(checkMounts("stranger", { zone0: "mgmt", dependsOn: ["pvehost:nfs"], config: { "pvehost:nfs": { mounts: [{ path: "/m", share: "media" }] } } }, list, read), '"consumer": "stranger"'), "mount: an existing share without a grant is an error (v0.8), printing the grant to add");
check(has(mounts("jellyfin", [{ path: "/m", share: "tappaas1:/tappaas-nfs/media" }]), "name its share"), "mount: a literal on a module instance refused");
check(has(mounts("jellyfin", [{ path: "/m", share: "media", subdir: "../etc" }]), "subdir"), "subdir: .. refused");
check(has(mounts("jellyfin", [{ path: "/m", share: "media", subdir: "/abs" }]), "subdir"), "subdir: leading / refused");
check(errors(mounts("jellyfin", [{ path: "/m", share: "media", subdir: "a/b-c.d" }])) === 0, "subdir: a nested relative path passes");
check(has(mounts("jellyfin", [{ path: "/m", share: "media", stopUnits: "jellyfin.service" }]), "stopUnits"), "stopUnits: must be a list");
check(has(mounts("jellyfin", [{ path: "/etc", share: "media" }]), "not a directory a share may cover"), "mount: /etc refused");
check(has(mounts("jellyfin", [{ path: "/m", share: "media" }, { path: "/m", share: "media" }]), "mounted twice"), "mount: one path twice refused");
check(has(checkMounts("x", { dependsOn: ["cluster:vm"], config: { "pvehost:nfs": { mounts: [{ path: "/m", share: "media" }] } } }, list, read), "without pvehost:nfs"), "mount: mounts without the dependency refused");

// ── the firewall path (D5 layer 2) and the wan refusal (D2a) ──
check(has(mounts("viewer", [{ path: "/m", share: "media" }]), "must depend on network:rules"), "path: cross-zone without network:rules refused");
check(errors(mounts("viewer", [{ path: "/m", share: "media" }], { zone0: "mgmt" })) === 0, "path: same zone needs no rule");
check(errors(mounts("viewer", [{ path: "/m", share: "nope" }])) === 0, "path: a pending mount needs no rule");
check(has(mounts("viewer", [{ path: "/f", share: "files.example:/x" }]), "must depend on network:rules"), "path: an unmodelled server needs network:rules");
check(has(mounts("jellyfin", [{ path: "/f", share: "8.8.8.8:/x" }]), "public address"), "wan: a public literal IP refused");
check(errors(mounts("jellyfin", [{ path: "/f", share: "192.168.1.20:/x" }])) === 0, "wan: a private literal IP passes");
check(has(mounts("jellyfin", [{ path: "/f", share: "outside" }]), "wan zone"), "wan: a share on a wan-zone server refused");
check(isPublicIpv4("8.8.8.8") && !isPublicIpv4("10.2.0.5") && !isPublicIpv4("100.64.1.1") && !isPublicIpv4("nas.lan"), "wan: the address classes");

// ── unused grants, and the wiring into validate ──
check(has(unusedGrants(configs.tappaas1, read), "grants ghost, which is not deployed"), "grant: an undeployed consumer is a warning");
check(unusedGrants(configs.tappaas1, read).every((f) => f.severity === "warning"), "grant: never an error");
{
  const out: ValidateFinding[] = [];
  const m = { name: "viewer", raw: { ...configs.viewer, config: { "pvehost:nfs": { mounts: [{ path: "/m", share: "media", access: "rw" }] } } } } as unknown as ModuleConfig;
  validateNfs(m, { readConfig: read, listInstances: list } as unknown as ServiceFs, out);
  check(out.some((f) => f.module === "viewer" && f.severity === "error"), "validate: a refused mount is an error on the consumer");
  const none: ValidateFinding[] = [];
  validateNfs(m, {} as ServiceFs, none);
  check(none.length === 0, "validate: without the instance reader the cross-module check is skipped, not failed");
}

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
