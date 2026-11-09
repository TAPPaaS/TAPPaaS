// security.test.ts — the Security page's read and shaping: /api/security's view
// of `health-manager report security --json` (src/security.ts) over the
// synthetic scan in test/fixtures, the Modules badge, and the page's pure
// helpers (web/src/security.ts).

import { readFileSync } from "fs";
import { join } from "path";
import { moduleSummaries } from "../../src/badges";
import { ModuleRow } from "../../src/model";
import { lastDays, moduleLevel, securityView } from "../../src/security";
import { allUnits, countsText, cveCategory, cveNote, levelsText, riskText, riskTone, securityTile, sparkPoints, sparkTitle, unitLabel } from "../../web/src/security";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const raw = JSON.parse(readFileSync(join(FIX, "reads", "health-manager-report-security-json.out"), "utf8")) as Record<string, unknown>;
const v = securityView(raw)!;
check(levelsText(v.levels) === "critical 30 and above · high 16–29 · medium 7–15 · low 1–6 · ok 0", `the score per level, explained in one line (${levelsText(v.levels)})`);

// ── the view ──
check(v !== null && v.site.level === "high" && v.site.score === 20 && v.site.setBy === "immich in rossen", "the site: high, 20, set by immich in rossen");
check(v.days.length === 7 && v.days[6] === "2026-11-01" && v.days[0] === "2026-10-26", "seven days, ending on the scan's");
check(v.site.spark.join() === "32,32,24,20,20,10,20", "the site's sparkline from the history");
const rossen = v.environments.find((e) => e.name === "rossen")!;
check(rossen.zones.length === 1 && rossen.zones[0].name === "rossen" && rossen.zones[0].multiplier === 1, "an environment holds its zones, each with its multiplier");
const immich = rossen.zones[0].units.find((u) => u.name === "immich")!;
check(immich.level === "high" && immich.score === 20 && immich.setBy === "1 critical", "a module: level, score, what counts");
check(immich.counts.open === 2 && immich.counts.risk === 1 && immich.counts.carried === 1 && immich.counts.decided === 1, "…its CVEs by state");
check(immich.cves.length === 5 && immich.cves.some((c) => c.state === "carried" && c.carriedFrom === "4.7.1" && !!c.analysis), "…and its counted CVEs with their analysis");
check(immich.cves.map((c) => c.state).join() === "open,open,risk,carried,decided" && immich.cves[0].severity === "Critical", "…what counts most first: open (critical first), risk, carried, decided");
check(rossen.zones[0].units[0].score >= rossen.zones[0].units[rossen.zones[0].units.length - 1].score, "modules worst first");
const mgmt = v.environments.find((e) => e.name === "mgmt")!.zones[0];
check(mgmt.multiplier === 2 && mgmt.units.some((u) => u.kind === "firewall") && mgmt.units.some((u) => u.kind === "node"), "the management zone ×2, with the firewall and the nodes");
check(v.outside.some((z) => z.name === "dmz" && z.multiplier === 0.25), "a zone in no environment sits directly under the site");
check(!v.outside.some((z) => z.name === "guest"), "…a zone nothing runs in is left out");
check(v.failed.join() === "lazysite", "a module whose scan failed is named");
const text = JSON.stringify(v);
check(!/fix/i.test(text.replace(/"analysis":"[^"]*"/g, "")), "nothing about a fix leaves the server");
check(!("act" in (v as unknown as Record<string, unknown>)) && !text.includes("critHighFixable"), "…not the scan's act list nor its fixable counts");
check(securityView({ schema: 1, targets: [] }) === null, "a scan from before the scores: no view");
check(securityView(null) === null, "no scan: no view");
check(lastDays("2026-03-01").join() === "2026-02-23,2026-02-24,2026-02-25,2026-02-26,2026-02-27,2026-02-28,2026-03-01", "seven days across a month");

// ── the Modules badge ──
check(moduleLevel(raw, "immich")?.level === "high" && moduleLevel(raw, "nobody") === null, "a module's level, or none");
const rows = [{ name: "immich" }, { name: "vaultwarden" }, { name: "coturn" }, { name: "nomad" }] as unknown as ModuleRow[];
const ms = moduleSummaries(rows, null, null, raw);
check(ms[0].badges.cve === "high" && ms[0].badges.cveScore === 20, "immich's badge: high, 20");
check(ms[1].badges.cve === "critical" && ms[1].badges.cveScore === 30, "vaultwarden: two open criticals, its own 30, critical (the dmz's ×0.25 is the zone's)");
check(v.outside.find((z) => z.name === "dmz")?.score === 7.5 && v.outside.find((z) => z.name === "dmz")?.level === "medium", "…and the dmz 7.5, medium");
check(ms[2].badges.cve === "ok" && ms[3].badges.cve === "unknown", "nothing counted is ok; not scanned is unknown");

// ── the page's helpers ──
check(riskTone("ok") === "pass" && riskTone("low") === "pass" && riskTone("medium") === "warn" && riskTone("high") === "warn" && riskTone("critical") === "fail", "a level's colour, as health has it");
check(riskText({ level: "high", score: 20 }) === "high, 20" && riskText({ level: "ok", score: 0 }) === "ok", "level and score as one phrase");
check(unitLabel({ ...immich, kind: "node", name: "tappaas1" }) === "node tappaas1" && unitLabel({ ...immich, kind: "firewall", name: "network" }) === "network (firewall)", "platform targets named as such");
const risk = immich.cves.find((c) => c.state === "risk")!;
check(cveCategory(risk) === "medium, rated here", "a risk CVE counts at the rating given here");
check(cveNote(immich.cves.find((c) => c.state === "open")!) === "Not analysed yet.", "an open CVE: not analysed yet");
check(/^Analysed for 4\.7\.1: .*Confirm it for 4\.7\.2\.$/.test(cveNote(immich.cves.find((c) => c.state === "carried")!) ?? ""), "a carried CVE: the earlier analysis, and what to confirm");
check(countsText(immich.counts) === "2 open, 1 risk, 1 carried, 1 decided" && countsText({ open: 0, risk: 0, carried: 0, decided: 0 }) === "none", "the counts, only what is there");
const pts = sparkPoints([0, null, 10, 20, null, null, 5], 60, 20);
check(pts.length === 3 && pts[0] === "0.0,19.0" && pts[1].split(" ").length === 2 && pts[2] === "60.0,14.5", "the sparkline: gaps where no scan wrote, scaled to the highest");
check(sparkPoints([0, 0], 10, 10)[0] === "0.0,9.0 10.0,9.0", "…a flat zero sits on the floor");
check(sparkTitle(["2026-11-01"], [null]) === "11-01: no scan", "…its title says the days");
check(allUnits(v)[0].score === Math.max(...allUnits(v).map((u) => u.score)), "every unit, worst first");
const tile = securityTile(v)!;
check(tile.value === "CVE risk high, 20" && tile.level === "warn" && /modules high or critical · set by immich in rossen · 1 not scanned/.test(tile.sub), `the Overview tile (${tile.sub})`);
check(securityTile(null) === null, "…none without a scan");

done("security");
