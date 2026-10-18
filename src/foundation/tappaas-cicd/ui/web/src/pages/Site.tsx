// Site — two tabs. Overview: site.json, the nodes, the repositories, the update
// schedule and the release (spike §5.2, Appendix A): site-manager site show /
// modify, node list and node network show / set, Add node (a guided sequence),
// repository hold / release / sync, `site update` (Update now: the sweep's plan
// first, then the sweep), and the release train's preview (tappaas-train.sh
// preview, text: it has no --json). Physical: the site as cabled (/site/physical).

import { useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { fieldsStep } from "../fields";
import { SiteRead } from "../types";
import { KV, ReadState, Section, navigate, since } from "../ui";
import { AddNodeButton } from "./AddNode";
import { Physical } from "./Physical";

const sm = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "site-manager", verb, ...extra });

interface Repo {
  name: string;
  url?: string;
  branch?: string;
  path?: string;
  managed?: string;
  hold?: { reason?: string; until?: string } | null;
}

const SCHEDULE_FIELDS = ["updateSchedule.frequency", "updateSchedule.weekday", "updateSchedule.hour"];

export const SITE_TABS = [
  { name: "Overview", path: "/site" },
  { name: "Physical", path: "/site/physical" },
] as const;

export function Site({ tab = "Overview" }: { tab?: "Overview" | "Physical" }) {
  const r = useRead<SiteRead>("site");
  const d = r.env?.data;
  const s = (d?.site ?? {}) as Record<string, unknown> & { updateSchedule?: { frequency?: string; weekday?: string; hour?: number } };
  const sched = s.updateSchedule;
  const repos = (d?.repositories ?? []) as Repo[];
  const last = d?.lastSweep;
  const tabs = (
    <div className="tabs" role="tablist">
      {SITE_TABS.map((t) => (
        <button key={t.name} role="tab" aria-selected={tab === t.name} className={tab === t.name ? "tab tab-on" : "tab"} onClick={() => navigate(t.path)}>
          {t.name}
        </button>
      ))}
    </div>
  );
  if (tab === "Physical") {
    return (
      <div className="page page-wide">
        <div className="page-head">
          <h1>Site</h1>
          <span className="muted">{s.displayName ? String(s.displayName) : String(s.name ?? "")} as cabled</span>
        </div>
        {tabs}
        <Physical embedded />
      </div>
    );
  }
  return (
    <div className="page">
      <div className="page-head">
        <h1>Site</h1>
        <span className="muted">site-manager · read {since(r.env?.at)}</span>
        <span className="spacer" />
        <OperateButton
          label="Update now…"
          kind="primary"
          title="site-manager update"
          steps={[
            sm("site-manager update — the whole-site sweep, now", "update", {
              hide: ["--no-git-pull"],
              note: "The preview is the sweep's plan (update-tappaas --dry-run): nothing starts. Apply starts update-tappaas.service; while it runs the console starts no job, and its journal lands in Activity.",
            }),
          ]}
        />
      </div>
      {tabs}
      <ReadState env={r.env} failure={r.failure} what="site" />
      <div className="grid2">
        <Section title="site.json" aside={<OperateButton label="Modify…" title="site-manager site modify" steps={() => [fieldsStep({ title: "site-manager site modify", bin: "site-manager", verb: "site modify", kind: "site", name: null, mode: "modify", note: "Writes site.json: one modify for every field changed." })]} />}>
          <KV
            rows={[
              ["name", String(s.name ?? "")],
              ["display name", String(s.displayName ?? "")],
              ["channel", String(s.channel ?? "")],
              ["default environment", String(s.defaultEnvironment ?? "")],
              ["owner", String(s.owner ?? "")],
              ["email", String(s.email ?? "")],
              ["automatic reboot", String(s.automaticReboot ?? "")],
              ["snapshots kept", String(s.snapshotRetention ?? "")],
            ]}
          />
        </Section>
        <Section
          title="Update schedule"
          aside={<OperateButton label="Change…" title="The update schedule" steps={() => [fieldsStep({ title: "site-manager site modify (the schedule)", bin: "site-manager", verb: "site modify", kind: "site", name: null, mode: "modify", fields: SCHEDULE_FIELDS })]} />}
        >
          <KV
            rows={[
              ["frequency", sched?.frequency ?? ""],
              ["weekday", sched?.weekday ?? ""],
              ["hour", sched?.hour !== undefined ? `${sched.hour}:00` : ""],
              ["last sweep", last ? `${last.end_time ?? "?"} · ${last.succeeded ?? "?"} of ${last.total ?? "?"} ${last.ok ? "ok" : "with failures"}` : ""],
            ]}
          />
          <div className="toolbar">
            <OperateButton label="Release train: preview" title="tappaas-train.sh preview" steps={[{ title: "tappaas-train.sh preview — the last release against 'if released now'", bin: "tappaas-train.sh", verb: "preview", note: "Nothing built, nothing moved; it writes config/train-preview.json. Text output: the train has no --json yet." }]} />
            <OperateButton label="Release train: status" title="tappaas-train.sh status" steps={[{ title: "tappaas-train.sh status", bin: "tappaas-train.sh", verb: "status" }]} />
          </div>
        </Section>
      </div>
      <Section
        title="Nodes"
        aside={
          <span className="toolbar">
            <AddNodeButton />
            <OperateButton label="Register joined nodes…" title="site-manager node reconcile" steps={[sm("site-manager node reconcile", "node reconcile")]} />
          </span>
        }
      >
        <table className="table compact">
          <thead>
            <tr><th>node</th><th>storage pools</th><th /></tr>
          </thead>
          <tbody>
            {(d?.nodes ?? []).map((n) => (
              <tr key={n.name}>
                <td className="mono">{n.name}</td>
                <td>{(n.storagePools ?? []).join(", ")}</td>
                <td className="toolbar">
                  <OperateButton label="Network: show" title={`${n.name} — uplinks`} steps={[sm(`site-manager node network show ${n.name}`, "node network show", { fixed: [n.name] })]} />
                  <OperateButton label="Network: set…" title={`${n.name} — set the uplinks`} steps={[sm(`site-manager node network set ${n.name}`, "node network set", { fixed: [n.name], note: "The preview (without --apply) declares the uplink in config/<node>.json and previews it on the node; apply drains the node and moves lan under a 45 s rollback." })]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
      <Section title="Repositories" aside={<OperateButton label="Reconcile…" title="site-manager repository reconcile" steps={[sm("site-manager repository reconcile", "repository reconcile")]} />}>
        <table className="table compact">
          <thead>
            <tr><th>repository</th><th>branch</th><th>managed</th><th>hold</th><th /></tr>
          </thead>
          <tbody>
            {repos.map((x) => (
              <tr key={x.name}>
                <td className="mono" title={x.url}>{x.name}</td>
                <td className="mono">{x.branch ?? ""}</td>
                <td>{x.managed ?? ""}</td>
                <td>{x.hold ? `held${x.hold.until ? ` until ${x.hold.until}` : ""}${x.hold.reason ? ` — ${x.hold.reason}` : ""}` : ""}</td>
                <td className="toolbar">
                  <OperateButton label="Sync…" title={`site-manager repository sync ${x.name}`} steps={[sm(`site-manager repository sync ${x.name}`, "repository sync", { fixed: [x.name], note: "The preview (--dry-run) reports the commits, any pending migration and the modules it would move." })]} />
                  {x.hold ? (
                    <OperateButton label="Release" title={`site-manager repository release ${x.name}`} steps={[sm(`site-manager repository release ${x.name}`, "repository release", { fixed: [x.name] })]} />
                  ) : (
                    <OperateButton label="Hold…" title={`site-manager repository hold ${x.name}`} steps={[sm(`site-manager repository hold ${x.name}`, "repository hold", { fixed: [x.name] })]} />
                  )}
                  <OperateButton label="Stashes" title={`site-manager repository stash list ${x.name}`} steps={[{ ...sm(`site-manager repository stash list ${x.name}`, "repository stash"), words: ["repository", "stash", "list"], fixed: [x.name] }]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
    </div>
  );
}
