// cipanel.test.ts — a CI's panel, shaped from fixtures (no CMDB, no socket):
// its record and open events, its history the newest first, the trace up the
// backbone and where it stops, and what is read of the repository for it.

import { CmdbHistory, CmdbShow } from "../../src/cmdb";
import { Backbone, ModuleRef, adrRefs, backboneSteps, ciHistory, ciRecord, issuesUrl, openEvents, walkTrace, webUrlOf } from "../../src/cipanel";
import { check, done } from "./check";

const NOW = Date.parse("2026-10-31T12:00:00Z");
const T0 = "2026-10-30T08:00:00Z";
const a = (value: unknown, source = "module-manager", since = T0) => ({ value, source, since });
const end = (id: string, cls: string, name: string) => ({ id, class: cls, name });

// A port on an asset allocated to a machine in a cluster; a vm on the machine.
const SHOWS: Record<string, CmdbShow> = {
  port: {
    id: "port", class: "port", name: "srv-01:nic0", attributes: { kind: a("rj45", "site-manager") }, drift: null,
    relations: [{ id: 1, type: "part-of", direction: "out", other: end("asset", "server", "srv-01") }],
  },
  asset: {
    id: "asset", class: "server", name: "srv-01", displayName: "tappaas1's box", attributes: { serial: a("XYZ", "asset-manager") }, drift: null,
    relations: [
      { id: 1, type: "part-of", direction: "in", other: end("port", "port", "srv-01:nic0") },
      { id: 2, type: "allocated-to", direction: "out", other: end("m1", "machine", "tappaas1") },
    ],
  },
  m1: {
    id: "m1", class: "machine", name: "tappaas1", drift: null,
    attributes: { desired: a({ file: "tappaas1" }), release: a({ module: "tappaas-node", version: "1.4.0" }) },
    relations: [
      { id: 3, type: "member-of", direction: "out", other: end("env", "environment", "mgmt") },
      { id: 4, type: "member-of", direction: "out", other: end("cl", "cluster", "tappaas") },
      { id: 5, type: "runs-on", direction: "in", other: end("vm1", "vm", "nextcloud") },
      { id: 2, type: "allocated-to", direction: "in", other: end("asset", "server", "srv-01") },
    ],
  },
  cl: { id: "cl", class: "cluster", name: "tappaas", attributes: {}, drift: null, relations: [{ id: 4, type: "member-of", direction: "in", other: end("m1", "machine", "tappaas1") }] },
  vm1: {
    id: "vm1", class: "vm", ancestors: ["object", "ci", "node", "vm"], name: "nextcloud", drift: { attributes: { memory: { was: 4096, now: 8192 } } },
    attributes: {
      vmid: a(301, "site-manager", "2026-10-29T10:00:00Z"),
      desired: a({ file: "nextcloud.json" }),
      release: a({ module: "nextcloud", version: "3.4.1" }),
      drift: a({ attributes: {} }, "cmdb-controller"),
      conditions: a([
        { type: "operational", status: "ok", since: "2026-10-30T00:00:00Z" },
        { type: "backup", status: "warning", reason: "stale", since: "2026-10-31T06:00:00Z", source: "backup-manager" },
        { type: "capacity", status: "critical", message: "disk 97%", since: "2026-10-30T22:00:00Z", acknowledged: { by: "lars", until: "2026-10-31T10:00:00Z" } },
        { type: "security", status: "warning", since: "2026-10-30T20:00:00Z", maintenance: { until: "2026-11-01T00:00:00Z" } },
      ], "health-manager"),
    },
    relations: [
      { id: 5, type: "runs-on", direction: "out", other: end("m1", "machine", "tappaas1"), source: "site-manager", since: T0 },
      { id: 6, type: "depends-on", direction: "out", other: end("svc", "service", "identity:sso") },
      { id: 7, type: "backs-up", direction: "in", other: end("ds", "datastore", "tappaas_backup") },
    ],
  },
};

const lookup = async (id: string): Promise<CmdbShow> => {
  const s = SHOWS[id];
  if (!s) throw new Error(`no object ${id}`);
  return s;
};
const MOD: ModuleRef = { name: "nextcloud", version: "3.4.2", issues: "https://codeberg.org/TAPPaaS/TAPPaaS/issues?state=open&q=nextcloud", adrs: [{ name: "ADR-020", link: "https://x/ADR-020.md" }] };
const asked: Backbone[] = [];
const modules = async (b: Backbone): Promise<ModuleRef | null> => {
  asked.push(b);
  return b.release?.module === "nextcloud" ? MOD : null;
};

function record(): void {
  const r = ciRecord(SHOWS.vm1, NOW);
  check(r.label === "nextcloud" && r.class === "vm", "the record names the CI and its class");
  check(r.attributes.map((x) => x.name).join(",") === "desired,release,vmid", "attributes sorted, conditions and drift kept for their own sections");
  const vmid = r.attributes.find((x) => x.name === "vmid")!;
  check(vmid.source === "site-manager" && vmid.since === "2026-10-29T10:00:00Z", "each attribute keeps its source and since");
  check(r.relations.length === 3 && r.relations[0].direction === "out" && r.relations[2].direction === "in", "relations both ways, out first");
  check(r.relations[0].type === "depends-on" && r.relations[0].source === null && r.relations[1].source === "site-manager", "within a direction by type; a relation's source where it has one");
  check(r.relations[2].other.name === "tappaas_backup" && r.relations[2].type === "backs-up", "a relation's far end");
  check(JSON.stringify(r.drift) === JSON.stringify({ attributes: { memory: { was: 4096, now: 8192 } } }), "drift is the show's");

  // Open events: not ok only, the worst first, then the newest.
  const ev = r.events;
  check(ev.map((e) => e.type).join(",") === "capacity,backup,vulnerability", "open events: critical first, then warnings newest first; ok left out");
  check(ev[0].acknowledged === false, "an acknowledgement that ran out no longer silences");
  check(ev[2].maintenance === true, "a maintenance window that holds marks the event");
  check(ev[1].reason === "stale" && ev[1].source === "backup-manager", "an event keeps its reason and source");
  check(openEvents({}, NOW).length === 0 && openEvents({ conditions: "nonsense" }, NOW).length === 0, "no conditions, or none readable: no events");
  check(openEvents({ conditions: [{ type: "x", status: "bogus" }, { type: "y", status: "unknown" }] }, NOW).map((e) => e.type).join() === "y", "unknown is open; an unknown status word is dropped");
}

function history(): void {
  const h: CmdbHistory = {
    id: "vm1",
    attributes: [
      { name: "memory", value: 4096, source: "site-manager", from: "2026-10-20T00:00:00Z", to: "2026-10-30T08:00:00Z" },
      { name: "memory", value: 8192, source: "site-manager", from: "2026-10-30T08:00:00Z", to: null },
      { name: "vmid", value: 301, source: "site-manager", from: "2026-10-20T00:00:00Z", to: null },
    ],
    relations: [{ id: 5, type: "runs-on", direction: "out", other: end("m1", "machine", "tappaas1"), source: "site-manager", from: "2026-10-25T00:00:00Z", to: null }],
    changes: [
      { id: 1, kind: "observation", source: "site-manager", job: null, verb: null, actor: null, time: "2026-10-20T00:00:00Z", drift: false },
      { id: 9, kind: "change", source: "module-manager", job: "j42", verb: "modify", actor: "lars", time: "2026-10-30T08:00:00Z", drift: true },
    ],
  };
  const rows = ciHistory(h);
  check(rows.length === 6, "every period and every change is a row");
  check(rows.every((r, i) => i === 0 || Date.parse(rows[i - 1].at) >= Date.parse(r.at)), "the newest first");
  check(rows[0].what === "change" && rows[0].name === "modify" && rows[0].detail === "lars · job j42" && rows[0].drift, "at one moment the change before what it wrote; its actor and job");
  check(rows[1].what === "attribute" && rows[1].value === 8192 && rows[1].until === null, "then the period it opened, still holding");
  check(rows[2].what === "relation" && rows[2].detail === "out" && (rows[2].value as { name: string }).name === "tappaas1", "a relation's period names its far end and direction");
  check(rows[rows.length - 1].what === "attribute" || rows[rows.length - 1].what === "change", "the oldest last");
  check(ciHistory(h, 2).length === 2, "the limit holds");
  check(ciHistory({ id: "x", attributes: [], changes: [] }).length === 0, "a history without relations: none");
}

async function trace(): Promise<void> {
  const vm = await walkTrace(SHOWS.vm1, lookup, modules);
  check(vm.map((s) => s.name).join(" > ") === "nextcloud > tappaas1 > tappaas > config/nextcloud.json > nextcloud 3.4.1 > nextcloud > open issues of nextcloud > ADR-020", "a vm: its machine, the cluster, then its own desired record, release, module, issues, ADRs");
  check(vm[0].relation === null && vm[1].relation === "runs-on" && vm[2].relation === "member-of", "each hop names its relation");
  check(vm[2].class === "cluster", "member-of prefers the cluster to the environment");
  check(vm.slice(0, 3).every((s) => s.id !== null) && vm.slice(3).every((s) => s.id === null), "CIs carry an id; the backbone above them does not");
  check(vm[5].link === "/modules/nextcloud" && vm[6].link === MOD.issues && vm[7].link === "https://x/ADR-020.md", "the module opens its page, the issues and ADRs the forge");
  check(asked.length === 1 && asked[0].release?.module === "nextcloud", "the backbone is the start's own when it records one");

  const port = await walkTrace(SHOWS.port, lookup, modules);
  check(port.map((s) => s.relation ?? "-").slice(0, 4).join(",") === "-,part-of,allocated-to,member-of", "a port: its asset, the machine it is allocated to, the cluster");
  check(port[1].name === "tappaas1's box", "a hop shows the object's display name");
  check(port.some((s) => s.class === "desired" && s.name === "config/tappaas1.json") && port.some((s) => s.class === "release" && s.name === "tappaas-node 1.4.0"), "the nearest backbone up the way: the machine's desired record and release");
  check(!port.some((s) => s.class === "issues"), "no module read: no issues step");

  const short = await walkTrace(SHOWS.port, lookup, modules, 1);
  check(short.length === 1 + 1 && short[1].class === "server", "the hop limit stops the walk; nothing up the way had a backbone");

  // A cycle never loops; a CI the CMDB cannot show ends the walk.
  const loopA: CmdbShow = { id: "A", class: "vm", name: "a", attributes: {}, drift: null, relations: [{ id: 1, type: "runs-on", direction: "out", other: end("B", "machine", "b") }] };
  const loopB: CmdbShow = { id: "B", class: "machine", name: "b", attributes: {}, drift: null, relations: [{ id: 2, type: "member-of", direction: "out", other: end("A", "cluster", "a") }] };
  const loop = await walkTrace(loopA, async (id) => (id === "A" ? loopA : loopB), modules);
  check(loop.length === 2, "a cycle stops at the object seen");
  const gone: CmdbShow = { id: "G", class: "vm", name: "g", attributes: {}, drift: null, relations: [{ id: 1, type: "runs-on", direction: "out", other: end("nope", "machine", "nope") }] };
  const g = await walkTrace(gone, lookup, modules);
  check(g.length === 2 && g[1].name === "nope", "a CI the CMDB cannot show is the last step, by the name the relation gives");

  // A chain longer than eight hops stops at eight.
  const chain: Record<string, CmdbShow> = {};
  for (let i = 0; i < 12; i++) chain[`c${i}`] = { id: `c${i}`, class: "vm", name: `c${i}`, attributes: {}, drift: null, relations: i < 11 ? [{ id: i, type: "runs-on", direction: "out", other: end(`c${i + 1}`, "vm", `c${i + 1}`) }] : [] };
  const long = await walkTrace(chain.c0, async (id) => chain[id], modules);
  check(long.length === 9, "eight hops at most");
}

function backbone(): void {
  check(backboneSteps({ desired: null, release: null }, null).length === 0, "nothing recorded, nothing read: no backbone");
  const d = backboneSteps({ desired: { file: "config/zones.json", key: "srv" }, release: null }, null);
  check(d.length === 1 && d[0].name === "config/zones.json · srv", "a desired record with its key; no module, the trace ends there");
  const m = backboneSteps({ desired: null, release: null }, { name: "gitea", version: "1.2.0", issues: null, adrs: [] });
  check(m.map((s) => s.name).join(",") === "gitea 1.2.0,gitea", "a module found by its instance: the catalogue's version");

  check(adrRefs("Implements ADR-040 D10 and ADR-007a; see ADR-040, ADR-41 and ADR041.").join() === "ADR-007a,ADR-040,ADR-041", "ADR references, each once, sorted");
  check(webUrlOf("git@codeberg.org:TAPPaaS/TAPPaaS.git") === "https://codeberg.org/TAPPaaS/TAPPaaS", "an ssh remote");
  check(webUrlOf("ssh://git@codeberg.org/TAPPaaS/TAPPaaS.git") === "https://codeberg.org/TAPPaaS/TAPPaaS", "an ssh:// remote");
  check(webUrlOf("https://codeberg.org/TAPPaaS/TAPPaaS.git") === "https://codeberg.org/TAPPaaS/TAPPaaS", "an https remote");
  check(webUrlOf("https://codeberg.org/TAPPaaS/Community/") === "https://codeberg.org/TAPPaaS/Community", "an https remote without .git");
  check(webUrlOf(null) === null && webUrlOf("/srv/repo") === null, "no remote, or a path: no web address");
  check(issuesUrl("https://codeberg.org/TAPPaaS/TAPPaaS", "home assistant") === "https://codeberg.org/TAPPaaS/TAPPaaS/issues?state=open&q=home%20assistant", "the open issues naming the module");
}

async function main(): Promise<void> {
  console.log("cipanel");
  record();
  history();
  await trace();
  backbone();
  done("cipanel");
}

void main();
