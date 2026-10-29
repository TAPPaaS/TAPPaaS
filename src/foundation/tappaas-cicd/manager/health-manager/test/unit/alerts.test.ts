// alerts.test.ts — offline tests for the open/recent alert listing and the
// open-alerts gate (ADR-039 D8). Grafana is a fixture; the receiver's record a
// temp file.

import { mkdtempSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { alertLine, checkOpenAlerts, filterAlerts, openAlerts, placeAlert, recentEvents } from "../../src/alerts";

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

const dir = mkdtempSync(join(tmpdir(), "health-alerts-"));
const put = (name: string, o: Record<string, unknown>): void => writeFileSync(join(dir, `${name}.json`), JSON.stringify(o));
put("tappaas1", { moduleSource: "/x/src/foundation/pvehost" });
put("shop", { vmname: "site1", moduleSource: "/c/hosting" });
put("network", { vmname: "network", moduleSource: "/x/src/foundation/network" });
put("old", { vmname: "gone", moduleSource: "/c/hosting", status: "archived" });

console.log("placeAlert");
{
  check(JSON.stringify(placeAlert("tappaas1", "cluster", dir)) === JSON.stringify({ kind: "node", name: "tappaas1" }), "a node's host is its pvehost instance");
  check(JSON.stringify(placeAlert("site1", "hosting", dir)) === JSON.stringify({ kind: "module", name: "shop" }), "a host is the instance whose vmname it is");
  check(JSON.stringify(placeAlert("network.internal", "", dir)) === JSON.stringify({ kind: "module", name: "network" }), "a FQDN host is placed by its first label");
  check(JSON.stringify(placeAlert("gone", "hosting", dir)) === JSON.stringify({ kind: "module", name: "hosting" }), "an archived instance is not a place: the rule's module is");
  check(placeAlert("", "", dir) === null, "nothing to place: null");
}

console.log("openAlerts");
const grafana = [
  { labels: { alertname: "Heartbeat", kind: "heartbeat" }, startsAt: "2026-10-29T10:00:00Z" },
  { labels: { alertname: "HostSilent", host: "site1", kind: "state", module: "logging", bundle: "true" }, startsAt: "2026-10-29T11:00:00Z" },
  { labels: { alertname: "QuorumLost", host: "tappaas1", kind: "event", module: "cluster" }, startsAt: "2026-10-29T11:05:00Z" },
  { labels: { alertname: "ReplicationFailed", host: "tappaas1", kind: "state", module: "cluster", replication_job: "110-0" }, startsAt: "2026-10-29T09:00:00Z" },
];
{
  const open = openAlerts(grafana, dir);
  check(open.length === 2 && open.every((a) => a.state === "open"), `only state alerts are open, the heartbeat never (${open.map((a) => a.alertname)})`);
  const rep = open.find((a) => a.alertname === "ReplicationFailed");
  check(!!rep && rep.labels.replication_job === "110-0" && !("bundle" in rep.labels), "a series label is kept, the plain ones are not");
  check(/^open   ReplicationFailed on tappaas1 \(replication_job 110-0\)  since 2026-10-29T09:00:00Z  \[cluster\]$/.test(alertLine(rep!)), `the line names it (${alertLine(rep!)})`);
}

console.log("recentEvents");
{
  const log = join(dir, "alerts.jsonl");
  const now = Date.parse("2026-10-29T12:00:00Z");
  writeFileSync(log, [
    { time: "2026-10-29T11:05:30Z", status: "firing", alertname: "QuorumLost", host: "tappaas1", module: "cluster", kind: "event", labels: {}, startsAt: "2026-10-29T11:05:00Z" },
    { time: "2026-10-29T11:10:30Z", status: "firing", alertname: "QuorumLost", host: "tappaas1", module: "cluster", kind: "event", labels: {}, startsAt: "2026-10-29T11:05:00Z" },
    { time: "2026-10-27T11:00:00Z", status: "firing", alertname: "OomKill", host: "site1", module: "logging", kind: "event", labels: {}, startsAt: "2026-10-27T11:00:00Z" },
    { time: "2026-10-29T11:20:00Z", status: "firing", alertname: "HostSilent", host: "site1", module: "logging", kind: "state", labels: {}, startsAt: "2026-10-29T11:00:00Z" },
    { time: "2026-10-29T11:30:00Z", status: "resolved", alertname: "Signature", host: "site1", module: "hosting", kind: "event", labels: {}, startsAt: "2026-10-29T11:25:00Z" },
  ].map((o) => JSON.stringify(o)).join("\n") + "\nnot json\n");
  const rec = recentEvents(log, dir, now);
  check(rec.length === 1 && rec[0].alertname === "QuorumLost" && rec[0].state === "recent", `one event of the last day, its repeat folded (${rec.map((a) => a.alertname)})`);
  check(rec[0].subject?.kind === "node" && rec[0].subject.name === "tappaas1", "a recent event is placed too");
  check(recentEvents(join(dir, "none.jsonl"), dir, now).length === 0, "no record: nothing recent");

  const all = [...openAlerts(grafana, dir), ...rec];
  check(filterAlerts(all, { node: "tappaas1" }).length === 2, "--node: the node's own alerts, open and recent");
  check(filterAlerts(all, { module: "shop" }).map((a) => a.alertname).join() === "HostSilent", "--module: the instance's alerts by its host");
  check(filterAlerts(all, { module: "cluster" }).length === 2, "--module: a rule's module");
  check(filterAlerts(all, { host: "site1" }).length === 1, "--host");
}

console.log("checkOpenAlerts");
{
  check(checkOpenAlerts(dir, () => grafana).status === "skip", "no logging deployed: skip");
  put("logging", { vmname: "logging", zone0: "mgmt" });
  check(checkOpenAlerts(dir, () => null).status === "skip", "Grafana cannot be asked: skip, never fail");
  check(checkOpenAlerts(dir, () => [grafana[0]]).status === "pass", "only the heartbeat: pass");
  const r = checkOpenAlerts(dir, () => grafana);
  check(r.status === "warn" && (r.rows ?? []).length === 2, `open state alerts: warn, one row each (${r.detail})`);
  check((r.rows ?? []).some((x) => x.subject?.kind === "node" && x.subject.name === "tappaas1"), "a row carries the object it is about");
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
