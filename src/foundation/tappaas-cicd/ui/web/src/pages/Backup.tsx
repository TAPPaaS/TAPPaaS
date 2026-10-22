// Backup — what backup-manager knows (spike §5.2, Appendix A). On top, the
// overview: the site's backup record (site.json backup: target, default
// schedule) with its Modify, the backup health (the backup-status gate and the
// pulse's targets), and the buddies and the satellite with their state (the
// topology's outside parties). Below: every module's policy and whether the
// PBS job has it, the off-site peers, and
// per module show / coverage / restore list (reads that run at once), modify
// (a job with its preview) and purge (destructive: the name typed, Installer;
// never a side effect of a module's delete).

import { useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { fieldsStep } from "../fields";
import { BackupRowView, Health, SiteRead, Topology } from "../types";
import { KV, ReadState, Section, Tag, since } from "../ui";

const bm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "backup-manager", verb, ...extra });

// A gate's finding as a row: its level and its words.
const level = (s: string) => (s === "fail" ? "fail" : s === "warn" ? "warn" : s === "pass" ? "pass" : "skip");

function Overview({ p }: { p: Record<string, unknown>[] }) {
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
      <Section title="Buddies and the satellite" aside="backup-manager peers · the topology">
        <table className="table compact">
          <tbody>
            {p.map((x, i) => {
              const o = outside.find((y) => y.kind === "buddy" && y.name === x.name);
              const loc = x.physicalLocation as { city?: string; country?: string } | undefined;
              return (
                <tr key={i}>
                  <td><Tag level={o?.state === "down" ? "warn" : o?.state === "up" ? "pass" : "skip"} /></td>
                  <td className="mono" title={x.tunnel ? `tunnel ${String(x.tunnel)}` : undefined}>{String(x.name ?? "")}</td>
                  <td>{String(x.role ?? "")}</td>
                  <td className="muted">{[loc?.city, loc?.country].filter(Boolean).join(", ") || String(x.remoteHost ?? "")}</td>
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
      <Overview p={p} />
      <Section title="Modules" aside="backup-manager list">
        <ReadState env={list.env} failure={list.failure} what="backup list" />
        <table className="table compact">
          <thead>
            <tr><th>module</th><th>backup</th><th>in the PBS job</th><th>schedule</th><th>retention</th><th /></tr>
          </thead>
          <tbody>
            {rows.map((b) => (
              <tr key={b.module}>
                <td className="mono">{b.module}</td>
                <td><Tag level={b.enabled ? "pass" : "skip"} /> {b.enabled ? "enabled" : "disabled"}{b.archived ? " · archived" : ""}</td>
                <td>{b.inPbsJob ? "yes" : "no"}</td>
                <td>{b.schedule ?? ""}</td>
                <td>{b.retention ?? ""}</td>
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
