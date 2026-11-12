// site-security.test.ts — the running site's CVE risk (ADR-045 D1, D3, D4):
// each scanned CVE's state, the units and where they sit, the site's scores,
// the history behind the sparkline, the lines the alert rules read, the digest
// section and the daily rescan.

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { RemoteResult } from "../../../../lib/ts/src/cluster";
import {
  CveItem, Finding, PREVIOUS_FILE, SITE_CDX_FILE, STATUS_FILE, ScanStatus, SecurityIO, TargetStatus, VexStatement, cveItems, diffScans, osOf,
  parseVex, patchVex, runRescan, sbomDir, summarize, trivySbomDoc, vexCarried, writeScan,
} from "../../src/security";
import {
  HISTORY_FILE, NO_ZONE, HistoryEntry, loadSiteSecurity, readHistory, recordHistory, renderSecurity, scoreUnits, sitePlacement, siteSecurity, sparkline, withToday,
} from "../../src/site-score";
import { cveChangesEvent, cveNewEvent, quietUnits } from "../../src/security-alerts";
import { buildDigest } from "../../src/digest";
import { ListRow } from "../../src/emit-read";
import { run } from "../../src/main";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const f = (id: string, severity: string, pkg = "brotli", installed = "1.1.0", fixed = ""): Finding =>
  ({ id, severity, pkg, installed, fixed, purl: `pkg:nix/${pkg}@${installed}` });
const st = (id: string, state: string, ref: string, extra: Partial<VexStatement> = {}): VexStatement =>
  ({ id, state, refs: [ref], source: "immich-vex.json", module: "immich", ...extra });

// ── D1: each CVE's state ──
console.log("cveItems: the four states");
{
  const vex = parseVex(JSON.stringify({ vulnerabilities: [
    { id: "CVE-D", analysis: { state: "not_affected", justification: "code_not_reachable", detail: "only the CLI uses it" }, affects: [{ ref: "pkg:nix/zlib@1.3" }] },
    { id: "CVE-R", analysis: { state: "exploitable", detail: "admin-only upload" }, affects: [{ ref: "pkg:nix/libxml2@2.13" }], ratings: [{ source: { name: "TAPPaaS" }, severity: "medium" }] },
    { id: "CVE-C", analysis: { state: "not_affected", detail: "the parser is off" }, affects: [{ ref: "pkg:nix/libtiff@4.7.1" }] },
  ] }), "immich-vex.json", "immich");
  check(vex[0].detail === "code_not_reachable: only the CLI uses it", "parseVex keeps the analysis for people to read");
  const items = cveItems([
    f("CVE-O", "Critical"), f("CVE-D", "High", "zlib", "1.3"), f("CVE-R", "Critical", "libxml2", "2.13"), f("CVE-C", "High", "libtiff", "4.7.2"),
    f("CVE-M", "Medium"), f("CVE-RL", "Low", "libxml2", "2.13"),
  ], [...vex, st("CVE-RL", "exploitable", "pkg:nix/libxml2@2.13", { risk: "low" })]);
  const by = (id: string): CveItem | undefined => items.find((i) => i.id === id);
  check(by("CVE-O")?.state === "open", "an unanalysed critical is open");
  check(by("CVE-D")?.state === "decided" && by("CVE-D")?.analysis === "code_not_reachable: only the CLI uses it", "a not-affected high is decided, with its analysis");
  check(by("CVE-R")?.state === "risk" && by("CVE-R")?.rating === "medium" && by("CVE-R")?.analysis === "admin-only upload", "an exploitable one is a risk at its TAPPaaS rating");
  check(by("CVE-C")?.state === "carried" && by("CVE-C")?.carriedFrom === "4.7.1" && by("CVE-C")?.analysis === "the parser is off", "decided for 4.7.1, found in 4.7.2: carried, the earlier analysis attached");
  check(by("CVE-M") === undefined, "an unanalysed medium is not listed (it counts nothing)");
  check(by("CVE-RL")?.state === "risk", "an analysed low is a risk, listed");
  check(items[0].state === "risk" && items[items.length - 1].state === "decided", "risk first, decided last");
  check(!items.some((i) => "fixed" in i), "whether a fix exists is not part of an item");
  const two = cveItems([f("CVE-X", "High", "a"), f("CVE-X", "High", "b", "2")], [st("CVE-X", "exploitable", "pkg:nix/b@2", { risk: "high" })]);
  check(two.length === 1 && two[0].state === "risk", "one CVE in two packages, one analysed exploitable: one item, a risk");
  const patched = patchVex({ brotli: { version: "1.1.0", patches: ["CVE-2026-1111.patch"] } });
  check(cveItems([f("CVE-2026-1111", "High")], patched)[0].state === "decided", "a nixpkgs patch decides it");
  check(vexCarried(f("CVE-2026-1111", "High", "brotli", "1.2.0"), patched) === null, "…and is never carried to another version");
  check(vexCarried(f("CVE-U", "High"), [st("CVE-U", "not_affected", "pkg:nix/brotli")]) === null, "an unversioned statement matches every version: never carried");

  const base = { id: "immich", name: "immich", layer: "nix" as const, host: "immich" };
  const t = summarize(base, 400, "", [f("CVE-O", "Critical"), f("CVE-C", "High", "libtiff", "4.7.2")], vex, false);
  check(t.items?.length === 2, "summarize lists the items on the target");
  check(summarize(base, 3, "only 3 package(s) inventoried", [], vex, false).items?.length === 0, "…none for a failed scan");
  const prev = { targets: [{ ...t, critHighKeys: ["CVE-C libtiff"] }] } as unknown as ScanStatus;
  const cur = { targets: [t] } as unknown as ScanStatus;
  diffScans(cur, prev);
  check(t.new.join() === "CVE-O brotli" && t.newOpen?.join() === "CVE-O", "newOpen: the new critical/high ids nobody analysed");
  const t2 = summarize(base, 400, "", [f("CVE-C", "High", "libtiff", "4.7.2")], vex, false);
  diffScans({ targets: [t2] } as unknown as ScanStatus, null);
  check(t2.new.length === 1 && t2.newOpen?.length === 0, "…a new carried item is not open");
}

// ── units, placement and the site's scores ──
const item = (id: string, state: CveItem["state"], severity: string, rating?: string): CveItem => ({ id, state, severity, pkg: "p", version: "1", ...(rating ? { rating } : {}) });
const target = (id: string, items: CveItem[], extra: Partial<TargetStatus> = {}): TargetStatus => ({
  id, name: id, layer: "nix", host: id, coverage: "ok", note: "", seen: 1, findings: 0, critical: 0, high: 0, fixable: null, critHighFixable: null,
  suppressed: 0, verdict: "triage", act: [], critHighKeys: [], new: [], items, ...extra,
});
const scan = (targets: TargetStatus[], generated = "2026-11-08T03:00:00.000Z"): ScanStatus => ({ schema: 1, generated, sweep: null, scanners: {}, notes: [], targets });

function site(): string {
  const dir = mkdtempSync(join(tmpdir(), "hm-sitesec-"));
  writeFileSync(join(dir, "zones.json"), JSON.stringify({
    _comment: "x",
    mgmt: { state: "mandatory", tier: 0, environment: "mgmt", vlantag: 0 },
    rossen: { state: "active", tier: 1, environment: "rossen", vlantag: 210 },
    dmz: { state: "active", tier: 4, vlantag: 600 },
    iotCams: { state: "active", tier: 6, vlantag: 700 },
  }));
  writeFileSync(join(dir, "immich.json"), JSON.stringify({ zone0: "rossen" }));
  writeFileSync(join(dir, "proxy.json"), JSON.stringify({ zone0: "dmz" }));
  writeFileSync(join(dir, "cams.json"), JSON.stringify({ zone0: "iotCams" }));
  writeFileSync(join(dir, "loose.json"), JSON.stringify({}));
  return dir;
}

console.log("site scores");
{
  const dir = site();
  const s = scan([
    target("immich", [item("CVE-1", "open", "Critical")]),
    target("image:immich/immich-server", [item("CVE-1", "open", "Critical"), item("CVE-2", "risk", "High", "high")], { layer: "image" }),
    target("node:tappaas1", [item("CVE-3", "open", "High")], { layer: "debian" }),
    target("firewall", [item("CVE-4", "open", "Critical")], { layer: "opnsense" }),
    target("proxy", [item("CVE-5", "risk", "Critical", "critical"), item("CVE-6", "risk", "Critical", "critical")]),
    target("cams", [item("CVE-7", "open", "Critical")]),
    target("loose", [item("CVE-8", "open", "High")]),
    target("broken", [], { coverage: "fail", verdict: "failed", note: "unreachable" }),
  ]);
  const units = scoreUnits(s);
  check(units.immich.targets.length === 2 && units.immich.kind === "module", "a module's VM and its images are one unit");
  check(units["node:tappaas1"].kind === "node" && units.firewall.kind === "firewall", "a node and the firewall are units of their own");
  check(units.broken.failed.join() === "broken", "a failed target is said, not counted");
  const place = sitePlacement(dir, units);
  check(place.placement.immich.join() === "rossen" && place.placement["node:tappaas1"].join() === "mgmt" && place.placement.firewall.join() === "mgmt",
    "a module sits in its zone0; a node and the firewall in the management zone");
  check(place.placement.loose.join() === NO_ZONE, "a module with no zone sits in 'no zone'");
  const sec = siteSecurity(s, place);
  check(sec.units.immich.score === 20 && sec.units.immich.level === "high", "immich: one open critical, the same CVE in its image counted once: 20, high");
  check(sec.zones.rossen.score === 20 && sec.zones.rossen.multiplier === 1, "rossen ×1: 20");
  check(sec.zones.mgmt.score === 40 && sec.zones.mgmt.level === "critical" && sec.zones.mgmt.setBy.module === "firewall", "mgmt ×2: the firewall's open critical is 40, critical");
  check(sec.zones.dmz.score === 8 && sec.zones.dmz.level === "medium", "dmz ×0.25: two rated criticals (30) are 7.5, shown 8, medium");
  check(sec.zones.iotCams.score === 2 && sec.zones.iotCams.level === "low", "iotCams ×0.1: an open critical is 2, low");
  check(sec.environments.rossen.score === 20 && sec.environments.mgmt.score === 40, "an environment is the highest of its zones");
  check(sec.outside.includes("dmz") && sec.outside.includes(NO_ZONE), "zones in no environment roll up to the site directly");
  check(sec.site.score === 40 && sec.site.level === "critical" && sec.site.setBy.module === "firewall" && sec.site.setBy.zone === "mgmt", "the site: 40, set by the firewall in mgmt");
  check(sec.units.broken.score === 0 && sec.units.broken.failed.length === 1, "a failed unit scores 0 and carries its failure");

  // history and the sparkline
  const h1 = withToday([], sec, "2026-11-07T03:00:00.000Z");
  const h2 = withToday(h1, sec, "2026-11-08T03:00:00.000Z");
  const h3 = withToday(h2, { ...sec, site: { ...sec.site, score: 20 } }, "2026-11-08T09:00:00.000Z");
  check(h3.length === 2 && h3[1].site === 20, "one entry a day: a later scan replaces the day's");
  const old: HistoryEntry[] = Array.from({ length: 40 }, (_, i) => ({ date: new Date(Date.UTC(2026, 8, 1 + i)).toISOString().slice(0, 10), at: "", site: i, environments: {}, zones: {}, units: {} }));
  check(withToday(old, sec, "2026-11-08T03:00:00.000Z").length === 30, "thirty days are kept");
  const sp = sparkline(h3, (h) => h.units.immich, "2026-11-08");
  check(sp.length === 7 && sp[6] === 20 && sp[5] === 20 && sp[0] === null, "the sparkline: seven days, oldest first, a gap where no scan wrote");

  writeFileSync(join(dir, "x"), "");
  mkdirSync(sbomDir(dir), { recursive: true });
  const rec = recordHistory(dir, s);
  check(readHistory(dir).length === 1 && rec.history.length === 1, `recordHistory writes ${HISTORY_FILE}`);
  writeFileSync(join(sbomDir(dir), STATUS_FILE), JSON.stringify(s));
  check(loadSiteSecurity(dir, s).history.length === 1, "loadSiteSecurity reads the history back");

  const lines = renderSecurity(rec, Date.parse("2026-11-08T05:00:00Z"));
  const at = (re: RegExp): string => lines.find((l) => re.test(l)) ?? "";
  check(/critical\s+40\s+firewall in mgmt/.test(at(/^site/)), "report: the site's level, score and what sets it");
  check(at(/environment rossen/) !== "" && lines.findIndex((l) => /environment rossen/.test(l)) < lines.findIndex((l) => /zone rossen/.test(l)), "…environments, then their zones");
  check(/zone mgmt ×2/.test(at(/zone mgmt/)), "…a zone with its multiplier");
  check(/^  zone dmz ×0.25/.test(at(/zone dmz/)), "…a zone in no environment directly under the site");
  check(/immich\s+high\s+20\s+1 critical\s+1\/0\/1\/0\/0/.test(at(/^\s+immich/)), "…a module: level, score, what counts, unread/rule/confirmed/review/accepted");
  check(/firewall firewall/.test(at(/firewall firewall/)) && /node tappaas1/.test(at(/node tappaas1/)), "…platform targets named as such");
  check(lines.some((l) => /scan failed: broken/.test(l)), "…and what was not counted");
  const withCves = renderSecurity(rec, Date.parse("2026-11-08T05:00:00Z"), { items: true });
  check(withCves.some((l) => /confirmed\s+high\s+CVE-2/.test(l)), "--cves: each counted CVE with its mark, upstream and effective level");
  check(!lines.join("\n").match(/fix/i), "the report never says whether a fix exists");

  check(run(["report", "security", "--config-dir", dir], new FakeClusterClient()) === 0, "report security prints the table");
  check(run(["report", "security", "--scan", "--config-dir", dir], new FakeClusterClient()) === 0, "report security --scan prints the scan");
}

// ── what the scan tells the alert rules ──
console.log("security alerts");
{
  const dir = site();
  const prevScan = scan([target("immich", [item("CVE-1", "open", "High")]), target("proxy", [])]);
  const t = target("immich", [item("CVE-1", "open", "High"), item("CVE-9", "open", "Critical"), item("CVE-10", "carried", "High")], { newOpen: ["CVE-9"] });
  const cur = scan([t, target("proxy", [item("CVE-11", "risk", "Medium", "medium")], { newOpen: [] })]);
  const sec = siteSecurity(cur, sitePlacement(dir, scoreUnits(cur)));
  const prev = siteSecurity(prevScan, sitePlacement(dir, scoreUnits(prevScan)));
  const e = cveNewEvent(cur, sec, new Set());
  check(e?.count === 1 && e.items === "CVE-9 critical p 1 (immich)" && e.modules === "immich", "cve-new: the new open items, one line per scan");
  check(cveNewEvent(cur, sec, new Set(["immich"])) === null, "…a quiet module tells nothing");
  const kevItem = { ...item("CVE-10", "carried", "High"), mark: "review" as const, level: "high" as const, kev: "2026-11-11", flags: ["kev"] };
  const prevK = scan([target("immich", [item("CVE-10", "risk", "High", "low")])]);
  const curK = scan([target("immich", [kevItem])]);
  diffScans(curK, prevK);
  check(curK.targets[0].newKev?.join() === "CVE-10", "a CVE that joined the known-exploited list since the last scan is noted");
  const ek = cveNewEvent(curK, siteSecurity(curK, sitePlacement(dir, scoreUnits(curK))), new Set());
  check(ek?.items === "CVE-10 high p 1 (immich, known exploited)", "…and mailed at once, though it was decided before");
  diffScans(curK, curK);
  check(curK.targets[0].newKev?.length === 0, "…once");
  check(/"event":"cve-new".*"silenced":false/.test(JSON.stringify(e)), "…the line the rule matches");
  const c = cveChangesEvent(prev, sec, new Set());
  check(c !== null && /immich: 1 new carried/.test(c.what) && /proxy: 1 new risk/.test(c.what), "cve-changes: new carried and risk items for the digest");
  const down = cveChangesEvent(sec, prev, new Set());
  check(down !== null && /level high → medium/.test(down.what), "…and a level going down");
  check(cveChangesEvent(null, sec, new Set()) === null, "…nothing on the first scan");
  const objs = [{ class: "vm", name: "immich", attributes: { conditions: [{ type: "vulnerability", acknowledged: { until: null } }] } }];
  check(quietUnits(sec, objs, new Date()).has("immich"), "an acknowledged vulnerability condition makes a module quiet");
  const later = [{ class: "vm", name: "immich", attributes: { conditions: [{ type: "vulnerability", acknowledged: { until: "2020-01-01T00:00:00Z" } }] } }];
  check(!quietUnits(sec, later, new Date()).has("immich"), "…an expired one does not");

  // the digest's security section
  const rows = [{ id: "immich", class: "vm", name: "immich", type: "vulnerability", status: "warning", reason: "cve-high", message: "score 20, high: 1 critical", since: "x", derived: false, rootCause: null, acknowledged: null, maintenance: null }] as unknown as ListRow[];
  const d = buildDigest(rows, null, null, sec);
  check(d.body.includes("Vulnerability: the site's CVE risk is"), "the digest says the site's level");
  check(d.body.includes("carried from another version: CVE-10") || d.body.includes("carried from"), "…lists carried items");
  check(d.body.includes("medium risk: CVE-11"), "…and analysed risk items");
  check(!d.body.includes("CVE-9"), "…not the open one (mailed at once)");
  const again = buildDigest(rows, null, { at: "2026-11-08T00:00:00Z", keys: d.keys }, sec);
  check(again.word === "STATUS", "told once: the next digest repeats them as still open");
  const ackd = buildDigest(rows.map((r) => ({ ...r, acknowledged: { by: "x" } }) as unknown as ListRow), null, null, sec);
  check(!ackd.body.includes("CVE-10"), "an acknowledged module's items are left out");
}

// ── the daily rescan ──
console.log("rescan");
{
  const ok = (stdout: string): RemoteResult => ({ rc: 0, stdout, stderr: "", ran: true });
  const dir = site();
  const sb = sbomDir(dir);
  mkdirSync(sb, { recursive: true });
  const comps = (n: number): unknown[] => Array.from({ length: n }, (_, i) => ({ type: "library", name: `lib${i}`, version: "1.0", purl: `pkg:nix/lib${i}@1.0`, cpe: `cpe:2.3:a:lib${i}:lib${i}:1.0:*:*:*:*:*:*:*` }));
  const deb = [{ type: "library", name: "libc6", version: "2.41-12", purl: "pkg:deb/debian/libc6@2.41-12?arch=amd64&distro=debian-13.7",
    properties: [{ name: "aquasecurity:trivy:SrcName", value: "glibc" }, { name: "aquasecurity:trivy:SrcVersion", value: "2.41" }, { name: "aquasecurity:trivy:SrcRelease", value: "12" }] },
    { type: "library", name: "requests", version: "2.0", purl: "pkg:pypi/requests@2.0" },
    { type: "library", name: "ffmpeg (in av)", version: "7.1", purl: "pkg:generic/ffmpeg@7.1", cpe: "cpe:2.3:a:ffmpeg:ffmpeg:7.1:*:*:*:*:*:*:*", properties: [{ name: "tappaas:bundled-in", value: "av" }] }];
  const prev = scan([
    target("immich", [], { layer: "nix" }),
    target("node:tappaas1", [], { layer: "debian", note: "debian 13.7; Proxmox packages not matched" }),
    target("firewall", [item("CVE-F", "open", "High")], { layer: "opnsense" }),
    target("old-lxc", [item("CVE-OLD", "open", "High")], { layer: "debian", note: "debian 13.7" }),
    target("broken", [], { coverage: "fail", verdict: "failed", note: "unreachable", layer: "unknown" }),
  ], "2026-11-07T03:00:00.000Z");
  writeFileSync(join(sb, STATUS_FILE), JSON.stringify(prev));
  writeFileSync(join(sb, SITE_CDX_FILE), JSON.stringify({ bomFormat: "CycloneDX", components: [
    { "bom-ref": "immich", components: comps(60) }, { "bom-ref": "node:tappaas1", components: deb },
    { "bom-ref": "old-lxc", components: [{ type: "library", name: "libtiff6", version: "4.7.0-3", purl: "pkg:deb/debian/libtiff6@4.7.0-3?arch=amd64" }] }, { "bom-ref": "firewall", components: [{ name: "unbound", version: "1", purl: "pkg:generic/opnsense/unbound@1" }] },
  ] }));
  const calls: string[] = [];
  const sbomDocs: Record<string, unknown>[] = [];
  const io = {
    now: () => Date.parse("2026-11-08T03:00:00Z"),
    dbUpdate: () => { calls.push("db"); return []; },
    nixPatches: () => ({}),
    grype: (file: string) => {
      const doc = JSON.parse(readFileSync(file, "utf8")) as { components: { name: string }[] };
      calls.push(`grype:${doc.components.length}`);
      return doc.components[0].name.startsWith("ffmpeg")
        ? ok(JSON.stringify({ matches: [{ vulnerability: { id: "CVE-B", severity: "High" }, artifact: { name: "ffmpeg (in av)", version: "7.1", purl: "pkg:generic/ffmpeg@7.1" } }] }))
        : ok(JSON.stringify({ matches: [{ vulnerability: { id: "CVE-N", severity: "Critical" }, artifact: { name: "lib1", version: "1.0", purl: "pkg:nix/lib1@1.0" } }] }));
    },
    trivySbom: (file: string) => {
      sbomDocs.push(JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>);
      calls.push("trivy-sbom");
      return ok(JSON.stringify({ Metadata: { OS: { Family: "debian", Name: "13.7" } }, Results: [{ Vulnerabilities: [{ VulnerabilityID: "CVE-T", Severity: "HIGH", PkgName: "libc6", InstalledVersion: "2.41-12", FixedVersion: "", PkgIdentifier: { PURL: "pkg:deb/debian/libc6@2.41-12" } }] }] }));
    },
    versions: () => ({ grype: "1", trivy: "1" }),
    probeLocal: () => { throw new Error("no probe"); }, probeGuest: () => { throw new Error("no probe"); }, probeLxc: () => { throw new Error("no probe"); },
    probeNode: () => { throw new Error("no probe"); }, probeFirewall: () => { throw new Error("no probe"); }, trivyImage: () => { throw new Error("no registry"); },
    trivyRootfs: () => { throw new Error("no rootfs"); },
  } as unknown as SecurityIO;
  const r = runRescan({ configDir: dir, repoDir: dir }, io);
  if ("error" in r) throw new Error(r.error);
  const by = (id: string): TargetStatus => r.status.targets.find((t) => t.id === id)!;
  check(calls[0] === "db", "the databases are refreshed first");
  check(by("immich").items?.some((i) => i.id === "CVE-N" && i.state === "open") === true, "a Nix target is matched again by grype from its stored inventory");
  check(by("node:tappaas1").items?.map((i) => i.id).sort().join() === "CVE-B,CVE-T", "an OS target by trivy offline, its bundled libraries by grype");
  check(by("firewall").items?.[0].id === "CVE-F", "the firewall stays as its last audit found it");
  check(by("old-lxc").items?.[0].id === "CVE-OLD" && calls.filter((c) => c === "trivy-sbom").length === 1 && r.status.notes.some((n) => n.includes("no source packages")),
    "an OS inventory without source packages is not matched thinner: the last scan stands, and the notes say so");
  const libc = (sbomDocs[0] as { components: { name: string; properties?: { name: string; value: string }[] }[] }).components.find((c) => c.name === "libc6");
  check(libc?.properties?.some((x) => x.name === "aquasecurity:trivy:SrcName" && x.value === "glibc") === true, "trivy is handed each package's source package, as it found it");
  check(by("broken").verdict === "failed", "a failed inventory stays failed");
  check(r.status.inventory === prev.generated && r.status.generated === "2026-11-08T03:00:00.000Z", "the status says when the inventory was taken and when it was matched");
  const doc = sbomDocs[0] as { components: { type: string; "bom-ref": string; purl?: string }[]; dependencies: { ref: string; dependsOn: string[] }[] };
  check(doc.components[0].type === "operating-system" && doc.dependencies[0].dependsOn.length === 1, "trivy is told the OS, with its OS packages under it");
  check(!doc.components.some((c) => c.purl === "pkg:generic/ffmpeg@7.1"), "…the bundled library goes to grype, not trivy");
  check(osOf(target("x", [], { note: "debian 13.7; more" }))?.name === "13.7", "the OS of a scan made before it was recorded: from the note");
  check((trivySbomDoc([], null).components as unknown[]).length === 0, "no OS known: packages only");
  writeScan(dir, r.status, r.cdx);
  check(JSON.parse(readFileSync(join(sb, PREVIOUS_FILE), "utf8")).generated === prev.generated, "written like a scan: the last one becomes the previous");
  check((JSON.parse(readFileSync(join(sb, SITE_CDX_FILE), "utf8")) as { components: unknown[] }).components.length === 4, "…the inventory itself unchanged");
  const none = runRescan({ configDir: mkdtempSync(join(tmpdir(), "hm-none-")), repoDir: dir }, io);
  check("error" in none, "no scan yet: the rescan says so");
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
