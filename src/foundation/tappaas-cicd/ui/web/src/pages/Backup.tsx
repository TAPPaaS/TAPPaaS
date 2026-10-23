// Backup — what backup-manager knows (spike §5.2, Appendix A). On top, the
// overview: the site's backup record (site.json backup: target, default
// schedule) with its Modify, the backup health (the backup-status gate and the
// pulse's targets), the last backup and the last verify per target and per
// job with what needs a look (restore list-all --json), and the buddies and
// the satellite with their state (the topology's outside parties). Below:
// every module's policy, whether the PBS job has it, its last backup and
// verify, the off-site peers, and
// per module show / coverage / restore list (reads that run at once), modify
// (a job with its preview) and purge (destructive: the name typed, Installer;
// never a side effect of a module's delete).

import { Read, useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { fieldsStep } from "../fields";
import { BackupRowView, BackupRuns, GuestRuns, Health, SiteRead, Topology } from "../types";
import { KV, ReadState, Section, Tag, since, when } from "../ui";
import { ago, attention, byModule, guestLevel, latestRuns, runLevel, summary, targetLabel, targetLevel, verifyLevel } from "../backupruns";

const bm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "backup-manager", verb, ...extra });

// A gate's finding as a row: its level and its words.
const level = (s: string) => (s === "fail" ? "fail" : s === "warn" ? "warn" : s === "pass" ? "pass" : "skip");

const nowSec = () => Math.floor(Date.now() / 1000);
const at = (epoch: number | null | undefined) => (epoch ? when(new Date(epoch * 1000).toISOString()) : "never");

// The last backup and the last verify: per target, the jobs' runs, and the
// guests that need a look.
function LastRuns({ runs }: { runs: Read<BackupRuns> }) {
  const r = runs.env?.data;
  const now = nowSec();
  const look = r ? attention(r) : [];
  return (
    <Section title="Last backup and verify" aside={`backup-manager restore list-all · ${since(runs.env?.at)}`}>
      <ReadState env={runs.env} failure={runs.failure} what="backup runs" />
      {r && !r.reachable ? <p className="muted">PBS did not answer: no last backup or verify to show.</p> : null}
      {r && r.reachable ? (
        <>
          <p>{summary(r)} <span className="muted small">· {r.store} on {r.node}</span></p>
          <table className="table compact">
            <thead>
              <tr><th /><th>target</th><th>groups</th><th>last backup</th><th>last verify</th></tr>
            </thead>
            <tbody>
              {r.targets.map((t) => (
                <tr key={t.ns}>
                  <td><Tag level={targetLevel(t)} /></td>
                  <td title={t.ns ? `namespace ${t.ns}` : "the root namespace"}>{targetLabel(t)}</td>
                  <td>{t.groups} · {t.snapshots} snapshots</td>
                  <td title={at(t.lastBackup)}>{ago(t.lastBackup, now)}</td>
                  <td title={t.lastVerify ? at(t.lastVerify.time) : undefined}>
                    {t.lastVerify ? `${t.lastVerify.state} · ${ago(t.lastVerify.time, now)}` : "never verified"}
                    {t.failedVerifies > 0 ? <span className="muted"> · {t.failedVerifies} failed</span> : null}
                    {t.unverified > 0 ? <span className="muted"> · {t.unverified} newest unverified</span> : null}
                  </td>
                </tr>
              ))}
              {r.targets.length === 0 ? <tr><td className="muted" colSpan={5}>nothing stored yet</td></tr> : null}
            </tbody>
          </table>
          <ul className="findings">
            {latestRuns(r).map((x) => (
              <li key={`run-${x.node}`} title={at(x.time)}>
                <Tag level={runLevel(x)} /> backup run on {x.node}, {ago(x.time, now)}: {x.state}
              </li>
            ))}
            {r.verifyJobs.map((v) => (
              <li key={`v-${v.id}`} title={v.lastRun ? at(v.lastRun.time) : undefined}>
                <Tag level={runLevel(v.lastRun)} /> verify job {v.id} ({v.schedule}): {v.lastRun ? `${v.lastRun.state}, ${ago(v.lastRun.time, now)}` : "never run"}
              </li>
            ))}
            {r.syncJobs.map((v) => (
              <li key={`s-${v.id}`} title={v.lastRun ? at(v.lastRun.time) : undefined}>
                <Tag level={runLevel(v.lastRun)} /> pull from {v.remote} ({v.schedule}): {v.lastRun ? `${v.lastRun.state}, ${ago(v.lastRun.time, now)}` : "never run"}
              </li>
            ))}
            {r.verifyJobs.length === 0 ? <li><Tag level="warn" /> no verify job: nothing checks the backups can be read back</li> : null}
          </ul>
          {look.length ? (
            <>
              <h3>Needs a look</h3>
              <ul className="findings">
                {look.map((g) => (
                  <li key={g.id}>
                    <Tag level={guestLevel(g)} /> <span className="mono">{g.module ?? g.id}</span> {guestWords(g, now)}
                  </li>
                ))}
              </ul>
            </>
          ) : null}
        </>
      ) : null}
    </Section>
  );
}

function guestWords(g: GuestRuns, now: number): string {
  const parts: string[] = [];
  if (g.snapshots === 0) parts.push(`never backed up, though the ${g.bucket ?? ""} job has it`);
  else if (g.outcome === "late") parts.push(`last backed up ${ago(g.lastBackup, now)}, later than its ${g.bucket ?? "job's"} schedule`);
  if (g.latestVerify === "failed") parts.push("its newest backup failed its verify");
  else if (g.failedVerifies > 0) parts.push(`${g.failedVerifies} older backup${g.failedVerifies === 1 ? "" : "s"} failed verify`);
  return parts.join("; ");
}

function Overview({ p, runs }: { p: Record<string, unknown>[]; runs: Read<BackupRuns> }) {
  const site = useRead<SiteRead>("site");
  const health = useRead<Health>("health");
  const topo = useRead<Topology>("topology");
  const b = (site.env?.data?.site as { backup?: { target?: string | null; defaultSchedule?: string | null } | null } | undefined)?.backup;
  const gates = health.env?.data?.gates ?? [];
  const status = gates.find((g) => g.name === "backup-status");
  const pulse = gates.find((g) => g.name === "pulse");
  const outside = topo.env?.data?.outside ?? [];
  const sats = outside.filter((o) => o.kind === "satellite");
  return (
    <div className="grid2 backup-overview">
      <Section
        title="Site backup"
        aside={<OperateButton label="Modify…" title="The site's backup" steps={() => [fieldsStep({ title: "site-manager site modify (backup)", bin: "site-manager", verb: "site modify", kind: "site", name: null, mode: "modify", fields: ["backup"], note: "The site's backup target (the PBS server) and the schedule a module takes unless its environment or its own policy says otherwise." })]} />}
      >
        <ReadState env={site.env} failure={site.failure} what="site" />
        {b === null || b === undefined ? (
          <p className="muted">No backup configured for the site yet.</p>
        ) : (
          <KV rows={[["target", b.target ?? "not set"], ["default schedule", b.defaultSchedule ?? "not set"]]} />
        )}
      </Section>
      <Section title="Health" aside={`health-manager validate · ${since(health.env?.at)}`}>
        {status ? (
          <p>
            <Tag level={level(status.status)} /> <b>backup-status</b> {status.detail}
          </p>
        ) : (
          <p className="muted">{health.env ? "no backup-status gate in the last validate" : "reading the health…"}</p>
        )}
        {status?.findings.length ? (
          <ul className="findings">
            {status.findings.map((f, i) => (
              <li key={i}>
                <Tag level={level(f.status)} /> {f.subject?.name ?? ""} {f.text}
              </li>
            ))}
          </ul>
        ) : null}
        {pulse ? (
          <>
            <h3>The pulse</h3>
            <p className="muted small">What the backup node watches: {pulse.detail}</p>
            <ul className="findings">
              {pulse.findings.map((f, i) => (
                <li key={i}>
                  <Tag level={level(f.status)} /> {f.text}
                </li>
              ))}
            </ul>
          </>
        ) : null}
      </Section>
      <LastRuns runs={runs} />
      <Section title="Buddies and the satellite" aside="backup-manager peers · the topology">
        <table className="table compact">
          <tbody>
            {p.map((x, i) => {
              const o = outside.find((y) => y.kind === "buddy" && y.name === x.name);
              // The location the buddy names (site-manager's), its place as the title;
              // a peer not yet migrated shows its own place.
              const place = (x.place ?? x.physicalLocation) as { address?: string; city?: string; country?: string } | undefined;
              const placeLine = [place?.address, place?.city, place?.country].filter(Boolean).join(", ");
              const where = typeof x.location === "string" ? x.location : placeLine;
              return (
                <tr key={i}>
                  <td><Tag level={o?.state === "down" ? "warn" : o?.state === "up" ? "pass" : "skip"} /></td>
                  <td className="mono" title={x.tunnel ? `tunnel ${String(x.tunnel)}` : undefined}>{String(x.name ?? "")}</td>
                  <td>{String(x.role ?? "")}</td>
                  <td className="muted" title={placeLine || undefined}>{where || String(x.remoteHost ?? "")}</td>
                  <td className="muted">{o?.state ?? "state unknown"}</td>
                </tr>
              );
            })}
            {p.length === 0 ? <tr><td className="muted">no backup buddy (Setup › Day 2: Add a backup buddy)</td></tr> : null}
            {sats.map((sat) => (
              <tr key={sat.name}>
                <td><Tag level={sat.state === "down" ? "warn" : sat.state === "up" ? "pass" : "skip"} /></td>
                <td className="mono" title={sat.tunnel ? `tunnel ${sat.tunnel}` : undefined}>{sat.name}</td>
                <td>satellite</td>
                <td className="muted">{sat.location ?? ""}</td>
                <td className="muted">{sat.state ?? "state unknown"}</td>
              </tr>
            ))}
            {sats.length === 0 ? <tr><td className="muted" colSpan={5}>no satellite installed (Setup › Day 2: Add a satellite)</td></tr> : null}
          </tbody>
        </table>
      </Section>
    </div>
  );
}

export function Backup() {
  const list = useRead<BackupRowView[]>("backup");
  const peers = useRead<{ peers: Record<string, unknown>[] | null }>("pulse");
  const runs = useRead<BackupRuns>("backup-runs");
  const mine = byModule(runs.env?.data ?? null);
  const now = nowSec();
  const rows = list.env?.data ?? [];
  const p = peers.env?.data?.peers ?? [];
  return (
    <div className="page">
      <div className="page-head">
        <h1>Backup</h1>
        <span className="muted">backup-manager · read {since(list.env?.at)}</span>
        <span className="spacer" />
        <span className="toolbar">
          <OperateButton label="Pulse" title="backup-manager pulse" steps={[bm("backup-manager pulse", "pulse")]} />
          <OperateButton label="All restore points" title="backup-manager restore list-all" steps={[bm("backup-manager restore list-all", "restore list-all")]} />
          <OperateButton label="Placement" title="backup-manager placement" steps={[bm("backup-manager placement", "placement")]} />
          <OperateButton label="Reconcile the PBS job…" kind="primary" title="backup-manager reconcile" steps={[bm("backup-manager reconcile", "reconcile", { note: "The preview is the PBS job's plan; apply rewires it." })]} />
        </span>
      </div>
      <Overview p={p} runs={runs} />
      <Section title="Modules" aside="backup-manager list">
        <ReadState env={list.env} failure={list.failure} what="backup list" />
        <table className="table compact">
          <thead>
            <tr><th>module</th><th>backup</th><th>in the PBS job</th><th>schedule</th><th>retention</th><th>last backup</th><th>verified</th><th /></tr>
          </thead>
          <tbody>
            {rows.map((b) => (
              <tr key={b.module}>
                <td className="mono">{b.module}</td>
                <td><Tag level={b.enabled ? "pass" : "skip"} /> {b.enabled ? "enabled" : "disabled"}{b.archived ? " · archived" : ""}</td>
                <td>{b.inPbsJob ? "yes" : "no"}</td>
                <td>{b.schedule ?? ""}</td>
                <td>{b.retention ?? ""}</td>
                <LastCells g={mine.get(b.module)} now={now} />
                <td className="toolbar">
                  <OperateButton label="Show" title={`backup-manager show ${b.module}`} steps={[bm(`backup-manager show ${b.module}`, "show", { fixed: [b.module] })]} />
                  <OperateButton label="Coverage" title={`backup-manager coverage ${b.module}`} steps={[bm(`backup-manager coverage ${b.module}`, "coverage", { fixed: [b.module] })]} />
                  <OperateButton label="Restore points" title={`backup-manager restore list ${b.module}`} steps={[bm(`backup-manager restore list ${b.module}`, "restore list", { fixed: [b.module] })]} />
                  <OperateButton label="Modify…" title={`Modify ${b.module}'s backup`} steps={() => [fieldsStep({ title: `backup-manager modify ${b.module}`, bin: "backup-manager", verb: "modify", fixed: [b.module], kind: "backup", name: b.module, mode: "modify", note: "An empty field takes what the environment or the site sets." })]} />
                  <OperateButton
                    label="Purge…"
                    kind="danger"
                    title={`Purge ${b.module}'s backups`}
                    steps={[bm(`backup-manager purge ${b.module}`, "purge", { fixed: [b.module], initial: { "--yes": true }, note: "Deletes every backup of the module from PBS. Not undone by anything; the typed name is the confirmation." })]}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
      <Section title="Off-site peers" aside="backup-manager peers">
        <ReadState env={peers.env} failure={peers.failure} what="peers" />
        <table className="table compact">
          <tbody>
            {p.map((x, i) => (
              <tr key={i}>
                <td className="mono">{String(x.name ?? "")}</td>
                <td>{String(x.role ?? "")}</td>
                <td className="muted">{String(x.location ?? x.host ?? "")}</td>
                <td className="toolbar">
                  {x.role === "pull" || x.role === "remote" ? (
                    <OperateButton label="Check" title={`backup-manager peer check ${x.role} ${x.name}`} steps={[bm(`backup-manager peer check ${x.role} ${x.name}`, "peer check", { fixed: [String(x.role), String(x.name)] })]} />
                  ) : null}
                </td>
              </tr>
            ))}
            {p.length === 0 ? <tr><td className="muted">no off-site peer</td></tr> : null}
          </tbody>
        </table>
      </Section>
    </div>
  );
}

// A module's last backup and its verify, in the Modules table.
function LastCells({ g, now }: { g: GuestRuns | undefined; now: number }) {
  if (!g) return <><td className="muted">—</td><td className="muted">—</td></>;
  return (
    <>
      <td title={at(g.lastBackup)}><Tag level={guestLevel(g)} /> {ago(g.lastBackup, now)}</td>
      <td title={g.lastVerify ? `last verify ${at(g.lastVerify.time)}` : undefined}>
        <Tag level={g.latestVerify === "unverified" ? (g.lastVerify ? "skip" : "warn") : verifyLevel({ time: null, state: g.latestVerify })} /> {g.latestVerify === "unverified" ? (g.lastVerify ? `not yet (${g.lastVerify.state} ${ago(g.lastVerify.time, now)})` : "never") : `${g.latestVerify} · ${ago(g.lastVerify?.time, now)}`}
      </td>
    </>
  );
}
