// disks.test.ts — disks in the console (ADR-042 D6): the Assets tree with
// disks under the server they are in and in stock, each with its health and
// pool from the CMDB (src/assets.ts); a disk's placements from the history of
// its CIs; the page helpers (web/src/diskview.ts); which placement fields a
// form offers; a disk CI's and a Storage selection's Details; and a pool's
// members in the Storage view (web/src/physical/storage.ts).

import { readFileSync } from "fs";
import { join } from "path";
import { AssetPositions, DiskFacts, assetTree, byBay, diskPlacements, diskState } from "../../src/assets";
import { CmdbObject, CmdbRelationRow } from "../../src/cmdb";
import { filterLocation, itemsOf } from "../../web/src/assetview";
import { assetPath, ciDetails, selDetails } from "../../web/src/details";
import { adoptOffer, bayRow, diskAssetOf, diskText, disksOf, healthText, hostChoices, placeFieldsFor, placementLines, poolText, serialKey, worstDisk } from "../../web/src/diskview";
import { STORAGE_GATES, diskKey, poolMembers, storageNotes } from "../../web/src/physical/storage";
import { AssetTree, Gate, StorageInventory } from "../../web/src/types";
import { check, done } from "./check";
import { PIN } from "./fake-site";


// ── the tree ─────────────────────────────────────────────────────────────

const pos: AssetPositions = {
  assets: [
    { name: "srv-01", kind: "server", displayName: null, vendor: "HP", model: "hp/z840", serial: "S1", stage: "operational", role: "tappaas1", location: "home", placed: true, ports: [] },
    { name: "srv-02", kind: "server", displayName: null, vendor: null, model: null, serial: "S2", stage: "stock", role: null, location: "home", placed: false, ports: [] },
    { name: "dsk-01", kind: "disk", displayName: "nvme-Samsung_A", vendor: null, model: "Samsung 990", serial: "SAM-001", stage: "placed", role: null, location: "home", placed: true, in: { asset: "srv-01", bay: "2" }, disk: { kind: "nvme", size: 2_000_398_934_016 } },
    { name: "dsk-02", kind: "disk", displayName: "nvme-Samsung_B", vendor: null, model: "Samsung 990", serial: "SAM-002", stage: "placed", role: null, location: "home", placed: true, in: { asset: "srv-01", bay: "10" }, disk: { kind: "nvme", size: 2_000_398_934_016 } },
    { name: "dsk-03", kind: "disk", displayName: "ata-HGST_X", vendor: null, model: "HGST", serial: "NAHW317X", stage: "placed", role: null, location: "home", placed: true, in: { asset: "srv-01", bay: null }, disk: { kind: "hdd" } },
    { name: "dsk-04", kind: "disk", displayName: "ata-WD_spare", vendor: null, model: null, serial: "WD-9", stage: "stock", role: null, location: "home", placed: false },
    { name: "dsk-05", kind: "disk", displayName: null, vendor: null, model: null, serial: "OLD-1", stage: "disposed", role: null, location: "home", placed: false },
  ],
  locations: [{ name: "home", displayName: "Home", primary: true, rooms: ["cellar"], unplaced: [] }],
  racks: [{ name: "r1", displayName: null, units: 12, room: "cellar", placements: [{ device: "tappaas1", kind: "node", u: 5, height: 2, face: "front" }] }],
  rooms: [{ name: "cellar", displayName: null, location: "home", recorded: true, racks: ["r1"], loose: [] }],
  unplaced: [],
  cables: [],
};

const obj = (id: string, cls: string, name: string, attributes: Record<string, unknown>): CmdbObject => ({ id, class: cls, name, attributes });
const facts: DiskFacts = {
  disks: [
    obj("c1", "disk", "dsk-01", { health: "PASSED", conditions: [{ type: "operational", status: "ok" }] }),
    obj("c2", "disk", "dsk-02", { health: "PASSED", conditions: [{ type: "operational", status: "warning", message: "534 reallocated sectors", reason: "smart" }] }),
    obj("c3", "disk", "dsk-03", { health: "FAILED" }),
  ],
  builtOn: [
    { id: 1, type: "built-on", from: { id: "p1", class: "storage-pool", name: "tanka1" }, to: { id: "c1", class: "disk", name: "dsk-01" }, attributes: { redundancyGroup: "tappaas1:tanka1:mirror-0" } },
    { id: 2, type: "built-on", from: { id: "p1", class: "storage-pool", name: "tanka1" }, to: { id: "c2", class: "disk", name: "dsk-02" }, attributes: { redundancyGroup: "tappaas1:tanka1:mirror-0" } },
    { id: 3, type: "built-on", from: { id: "p2", class: "storage-pool", name: "tankc1" }, to: { id: "c3", class: "disk", name: "dsk-03" }, attributes: { redundancyGroup: null } },
  ] as CmdbRelationRow[],
  servers: [
    obj("s1", "server", "srv-01", {
      disks: [
        { name: "nvme-Samsung_A", serial: "sam 001" }, // recorded: dsk-01, spelt otherwise
        { name: "ata-ST12000_ZZ30", serial: "ZZ30MJL6", model: "ST12000", size: 12e12, type: "hdd" },
        { name: "usb-stick", device: "/dev/sdx" }, // no serial: not adoptable
      ],
    }),
  ],
};

const tree = assetTree(pos, [], facts);
const home = tree.locations.find((l) => l.name === "home")!;
const srv1 = tree.assets.find((a) => a.name === "srv-01")!;
check(srv1.disks.map((d) => d.name).join(",") === "dsk-01,dsk-02,dsk-03", "a server's disks, by bay (2 before 10), one without a bay last");
check(srv1.disks[0].bay === "2" && srv1.disks[0].serial === "SAM-001" && srv1.disks[0].size === 2_000_398_934_016 && srv1.disks[0].kind === "nvme", "a disk row: bay, serial, size, kind");
check(srv1.disks[0].state === "ok" && srv1.disks[0].health === "PASSED" && srv1.disks[0].ci === "c1", "its health from its CI");
check(srv1.disks[1].state === "warn" && srv1.disks[1].reason === "534 reallocated sectors", "a condition not ok: its state and message");
check(srv1.disks[2].state === "fail" && srv1.disks[2].reason === "Proxmox says FAILED", "no condition yet: Proxmox's word");
check(srv1.disks[0].pool?.name === "tanka1" && srv1.disks[0].pool.node === "tappaas1" && srv1.disks[0].pool.vdev === "mirror-0", "the pool built on it, its node and vdev from the redundancy group");
check(srv1.disks[2].pool?.name === "tankc1" && srv1.disks[2].pool.node === null, "a lone disk's pool: no group");
check(srv1.unrecordedDisks.length === 2 && srv1.unrecordedDisks[0].serial === "ZZ30MJL6" && srv1.unrecordedDisks[1].serial === null, "the server CI's disks no asset records (a serial spelt otherwise is recorded)");
check(itemsOf(home).every((i) => !["dsk-01", "dsk-02", "dsk-03"].includes(i.asset ?? "")), "a disk in a server is no row of its own in the tree");
check(home.unplaced.some((i) => i.asset === "dsk-04" && i.kind === "disk"), "a disk in stock: under its location's not placed");
check(home.disposed.some((i) => i.asset === "dsk-05"), "a disposed disk: under disposed");
const d1 = tree.assets.find((a) => a.name === "dsk-01")!;
check(d1.asDisk?.host === "srv-01" && d1.where.rack === "r1" && d1.where.room === "cellar" && d1.where.at === null, "a disk stands where its server stands");
check(!d1.allocationDrift && d1.disks.length === 0, "a disk plays no role: no allocation drift");
check(tree.assets.find((a) => a.name === "dsk-04")!.asDisk?.state === "unknown" && tree.assets.find((a) => a.name === "dsk-04")!.asDisk?.host === null, "a disk in stock: no CI, its state unknown");
const blind = assetTree(pos, [], new Error("down"));
check(blind.disksError === "down" && blind.assets.find((a) => a.name === "srv-01")!.disks.every((d) => d.state === "unknown" && d.ci === null && d.pool === null), "the CMDB's disks not read: listed from the record, without health or pool");
check(assetTree(pos, []).disksError === null && assetTree(pos, []).assets.find((a) => a.name === "srv-01")!.disks.length === 3, "no disk facts given: the disks still listed");
check(byBay({ ...srv1.disks[0], bay: "a" }, { ...srv1.disks[1], bay: null }) < 0, "a bay before none");

// diskState alone
check(diskState({ conditions: [{ type: "operational", status: "critical", message: "FAULTED in tanka1" }, { type: "drift", status: "warning" }] }).state === "fail", "the worst condition wins");
check(diskState({ health: "passed" }).state === "ok" && diskState({}).state === "unknown" && diskState(null).state === "unknown", "the health word, any case; nothing: unknown");

// ── a disk's placements ──────────────────────────────────────────────────

const hist = new Map([
  ["c-old", { attributes: [{ name: "bay", value: "3", from: "2026-01-01T00:00:00Z", to: "2026-06-01T00:00:00Z" }], relations: [{ type: "part-of", direction: "out", other: { name: "srv-02" }, from: "2026-01-01T00:00:00Z", to: "2026-06-01T00:00:00Z" }] }],
  ["c1", { attributes: [{ name: "bay", value: "1", from: "2026-06-02T00:00:00Z", to: "2026-07-01T00:00:00Z" }, { name: "bay", value: "2", from: "2026-07-01T00:00:00Z", to: null }], relations: [{ type: "part-of", direction: "out", other: { name: "srv-01" }, from: "2026-06-02T00:00:00Z", to: null }, { type: "built-on", direction: "in", other: { name: "tanka1" }, from: "2026-06-02T00:00:00Z", to: null }] }],
]);
const pl = diskPlacements([{ id: "c-old", created: "2026-01-01T00:00:00Z", ended: "2026-06-01T00:00:00Z" }, { id: "c1", created: "2026-06-02T00:00:00Z", ended: null }], hist);
check(pl.length === 2 && pl[0].asset === "srv-01" && pl[0].until === null && pl[0].bay === "2" && pl[1].asset === "srv-02" && pl[1].bay === "3", "placements: each CI's asset, the newest first, the last bay");
const lines = placementLines(pl);
check(lines[0].now && !lines[1].now, "the one it is in now");
check(diskPlacements([{ id: "x", created: "2026-02-02T00:00:00Z", ended: null }], new Map()).map((p) => p.asset).join() === "?", "a CI without its relation's history: still a period");

// ── the page helpers ─────────────────────────────────────────────────────

const t = tree as unknown as AssetTree;
check(serialKey(" Sam-001 ") === "sam001" && diskAssetOf(t, "sam 001")?.name === "dsk-01" && diskAssetOf(t, "nope") === null && diskAssetOf(t, null) === null, "a disk asset by its serial, spelt any way");
check(disksOf(t, "tappaas1").length === 3 && disksOf(t, "srv-01").length === 3 && disksOf(t, "nothing").length === 0 && disksOf(null, "x").length === 0, "the disks of a device, by its role or its name");
const row = bayRow(srv1.disks as AssetTree["assets"][number]["disks"]);
check(row.map((c) => c.label).join(",") === "2,10,dsk-03" && row[1].state === "warn" && row[0].title.includes("bay 2") && row[0].title.includes("dsk-01"), "the bay row: a cell per disk, its bay else its tag, its state");
check(worstDisk(srv1.disks as AssetTree["assets"][number]["disks"]) === "fail" && worstDisk([]) === null, "the worst of a row");
check(diskText(srv1.disks[0] as AssetTree["assets"][number]["disks"][number]).includes("nvme") && diskText(srv1.disks[0] as AssetTree["assets"][number]["disks"][number]).includes("pool tanka1 · mirror-0 on tappaas1"), "a disk in one line");
check(poolText(null) === "" && poolText({ name: "tankc1", node: null, vdev: null }) === "tankc1", "a pool in words");
check(healthText(srv1.disks[1] as AssetTree["assets"][number]["disks"][number]).startsWith("warn · 534") && healthText({ state: "unknown", reason: null, health: null, ci: null }) === "not in the CMDB", "health in words");
check(hostChoices(t, d1).join(",") === "srv-02", "a disk moves into any other asset that is no disk");
check(hostChoices(t, { in: undefined }).join(",") === "srv-01,srv-02", "from stock: every asset that is no disk");
const offer = adoptOffer(t.assets.find((a) => a.name === "srv-01")!);
check(offer?.count === 1 && offer.text.includes("ZZ30MJL6"), "Adopt…: offered for the disks with a serial its CI lists and no asset records");
check(adoptOffer(t.assets.find((a) => a.name === "srv-02")!) === null && adoptOffer(t.assets.find((a) => a.name === "dsk-01")!) === null, "nothing to adopt, or a disk: not offered");
const f = filterLocation(t, home as unknown as AssetTree["locations"][number], "SAM-002");
check(f !== null && itemsOf(f).some((i) => i.asset === "srv-01"), "the filter finds a server by a disk's serial");

// ── the place form's fields ──────────────────────────────────────────────

check(placeFieldsFor("disk").join(",") === "in,bay", "a disk: in and bay only");
const dev = placeFieldsFor("server");
check(dev.includes("rack") && dev.includes("room") && dev.includes("u") && !dev.includes("in") && !dev.includes("bay"), "anything else: rack or room, never in or bay");
check(placeFieldsFor(undefined).join() === dev.join(), "no kind: a device's");

// ── the Details of a disk ────────────────────────────────────────────────

check(ciDetails({ class: "disk", ancestors: ["resource", "object"], name: "dsk-01", module: null, relations: [] }).map((x) => x.to).join() === "/site/assets/dsk-01", "a disk CI: its own page");
const mods = new Set<string>();
const sd = selDetails({ kind: "disk", id: "/dev/sdb", node: "tappaas3" }, { modules: mods, diskAsset: "dsk-03" });
check(sd.length === 2 && sd[0].to === assetPath("dsk-03") && sd[1].to === "/site/assets/tappaas3", "a Storage disk an asset records: its page, its node's second");
check(selDetails({ kind: "disk", id: "/dev/sdb", node: "tappaas3" }, { modules: mods, diskAsset: null }).map((x) => x.to).join() === "/site/assets/tappaas3", "one no asset records: its node");

// ── the Storage view: the gates, a pool's members ────────────────────────

const inv = JSON.parse(readFileSync(join(PIN, "storage-inventory.json"), "utf8")) as StorageInventory;
check(STORAGE_GATES.join(",") === "storage-pools,storage-replication", "the storage gates: pools and replication; disks are judged on their CIs");
const gates: Gate[] = [
  { name: "storage-replication", status: "warn", detail: "", findings: [{ status: "warn", text: "nextcloud → tappaas2 behind", subject: { kind: "node", name: "tappaas1" } }] },
  { name: "storage-disks", status: "warn", detail: "", findings: [{ status: "warn", text: "retired gate", subject: { kind: "disk", name: "tappaas3:/dev/sdb" } }] },
];
const notes = storageNotes(inv, gates);
check((notes.get("node:tappaas1") ?? []).some((n) => n.source === "storage-replication"), "a replication row on its node");
check(!(notes.get(diskKey("tappaas3", "/dev/sdb")) ?? []).some((n) => n.source === "storage-disks"), "the retired storage-disks gate is no longer read");
const t1 = inv.nodes.find((n) => n.name === "tappaas1")!;
const members = poolMembers("tappaas1", t1.pools.find((p) => p.name === "tanka1")!, notes);
check(members.length === 2 && members.every((m) => m.vdev === "mirror-0" && !m.missing && m.serial !== null), "a mirror's members: its two disks with their serials");
const t3 = inv.nodes.find((n) => n.name === "tappaas3")!;
const sick = poolMembers("tappaas3", t3.pools.find((p) => p.name === "tankc1")!, notes);
check(sick.length === 1 && sick[0].device === "/dev/sdb" && sick[0].state === "fail" && sick[0].serial === "NAHW317X", "a failing member: its state");
const gone = poolMembers("x", { ...t3.pools[0], vdevs: [{ ...t3.pools[0].vdevs[0], disks: [], missing: [{ name: "1234567", state: "UNAVAIL" }] }] });
check(gone.length === 1 && gone[0].missing && gone[0].state === "fail" && gone[0].text.startsWith("UNAVAIL"), "a member ZFS names that is gone: missing, failed");

done("disks");
