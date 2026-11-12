// security-queues.test.ts — the site's CVEs as things to do (security-queues.ts).

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { CveItem, ScanStatus, TargetStatus } from "../../src/security";
import { buildQueues, renderQueues } from "../../src/security-queues";
import { siteSecurity, sitePlacement, scoreUnits, renderSecurity } from "../../src/site-score";
import { CmdbItem, SiteIndex } from "../../src/assess-model";
import { fromCve } from "../../src/assess-sources";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const NOW = Date.parse("2026-11-12T12:00:00Z");
const it = (id: string, over: Partial<CveItem>): CveItem => ({ id, state: "open", severity: "High", pkg: "p", version: "1", level: "high", mark: "unread", counted: true, ...over });
const tg = (id: string, layer: TargetStatus["layer"], items: CveItem[]): TargetStatus => ({
  id, name: id, layer, host: id, coverage: "ok", note: "", seen: 1, findings: items.length, critical: 0, high: 0, fixable: 0, critHighFixable: 0,
  suppressed: 0, verdict: "watch", act: [], critHighKeys: [], new: [], items,
});
const CURL = "network/opnsense:curl";
const SQL = "templates/nix:sqlite";
const s: ScanStatus = { schema: 1, generated: "2026-11-12T03:00:00Z", sweep: null, scanners: {}, notes: [], targets: [
  tg("network", "opnsense", [
    it("CVE-C1", { severity: "Critical", level: "critical", component: CURL, vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:H" }),
    it("CVE-C2", { component: CURL, vector: "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:N" }),
    it("CVE-U1", { component: "network/opnsense:unbound", fixed: "channel update" }),
  ]),
  tg("immich", "nix", [it("CVE-S1", { component: SQL }), it("CVE-IM", { component: "immich/nix:imagemagick", mark: "rule", level: "medium", state: "risk" })]),
  tg("coturn", "nix", [it("CVE-S1", { component: SQL })]),
  tg("nextcloud", "nix", [it("CVE-NC", { component: "nextcloud/nix:imagemagick", mark: "review", flags: ["assumption"], analysis: "assumes internal only; nextcloud is reachable from the internet here" })]),
  tg("karakeep", "nix", [it("CVE-D", { component: "karakeep/deb:tiff", mark: "deferred", note: "fix in 2.5", flags: ["deferred-until:2026-11-23"] }),
    it("CVE-K", { component: "karakeep/deb:tiff", mark: "confirmed", state: "risk", level: "medium" })]),
] };
const cfg = mkdtempSync(join(tmpdir(), "queues-"));
mkdirSync(join(cfg, "sbom"), { recursive: true });
writeFileSync(join(cfg, "train-preview-details.json"), JSON.stringify({ modules: { immich: { cves: { fixed: [{ id: "CVE-S1" }] } } } }));
writeFileSync(join(cfg, "pin-candidates.json"), JSON.stringify({ proposals: [{ kind: "move", module: "karakeep", from: "0.31.2", to: "0.31.4", clears: ["CVE-K"], adds: [], patchLevel: true }] }));

const q = buildQueues(s, { configDir: cfg, now: NOW, maintainer: true });
const titles = (n: string, m = q.operator): string[] => (m[n] ?? []).map((c) => c.title);
console.log("for the site's operator");
check(q.operator.update.length === 1 && q.operator.update[0].title === "network: firewall packages" && q.operator.update[0].cves.join() === "CVE-U1", "update: what the channel already offers, per unit");
check(q.operator.coming[0]?.cves.join() === "CVE-S1" && q.operator.coming[0].units.join() === "coturn,immich", "coming: what the next release clears, across units");
check(q.operator.decision.length === 1 && q.operator.decision[0].text.includes("reachable from the internet"), "your decision: an assumption that fails here, saying why");
check(titles("tappaas")[0] === "curl on network" && q.operator.tappaas[0].worst === "critical" && q.operator.tappaas[0].cves.length === 2, "with TAPPaaS: one card per component, worst first");
const base = q.operator.tappaas.find((c) => c.component === SQL)!;
check(base.baseline === true && base.units.join() === "coturn,immich" && base.cves.length === 1 && base.text.includes("in 2 unit(s)"), "the baseline is one card, naming how many units have it");
check(titles("upstream").includes("tiff on karakeep") && titles("upstream").includes("imagemagick on immich"), "with upstream: decided components still counted");
console.log("for the maintainers");
check(q.maintainer!.move[0].title === "karakeep 0.31.2 → 0.31.4" && q.maintainer!.move[0].action === "tappaas-train.sh candidates apply karakeep", "move a pin: from the daily candidates");
const dc = q.maintainer!.decide.find((c) => c.component === CURL)!;
check(dc.text.startsWith("2 unread (1 critical, 1 high), all AV:N/PR:N/UI:R") && dc.action?.startsWith("cve-triage.sh component network curl --eco opnsense") === true,
  "decide: a component's unread CVEs, what their vectors share, and the command");
check(q.maintainer!.decide.find((c) => c.component === SQL)?.action?.includes("component baseline sqlite") === true, "…the baseline's is decided as baseline");
check(q.maintainer!.review.some((c) => c.component === "immich/nix:imagemagick" && c.text.includes("by rule, unread")), "review: a rule's result nobody read");
check(q.maintainer!.deferred[0]?.text === "1 CVE(s) until 2026-11-23: fix in 2.5", "deferred: until when, and why");
check(buildQueues(s, { configDir: cfg, now: NOW, maintainer: false }).maintainer === undefined, "a site without the train sees no maintainers' queues");
const text = renderQueues(q).join("\n");
check(/FOR YOU[\s\S]*Update[\s\S]*WAITING[\s\S]*With TAPPaaS[\s\S]*FOR THE MAINTAINERS[\s\S]*Decide/.test(text), "the text: for you, waiting, for the maintainers");
const quiet = buildQueues({ ...s, targets: [tg("immich", "nix", [])] }, { configDir: mkdtempSync(join(tmpdir(), "q2-")), now: NOW, maintainer: false });
check(renderQueues(quiet).filter((l) => l.includes("nothing")).length === 5, "a quiet site says nothing is waiting, queue by queue");

console.log("the baseline in the table");
const sec = siteSecurity(s, sitePlacement(cfg, scoreUnits(s)));
check(sec.units.coturn.baselineOnly === true && !sec.units.network.baselineOnly, "a unit set only by the baseline is marked");
check(renderSecurity(sec, NOW).some((l) => /coturn.*1 high, baseline/.test(l)), "…and the table says so");

console.log("health: the baseline is one root");
const o = (cls: string, name: string): CmdbItem => ({ id: `${cls}-${name}`, class: cls, name, attributes: {} });
const idx = new SiteIndex([o("site", "home"), o("vm", "coturn"), o("vm", "immich"), o("device", "network")], []);
const fs = fromCve(s, sec, NOW, idx);
const coturn = fs.find((x) => x.object === "vm-coturn" && x.reason.startsWith("cve-"))!;
check(coturn.labels?.setBy === "baseline" && coturn.message.includes("from the NixOS baseline"), "a unit set only by the baseline carries the label a classify record matches");
check(fs.filter((x) => x.labels?.setBy === "baseline").length === 2 && !fs.some((x) => x.message.includes("critical") && x.labels), "…only those: the firewall, set by curl, does not");
const root = fs.find((x) => x.object === "site-home" && x.reason === "cve-baseline");
check(root !== undefined && root.status === "warning" && root.message.includes("the NixOS baseline") && root.message.includes("in 2 unit(s)"), "the site gets the baseline's own finding: the root");

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
