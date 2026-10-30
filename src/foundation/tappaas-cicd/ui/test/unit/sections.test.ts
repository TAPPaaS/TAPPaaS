// sections.test.ts — a module's page as sections (ADR-034 D11): how the layers
// compose, what console.json may say and what a bad one shows, the reads a
// declared section may run, and the kind sections against the fixture site.

import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { renderManifest } from "../../../lib/ts/src/help";
import { CmdbObject, CmdbRelationRow, Cmdb } from "../../src/cmdb";
import { CONSOLE_SCHEMA, NO_FILE, parseConsole, readConsoleFile, schemaErrors } from "../../src/consolefile";
import { CmdbView, KindInput, NodeLive, kindSections } from "../../src/kindsections";
import { Manifests, normalize } from "../../src/manifest";
import { ModuleRow } from "../../src/model";
import { Reads } from "../../src/reads";
import { Block, GENERIC, Placed, Section, compose, declaredBlocks, moduleLayer, pathIn, readArgv, section } from "../../src/sections";
import { gaugeLevel, valueText } from "../../web/src/sectionview";
import { check, done } from "./check";
import { FakeCmdb } from "./fake-cmdb";
import { FIX, fakeSite } from "./fake-site";

const REPO = join(FIX, "..", "..", "..", "..", "..", "..");
const schema = JSON.parse(readFileSync(join(REPO, "src", "foundation", "schemas", CONSOLE_SCHEMA), "utf8")) as Record<string, unknown>;
const pvehost = JSON.parse(readFileSync(join(REPO, "src", "foundation", "pvehost", "console.json"), "utf8")) as Record<string, unknown>;

const ms: Manifests = {
  byBin: new Map([
    ["health-manager", normalize(renderManifest({ name: "health-manager", version: "1", tagline: "", verbs: [{ usage: "guests [<node>] [--json]", effect: "read" }, { usage: "update-os <name> [--json]", effect: { noPreview: "patches it" } }] }))],
    ["site-manager", normalize(renderManifest({ name: "site-manager", version: "1", tagline: "", verbs: [{ usage: "evacuate <node> [--force]", name: "evacuate", effect: { noPreview: "moves its guests" } }, { usage: "node reboot <name> [--apply]" }] }))],
  ]),
  errors: [],
  loadedAt: "",
};

const ids = (l: { id: string }[]): string => l.map((x) => x.id).join(" ");
const s = (id: string, title = id): Section => section(id, title, "kind");
const add = (id: string, rest: Partial<Placed<Section>> = {}): Placed<Section> => ({ id, item: s(id), ...rest });
const blockOf = <K extends Block["kind"]>(x: Section, kind: K): Extract<Block, { kind: K }> | undefined => x.blocks.find((b) => b.kind === kind) as Extract<Block, { kind: K }> | undefined;

function composition(): void {
  check(ids(compose(GENERIC, [])) === "health operate about", "the generic layer alone: Health, Operate, About");
  check(ids(compose(GENERIC, [[add("resources"), add("backups")]])) === "health resources backups operate about", "a kind's sections go before Operate, in their order");
  check(ids(compose(GENERIC, [[add("a")], [add("b")]])) === "health a b operate about", "each later layer adds after the one below");
  const replaced = compose(GENERIC, [[add("a")], [{ id: "a", item: s("a", "theirs") }]]);
  check(ids(replaced) === "health a operate about" && replaced[1].title === "theirs", "a later layer replaces a section by id, in its place");
  const about = compose(GENERIC, [[{ id: "about", item: s("about", "ours") }]]);
  check(about[2].title === "ours" && !about[2].generic, "a generic section can be replaced too");
  check(ids(compose(GENERIC, [[add("a")], [{ id: "about", before: "health", item: null }]])) === "about health a operate", "a move carries no section: it reorders");
  check(ids(compose(GENERIC, [[add("a"), add("b")], [{ id: "a", after: "b", item: null }]])) === "health b a operate about", "after: behind the section named");
  check(ids(compose(GENERIC, [[add("c", { before: "health" })]])) === "c health operate about", "an added section can say where it goes");
  check(ids(compose(GENERIC, [[{ id: "ghost", before: "health", item: null }]])) === "health operate about", "a move of nothing does nothing");
  check(ids(compose(GENERIC, [[add("a", { after: "ghost" })]])) === "health a operate about", "a place that does not exist: the default place");
  check(ids(compose([s("x")], [[add("a")]])) === "x a", "no Operate: added at the end");
}

function validation(): void {
  check(schemaErrors(schema, pvehost).length === 0, "pvehost's console.json passes the schema");
  const good = parseConsole(pvehost, schema);
  check(good.error === null && good.sections.length === 2 && good.operations.length === 2, "and is taken in whole");
  const mixed = parseConsole({
    sections: [
      { id: "fine", title: "Fine", read: { bin: "health-manager", verb: "guests" }, render: "kv" },
      { id: "nocolumns", title: "T", read: { bin: "health-manager", verb: "guests" }, render: "table" },
      { id: "Bad Id", title: "T", read: { bin: "x", verb: "y" }, render: "kv" },
      { id: "wrong", title: "T", read: { bin: "x", verb: "y" }, render: "pie" },
      { id: "move", after: "about" },
      { id: "movenothing" },
      { id: "movetitled", title: "T", after: "about" },
      { id: "gaugeless", title: "T", read: { bin: "x", verb: "y" }, render: "gauges", fields: [{ label: "x" }] },
    ],
    operations: [{ label: "Ok", bin: "site-manager", verb: "evacuate" }, { label: "No verb", bin: "site-manager" }],
  }, schema);
  const bad = mixed.sections.filter((x) => "bad" in x) as { bad: string; id: string }[];
  check(mixed.error === null && mixed.sections.length === 8, "a bad entry does not take the file down");
  check(!("bad" in mixed.sections[0]) && !("bad" in mixed.sections[4]), "the good ones stand, a move among them");
  check(bad.find((b) => b.id === "nocolumns")?.bad.includes("columns") === true, "a table needs columns");
  check(bad.some((b) => b.id === "bad-section-3"), "an id that is no id: named by its place");
  check(bad.find((b) => b.id === "wrong")?.bad.includes("kv, table, gauges") === true, "an unknown renderer: says which there are");
  check(bad.some((b) => b.id === "movenothing"), "an entry that neither draws nor moves is bad");
  check(bad.some((b) => b.id === "movetitled"), "a move carries no title");
  check(bad.find((b) => b.id === "gaugeless")?.bad.includes("value") === true, "a gauge needs value and max");
  check(mixed.operations.length === 1 && mixed.badOperations[0].startsWith("No verb"), "a bad operation is named, the good one stands");
  check(parseConsole({ tabs: [] }, schema).error?.includes("tabs") === true, "an unknown top-level key: the file is an error");
  check(parseConsole([], schema).error !== null, "not an object: the file is an error");
  check(parseConsole(pvehost, {}).error?.includes(CONSOLE_SCHEMA) === true, "no schema to check against: an error, not a pass");
  const dir = mkdtempSync(join(tmpdir(), "console-json-"));
  check(readConsoleFile(dir, schema) === NO_FILE, "no console.json: nothing declared");
  check(readConsoleFile(null, schema) === NO_FILE, "no module directory: nothing declared");
  writeFileSync(join(dir, "console.json"), "{ not json");
  check(readConsoleFile(dir, schema).error?.startsWith("console.json") === true, "not JSON: an error");
}

async function declared(): Promise<void> {
  const table = { id: "t", title: "T", read: { bin: "health-manager", verb: "guests", args: ["$module"] }, render: "table" as const, rows: "guests", columns: [{ path: "module", label: "m" }, { path: "a.b", label: "deep" }] };
  const a = readArgv(table, "tappaas1", ms);
  check("argv" in a && a.argv.join(" ") === "health-manager guests tappaas1 --json", "$module stands for the name, and the verb runs with --json");
  const refused = (r: { argv: string[] } | { refused: string }): string => ("refused" in r ? r.refused : "");
  check(/not a manager/.test(refused(readArgv({ ...table, read: { bin: "rm", verb: "x" } }, "m", ms))), "a binary with no manifest never runs");
  check(/not a verb/.test(refused(readArgv({ ...table, read: { bin: "health-manager", verb: "nothing" } }, "m", ms))), "nor a verb its manifest does not declare");
  check(/is not a read/.test(refused(readArgv({ ...table, read: { bin: "health-manager", verb: "update-os", args: ["x"] } }, "m", ms))), "nor a verb that changes something");
  check(/not loaded/.test(refused(readArgv(table, "m", null))), "manifests still loading: it says so");

  const rows = declaredBlocks(table, { guests: [{ module: "x", a: { b: 3 } }, { module: "y" }] })[0] as Extract<Block, { kind: "table" }>;
  check(rows.rows[0]["a.b"] === 3 && rows.rows[1]["a.b"] === null, "a table's cells are found by their paths");
  let threw = "";
  try {
    declaredBlocks(table, {});
  } catch (e) {
    threw = (e as Error).message;
  }
  check(threw.includes("guests"), "rows the answer does not have: an error");
  const g = declaredBlocks({ id: "g", render: "gauges", rows: "pools", fields: [{ labelPath: "name", value: "used", max: "size", format: "bytes" }] }, { pools: [{ name: "p", used: 1, size: 4 }, { name: "q", size: 4 }] })[0] as Extract<Block, { kind: "gauges" }>;
  check(g.gauges.length === 1 && g.gauges[0].label === "p" && g.gauges[0].max === 4, "a gauge per row; a row with no number has none");
  const kv = declaredBlocks({ id: "k", render: "kv" }, { a: 1, b: "x", c: { d: 1 } })[0] as Extract<Block, { kind: "kv" }>;
  check(kv.rows.length === 2, "kv with no fields: the answer's plain values");
  check(pathIn({ a: [{ b: 7 }] }, "a.0.b") === 7, "a path reads through an array");

  const reads: string[] = [];
  const read = async (argv: string[]): Promise<{ value: unknown; at: number | null; error: string | null }> => {
    reads.push(argv.join(" "));
    return argv.includes("fail") ? { value: null, at: null, error: "exit 1" } : { value: { guests: [], volumes: [] }, at: 1000, error: null };
  };
  const layer = await moduleLayer({
    ...NO_FILE,
    sections: [
      table,
      { ...table, id: "off", read: { bin: "health-manager", verb: "guests", args: ["fail"] } },
      { ...table, id: "shape", rows: "nope" },
      { bad: "columns missing", id: "badone" },
      { id: "about", before: "health" },
    ],
    operations: [{ label: "Migrate", bin: "site-manager", verb: "evacuate", args: ["$module"] }, { label: "Drain", bin: "site-manager", verb: "drain" }],
    badOperations: ["Broken: needs verb"],
  }, "tappaas1", ms, read);
  const by = (id: string): Section | null => layer.find((p) => p.id === id)?.item ?? null;
  check(by("t")?.blocks.length === 1 && by("t")?.source === "health-manager guests" && by("t")?.layer === "module", "a declared section with its data and where it read it");
  check(by("off")?.error === "exit 1", "a read that fails is an error in its place");
  check(by("shape")?.error?.includes("nope") === true, "an answer of the wrong shape too");
  check(by("badone")?.error === "columns missing", "a section the schema refused too");
  check(layer.find((p) => p.id === "about")?.item === null, "a move reads nothing");
  const ops = by("operations");
  check(ops?.operations.length === 1 && ops.operations[0].verb === "evacuate" && ops.operations[0].fixed[0] === "tappaas1", "an operation with a manifest, its name filled in");
  check(ops?.operationErrors.includes("Drain: site-manager drain has no manifest") === true && ops.operationErrors.includes("Broken: needs verb"), "one without is named, and offers nothing to press");
  const whole = await moduleLayer({ ...NO_FILE, error: "console.json: broken" }, "m", ms, read);
  check(whole.length === 1 && whole[0].item?.error === "console.json: broken", "a broken file is one error in its place");
  check(ids(compose(GENERIC, [whole])) === "health console-json operate about", "and the page around it stands");
}

const row = (name: string, kind: string, rest: Partial<ModuleRow> = {}): ModuleRow => ({ name, kind, vmname: null, vmid: null, node: null, zone0: null, stack: null, status: null, environment: null, running: "running", actualNode: null, ...rest });
const blank: Omit<KindInput, "module"> = { cmdb: null, cmdbError: null, live: null, liveError: null, modules: [], topology: null, storage: null, backup: null, runs: null, snapshots: null, snapshotsError: null, ssids: null };

function kinds(): void {
  const live = (JSON.parse(readFileSync(join(FIX, "guests.json"), "utf8")) as { nodes: NodeLive[] }).nodes;
  check(ids(kindSections({ ...blank, module: row("x", "application") })) === "", "an application has no kind sections");
  check(ids(kindSections({ ...blank, module: row("x", "vm") })) === "resources backups", "a vm: resources backups");
  check(ids(kindSections({ ...blank, module: row("x", "lxc") })) === "resources backups", "an lxc: the same");
  check(ids(kindSections({ ...blank, module: row("x", "machine") })) === "guests pools ports cluster", "a machine: guests pools ports cluster");
  check(ids(kindSections({ ...blank, module: row("x", "device") })) === "ports", "a device: ports");
  const topoAp = { accessPoints: [{ name: "ap1", uplink: { switch: "sw1", port: "9" }, ssids: [{ name: "home" }] }] };
  const ap = kindSections({ ...blank, module: row("ap1", "device"), topology: topoAp, ssids: [{ name: "home", zone: "home", security: "wpa3", accessPoints: ["ap1"] }, { name: "guest", zone: "guest", security: "open", accessPoints: ["ap2"] }] });
  check(ids(ap) === "ports radios", "an access point: ports radios");
  const ssidTable = ap[1].blocks[1] as Extract<Block, { kind: "table" }>;
  check(ssidTable.rows.length === 1 && ssidTable.rows[0].zone === "home" && ssidTable.rows[0].security === "wpa3", "its SSIDs, with their zone and security");
  check((blockOf(ap[0], "table")?.rows[0].connects as string) === "sw1:9", "its uplink stands in for ports the CMDB has not recorded");
  check(blockOf(ap[0], "note")?.text.includes("no record") === true, "and it says the CMDB has none");

  const vm = kindSections({ ...blank, module: row("nextcloud", "vm", { vmid: 201, node: "tappaas1" }), live, snapshots: "tappaas-1\n", backup: { policy: { enabled: true, schedule: "daily" }, coverage: { jobs: [{ storage: "pbs" }] } }, runs: { reachable: true, targets: [], guests: [{ ns: "", id: "201", module: "nextcloud", outcome: "ok", latestVerify: "ok" }] } });
  const kv = blockOf(vm[0], "kv")!;
  const value = (l: string): unknown => kv.rows.find((r) => r.label === l)?.value;
  check(value("memory declared") === 8589934592 && value("allocated") === 6442450944 && value("used") === 4294967296 && value("available") === 4294967296, "memory declared, allocated and used, from the balloon figures");
  check(value("HA") === "an HA resource" && value("node") === "tappaas1", "its node and HA state");
  const disks = vm[0].blocks.find((b) => b.kind === "table" && b.title?.startsWith("Disks")) as Extract<Block, { kind: "table" }>;
  check(disks.rows.length === 2 && disks.rows[1].copy === "replica" && disks.rows[0].pool === "tanka1", "disks with their pools, a replica marked");
  check(blockOf(vm[0], "text")?.text === "tappaas-1", "its snapshots");
  const b = blockOf(vm[1], "kv")!;
  check(b.rows.find((r) => r.label === "last backup")?.value === "ok" && b.rows.find((r) => r.label === "PBS jobs")?.value === "pbs", "backups: the policy and the last run");

  const fw = kindSections({ ...blank, module: row("fw", "vm", { vmid: 110 }), live, snapshotsError: "no such vm" });
  const fwKv = blockOf(fw[0], "kv")!;
  check(fwKv.rows.find((r) => r.label === "used")?.value === null, "a guest that reports nothing has no used figure, not the host's");
  check(fw[0].blocks.some((x) => x.kind === "note" && x.text.includes("no such vm")), "snapshots that cannot be read say why");
  const down = kindSections({ ...blank, module: row("x", "vm"), liveError: "ssh failed", cmdbError: "refused" });
  check(down[0].blocks.filter((x) => x.kind === "note").length >= 2 && blockOf(down[0], "kv") !== undefined, "with no CMDB and no live read: notes and what is known, never blank");

  const self = (o: Partial<CmdbObject>): CmdbObject => ({ id: "m1", class: "machine", name: "tappaas1", attributes: {}, ...o });
  const pool = self({ id: "p1", class: "storage-pool", name: "tanka1", attributes: { size: 100, used: 95, zfsState: "ONLINE" } });
  const sick = self({ id: "p2", class: "storage-pool", name: "tankb1", attributes: { size: 100, used: 10, zfsState: "DEGRADED" } });
  const vmo = self({ id: "v1", class: "vm", name: "gitea", attributes: { vmid: 300, memory: 2048 } });
  const end = (o: CmdbObject): { id: string; class: string; name: string } => ({ id: o.id, class: o.class, name: o.name });
  const port = self({ id: "pt1", class: "port", name: "eno1", attributes: { kind: "rj45", speed: "10g", link: "up", role: "lan" } });
  const peer = { id: "pt2", class: "port", name: "1" };
  const cable: CmdbRelationRow = { id: 9, type: "connects", from: end(port), to: peer };
  const view: CmdbView = {
    self: self({ attributes: { clusterMember: true } }),
    relations: [
      { id: 1, type: "runs-on", direction: "in", other: end(vmo) },
      { id: 2, type: "runs-on", direction: "in", other: end(pool) },
      { id: 3, type: "runs-on", direction: "in", other: end(sick) },
      { id: 4, type: "member-of", direction: "out", other: { id: "c1", class: "cluster", name: "rossen" } },
    ],
    objects: new Map([vmo, pool, sick, self({ id: "c1", class: "cluster", name: "rossen", attributes: { quorum: true } })].map((o) => [o.id, o])),
    asset: self({ id: "a1", class: "server", name: "srv-01" }),
    ports: [port],
    connects: [cable],
    owners: new Map([["pt2", "sw-01"], ["pt1", "srv-01"]]),
    members: [{ id: "m1", class: "machine", name: "tappaas1" }, { id: "m2", class: "machine", name: "tappaas2" }],
  };
  const m = kindSections({ ...blank, module: row("tappaas1", "machine"), cmdb: view, live, modules: [row("gitea", "vm")] });
  const guests = blockOf(m[0], "table")!;
  check(guests.rows.length === 3 && guests.rows[0].module === "nextcloud", "guests: the CMDB's and the live ones, one row each, largest first");
  check(guests.rows.find((r) => r.module === "gitea")?.declared === 2048 * 1024 ** 2, "a guest only the CMDB knows: its recorded memory");
  check(guests.rows.find((r) => r.module === "firewall")?.used === null, "a guest with no figure of its own shows none");
  const gauges = blockOf(m[1], "gauges")!.gauges;
  check(gauges.length === 2 && gaugeLevel(gauges[0]) === "fail" && gaugeLevel(gauges[1]) === "warn" && gauges[1].label.includes("DEGRADED"), "pools: fill, and health over fill");
  const ports = blockOf(m[2], "table")!;
  check(ports.rows[0].connects === "sw-01:1" && ports.rows[0].speed === "10g", "a port and what its cable reaches, by box and port");
  const c = blockOf(m[3], "kv")!;
  check(c.rows.find((r) => r.label === "cluster")?.value === "rossen" && c.rows.find((r) => r.label === "other members")?.value === "tappaas2" && c.rows.find((r) => r.label === "quorum")?.value === true, "cluster membership: its cluster, quorum, the others");
  const noCmdb = kindSections({ ...blank, module: row("tappaas1", "machine"), storage: { nodes: [{ name: "tappaas1", pools: [{ name: "tanka1", health: "ONLINE", usable: { total: 10, used: 5 } }] }] } as never, topology: { nodes: [{ name: "tappaas1", kind: "cluster-member", guests: [{ module: "gitea", vmid: 300, kind: "vm" }], uplinks: [{ name: "lan", legs: [{ nic: "nic2", speed: "10G", up: true, peer: { switch: "sw", port: "12" } }] }] }] } });
  check(blockOf(noCmdb[0], "table")?.rows[0].module === "gitea", "no CMDB: the topology's guests");
  check(blockOf(noCmdb[1], "gauges")?.gauges[0].value === 5, "the inventory's pools");
  check(blockOf(noCmdb[2], "table")?.rows[0].connects === "sw:12", "the topology's uplinks");

  check(valueText(1024 ** 3, "bytes") === "1.0 GiB" && valueText(2048, "mib") === "2.0 GiB", "sizes read as sizes");
  check(valueText(null) === "—" && valueText(true) === "yes", "nothing reads as a dash, a boolean as a word");
}

async function endToEnd(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-sections-"));
  const src = join(dir, "pvehost-src");
  mkdirSync(src);
  copyFileSync(join(REPO, "src", "foundation", "pvehost", "console.json"), join(src, "console.json"));
  writeFileSync(join(dir, "tappaas1.json"), JSON.stringify({ moduleSource: src, kind: "machine" }));
  const site = fakeSite();
  const fake = new FakeCmdb();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7, repoRoot: REPO, cmdb: fake as unknown as Cmdb });
  const m = row("tappaas1", "machine", { node: "tappaas1" });
  const out = await reads.moduleSections(m, ms);
  check(ids(out) === "health guests pools ports cluster memory-by-module storage-by-module operations operate about", "a pvehost instance: generic, machine, then its console.json, before Operate");
  const mem = out.find((x) => x.id === "memory-by-module")!;
  check(mem.error === null && blockOf(mem, "table")?.rows[0].module === "nextcloud", "Memory by module, read with its node's name");
  check(blockOf(out.find((x) => x.id === "storage-by-module")!, "table")?.rows[0].pool === "tanka1", "Storage used by modules");
  check(out.find((x) => x.id === "operations")?.operations.map((o) => o.verb).join() === "evacuate,node reboot", "its operations, both with manifests");
  const guests = blockOf(out.find((x) => x.id === "guests")!, "table")!;
  check(guests.rows.some((r) => r.module === "gitea"), "the CMDB's runs-on");
  const ports = blockOf(out.find((x) => x.id === "ports")!, "table")!;
  check(ports.rows.some((r) => r.port === "eno1" && String(r.connects).includes("srv-02")), "the asset's ports and the cable's far end");
  check(blockOf(out.find((x) => x.id === "cluster")!, "kv")?.rows.find((r) => r.label === "other members")?.value === "tappaas2", "the cluster's other member");
  const before = site.calls.filter((c) => c.startsWith("health-manager guests tappaas1")).length;
  await reads.moduleSections(m, ms);
  check(site.calls.filter((c) => c.startsWith("health-manager guests tappaas1")).length === before && before === 1, "a declared read runs once and is cached; two sections share it");

  const vm = await reads.moduleSections(row("nextcloud", "vm", { vmid: 201 }), ms);
  check(ids(vm) === "health resources backups operate about", "a vm with no console.json");
  check(blockOf(vm[1], "text")?.text.includes("tappaas-20261030") === true && !blockOf(vm[1], "text")?.text.includes("\u001b"), "its snapshots, colour taken out");
  check(ids(await reads.moduleSections(row("nothing", "application"), ms)) === "health operate about", "an application: the generic three");

  writeFileSync(join(src, "console.json"), JSON.stringify({ sections: [{ id: "broken", render: "table" }] }));
  const bad = await reads.moduleSections(m, ms);
  check(bad.find((x) => x.id === "broken")?.error?.includes("columns") === true && ids(bad).startsWith("health guests"), "a bad section is an error in its place; the rest of the page stands");

  fake.down = true;
  reads.moduleCmdb.clear();
  const offline = await reads.moduleSections(row("nextcloud", "vm", { vmid: 201 }), ms);
  check(blockOf(offline[1], "note")?.text.includes("CMDB") === true && blockOf(offline[1], "kv") !== undefined, "the CMDB down: it says so and the live numbers stand");
}

async function main(): Promise<void> {
  composition();
  validation();
  await declared();
  kinds();
  await endToEnd();
  done("sections");
}

void main();
