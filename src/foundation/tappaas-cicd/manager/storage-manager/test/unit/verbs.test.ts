// verbs.test.ts — what each storage-manager verb does to config/shares.json, and the
// shared share model it validates with (ADR-029 v0.9). Offline: documents in, documents
// out, configs from an in-memory reader.

import { addShare, deleteShare, grant, modifyShare, revoke } from "../../src/verbs";
import {
  SharesDoc,
  checkMounts,
  checkShares,
  nextOwner,
  parseShareRef,
  shareAlias,
  sharesOf,
} from "../../../../lib/ts/src/nfs-shares";

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
const ok = (r: unknown): r is { doc: SharesDoc } => !!r && typeof r === "object" && "doc" in r;
const refused = (r: unknown, needle: string): boolean =>
  !!r && typeof r === "object" && "refused" in r && String((r as { refused: string }).refused).includes(needle);
const has = (fs: { message: string }[], needle: string): boolean => fs.some((f) => f.message.includes(needle));
const errors = (fs: { severity: string }[]): number => fs.filter((f) => f.severity === "error").length;

const configs: Record<string, Record<string, unknown>> = {
  tappaas1: { kind: "machine", management: "managed", zone0: "mgmt", address: "tappaas1.mgmt.internal", moduleSource: "/r/pvehost" },
  debhost: { kind: "machine", management: "managed", zone0: "mgmt", moduleSource: "/r/debianhost" },
  nas1: { kind: "machine", management: "unmanaged", zone0: "home", address: "nas1.home.internal" },
  edge: { kind: "machine", management: "unmanaged", zone0: "wan" },
  jellyfin: { zone0: "srvHome", vmname: "jellyfin", dependsOn: ["cluster:vm", "network:rules", "storage:nfs"] },
  viewer: { zone0: "srvHome", dependsOn: ["cluster:vm", "storage:nfs"] },
};
const read = (i: string): Record<string, unknown> | null => configs[i] ?? null;
const hasHook = (i: string): boolean => i === "tappaas1";

// ── share add ──
let doc: SharesDoc = {};
const a = addShare(doc, "media", { server: "tappaas1", pool: "tankb1", quota: "4T", backup: true, properties: { recordsize: "1M" } }, true);
check(ok(a), "add: a managed share is declared");
if (ok(a)) doc = a.doc;
const media = sharesOf(doc).media;
check(media?.owner?.uid === 64000 && media.owner.gid === 64000, "add: the owner is allocated at add (64000), not by a server");
check(JSON.stringify(media?.grants) === "{}", "add: no grants yet");
check(refused(addShare(doc, "media", { server: "tappaas1", pool: "tankb1", backup: true }, true), "already declared"), "add: a name already declared refused — Site-unique by construction");
check(refused(addShare(doc, "p", { server: "tappaas1", pool: "tankb1" }, true), "--backup"), "add: backup must be stated for a managed share");
check(refused(addShare(doc, "p", { server: "tappaas1", backup: true }, true), "--pool"), "add: a managed share needs a pool");
check(refused(addShare(doc, "p", { server: "tappaas1", path: "/x", backup: true }, true), "--path is for a registered"), "add: --path refused on a managed server");
check(refused(addShare(doc, "Bad", { server: "tappaas1", pool: "p", backup: true }, true), "must match"), "add: a bad name refused");
const v = addShare(doc, "video", { server: "nas1", path: "/volume1/video", version: "4.1" }, false);
check(ok(v) && sharesOf(v.doc).video?.path === "/volume1/video" && !sharesOf(v.doc).video?.owner, "add: a registered server's share is a descriptor, no owner");
if (ok(v)) doc = v.doc;
check(refused(addShare(doc, "x", { server: "nas1", pool: "tankb1" }, false), "registered, unmanaged"), "add: --pool refused on a registered server");
const p2 = addShare(doc, "photos", { server: "tappaas1", pool: "tankb1", backup: false }, true);
check(ok(p2) && sharesOf(p2.doc).photos?.owner?.uid === 64001, "add: the next share gets the next free owner");
check(nextOwner({ nfs: { shares: { a: { owner: { uid: 64000 } }, b: { owner: { uid: 64002 } } } } }) === 64001, "owner: the lowest free uid");

// ── grant / revoke ──
const g = grant(doc, "media", "jellyfin", "rw");
check(ok(g) && sharesOf(g.doc).media.grants?.jellyfin === "rw", "grant: one consumer added");
if (ok(g)) doc = g.doc;
const g2 = grant(doc, "media", "viewer", "ro");
check(ok(g2) && Object.keys(sharesOf(g2.doc).media.grants ?? {}).length === 2, "grant: another consumer added without touching the first");
if (ok(g2)) doc = g2.doc;
check(refused(grant(doc, "nope", "jellyfin", "rw"), "not declared"), "grant: an undeclared share refused");
check(refused(grant(doc, "media", "jellyfin", "admin"), "ro or rw"), "grant: bad access refused");
check(refused(revoke(doc, "media", "jellyfin", true), "still mounts"), "revoke: refused while the consumer mounts the share (D6)");
const r = revoke(doc, "media", "viewer", false);
check(ok(r) && !("viewer" in (sharesOf(r.doc).media.grants ?? {})) && sharesOf(r.doc).media.grants?.jellyfin === "rw", "revoke: one grant goes, the rest stay");
check(refused(revoke(doc, "media", "stranger", false), "grants stranger nothing"), "revoke: a grant that does not exist refused");

// ── modify ──
const m = modifyShare(doc, "media", [["quota", "8T"], ["properties.compression", "lz4"], ["backup.enabled", "false"]]);
check(ok(m) && sharesOf(m.doc).media.quota === "8T" && sharesOf(m.doc).media.properties?.compression === "lz4" && sharesOf(m.doc).media.backup?.enabled === false,
  "modify: quota, a property and backup.enabled change in place");
check(ok(m) && sharesOf(m.doc).media.properties?.recordsize === "1M", "modify: other properties are kept");
check(refused(modifyShare(doc, "media", [["pool", "tankc1"]]), "data migration"), "modify: pool refused — a data migration (D7)");
check(refused(modifyShare(doc, "media", [["server", "tappaas3"]]), "data migration"), "modify: server refused — a move comes later (Q18)");
check(refused(modifyShare(doc, "media", [["owner.uid", "1"]]), "immutable"), "modify: owner refused — immutable");
check(refused(modifyShare(doc, "media", [["grants.x", "rw"]]), "nfs grant"), "modify: grants go through grant/revoke");
check(refused(modifyShare(doc, "media", [["properties.mountpoint", "/x"]]), "not a property"), "modify: an unknown property refused");
check(refused(modifyShare(doc, "media", [["backup.enabled", "maybe"]]), "true or false"), "modify: backup.enabled is boolean");
check(refused(modifyShare(doc, "video", [["quota", "1T"]]), "registered, unmanaged"), "modify: nothing to provision on a registered server");

// ── delete ──
check(refused(deleteShare(doc, "media", ["jellyfin"]), "mounted by jellyfin"), "delete: refused while mounted (D6)");
const d = deleteShare(doc, "photos" in sharesOf(doc) ? "photos" : "video", []);
check(ok(d), "delete: an unmounted share's declaration goes");
check(ok(d) && /data kept/.test((d as { summary: string }).summary), "delete: says the data is kept");

// ── validation of the whole file ──
check(errors(checkShares(doc, read, hasHook)) === 0, "validate: the built document is valid");
check(has(checkShares({ nfs: { shares: { x: { server: "debhost", pool: "p", backup: { enabled: true } } } } }, read, hasHook), "ships no NFS server hook"),
  "validate: a managed server whose module has no hook cannot serve (D19)");
check(has(checkShares({ nfs: { shares: { x: { server: "ghost", pool: "p", backup: { enabled: true } } } } }, read, hasHook), "not a module instance"), "validate: an unknown server refused");
check(has(checkShares({ nfs: { shares: { x: { server: "edge", path: "/x" } } } }, read, hasHook), "wan zone"), "validate: a server in the wan zone refused");
check(has(checkShares({ nfs: { shares: { a: { server: "tappaas1", pool: "p", backup: { enabled: true }, owner: { uid: 64000, gid: 64000 } }, b: { server: "tappaas1", pool: "p", backup: { enabled: true }, owner: { uid: 64000, gid: 64000 } } } } }, read, hasHook), "one owner per share"),
  "validate: two shares with one owner refused");
check(has(checkShares({ nfs: { shares: { x: { server: "nas1", path: "/v", version: "3" } } } }, read, hasHook), "v3Ports"), "validate: NFSv3 needs pinned ports");
check(has(checkShares({ nfs: { shares: { x: { server: "tappaas1", pool: "p", backup: { enabled: true }, grants: { ghost: "rw" } } } } }, read, hasHook), "not deployed"), "validate: a grant to an undeployed consumer is a warning");

// ── consumers' mounts against shares.json (module-manager validate) ──
const withShares = (d2: SharesDoc) => (i: string) => (i === "shares" ? (d2 as Record<string, unknown>) : read(i));
const mounts = (name: string, ms: unknown[], extra: Record<string, unknown> = {}) =>
  checkMounts(name, { ...configs[name], ...extra, config: { "storage:nfs": { mounts: ms } } }, withShares(doc));
check(errors(mounts("jellyfin", [{ path: "/media", share: "media", subdir: "jellyfin", access: "rw" }])) === 0, "mount: granted rw passes");
{
  const f = mounts("jellyfin", [{ path: "/m", share: "nope" }]);
  check(errors(f) === 0 && has(f, "pending"), "mount: an undeclared share is pending — a warning, never an error");
}
{
  const revoked = ok(r) ? r.doc : doc;
  const f = checkMounts("viewer", { ...configs.viewer, zone0: "mgmt", config: { "storage:nfs": { mounts: [{ path: "/m", share: "media" }] } } }, withShares(revoked));
  check(has(f, "grants viewer nothing"), "mount: an existing share without a grant is an error");
  check(has(f, "storage-manager nfs grant media viewer"), "mount: the message is the command to run");
}
check(has(mounts("jellyfin", [{ path: "/m", share: "tappaas1:/tappaas-nfs/media" }]), "name its share"), "mount: a literal on a module instance refused");
check(has(mounts("jellyfin", [{ path: "/m", share: "media", subdir: "../x" }]), "subdir"), "mount: subdir .. refused");
check(has(mounts("jellyfin", [{ path: "/f", share: "8.8.8.8:/x" }]), "public address"), "mount: a public literal IP refused");
check(has(checkMounts("x", { dependsOn: ["cluster:vm"], config: { "storage:nfs": { mounts: [{ path: "/m", share: "media" }] } } }, withShares(doc)), "without storage:nfs"),
  "mount: mounts without the storage:nfs dependency refused");
check(typeof parseShareRef("tappaas1:media") === "string", "ref: the withdrawn <instance>:<name> form refused");
check(shareAlias("media") === "nfs-media.mgmt.internal", "alias name");

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
