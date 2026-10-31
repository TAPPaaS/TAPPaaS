// cmdb.test.ts — what asset-manager reports to the CMDB (ADR-040 step 3), over
// hrossen's positions.json as migration 0027 leaves it
// (scripts/test/fixtures/0027-hrossen/positions-after.json): the classes, the
// keys, the relations and the recorded source of `report`; that every object
// fits cmdb-controller's metamodel (its metamodel/*.json, read as the
// controller reads them); the change reports of asset allocate and release,
// and of a removal; and that `export --cmdb` reads back into the document.
// Offline: no controller, no PostgreSQL — what the controller does with a
// report is cmdb-controller's test.
//
// Run: RM_FIXTURE_DIR=<asset-manager>/test/fixtures RM_CATALOG_DIR=<asset-manager>/faceplates node cmdb.test.js

import { readFileSync } from "fs";
import { join } from "path";
import { Metamodel } from "../../../../controller/cmdb-controller/src/metamodel";
import type { CmdbObject, CmdbRef, CmdbRelation, CmdbReport } from "../../../../lib/ts/src/cmdb";
import { PositionsDoc, cablesOf, heightOf, placementsOf, stageOf, withSiteFaceplates } from "../../../../lib/ts/src/positions";
import { CmdbAnswer, SOURCE, View, changeReport, cmdbAnswer, cmdbView, fullReport, positionsFromCmdb } from "../../src/cmdb";
import { loadCatalog } from "../../src/store";
import { addDisk, addFaceplate, allocateAsset, placeDisk, releaseAsset, removeAsset, removePort, unplaceDevice } from "../../src/verbs";

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
type Obj = Record<string, unknown>;

const FIX = process.env.RM_FIXTURE_DIR ?? "test/fixtures";
const CICD = join(FIX, "..", "..", "..", "..");
const doc0 = JSON.parse(readFileSync(join(CICD, "scripts/test/fixtures/0027-hrossen/positions-after.json"), "utf8")) as PositionsDoc;
const site = JSON.parse(readFileSync(join(FIX, "site-hrossen.json"), "utf8")) as { primaryLocation: string };
const primary = site.primaryLocation;
const shipped = loadCatalog(process.env.RM_CATALOG_DIR ?? "faceplates").catalog;
const catalogOf = (d: PositionsDoc) => withSiteFaceplates(shipped, d).catalog;
const viewOf = (d: PositionsDoc): View => cmdbView(d, catalogOf(d), primary);
const mm = Metamodel.fromDir(join(CICD, "controller/cmdb-controller/metamodel"));
const doc = (r: { doc: PositionsDoc } | { refused: string }): PositionsDoc => {
  if ("refused" in r) throw new Error(r.refused);
  return r.doc;
};

// ── the report fits the metamodel, as the controller checks a batch ────────

// The controller's checks, offline: a concrete class; every attribute a field
// of it (not derived, not name), of its type and enum, allowedBy holding;
// a relation field a ref to an earlier object its relation joins; required
// fields present; a complete key; a relation's ends joined by its type.
function problems(r: CmdbReport, extra: Map<string, string> = new Map()): string[] {
  const out: string[] = [];
  const refs = new Map<string, string>(extra); // ref → class
  const keys = new Set<string>();
  const targetOf = (at: string, ref: CmdbRef): string | null => {
    if (typeof ref === "object" && ref.ref) return refs.get(ref.ref) ?? (out.push(`${at}: ref ${ref.ref} is not earlier in the report`), null);
    if (typeof ref === "object" && ref.class && ref.name) return ref.class;
    out.push(`${at}: an unresolvable reference ${JSON.stringify(ref)}`);
    return null;
  };
  (r.objects ?? []).forEach((o: CmdbObject, i) => {
    const at = `objects[${i}] ${o.class} ${o.name}`;
    const c = mm.classes.get(o.class);
    if (!c) return void out.push(`${at}: no class`);
    if (c.abstract) out.push(`${at}: abstract`);
    const fields = mm.fields(o.class);
    const attrs = (o.attributes ?? {}) as Obj;
    for (const [k, v] of Object.entries(attrs)) {
      const f = fields.get(k);
      if (!f) {
        out.push(`${at}: no field ${k}`);
        continue;
      }
      if (k === "name" || f.spec.derived === true) out.push(`${at}: ${k} is not reported`);
      if (v === null) {
        if (f.required) out.push(`${at}: ${k} is required`);
        if (f.immutable) out.push(`${at}: ${k} is immutable and is unset`);
        continue;
      }
      if (f.type === "relation") {
        const tc = targetOf(`${at}.${k}`, v as CmdbRef);
        const dir = f.spec.direction === "in" ? "in" : "out";
        if (tc && !mm.descendants(tc).some((d) => (dir === "out" ? mm.allows(String(f.spec.relation), o.class, d) : mm.allows(String(f.spec.relation), d, o.class)))) {
          out.push(`${at}.${k}: ${String(f.spec.relation)} does not join ${o.class} and ${tc}`);
        }
        continue;
      }
      const t = f.type;
      const ok =
        t === "string" ? typeof v === "string" : t === "integer" ? Number.isInteger(v) : t === "number" ? typeof v === "number" : t === "boolean" ? typeof v === "boolean" : t === "array" ? Array.isArray(v) : t === "object" ? typeof v === "object" && !Array.isArray(v) : true;
      if (!ok) out.push(`${at}.${k}: not ${t}`);
      const en = Array.isArray(f.spec.enum) ? (f.spec.enum as unknown[]) : null;
      if (en && !en.includes(v)) out.push(`${at}.${k}: ${JSON.stringify(v)} is not one of ${en.join(", ")}`);
      const items = f.spec.items as Obj | undefined;
      if (Array.isArray(v) && items && Array.isArray(items.enum) && !v.every((x) => (items.enum as unknown[]).includes(x))) out.push(`${at}.${k}: an item outside ${String(items.enum)}`);
      const ab = f.spec.allowedBy as Record<string, Record<string, unknown[]>> | undefined;
      for (const [ctl, table] of Object.entries(ab ?? {})) {
        const allowed = table[String(attrs[ctl])];
        if (!Array.isArray(allowed)) out.push(`${at}.${k}: does not apply when ${ctl} is ${String(attrs[ctl])}`);
        else if (allowed.length && !(Array.isArray(v) ? v : [v]).every((x) => allowed.includes(x))) out.push(`${at}.${k}: ${String(v)} not allowed for ${ctl} ${String(attrs[ctl])}`);
      }
    }
    if (!o.end) for (const f of fields.values()) if (f.required && f.name !== "name" && (attrs[f.name] === undefined || attrs[f.name] === null)) out.push(`${at}: ${f.name} is required`);
    const ks = mm.keys(o.class);
    const complete = ks.find((k) => k.components.every((n) => n === "name" || (attrs[n] !== undefined && attrs[n] !== null)));
    if (ks.length && !complete) out.push(`${at}: no complete key`);
    // The identity it is known by in this batch: its class's key scope, the
    // key's values (a ref stands for its object).
    const kv = complete ? complete.components.map((n) => (n === "name" ? o.name : JSON.stringify(attrs[n]))).join("|") : o.name;
    const id = `${mm.keyScope(o.class)}|${kv}`;
    if (!o.end && keys.has(id)) out.push(`${at}: its key ${id} is another object's in this batch`);
    keys.add(id);
    if (o.ref) refs.set(o.ref, o.class);
  });
  (r.relations ?? []).forEach((rel: CmdbRelation, i) => {
    const at = `relations[${i}] ${rel.type}`;
    const f = targetOf(`${at}.from`, rel.from);
    const t = targetOf(`${at}.to`, rel.to);
    if (!f || !t) return;
    const ok = mm.descendants(f).some((a) => mm.descendants(t).some((b) => mm.allows(rel.type, a, b)));
    if (!ok) out.push(`${at}: does not join ${f} to ${t}`);
  });
  return out;
}

// ── report ────────────────────────────────────────────────────────────────
{
  const v = viewOf(doc0);
  const { report, allocations } = fullReport(v);
  check(report.source === SOURCE && SOURCE === "asset-manager" && report.kind === "observation", "report: source asset-manager, an observation");
  check([...(report.objects ?? []), ...(report.relations ?? [])].every((x) => (x as { recorded?: boolean }).recorded === true), "report: every object and relation marked recorded");
  check(v.skipped.length === 0, `report: nothing of hrossen's left out${v.skipped.length ? ` (${v.skipped.join("; ")})` : ""}`);
  const nic = viewOf({ ...doc0, cables: [...(doc0.cables ?? []), { from: { device: "patchpanel1", port: "9", side: "rear" }, to: { device: "tappaas2", port: "enp97s0" }, kind: "patch" as const }] });
  check(nic.skipped.length === 0 && nic.objects.some((x) => x.class === "port" && x.name === "enp97s0" && x.attributes.kind === undefined) && nic.relations.some((r) => r.type === "connects" && (r.to as { ref?: string }).ref?.endsWith(":enp97s0")), "report: a cable to a NIC its server does not list makes it a port");
  check(!positionsFromCmdb(cmdbAnswer(nic)).assets!["srv-02"].ports?.some((x) => x.name === "enp97s0"), "report: …which the asset's own ports do not take up");
  const p = problems(report);
  check(p.length === 0, `report: every object fits cmdb-controller's metamodel${p.length ? ` — ${p.slice(0, 5).join("; ")}` : ""}`);
  const objs = report.objects ?? [];
  const o = (cls: string, name: string) => objs.find((x) => x.class === cls && x.name === name);
  const classOf = (name: string) => objs.find((x) => x.name === name && x.class !== "port")?.class;
  check(
    classOf("srv-01") === "server" && classOf("sw-01") === "network-device" && classOf("ap-01") === "network-device" && classOf("ISP modem") === "appliance" && classOf("patchpanel1") === "passive-device" && classOf("printer") === "other-device",
    "report: each asset as its D3 subclass (server, network-device, appliance, passive-device, other-device)",
  );
  check(o("network-device", "ap-01")?.attributes?.deviceType === "access-point" && o("appliance", "ISP modem")?.attributes?.deviceType === "modem", "report: the subclass's deviceType");
  check(o("network-device", "sw-01")?.attributes?.vendor === "unifi" && o("network-device", "sw-01")?.attributes?.stage === "operational", "report: vendor, and the stage as derived (a role: operational)");
  check(o("passive-device", "patchpanel1")?.attributes?.stage === "operational" && o("other-device", "printer")?.attributes?.faulty === false, "report: faulty reported, false when unset");
  check(o("room", "basement")?.attributes?.location !== undefined && objs.some((x) => x.class === "location" && x.name === "knudanchersvej95" && !Object.keys(x.attributes ?? {}).length), "report: a room at its location, named by name only");
  check(JSON.stringify(o("rack", "rack1")?.attributes?.room) === JSON.stringify({ ref: "room:basement" }) && o("rack", "rack1")?.attributes?.width === 19, "report: a rack in its room, its width in inches");
  const ports = objs.filter((x) => x.class === "port");
  check(ports.length > 0 && ports.every((x) => typeof (x.attributes?.asset as { ref?: string })?.ref === "string"), "report: every port part of its asset");
  check(ports.filter((x) => (x.attributes?.asset as { ref: string }).ref === "asset:patchpanel1").length === 24, "report: the patch panel's 24 ports");
  check(ports.some((x) => (x.attributes?.asset as { ref: string }).ref === "asset:sw-01" && x.name === "5"), "report: a switch's ports from the faceplate it is placed with (its model is no catalog key)");
  check(ports.find((x) => x.name === "eth0")?.attributes?.mac === "aa:bb:cc:00:11:22", "report: a port's MAC");
  const rels = report.relations ?? [];
  const placed = rels.filter((r) => r.type === "placed-in");
  check(placed.length === Object.keys(placementsOf(doc0)).length, "report: every placement as placed-in");
  const srv2 = placed.find((r) => JSON.stringify(r.from) === JSON.stringify({ ref: "asset:srv-02" }));
  check(
    JSON.stringify(srv2?.to) === JSON.stringify({ ref: "rack:rack1" }) && JSON.stringify(srv2?.attributes) === JSON.stringify({ u: 13, height: 6, width: "third", slot: 0, face: "front", faceplate: "generic/server-2u", description: "placeholder position, set by the operator" }),
    "report: a placement in a rack, its unit, height, width, slot, face and faceplate on the relation",
  );
  check(JSON.stringify(placed.find((r) => JSON.stringify(r.from) === JSON.stringify({ ref: "asset:ISP modem" }))?.to) === JSON.stringify({ ref: "room:basement" }), "report: a loose placement in its room");
  const cables = rels.filter((r) => r.type === "connects");
  check(cables.length === cablesOf(doc0).length, "report: every recorded cable as connects");
  check(
    cables.some((r) => JSON.stringify([r.from, r.to, r.attributes]) === JSON.stringify([{ ref: "port:sw-01:5" }, { ref: "port:ISP modem:LAN 1" }, { kind: "uplink", label: "ISP hand-off" }])),
    "report: a cable port to port, by the asset under its role, with kind and label",
  );
  check(allocations.length === 10 && allocations.every((a) => a.source === SOURCE && (a.relations ?? []).length === 1 && !a.objects), "report: the allocations, a report each");
  const alloc = allocations.map((a) => a.relations![0]).find((r) => JSON.stringify(r.from) === JSON.stringify({ class: "server", name: "srv-01" }));
  check(alloc?.type === "allocated-to" && JSON.stringify(alloc.to) === JSON.stringify({ class: "node", name: "tappaas1" }), "report: srv-01 allocated-to the node tappaas1, by class and name");
  check(allocations.every((a) => problems(a, new Map()).length === 0), "report: each allocation fits the metamodel on its own");
  check(o("server", "srv-01")?.attributes?.allocatedTo === undefined && o("server", "srv-01")?.attributes?.location === undefined, "report: an allocated, placed asset leaves allocatedTo and location to the relations");
}

// ── changes ───────────────────────────────────────────────────────────────
{
  const before = viewOf(doc0);
  const released = doc(releaseAsset(doc0, "srv-01"));
  const ctx = { verb: "asset release", job: "20261030101500-abc123", actor: "tappaas" };
  const rel = changeReport(before, viewOf(released), ctx);
  const r = rel.report!;
  check(r && r.kind === "change" && r.verb === "asset release" && r.job === "20261030101500-abc123" && r.actor === "tappaas" && r.source === SOURCE, "asset release: a change, with its verb, job and actor");
  const srv = (r.objects ?? []).find((o) => o.name === "srv-01");
  check(srv?.attributes?.allocatedTo === null && srv.attributes.stage === "placed", "asset release: the asset unallocated, back to placed");
  check((r.objects ?? []).every((o) => ["srv-01"].includes(o.name)) && !(r.relations ?? []).length, "asset release: nothing else touched (the placement follows the asset, not its name)");
  check(rel.allocations.length === 0, "asset release: no allocation reported");
  check(problems(r).length === 0, "asset release: the change fits the metamodel");

  const allocated = doc(allocateAsset(released, "srv-01", "tappaas1", null));
  const al = changeReport(viewOf(released), viewOf(allocated), { verb: "asset allocate", job: "j2" });
  check(al.report?.verb === "asset allocate" && (al.report.objects ?? []).find((o) => o.name === "srv-01")?.attributes?.stage === "operational", "asset allocate: the asset operational");
  check((al.report?.objects ?? []).find((o) => o.name === "srv-01")?.attributes?.allocatedTo === undefined, "asset allocate: allocatedTo left to the allocation report");
  const a = al.allocations[0];
  check(
    al.allocations.length === 1 && a.kind === "change" && a.verb === "asset allocate" && a.job === "j2" && JSON.stringify(a.relations) === JSON.stringify([{ type: "allocated-to", from: { class: "server", name: "srv-01" }, to: { class: "node", name: "tappaas1" }, attributes: {}, recorded: true }]),
    "asset allocate: the allocation apart, to the node by class and name",
  );

  // A port removed: ended, naming its asset by class and name.
  const noPort = doc(removePort(doc0, "patchpanel1", "24", catalogOf(doc0)));
  const pr = changeReport(before, viewOf(noPort), { verb: "port remove" }).report!;
  const ended = (pr.objects ?? []).find((o) => o.end);
  check(ended?.class === "port" && JSON.stringify(ended.attributes?.asset) === JSON.stringify({ class: "passive-device", name: "patchpanel1" }), "port remove: the port ended, its asset by class and name");

  // An asset removed: its ports end before it does.
  const lone = doc(removeAsset(doc0, "patchpanel1"));
  const ar = changeReport(before, viewOf(lone), { verb: "asset remove" }).report!;
  const ends = (ar.objects ?? []).filter((o) => o.end);
  check(ends.length === 25 && ends[ends.length - 1].name === "patchpanel1" && ends.slice(0, -1).every((o) => o.class === "port"), "asset remove: its 24 ports ended, then the asset");
  check(problems(ar).length === 0, "asset remove: the change fits the metamodel");

  // A faceplate is the catalog's, not the CMDB's: nothing to report.
  const fp = doc(addFaceplate(doc0, "acme/nas-4", { units: 2, ports: "4xrj45" }, catalogOf(doc0)));
  const fr = changeReport(before, viewOf(fp), { verb: "faceplate add" });
  check(fr.report === null && fr.allocations.length === 0, "faceplate add: nothing the CMDB holds changed, no report");
}

// ── export --cmdb, read back ──────────────────────────────────────────────
{
  const v = viewOf(doc0);
  const ans = cmdbAnswer(v);
  check(ans.objects.every((o) => o.class !== "location") && ans.objects.every((o) => !Object.values(o.attributes).some((x) => x && typeof x === "object" && "ref" in (x as Obj))), "export --cmdb: objects as a query answers them, relation fields as relations");
  check(ans.relations.some((r) => r.type === "at" && r.from.name === "basement" && r.to.class === "location") && ans.relations.some((r) => r.type === "part-of"), "export --cmdb: at and part-of as relations");
  const back = positionsFromCmdb(ans);
  check(JSON.stringify(back.rooms) === JSON.stringify(doc0.rooms), "read back: the rooms");
  check(JSON.stringify(back.racks?.rack1) === JSON.stringify({ units: 37, width: "19in", numbering: "bottom-up", room: "basement", description: "primary TAPPaaS rack" }), "read back: the rack");
  const pm = (d: PositionsDoc) =>
    Object.entries(placementsOf(d))
      .map(([n, m]) => `${n}@${m.rack ?? m.room}:${m.u ?? "-"}:${m.rack ? heightOf(m) : "-"}:${m.slot ?? 0}:${m.faceplate ?? "-"}`)
      .sort()
      .join(",");
  check(pm(back) === pm(doc0), "read back: the placements, keyed by role");
  const cm = (d: PositionsDoc) => cablesOf(d).map((c) => `${c.from.device}:${c.from.port}>${c.to.device}:${c.to.port}:${c.kind}:${c.label ?? ""}`).join(",");
  check(cm(back) === cm(doc0), "read back: the cables, ends under the role");
  const am = (d: PositionsDoc) =>
    Object.entries(d.assets ?? {})
      .map(([n, a]) => `${n}:${a.kind}:${a.role ?? ""}:${a.vendor ?? ""}:${a.model ?? ""}:${stageOf(d, n, a)}`)
      .sort()
      .join(",");
  check(am(back) === am(doc0), "read back: the assets, kind, role, vendor, model, stage as derived");
  // The store answers by class then name: every port before every server, and
  // "10" before "2". The read-back must not depend on either.
  const nics = { ...doc0, assets: { ...doc0.assets, "srv-02": { ...doc0.assets!["srv-02"], ports: [{ name: "eno2", kind: "rj45" as const }, { name: "eno10", kind: "rj45" as const }, { name: "eno1", kind: "rj45" as const, mac: "20:7c:14:f4:d0:8c" }] } } };
  const sorted = (a: CmdbAnswer) => ({ ...a, objects: [...a.objects].sort((x, y) => x.class.localeCompare(y.class) || x.name.localeCompare(y.name)) });
  const byClass = sorted(ans);
  const stored = positionsFromCmdb(byClass);
  const pn = (d: PositionsDoc, n: string) => (d.assets?.[n]?.ports ?? []).map((p) => p.name).join(",");
  const srv = positionsFromCmdb(sorted(cmdbAnswer(viewOf(nics)))).assets!["srv-02"];
  check(pn({ assets: { "srv-02": srv } } as PositionsDoc, "srv-02") === "eno1,eno2,eno10" && srv.ports?.[0].mac === "20:7c:14:f4:d0:8c", `read back: a server's ports, in natural order, although the answer lists ports before servers (${pn({ assets: { "srv-02": srv } } as PositionsDoc, "srv-02") || "none"})`);
  const panel = Object.keys(doc0.assets ?? {}).find((n) => (doc0.assets![n].ports?.length ?? 0) > 10);
  check(!!panel && pn(stored, panel) === pn(doc0, panel), `read back: ${panel ?? "a panel"}'s ports in natural order, not "1,10,11"`);
}

// ── disks (ADR-042): a disk CI part of the asset it is in ─────────────────
{
  const d1 = doc(addDisk(doc0, "tappaas1", "ata-Samsung_SSD_870_EVO_1TB_S6PTNX0R123456A", { serial: "S6PTNX0R123456A", model: "Samsung SSD 870 EVO 1TB", size: "1TB", kind: "ssd", bus: "sata", bay: "2" }));
  const disks = doc(addDisk(d1, "srv-01", "nvme-WD_BLACK_SN850X_2000GB_23280K800123", { serial: "23280K800123", size: "2TB", kind: "nvme" }));
  const v = viewOf(disks);
  const { report } = fullReport(v);
  const objs = report.objects ?? [];
  const dsk = objs.filter((o) => o.class === "disk");
  check(dsk.length === 2 && dsk.every((o) => JSON.stringify(o.attributes?.asset) === JSON.stringify({ ref: "asset:srv-01" })), "disks: each a disk CI part of the asset it is in (by the role's asset)");
  const i = (ref: string) => objs.findIndex((o) => o.ref === ref);
  check(i("asset:srv-01") >= 0 && i("asset:srv-01") < i("disk:srv-01:dsk-01"), "disks: reported after the asset they are in");
  const one = dsk.find((o) => o.name === "dsk-01")!;
  check(one.attributes?.serial === "S6PTNX0R123456A" && one.attributes?.bay === "2" && one.attributes?.size === 1e12 && one.attributes?.kind === "ssd" && one.attributes?.bus === "sata" && one.attributes?.stage === "placed" && one.attributes?.displayName === "ata-Samsung_SSD_870_EVO_1TB_S6PTNX0R123456A", "disks: serial, bay, size, kind, bus, stage and the by-id name shown");
  const p = problems(report);
  check(p.length === 0, `disks: the report fits the metamodel${p.length ? ` — ${p.slice(0, 5).join("; ")}` : ""}`);
  check(!(report.relations ?? []).some((r) => JSON.stringify(r.from).includes("disk:")), "disks: no placed-in — the bay is the disk's, the asset its part-of");

  // In stock: no CI.
  const stock = doc(unplaceDevice(disks, "dsk-02", false));
  check(!viewOf(stock).objects.some((o) => o.name === "dsk-02") && viewOf(stock).skipped.length === 0, "disks: one in stock has no CI, and is no omission");
  const out = changeReport(v, viewOf(stock), { verb: "unplace" }).report!;
  check((out.objects ?? []).some((o) => o.class === "disk" && o.name === "dsk-02" && o.end && JSON.stringify(o.attributes?.asset) === JSON.stringify({ class: "server", name: "srv-01" })), "unplace: the disk's CI ends, naming its asset by class and name");

  // The move: the CI in the old asset ends, one in the new begins.
  const moved = doc(placeDisk(disks, "dsk-01", "tappaas2"));
  const mv = changeReport(v, viewOf(moved), { verb: "place" }).report!;
  const mo = mv.objects ?? [];
  check(mo.some((o) => o.class === "disk" && o.name === "dsk-01" && !o.end && JSON.stringify(o.attributes?.asset) === JSON.stringify({ ref: "asset:srv-02" })) && mo.some((o) => o.class === "disk" && o.name === "dsk-01" && o.end && JSON.stringify(o.attributes?.asset) === JSON.stringify({ class: "server", name: "srv-01" })), "place --in another asset: the old CI ends, a new one part of srv-02 begins");
  check(problems(mv).length === 0, `place --in: the change fits the metamodel (${problems(mv).slice(0, 3).join("; ")})`);

  // Read back: the disks, their asset and bay.
  const back = positionsFromCmdb(cmdbAnswer(v));
  check(back.assets?.["dsk-01"]?.kind === "disk" && back.assets["dsk-01"].serial === "S6PTNX0R123456A" && back.assets["dsk-01"].disk?.size === 1e12 && back.assets["dsk-01"].disk?.kind === "ssd" && back.assets["dsk-01"].displayName === "ata-Samsung_SSD_870_EVO_1TB_S6PTNX0R123456A", "read back: a disk asset, its serial, size, kind and name");
  check(JSON.stringify(back.placements?.["dsk-01"]) === JSON.stringify({ in: "srv-01", bay: "2" }) && back.placements?.["dsk-02"]?.in === "srv-01", "read back: each disk in its asset and bay");
  check(!Object.keys(back.placements ?? {}).some((k) => k === "srv-01"), "read back: a disk's asset is named by its own name, not its role");
}

console.log(`\ncmdb: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
