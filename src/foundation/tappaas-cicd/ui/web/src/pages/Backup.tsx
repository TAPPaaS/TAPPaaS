// Backup — what backup-manager knows (spike §5.2, Appendix A): every module's
// policy and whether the PBS job has it, the off-site peers and the pulse, and
// per module show / coverage / restore list (reads that run at once), modify
// (a job with its preview) and purge (destructive: the name typed, Installer;
// never a side effect of a module's delete).

import { useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { BackupRowView } from "../types";
import { ReadState, Section, Tag, since } from "../ui";

const bm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "backup-manager", verb, ...extra });

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
                  <OperateButton label="Modify…" title={`Modify ${b.module}'s backup`} steps={[bm(`backup-manager modify ${b.module}`, "modify", { fixed: [b.module] })]} />
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
