// workspace.test.ts — the console after the condition types split, over the
// capture from hrossen (stored under the old types) and its hand-kept overlay
// of threat findings: the Health page's root list (every type a root is a root
// in, the filters, the header under them), the hits and hold as fields, the
// Ack wording from the holding rule, the Logs links, the Overview's cards per
// type and the Security page's Threats.

import { join } from "path";
import { capturedCmdb, overlaid, repoAbove } from "../../src/fixtures";
import { HealthGraph, buildHealth, conditionsOf, filteredCounts, rootMatches } from "../../src/health";
import { objectLogs } from "../../src/jumps";
import { ModuleRow } from "../../src/model";
import { threatsView } from "../../src/threats";
import { rootChanges } from "../../src/openevents";
import { CONDITION_TYPES as WEB_TYPES, ackEffect, filtersOf, healthPath, holdText, rootMatches as webRootMatches } from "../../web/src/healthwords";
import { typeCards, typeValue } from "../../web/src/overview";
import { CONDITION_TYPES } from "../../../lib/ts/src/health-rules";
import { HealthRoot, HealthSummary } from "../../web/src/types";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const NOW = Date.parse("2026-11-01T08:54:11Z");
const site = capturedCmdb(FIX, repoAbove(FIX) ?? join(FIX, "..", "..", "..", "..", "..", ".."));
const doc: HealthGraph = buildHealth({ objects: site.objects.filter((x) => !(x as unknown as { ended?: unknown }).ended), relations: site.relations, classes: site.classes, relationTypes: site.relationTypes, now: NOW });
const root = (label: string) => doc.roots.find((r) => r.label === label || r.name === label);

console.log("the types");
check(WEB_TYPES.join() === CONDITION_TYPES.join(), "the web's filter speaks the shared list of types");
check(!doc.nodes.some((n) => n.issues.some((i) => i.type === "security" || i.type === "maintenance")), "nothing reads under an old type: the capture's are mapped");
check(conditionsOf({ conditions: [{ type: "maintenance", status: "warning", reason: "backup-key-not-escrowed" }] })[0].type === "backup", "an unescrowed key stored under maintenance reads as backup");

console.log("the root list");
const vllm = root("vllm-amd")!;
check(vllm.types.join() === "threat,vulnerability" && vllm.type === "threat", "a root lists every type it is a root in, the worst first");
check(vllm.conditions[0].heldUntil === "ack" && vllm.conditions[0].heldBy === "core.classify.siem-critical" && vllm.conditions[0].hits?.count === 1, "…each with its hits and its hold as fields");
check(root("coturn")!.conditions[0].hits?.count === 23 && !root("coturn")!.conditions[0].message?.includes("23"), "the count is a field, not words in the message");
const threat = { type: "threat" };
check(doc.roots.filter((r) => rootMatches(r, threat)).map((r) => r.name).sort().join() === "cluster,coturn,vllm-amd", "under type threat: the three threat roots");
check(doc.roots.filter((r) => rootMatches(r, { class: "vm" })).every((r) => r.class === "vm"), "under a class: its roots only");
const fc = filteredCounts(doc, threat);
check(fc.filtered && fc.roots === 3 && fc.rootsAll === doc.roots.length && fc.counts.critical === 1 && fc.counts.warning === 2, `the header under the filter: ${fc.roots} of ${fc.rootsAll} root causes, by that type's colour`);
check(!filteredCounts(doc, {}).filtered && filteredCounts(doc, {}).counts.critical === doc.counts.critical, "no filter: the document's own counts");
check(webRootMatches(vllm as unknown as HealthRoot, { type: "vulnerability", class: "", environment: "" }), "the web keeps the same root by the same rule");

console.log("the address");
check(healthPath("x", { type: "threat", class: "", environment: "prod" }) === "/health?type=threat&environment=prod&select=x", "the filters live in the address, the selection after them");
check(JSON.stringify(filtersOf("?type=threat&select=x")) === JSON.stringify({ type: "threat", class: "", environment: "" }), "…and are read back from it");

console.log("the hold and the ack");
check(holdText("ack") === "until acknowledged" && holdText("2026-11-02T08:41:00.000Z", NOW) === "24 h left" && holdText("2026-10-01T00:00:00Z", NOW) === "over", "the hold as a column");
check(/ends it at the next assessment/.test(ackEffect({ type: "threat", heldUntil: "ack", heldBy: "core.classify.siem-critical" })), "held until acknowledged: the ack ends it at the next assessment");
check(/keeps its status but stops counting/.test(ackEffect({ type: "upkeep" })), "an ordinary condition: it keeps its status and stops counting");

console.log("the logs");
const mods = [{ name: "logging", vmname: "logging", environment: "rossen" }, { name: "coturn", vmname: "coturn" }] as unknown as ModuleRow[];
const ctx = { topology: null, modules: mods, environments: [{ name: "rossen", domains: { primary: "example.org" } }] as never, mgmtDomain: "mgmt.internal", pbsStore: "" };
const cot = doc.nodes.find((n) => n.name === "coturn")!;
const logs = objectLogs(ctx, cot, cot.issues);
check(logs.host === "coturn" && !!logs.url && decodeURIComponent(logs.url).includes('{host=\\"coturn\\"}'), "Logs: Grafana Explore on the guest's own lines");
check(logs.rules.length === 1 && decodeURIComponent(logs.rules[0].url).includes("Failed password") && logs.rules[0].alert === "SshBruteForce", "…and the threat's own rule query, as its mail has it");
check(objectLogs({ ...ctx, modules: [] }, cot, cot.issues).url === null, "no logging module: no link");

console.log("threats");
const t = threatsView(doc, NOW);
check(t.open.map((r) => r.name).join() === "vllm-amd,coturn,cluster", "critical first, then a hit on an open CVE, then the rest");
check(t.open[0].cve?.open === true && t.open[2].cve === null, "the CVE state beside each finding");
check(t.acks.length === 1 && t.acks[0].note.startsWith("the office") && t.acks[0].label === "Immich", "a recent acknowledgement and why, kept after its condition ended");
check(threatsView(doc, NOW + 40 * 86_400_000).acks.length === 0, "…for 30 days");
const held = buildHealth({ objects: overlaid(site.objects as never, { objects: { [vllm.id]: { conditions: [{ ...(site.objects.find((o) => o.id === vllm.id)!.attributes.conditions as Record<string, unknown>[]).find((c) => c.type === "threat"), maintenance: { until: null, note: "update" } }] } } }) as never, relations: site.relations, classes: site.classes, relationTypes: site.relationTypes, now: NOW });
check(threatsView(held, NOW).open.some((r) => r.name === "vllm-amd"), "a threat critical in a maintenance window stays open");

console.log("the overview");
const summary = { available: true, byType: { threat: { status: "critical", items: [{ id: "a", label: "vllm-amd", class: "lxc", status: "critical", reason: null, since: null, silenced: false }, { id: "b", label: "coturn", class: "vm", status: "warning", reason: null, since: null, silenced: false }, { id: "c", label: "x", class: "vm", status: "warning", reason: null, since: null, silenced: true }] } } } as unknown as HealthSummary;
const cards = typeCards(summary);
check(cards.map((c) => c.type).join() === CONDITION_TYPES.join(), "one card per condition type, in the filter's order");
const tc = cards.find((c) => c.type === "threat")!;
check(typeValue(tc) === "1 critical · 1 warning" && tc.silenced === 1 && tc.names.join() === "vllm-amd,coturn", "a card: open by status, the silenced apart, the worst names first");
check(typeValue(cards.find((c) => c.type === "drift")!) === "ok", "a type with nothing open is ok");

console.log("what changed");
const rc = rootChanges(new Map([["a", { attributes: [], changes: [{ id: 1, time: "2026-11-01T07:00:00Z", kind: "change", source: "module-manager", verb: "modify", job: null, actor: "lars" }] } as never], ["b", new Error("no history")]]), ["c"], NOW);
check(rc.changes.a[0].actor === "lars" && rc.changesError.b === "no history" && rc.changesSkipped.join() === "c" && rc.windowHours === 24, "a root's changes of the last day, the errors and the ones not read");

done("workspace");
