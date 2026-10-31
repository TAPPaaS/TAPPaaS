// overview.test.ts — the Overview page's shaping (web/src/overview.ts): the four
// area tiles over hrossen's records (test/fixtures) and the Health fixture
// site's conditions, and which ten open events the Alerts show, in what order.

import { readFileSync } from "fs";
import { join } from "path";
import { moduleSummaries } from "../../src/badges";
import { buildHealth, healthSummary } from "../../src/health";
import { BackupRow, HealthDoc, ModuleRow } from "../../src/model";
import { operationsDoc } from "../../src/operations";
import { ZoneLike } from "../../web/src/envcards";
import { AREA_CLASSES, areaStatus, bytes, environmentTile, identityTile, modulesTile, siteTile, topAlerts } from "../../web/src/overview";
import { HealthSummary, JobSummary, ModuleSummary, OpsEvent, Operations, SiteRead, StorageInventory } from "../../web/src/types";
import { check, done } from "./check";
import { healthSite, relationTypes } from "./fake-cmdb";
import { FIX } from "./fake-site";

const read = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;
const NOW = Date.parse("2026-10-30T09:00:00Z");

const validate = read<HealthDoc>("validate.json");
const rows = read<{ modules: ModuleRow[] }>("modules.json").modules;
const modules = moduleSummaries(rows, validate, read<BackupRow[]>("backup.json")) as unknown as ModuleSummary[];
const storage = read<StorageInventory>("storage-inventory.json");
const envs = read<{ name: string; displayName?: string }[]>("environments.json");
const zones = read<ZoneLike[]>("zones.json");
const hs = healthSite();
const graph = buildHealth({ objects: hs.objects, relations: hs.relations, relationTypes: relationTypes(), modules: ["nextcloud", "immich", "gitea", "backup", "logging"], now: NOW });
const summary = healthSummary(graph) as unknown as HealthSummary;
const none: HealthSummary = { ...summary, available: false, byType: {} };

const site: SiteRead = {
  site: { name: "rossen", displayName: "Rossen", channel: "stable", locations: { hq: { displayName: "Home" }, cabin: { displayName: "Cabin", kind: "remote" } }, primaryLocation: "hq" },
  nodes: [{ name: "tappaas1" }, { name: "tappaas2" }, { name: "tappaas3", location: "hq" }],
  repositories: [],
  lastSweep: { end_time: "2026-10-30 23:00:00", ok: true, total: 25, failed: 0 },
};

function areas(): void {
  check(areaStatus(summary, "site") === "critical", "Site: a machine's critical (tappaas2) colours the tile");
  check(areaStatus(summary, "environment") === "critical", "Environment: the environment's impact condition counts");
  check(areaStatus(summary, "modules") === "critical", "Modules: the guests' conditions count");
  check(areaStatus(summary, "identity") === "ok", "Identity: nothing on a user, group or organization is ok");
  check(areaStatus(none, "site") === null && areaStatus(null, "modules") === null, "no conditions: no answer, the tile falls back to its own reads");
  // The silenced capacity critical on the datastore is the only one of its class: silenced, it does not count.
  const onlyStore: HealthSummary = { ...summary, byType: { capacity: summary.byType.capacity } };
  check(areaStatus(onlyStore, "site") === "ok", "a silenced condition does not colour a tile");
  const all = Object.values(AREA_CLASSES).flat();
  check(new Set(all).size === all.length, "every class belongs to one area");
}

function siteT(): void {
  const t = siteTile(site, storage, validate.gates as never, summary);
  check(t.name === "Rossen", "the site's display name");
  check(t.locations.map((l) => `${l.name}${l.primary ? "*" : ""}`).join(" ") === "hq* cabin", "the locations, the primary first");
  check(t.nodes.map((n) => `${n.name}:${n.status}`).join(" ") === "tappaas1:ok tappaas2:critical tappaas3:ok", `each node with its worst condition (${t.nodes.map((n) => `${n.name}:${n.status}`).join(" ")})`);
  check(t.nodes[2].location === "hq", "a node's location as site-manager lists it");
  check(t.quorum?.status === "ok" && t.quorum.text === "3 vote(s)", "the cluster's quorum from the quorum gate");
  check(t.storage?.total === 23549305704448 && t.storage.used === 1640166862848 && t.storage.pools === 5, "storage: every pool's usable space summed");
  check(t.status === "critical", "the tile's colour is the area's worst condition");
  const plain = siteTile(site, storage, validate.gates as never, none);
  check(plain.nodes.find((n) => n.name === "tappaas3")?.status === "warning", "no conditions: a node's state is the storage inventory's");
  check(plain.status === "warning", "no conditions: the tile is the worst of quorum and storage");
  check(siteTile(null, null, null, null).status === "unknown" && siteTile(null, null, null, null).storage === null, "nothing read yet: unknown");
}

function envT(): void {
  const t = environmentTile(envs, zones, modules, "rossen", summary);
  check(t.envs.map((e) => e.name).join(" ") === "rossen mgmt test", "one row per environment, the default first");
  const r = t.envs.find((e) => e.name === "rossen")!;
  check(r.zone === "rossen" && r.modules === 13, `rossen: its own zone and its 13 modules (${r.zone}, ${r.modules})`);
  check(r.maturity.map((m) => `${m.count} ${m.word}`).join(", ") === "7 Testing, 6 Development", "its modules' maturity, the most first");
  check(t.envs.find((e) => e.name === "mgmt")!.maturity[0].word === "Development", "mgmt: mostly Development");
  check(r.status === "critical", "an environment's dot is its modules' worst health badge (immich fails)");
  check(t.envs.reduce((s, e) => s + e.modules, 0) === modules.length, "every module counted once");
  check(t.status === "critical", "the tile's colour from the conditions");
  check(environmentTile(envs, zones, modules, "rossen", none).status === "critical", "no conditions: the worst module of any environment");
  check(environmentTile(null, null, null, null, null).status === "unknown", "nothing read yet: unknown");
}

const job = (id: string, object: string, state: JobSummary["state"], ended: string | null, exit: number | null, verb = "update", bin = "module-manager"): JobSummary =>
  ({ id, kind: "apply", state, bin, verb, object, argv: [bin, verb, object], ended, exit } as unknown as JobSummary);

function modT(): void {
  const jobs = [
    job("1", "immich", "running", null, null),
    job("2", "nextcloud", "done", "2026-10-30T07:00:00Z", 0),
    job("3", "forgejo", "done", "2026-10-29T07:00:00Z", 1),
    job("4", "litellm", "done", "2026-10-30T08:00:00Z", 0, "modify"),
    job("5", "zone-x", "done", "2026-10-30T08:30:00Z", 0, "update", "network-manager"),
  ];
  const t = modulesTile(modules, jobs, false, site.lastSweep, summary);
  check(t.total === 25 && t.running === 17 && t.updating === 1 && t.stopped === 0 && t.archived === 0 && t.noGuest === 7, `counts by state (${t.running} running, ${t.updating} updating, ${t.noGuest} without a guest)`);
  check(t.running + t.stopped + t.updating + t.archived + t.noGuest === t.total, "every module in exactly one state");
  check(t.lastUpdates.map((u) => u.what).join(" ") === "sweep nextcloud forgejo", `the last updates, newest first: the sweep and module updates only (${t.lastUpdates.map((u) => u.what).join(" ")})`);
  check(t.lastUpdates[2].ok === false, "a failed update says so");
  check(t.attention.slice(0, 3).map((m) => m.name).join(" ") === "immich logging openwebui" && t.attention.length === 11, `what needs attention, failing first (${t.attention.map((m) => m.name).join(" ")})`);
  check(t.status === "critical", "the tile's colour from the conditions");
  const archived = modulesTile([{ ...modules[2], status: "archived" }], [], true, null, none);
  check(archived.archived === 1 && archived.running === 0 && archived.sweepActive, "an archived module counts as archived, not running; a running sweep is said");
  check(modulesTile(modules, [], false, null, none).status === "critical", "no conditions: the worst health badge");
}

function idT(): void {
  const ids = { org: ["rossen"], group: ["installer", "admin", "users"], user: ["lars", "erik"], role: ["admin"] };
  const t = identityTile(ids, modules, summary);
  check(t.counts?.users === 2 && t.counts.groups === 3 && t.counts.roles === 1 && t.counts.orgs === 1, "users, groups, roles and organizations counted");
  check(t.provider?.installed === true && t.provider.run === "running" && t.provider.health === "warning", "the identity provider: the identity module's run state and health");
  check(t.status === "warning", "the tile carries the provider's warning beside the area's ok");
  const gone = identityTile(ids, modules.filter((m) => m.name !== "identity"), summary);
  check(gone.provider?.installed === false && gone.status === "critical", "no identity module: critical");
  check(identityTile(null, null, null).status === "unknown" && identityTile(null, null, null).counts === null, "nothing read yet: unknown");
}

const ev = (id: string, status: OpsEvent["status"], since: string | null): OpsEvent =>
  ({ id, class: "vm", name: id, label: id, environment: null, module: null, type: "operational", status, reason: `r-${id}`, message: null, since, flapping: false, conditions: [], isRoot: false, rootCause: [] } as OpsEvent);

function alerts(): void {
  const doc = operationsDoc(graph, new Map(), [], NOW) as unknown as Operations;
  const a = topAlerts(doc);
  check(a.rows.map((e) => e.label).join(" ") === "tappaas2 gitea", `the fixture site's open events, critical first (${a.rows.map((e) => e.label).join(" ")})`);
  check(a.total === 2 && a.more === 0, "two open: nothing more");

  // Thirteen events in three groups: critical first, the newest first within each.
  const t = (h: number) => `2026-10-30T${String(h).padStart(2, "0")}:00:00Z`;
  const groups = [
    { root: "w1", status: "warning", since: t(1), events: [ev("w1", "warning", t(1)), ev("w2", "warning", t(9)), ev("w3", "warning", null)], impact: { count: 0, objects: [] } },
    { root: "c1", status: "critical", since: t(2), events: [ev("c1", "critical", t(2)), ev("w4", "warning", t(8)), ev("c2", "critical", t(7))], impact: { count: 0, objects: [] } },
    { root: "c3", status: "critical", since: t(3), events: [ev("c3", "critical", t(3)), ev("w5", "warning", t(5)), ev("w6", "warning", t(6)), ev("w7", "warning", t(4)), ev("c4", "critical", t(5)), ev("w8", "warning", t(2)), ev("w9", "warning", t(3))], impact: { count: 0, objects: [] } },
  ];
  const ops = { ...doc, groups } as unknown as Operations;
  const top = topAlerts(ops);
  check(top.rows.length === 10 && top.total === 13 && top.more === 3, "ten rows of thirteen: three more on the Operations page");
  check(top.rows.map((e) => e.id).join(" ") === "c2 c4 c3 c1 w2 w4 w6 w5 w7 w9", `critical first, then warning, the newest first (${top.rows.map((e) => e.id).join(" ")})`);
  check(!top.rows.some((e) => e.id === "w3"), "an event with no since sorts last and falls off first");
  check(topAlerts(ops, 3).rows.every((e) => e.status === "critical"), "a smaller cut keeps the criticals");
  check(topAlerts(null).total === 0 && topAlerts(null).rows.length === 0, "no operations read: no alerts");
}

function units(): void {
  check(bytes(23549305704448) === "24 TB" && bytes(1640166862848) === "1.6 TB" && bytes(512) === "512 B", "bytes as the tile shows them");
}

areas();
siteT();
envT();
modT();
idT();
alerts();
units();
done("overview");
