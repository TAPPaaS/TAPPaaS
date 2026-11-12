// score.test.ts — the one CVE risk score (ADR-045 D3), lib/ts/src/score.ts.
//
// The ADR's worked numbers are pinned here, so a change to a weight, a band or
// the halving shows up as a broken example rather than a quietly different
// health status.

import {
  ScoredItem, displayScore, halvingSum, levelRanges, itemPoints, levelOf, moduleScore, releaseScores, siteScores, tierMultiplier, zoneScore,
} from "../../../../lib/ts/src/score";
import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { cmdScore, itemOfDetail, itemsOfDetails } from "../../src/score-verb";
import { run } from "../../src/main";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}
const near = (a: number, b: number): boolean => Math.abs(a - b) < 1e-9;

let n = 0;
const risk = (rating: string, severity = "Critical"): ScoredItem => ({ id: `CVE-R${++n}`, state: "risk", rating, severity });
const open = (severity: string): ScoredItem => ({ id: `CVE-O${++n}`, state: "open", severity });
const carried = (severity: string): ScoredItem => ({ id: `CVE-C${++n}`, state: "carried", severity });
const decided = (severity: string): ScoredItem => ({ id: `CVE-D${++n}`, state: "decided", severity });
const many = (k: number, f: () => ScoredItem): ScoredItem[] => Array.from({ length: k }, f);

console.log("points per item");
check(itemPoints(risk("critical"))?.points === 20, "a confirmed critical 20: one table, by effective level");
check(itemPoints(risk("high"))?.points === 8, "a confirmed high 8");
check(itemPoints(risk("medium"))?.points === 3, "risk medium 3");
check(itemPoints(risk("low"))?.points === 1, "risk low 1");
check(itemPoints(open("Critical"))?.points === 20, "open critical 20");
check(itemPoints(open("High"))?.points === 8, "open high 8");
check(itemPoints(open("Medium")) === null && itemPoints(open("Low")) === null, "an unanalysed medium or low counts nothing");
check(itemPoints(carried("CRITICAL"))?.points === 20 && itemPoints(carried("high"))?.points === 8, "carried counts as open (any case)");
check(itemPoints(decided("Critical")) === null, "decided counts nothing");
check(itemPoints(risk("low", "Critical"))?.category === "low", "a risk item counts by its TAPPaaS rating, not its CVE severity");
check(itemPoints({ id: "x", state: "risk", severity: "High" })?.points === 8, "an unrated risk item counts at its CVE severity");
check(itemPoints({ id: "x", state: "open", severity: "High", level: "low", mark: "rule" })?.points === 1, "an effective level counts, whatever the old state says");
check(itemPoints({ id: "x", state: "open", severity: "Critical", level: "none", mark: "confirmed" }) === null, "effective none counts nothing");
check(itemPoints({ id: "x", state: "open", severity: "Critical", level: "critical", mark: "accepted" }) === null, "an accepted CVE counts nothing");
check(itemPoints({ id: "x", state: "open", severity: "Medium", level: "medium", mark: "unread" }) === null, "an unread medium is listed, not counted");
check(itemPoints({ id: "x", state: "risk", severity: "Medium", level: "medium", mark: "confirmed" })?.points === 3, "…a confirmed one counts");
check(itemPoints({ id: "x", state: "open", severity: "Critical", level: "critical", counted: false }) === null, "a decision's own verdict wins");
check(moduleScore([{ id: "a", state: "open", severity: "High" }, { id: "b", state: "risk", severity: "High", level: "high", mark: "confirmed" }]).marks.unread === 1,
  "the marks are counted: unread and confirmed alike score 8 + 4");

console.log("module score: the ADR's examples");
const three = moduleScore(many(3, () => risk("critical")));
check(near(three.raw, 35) && three.level === "critical", "3 confirmed criticals = 20 + 10 + 5 = 35, critical");
const ro = moduleScore([open("Critical"), risk("critical")]);
check(near(ro.raw, 30) && ro.level === "critical", "a confirmed and an unread critical = 20 + 10 = 30: read or not, the same points");
const nine = moduleScore(many(9, () => open("High")));
check(near(nine.raw, 8 * (2 - 2 ** -8)) && nine.score === 15 && nine.level === "medium", "9 open highs ≈ 15.97, shown 15: medium, never rounded up into high");
const immich = moduleScore([open("Critical"), ...many(9, () => open("High")), ...many(6, () => risk("medium"))]);
check(immich.raw === 20 && immich.level === "high" && immich.category === "critical" && immich.counted === 1,
  "immich 2.4: one open critical, nine open highs, six risk items = 20, high (only the top category counts)");
check(immich.counts.open === 10 && immich.counts.risk === 6, "…and its counts say what it holds");
check(moduleScore([open("Critical")]).level === "high", "one open critical (20) is high, not critical");
check(moduleScore([risk("critical")]).level === "high", "one confirmed critical (20) is high");
check(moduleScore([risk("critical"), risk("critical")]).level === "critical", "two criticals (30) are critical");
check(moduleScore([open("Critical"), open("Critical")]).raw === 30 && moduleScore([open("Critical"), open("Critical")]).level === "critical",
  "two open criticals = 30 exactly: the band starts there");
check(moduleScore([open("High")]).level === "medium" && moduleScore([risk("high")]).level === "medium", "one open or analysed high is medium");
check(near(moduleScore(many(3, () => risk("high"))).raw, 14) && moduleScore(many(3, () => risk("high"))).level === "medium",
  "three highs, read or not, stay medium (14)");
check(moduleScore(many(20, () => risk("medium"))).level === "low", "mediums never pass low");
check(moduleScore([risk("low")]).level === "low" && moduleScore([risk("low")]).raw === 1, "one analysed low = 1, low");
check(moduleScore([]).level === "ok" && moduleScore([decided("Critical"), open("Medium")]).raw === 0, "nothing counted: 0, ok");
check(moduleScore([{ id: "CVE-1", state: "open", severity: "High", pkg: "a" }, { id: "CVE-1", state: "open", severity: "High", pkg: "b" }]).raw === 8,
  "one CVE in two packages is one item");

console.log("the float edge: a category never reaches twice its top");
const sixty = moduleScore(many(60, () => open("High")));
check(sixty.raw < 16 && sixty.level === "medium", `60 open highs stay below 16 and medium (raw ${sixty.raw})`);
check(sixty.score < 16, `…and are not displayed as 16.00 (${sixty.score})`);
check(moduleScore(many(200, () => risk("critical"))).raw < 50, "200 analysed criticals stay below 50");
check(halvingSum([1, 25, 10]) === 25 + 5 + 0.25, "the halving takes the points highest first");
check(displayScore(15.6) === 15 && displayScore(14.5) === 15 && displayScore(43.75) === 44 && displayScore(7.2) === 7, "a whole number, never rounded across a band");
check(displayScore(29.999) === 29 && levelOf(29.999) === "high", "29.999 stays high, shown 29");
check(displayScore(0.3) === 1 && displayScore(0) === 0, "just above 0 is low, shown 1; 0 is ok");
check(JSON.stringify(levelRanges()) === JSON.stringify([{ level: "critical", from: 30, to: null }, { level: "high", from: 16, to: 29 }, { level: "medium", from: 7, to: 15 }, { level: "low", from: 1, to: 6 }, { level: "ok", from: 0, to: 0 }]), "each level's range in whole points");

console.log("levels");
check(levelOf(0) === "ok" && levelOf(0.0001) === "low" && levelOf(6.99) === "low" && levelOf(7) === "medium", "ok 0, low below 7, medium from 7");
check(levelOf(15.99) === "medium" && levelOf(16) === "high" && levelOf(29.99) === "high" && levelOf(30) === "critical", "high from 16, critical from 30");

console.log("zones: the tier multiplier");
check(tierMultiplier(0) === 2 && tierMultiplier(1) === 1 && tierMultiplier(2) === 0.75 && tierMultiplier(3) === 0.5, "tiers 0–3: ×2, ×1, ×0.75, ×0.5");
check(tierMultiplier(4) === 0.25 && tierMultiplier(5) === 0.1 && tierMultiplier(6) === 0.1, "tiers 4–6: ×0.25, ×0.1, ×0.1");
check(tierMultiplier(undefined) === 1 && tierMultiplier(null) === 1 && tierMultiplier("1") === 1, "a zone without a tier counts ×1");
const mgmt = zoneScore(0, [{ module: "tappaas-cicd", raw: 20 }, { module: "identity", raw: 8 }]);
check(mgmt.raw === 40 && mgmt.level === "critical" && mgmt.setBy.module === "tappaas-cicd", "mgmt with an open critical = 40, critical, set by its module");
check(zoneScore(0, [{ module: "x", raw: 8 }]).level === "high", "one open high in mgmt is high (16)");
check(zoneScore(1, [{ module: "immich", raw: 20 }]).raw === 20, "one open critical in a service zone stays 20");
check(zoneScore(4, [{ module: "x", raw: 43.75 }]).level === "medium", "the DMZ quarters: 43.75 → 10.94, medium");
check(zoneScore(1, []).level === "ok" && zoneScore(1, []).setBy.module === null, "an empty zone is ok, set by nobody");

console.log("environments and the site");
const site = siteScores({
  modules: {
    immich: [open("Critical")],
    nextcloud: many(9, () => open("High")),
    deconz: [risk("critical"), risk("critical")],
    caddy: [risk("high")],
    firewall: [open("High")],
    homeassistant: [open("Critical")],
  },
  placement: { immich: ["rossen"], nextcloud: ["rossen"], deconz: ["iotLocal"], caddy: ["dmz"], firewall: ["mgmt"], homeassistant: ["home"] },
  zones: {
    mgmt: { tier: 0, environment: "mgmt" }, rossen: { tier: 1, environment: "rossen" }, home: { tier: 2, environment: ["rossen", "test"] },
    iotLocal: { tier: 5, environment: "rossen" }, dmz: { tier: 4 }, test: { tier: 1, environment: "test" }, work: {},
  },
});
check(site.zones.rossen.raw === 20 && site.zones.rossen.setBy.module === "immich", "rossen: its highest module, immich 20");
check(near(site.zones.iotLocal.raw, 3) && site.zones.iotLocal.level === "low", "iotLocal ×0.1: 30 → 3, low");
check(site.zones.home.raw === 15 && site.zones.home.level === "medium", "home ×0.75: 20 → 15, medium");
check(site.environments.rossen.raw === 20 && site.environments.rossen.setBy.zone === "rossen", "the rossen environment is the highest of its zones");
check(site.environments.test.raw === 15 && site.environments.test.setBy.module === "homeassistant", "a shared zone counts for every environment it names");
check(site.environments.mgmt.raw === 16 && site.environments.mgmt.level === "high", "the firewall counts in mgmt: one open high ×2 = 16, high");
check(site.outside.join(",") === "dmz,work" && near(site.zones.dmz.raw, 2), "zones in no environment roll up to the site directly");
check(site.site.raw === 20 && site.site.setBy.module === "immich" && site.site.setBy.zone === "rossen", "the site: 20, high, pointing at immich in rossen");
const crit = siteScores({ modules: { firewall: [open("Critical")] }, placement: { firewall: ["mgmt"] }, zones: { mgmt: { tier: 0, environment: "mgmt" } } });
check(crit.site.raw === 40 && crit.site.level === "critical", "one open critical on the firewall makes the site critical (40)");
const dmzOnly = siteScores({ modules: { caddy: many(3, () => risk("critical")) }, placement: { caddy: ["dmz"] }, zones: { dmz: { tier: 4 } } });
check(dmzOnly.site.setBy.zone === "dmz" && near(dmzOnly.site.raw, 8.75), "a DMZ-only site is set by the DMZ");
const unknown = siteScores({ modules: { x: [open("High")] }, placement: { x: ["lab"] }, zones: {} });
check(unknown.zones.lab.multiplier === 1 && unknown.site.raw === 8, "a zone zones.json does not know counts ×1, outside every environment");

console.log("release score");
const rel = releaseScores({ immich: [open("Critical")], identity: [risk("critical"), risk("critical")], coturn: [] });
check(rel.release.raw === 30 && rel.release.level === "critical" && rel.release.setBy.module === "identity", "a release is its highest module, no multiplier");
check(rel.modules.coturn.level === "ok" && rel.modules.immich.score === 20, "…each module scored");
check(releaseScores({}).release.level === "ok", "an empty release is ok");

console.log("health-manager score");
check(itemOfDetail({ id: "a", status: "baseline", severity: "High" }) === null, "a baseline CVE counts in the baseline's row, not the module's");
check(itemOfDetail({ id: "a", status: "ack", severity: "Critical" })?.state === "open", "an acked item still counts: the ack is for the gate, not the risk");
check(itemOfDetail({ id: "a", status: "ack", state: "risk", risk: "low", severity: "Critical" })?.rating === "low", "…in the state it has under the ack");
check(itemOfDetail({ id: "a", status: "carried", severity: "High" })?.state === "carried", "a carried item is carried");
const det = {
  modules: {
    immich: { cves: {
      new: [{ id: "CVE-B", severity: "Critical", status: "open" }],
      same: [...Array.from({ length: 9 }, (_, i) => ({ id: `CVE-H${i}`, severity: "High", status: "open" })),
        { id: "CVE-G", severity: "High", status: "baseline" },
        ...Array.from({ length: 6 }, (_, i) => ({ id: `CVE-R${i}`, severity: "High", status: "risk", risk: "medium" }))],
    } },
    baseline: { cves: { new: [], same: [{ id: "CVE-G", severity: "High", status: "carried" }] } },
    coturn: { cves: { new: [], same: [] } },
  },
};
check(itemsOfDetails(det).immich.length === 16, "a module's items: NEW and SAME, without the baseline's");
const dir = mkdtempSync(join(tmpdir(), "score-test-"));
writeFileSync(join(dir, "d.json"), JSON.stringify(det));
let outl: string[] = [];
check(cmdScore(["--details", join(dir, "d.json"), "--json"], (l) => outl.push(l)) === 0, "score --details --json runs");
const doc = JSON.parse(outl.join("\n"));
check(doc.modules.immich.score === 20 && doc.modules.immich.level === "high", "immich in the 2.4-style preview: 20, high");
check(doc.modules.baseline.score === 8 && doc.modules.baseline.level === "medium", "a carried baseline high: 8, medium");
check(doc.release.score === 20 && doc.release.setBy.module === "immich" && doc.modules.coturn.level === "ok", "the release: its highest module");
check(doc.model.points.critical === 20 && doc.model.tierMultipliers[0] === 2, "…with the values it used");
outl = [];
cmdScore(["--details", join(dir, "d.json")], (l) => outl.push(l));
check(outl[0] === "release: 20 high — set by immich" && outl.some((l) => /immich +20 +high +1 critical/.test(l)), "the text form: the release, then a line per module");
writeFileSync(join(dir, "i.json"), JSON.stringify({
  modules: { firewall: [{ id: "x", state: "open", severity: "Critical" }] }, placement: { firewall: ["mgmt"] }, zones: { mgmt: { tier: 0, environment: "mgmt" } },
}));
outl = [];
cmdScore(["--items", join(dir, "i.json"), "--json"], (l) => outl.push(l));
const sdoc = JSON.parse(outl.join("\n"));
check(sdoc.site.score === 40 && sdoc.site.level === "critical" && sdoc.zones.mgmt.multiplier === 2, "score --items with zones: the site's scores");
let threw = "";
try { cmdScore([], () => undefined); } catch (e) { threw = (e as Error).message; }
check(threw.includes("one of --details"), "score with no input says what it needs");
check(run(["score", "--details", join(dir, "d.json"), "--json"], new FakeClusterClient()) === 0, "health-manager score is a verb");
check(run(["score", "--nonsense"], new FakeClusterClient()) !== 0, "…that refuses an option it does not declare");

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
