// site-decisions.test.ts — a site's assumptions and acceptances on top of the
// central CVE decisions (site-decisions.ts), and the accept verb.

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { ComponentRecord } from "../../../../lib/ts/src/cve-decisions";
import { cmdAccept, cmdUnaccept } from "../../src/cve-verb";
import { Finding, ScanStatus, TargetDecisions, summarize, withDecisions } from "../../src/security";
import { acceptancesFor, exposureOf, failedAssumptions, readAcceptances, settleAcceptances, siteDecisions, unitName } from "../../src/site-decisions";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const NOW = Date.parse("2026-11-12T12:00:00Z");
const V = "CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H";
const cfg = mkdtempSync(join(tmpdir(), "site-dec-"));
mkdirSync(join(cfg, "sbom"), { recursive: true });
writeFileSync(join(cfg, "zones.json"), JSON.stringify({ mgmt: { tier: 0, environment: "mgmt" }, rossen: { tier: 1, environment: "rossen" }, dmz: { tier: 4 } }));
writeFileSync(join(cfg, "nextcloud.json"), JSON.stringify({ zone0: "rossen", config: { "network:proxy": { proxyAllowedZones: ["internet"] }, "identity:identity": { identity: {} } } }));
writeFileSync(join(cfg, "immich.json"), JSON.stringify({ zone0: "rossen", config: { "network:proxy": { proxyAllowedZones: ["home"] } } }));
writeFileSync(join(cfg, "lazysite.json"), JSON.stringify({ zone0: "dmz", config: { "network:proxy": { proxyAllowedZones: ["home"] }, mail: { enabled: true } } }));

console.log("exposure and assumptions");
const tiers = { mgmt: 0, rossen: 1, dmz: 4 };
const nc = exposureOf(cfg, "nextcloud", tiers);
const im = exposureOf(cfg, "immich", tiers);
const lz = exposureOf(cfg, "lazysite", tiers);
check(nc.public && nc.sso && nc.tier === 1, "a proxy route open to the internet is public; identity is SSO");
check(!im.public && im.tier === 1, "a route for the home zone only is internal");
check(lz.public && lz.tier === 4, "a DMZ zone counts as public");
check(!exposureOf(cfg, "node:tappaas1", tiers).public, "a node is internal, in the management zone");
check(failedAssumptions({ maxExposure: "internal" }, "immich", im).length === 0, "internal holds for immich");
check(failedAssumptions({ maxExposure: "internal" }, "nextcloud", nc)[0]?.text.includes("reachable from the internet") === true, "…and fails for public nextcloud, saying why");
check(failedAssumptions({ maxExposure: "authenticated" }, "nextcloud", nc).length === 0, "authenticated holds for a public module behind identity");
check(failedAssumptions({ zoneTier: "<=1" }, "lazysite", lz)[0]?.text.includes("tier 4") === true, "a zone tier assumption names the tier it found");
check(failedAssumptions({ serviceOff: "mail" }, "lazysite", lz).length === 1 && failedAssumptions({ serviceOff: "mail" }, "immich", im).length === 0, "serviceOff: configured fails, absent holds");
check(failedAssumptions({ nonsense: "x" }, "immich", im).length === 1, "an assumption the site cannot check fails");

console.log("in the scan");
const rec: ComponentRecord = {
  use: "Thumbnails are made from uploads by signed-in family members; only the image coders the worker passes reach ImageMagick.",
  reason: "internal-only", assumes: { maxExposure: "internal" }, versions: "7.*",
  rules: [{ id: "r1", match: { AV: ["N"] }, modified: { MAV: "A", CR: "L", IR: "L" }, why: "only from the home network" }],
  cves: {}, author: "lars", decided: "2026-11-10", reviewBy: "2027-11-10",
};
const records = { "immich/nix:imagemagick": rec, "nextcloud/nix:imagemagick": { ...rec } };
const site = siteDecisions(cfg);
const dec = (module: string): TargetDecisions => ({
  module, unit: module, records, baseline: new Set(), now: NOW, facts: (ids) => Object.fromEntries(ids.map((i) => [i, { vector: V }])),
  firstSeen: () => "2026-11-11T00:00:00Z", guardSince: () => undefined, site: (c, r, id) => site(module, c, r, id),
});
const f = (id: string): Finding => ({ id, severity: "Critical", pkg: "imagemagick", installed: "7.1.2-31", fixed: "", purl: "pkg:nix/imagemagick@7.1.2-31" });
const imT = summarize({ id: "immich", name: "immich", layer: "nix", host: "immich" }, 300, "", [f("CVE-1"), f("CVE-2")], withDecisions([], dec("immich")), false);
const ncT = summarize({ id: "nextcloud", name: "nextcloud", layer: "nix", host: "nextcloud" }, 300, "", [f("CVE-1")], withDecisions([], dec("nextcloud")), false);
check(imT.items![0].mark === "rule" && imT.items![0].level === "high", "immich, internal as assumed: the rule lowers the critical");
check(ncT.items![0].mark === "review" && ncT.items![0].level === "critical" && ncT.items![0].analysis?.includes("reachable from the internet") === true,
  "nextcloud, public: the same record does not apply, and says why");

console.log("acceptances");
const status: ScanStatus = { schema: 1, generated: new Date(NOW).toISOString(), sweep: null, scanners: {}, notes: [], targets: [imT, ncT] };
writeFileSync(join(cfg, "sbom", "cve-status.json"), JSON.stringify(status));
check(unitName("image:immich/immich-server") === "immich" && unitName("node:tappaas1") === "node:tappaas1", "units: an image counts in its module, a node by name");
let r = acceptancesFor({ unit: "nextcloud", cves: ["CVE-1"], note: "two users", until: "2027-05-01", by: "lars" }, status, NOW);
check(r.problems.length === 0 && r.add[0].component === "nextcloud/nix:imagemagick" && r.add[0].severity === "Critical", "an acceptance takes its component and upstream level from the scan");
check(acceptancesFor({ unit: "nextcloud", cves: ["CVE-1"], note: "", until: "2027-05-01", by: "x" }, status, NOW).problems.some((p) => p.includes("note")), "…needs a note");
check(acceptancesFor({ unit: "nextcloud", cves: ["CVE-1"], note: "x", until: "2028-05-01", by: "x" }, status, NOW).problems.some((p) => p.includes("a year")), "…at most a year");
check(acceptancesFor({ unit: "nextcloud", cves: ["CVE-9"], note: "x", until: "2027-05-01", by: "x" }, status, NOW).problems.some((p) => p.includes("not among")), "…of a CVE the scan shows");
const lines: string[] = [];
check(cmdAccept(["nextcloud", "CVE-1", "--note", "two users", "--until", "2027-05-01"], cfg, (l) => lines.push(l), NOW, "lars") === 0, "accept writes it");
check(readAcceptances(cfg).acceptances.length === 1, "…into config/security-acceptances.json");
const site2 = siteDecisions(cfg);
const ncT2 = summarize({ id: "nextcloud", name: "nextcloud", layer: "nix", host: "nextcloud" }, 300, "", [f("CVE-1")],
  withDecisions([], { ...dec("nextcloud"), site: (c, rr, id) => site2("nextcloud", c, rr, id) }), false);
check(ncT2.items![0].mark === "accepted" && ncT2.items![0].counted === false, "the next scan: accepted, out of the score");
check(settleAcceptances(cfg, { ...status, targets: [imT, ncT2] }, NOW).length === 0, "an acceptance still in force stays");
check(settleAcceptances(cfg, { ...status, targets: [imT, ncT] }, NOW).length === 0, "one accepted while the scan ran is not applied yet, and stays");
const risen = { ...ncT, items: ncT.items!.map((i) => ({ ...i, severity: "Critical" })) };
writeFileSync(join(cfg, "security-acceptances.json"), JSON.stringify({ schema: 1, acceptances: readAcceptances(cfg).acceptances.map((a) => ({ ...a, severity: "High" })), ended: [] }));
const ended = settleAcceptances(cfg, { ...status, targets: [imT, risen] }, NOW);
check(ended.length === 1 && ended[0].why === "severity-rose" && readAcceptances(cfg).ended.length === 1 && readAcceptances(cfg).acceptances.length === 0,
  "upstream rated it higher since: it ends, kept under ended with why");
cmdAccept(["nextcloud", "CVE-1", "--note", "two users", "--until", "2027-05-01"], cfg, () => undefined, NOW, "lars");
check(cmdUnaccept(["nextcloud", "CVE-1"], cfg, () => undefined, NOW) === 0 && readAcceptances(cfg).ended.some((e) => e.why === "withdrawn"), "unaccept withdraws it");
cmdAccept(["nextcloud", "CVE-1", "--note", "x", "--until", "2026-11-20"], cfg, () => undefined, NOW, "lars");
check(settleAcceptances(cfg, status, Date.parse("2026-11-21T00:00:00Z"))[0]?.why === "expired", "an acceptance ends at its date");
console.log("an accepted row hidden by a heavier row of the same CVE");
cmdAccept(["nextcloud", "CVE-1", "--note", "two users", "--until", "2027-05-01"], cfg, () => undefined, NOW, "lars");
const site3 = siteDecisions(cfg);
const ncT3 = summarize({ id: "nextcloud", name: "nextcloud", layer: "nix", host: "nextcloud" }, 300, "", [f("CVE-1")],
  withDecisions([], { ...dec("nextcloud"), site: (c, rr, id) => site3("nextcloud", c, rr, id) }), false);
check(ncT3.acceptances?.length === 1 && ncT3.acceptances[0].accepted && ncT3.acceptances[0].component === "nextcloud/nix:imagemagick", "the scan records each row an acceptance named");
const baseRow = { ...ncT3.items![0], mark: "confirmed" as const, level: "low" as const, counted: true, component: "templates/nix:imagemagick", version: "7.1.1-1" };
const hidden = { ...ncT3, items: [baseRow] };
check(settleAcceptances(cfg, { ...status, targets: [imT, hidden] }, NOW).length === 0 && readAcceptances(cfg).acceptances.length === 1,
  "the items show the baseline's counted row: the acceptance holds, it is not gone");
const endedRow = { ...hidden, acceptances: [{ ...ncT3.acceptances![0], accepted: false, ended: "known-exploited" }] };
check(settleAcceptances(cfg, { ...status, targets: [imT, endedRow] }, NOW)[0]?.why === "known-exploited", "…and one the scan ended ends with the scan's reason");
cmdAccept(["nextcloud", "CVE-1", "--note", "x", "--until", "2027-05-01"], cfg, () => undefined, NOW, "lars");
check(settleAcceptances(cfg, { ...status, targets: [imT, { ...ncT, items: [baseRow] }] }, NOW).length === 0, "one accepted while the scan ran, under another row: it stays");
check(settleAcceptances(cfg, { ...status, targets: [imT, { ...ncT, items: [] }] }, NOW)[0]?.why === "gone", "a CVE no longer on the unit at all: gone");
const raw = JSON.parse(readFileSync(join(cfg, "security-acceptances.json"), "utf8"));
check(raw.schema === 1 && Array.isArray(raw.ended), "the file keeps what ended");

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
