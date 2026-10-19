// reads.test.ts — the read layer and its cache (ADR-034 D1): each read is one
// manager verb's --json; validate's exit 1 still carries its document; the
// topology is handed the cached health instead of running validate again; a
// failed refresh keeps the last good answer; drift runs only when asked.

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Cached } from "../../src/cache";
import { Reads } from "../../src/reads";
import { attention, moduleSummaries } from "../../src/badges";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

async function main(): Promise<void> {
  // ── the cache ───────────────────────────────────────────────────────
  {
    let t = 0;
    let n = 0;
    let fail = false;
    const c = new Cached<number>("x", 1000, async () => {
      n++;
      if (fail) throw new Error("down");
      return n;
    }, () => t);
    const a = await c.get();
    check(a.value === 1 && n === 1, "the first read waits for its load");
    await c.get();
    check(n === 1, "a fresh answer is served from the cache");
    t = 1500;
    const b = await c.get();
    check(b.value === 1, "a stale answer is served at once…");
    await c.refresh();
    check(c.peek().value === 2, "…while the refresh runs behind it");
    const p1 = c.refresh();
    const p2 = c.refresh();
    await Promise.all([p1, p2]);
    check(n === 3, "two refreshes at once run the verb once");
    fail = true;
    await c.refresh();
    const e = c.peek();
    check(e.value === 3 && e.error === "down", "a failed refresh keeps the last good value and says why");
  }
  // a refresh after a change does not join a load that read before it (the
  // Setup checklist after Check: the page's own gather was still running)
  {
    let source = "before";
    const holds: (() => void)[] = [];
    const c = new Cached<string>("y", 0, async () => {
      const v = source;
      await new Promise<void>((r) => holds.push(r));
      return v;
    });
    const first = c.refresh();
    source = "after"; // the tests wrote their results
    const again = c.refreshAfterChange();
    const joined = c.refresh(); // the plain refresh joins the running load
    holds.shift()!();
    await Promise.all([first, joined]);
    for (let i = 0; i < 20 && holds.length === 0; i++) await new Promise<void>((r) => setTimeout(r, 1));
    holds.shift()?.();
    await again;
    check(c.peek().value === "after", "refreshAfterChange reads again after a load already running");
  }

  const cfgDir = mkdtempSync(join(tmpdir(), "console-reads-"));
  const stateDir = join(cfgDir, "state");
  writeFileSync(join(cfgDir, "last-update-result.json"), JSON.stringify({ ok: true, total: 25 }));
  writeFileSync(join(cfgDir, "zones.json"), JSON.stringify({ _README: "doc block, not a zone", mgmt: { state: "Mandatory", vlantag: 0, ip: "10.0.0.0/24" }, rossen: { state: "Active", vlantag: 200 }, notes: { description: "no state, no vlantag: not a zone" } }));
  writeFileSync(join(cfgDir, "update-tappaas.failures"), readFileSync(join(process.env.CONSOLE_FIXTURES ?? "test/fixtures", "update-tappaas.failures"), "utf8"));
  const site = fakeSite();
  writeFileSync(join(cfgDir, "wan-address.json"), JSON.stringify({ ipv4: "8.8.4.4", prefix: 24, ipv6: [], private: false, observed: "2026-10-19T03:12:00+02:00" }));
  const reads = new Reads({ configDir: cfgDir, stateDir, run: site.run, journalDays: 7, wanAddressFile: join(cfgDir, "wan-address.json") });

  // ── health ──────────────────────────────────────────────────────────
  const h = await reads.health.get();
  check(h.value !== null && h.error === null, "validate's exit 1 (a gate failed) still yields its document");
  check(site.calls.includes("health-manager validate --json"), "health is `health-manager validate --json`");
  const att = attention(h.value);
  check(att[0].level === "fail", "Attention lists the FAILs first");
  check(att.some((r) => r.gate === "guest-memory" && r.subject?.name === "immich" && r.level === "fail"), "immich's memory FAIL is in Attention");
  check(att.some((r) => r.gate === "lan-uplink" && r.subject?.name === "tappaas1"), "tappaas1's lan-uplink WARN is in Attention");

  // ── the topology gets the cached health ───────────────────────────────
  const t = await reads.topology.get();
  const topoCall = site.calls.find((c) => c.startsWith("network-manager topology")) ?? "";
  check(t.value !== null && /--health \S+health\.json/.test(topoCall), "topology is run with --health <the cached document>");
  check(JSON.parse(readFileSync(join(stateDir, "health.json"), "utf8")).gates.length === h.value!.gates.length, "…written to the state directory");
  check(site.calls.filter((c) => c.startsWith("health-manager validate")).length === 1, "…so validate ran once");

  // ── modules and their badges ─────────────────────────────────────────
  const m = await reads.modules.get();
  const b = await reads.backup.get();
  const list = moduleSummaries(m.value!.modules, h.value, b.value);
  const immich = list.find((x) => x.name === "immich")!;
  check(list.length === 25, `every deployed module is listed (${list.length})`);
  check(immich.badges.health === "fail" && immich.badges.run === "running" && immich.badges.backup === "covered", "immich: running, health FAIL, backed up");
  check(immich.findings.some((f) => f.gate === "guest-memory"), "…with the finding that fails it");
  const nomad = list.find((x) => x.name === "nomad")!;
  check(nomad.badges.cve === "act", "nomad's CVE badge says act");
  check(list.find((x) => x.name === "cluster")!.badges.run === "none", "a module with no guest has no run state");

  // ── module detail, drift on demand ──────────────────────────────────
  await reads.moduleShow.of("immich").get();
  await reads.moduleResolve.of("immich").get();
  check(site.calls.includes("module-manager show immich --json") && site.calls.includes("module-manager resolve immich --json"), "a module page is show + resolve");
  check(!site.calls.some((c) => c.includes("drift")), "drift has not run unasked");
  await reads.moduleDrift.of("immich").get();
  check(site.calls.includes("module-manager drift immich --json"), "drift runs when asked");

  // ── the rest ─────────────────────────────────────────────────────────
  const z = await reads.zones.get();
  check(z.value?.length === 2 && (z.value[1] as { name?: string; vlantag?: number }).name === "rossen" && (z.value[1] as { vlantag?: number }).vlantag === 200, "zones: zones.json read once, each zone with its name, doc blocks skipped");
  check(!site.calls.some((c) => c.startsWith("network-manager list") || c.startsWith("network-manager show")), "…without a network-manager process per zone");
  const sec = await reads.security.get();
  check(sec.value === null && sec.error === null, "no security scan yet is an answer, not an error");
  const a = await reads.activity.get();
  check((a.value?.runs.length ?? 0) > 5 && a.value!.lastResult?.total === 25 && a.value!.ledger.length > 0, "activity: sweep runs, the ledger and the last result");
  check(a.value?.sweepActive === false, "…and whether a sweep runs now");
  const st = await reads.site.get();
  check((st.value?.site as { name?: string }).name === "rossen" && (st.value?.lastSweep as { ok?: boolean }).ok === true, "site: site show and the last sweep");
  check((st.value?.wan as { ipv4?: string } | null)?.ipv4 === "8.8.4.4", "site: the address the WAN held at the last network update");

  // ── a failing source ─────────────────────────────────────────────────
  site.fail.add("environment-manager list");
  const env = await reads.environments.get();
  check(env.value === null && /exit 1 — \[Error\] failed on purpose/.test(env.error ?? ""), "a failing verb is an error naming it, with its last line");
  let threw = false;
  try {
    await reads.refresh("bogus");
  } catch {
    threw = true;
  }
  check(threw, "refreshing an unknown read is refused");

  // ── a node being added (the Site page's Add node) ──────────────────────
  {
    const site = fakeSite();
    const cfg = mkdtempSync(join(tmpdir(), "nodeprog-"));
    mkdirSync(join(cfg, "provision"));
    writeFileSync(join(cfg, "provision", "tappaas4.json"), "{}");
    writeFileSync(join(cfg, "provision", "tappaas3.json.consumed"), "{}");
    const r = new Reads({ configDir: cfg, stateDir: join(cfg, "s"), run: site.run, journalDays: 7, clusterNodes: (ns) => (ns.length ? ["tappaas1", "tappaas2", "tappaas3"] : null) });
    const p4 = (await r.nodeProgress.of("tappaas4").get()).value!;
    check(p4.registration === "pending" && p4.inCluster === false && !p4.inSite, "a registered node not yet booted: pending, not in the cluster or site.json");
    check(p4.pxe.enabled === false && /PXE: disabled/.test(p4.pxe.text), "the PXE window's state from node-provisioner status");
    const p3 = (await r.nodeProgress.of("tappaas3").get()).value!;
    check(p3.registration === "answered" && p3.inCluster === true && !p3.inSite, "installed and joined, not yet in site.json");
    const p1 = (await r.nodeProgress.of("tappaas1").get()).value!;
    check(p1.registration === "none" && p1.inSite && p1.inCluster === true, "a node already in place");
    const before = site.calls.length;
    await r.nodeProgress.of("tappaas1").get();
    check(site.calls.length === before, "read again within ten seconds: served from the cache");
  }

  // ── the identity records (the Identity page's graph) ──────────────────
  {
    const site = fakeSite();
    const r = new Reads({ configDir: mkdtempSync(join(tmpdir(), "idrec-")), stateDir: mkdtempSync(join(tmpdir(), "idrec-s-")), run: site.run, journalDays: 7 });
    const e = await r.identityRecords.get();
    const v = e.value!;
    check(v.org.length === 1 && v.group.length === 2 && v.role.length === 2, "every object of every kind is read with show");
    check((v.user.find((u) => u.name === "lars")?.memberOf as string[]).join() === "users,authentik Admins", "a record as identity-manager shows it");
    check(!site.calls.some((c) => c.includes("show -x")), "a listed name that looks like an option never reaches an argv");
    check(site.calls.includes("identity-manager group show authentik Admins --json"), "a name with a space is one argument");
  }

  done("reads");
}

void main();
