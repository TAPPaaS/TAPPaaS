// Modules — every deployed module with its badges (ADR-034 D6, the catalog's
// read half): run state, health, backup, CVE and maturity, filterable.

import { useMemo, useState } from "react";
import { useRead } from "../api";
import { ModuleSummary } from "../types";
import { Badge, Dot, Link, ReadState, levelOf, since } from "../ui";

export function ModuleBadges({ m }: { m: ModuleSummary }) {
  const b = m.badges;
  return (
    <span className="badges">
      {b.health !== "unknown" ? (
        <Badge level={levelOf(b.health)} title={m.findings.filter((f) => f.gate !== "cve-status").map((f) => `${f.gate}: ${f.text}`).join("\n")}>
          health {b.health}
        </Badge>
      ) : null}
      {b.backup !== "unknown" && m.vmid !== null ? (
        <Badge level={b.backup === "covered" ? "pass" : b.backup === "not-opted" ? "skip" : "warn"}>backup {b.backup}</Badge>
      ) : null}
      {b.cve === "act" ? <Badge level="warn">CVE act</Badge> : null}
      {b.maturity ? <Badge level="info">{b.maturity}</Badge> : null}
    </span>
  );
}

const rank: Record<string, number> = { fail: 0, warn: 1, pass: 2, unknown: 3 };

export function Modules() {
  const mods = useRead<ModuleSummary[]>("modules");
  const [q, setQ] = useState("");
  const [only, setOnly] = useState<"all" | "attention">("all");
  const list = useMemo(() => {
    const all = mods.env?.data ?? [];
    return all
      .filter((m) => !q || `${m.name} ${m.stack ?? ""} ${m.environment ?? ""} ${m.zone0 ?? ""} ${m.actualNode ?? m.node ?? ""}`.toLowerCase().includes(q.toLowerCase()))
      .filter((m) => only === "all" || m.badges.health === "fail" || m.badges.health === "warn" || m.badges.cve === "act")
      .sort((a, b) => (rank[a.badges.health] ?? 3) - (rank[b.badges.health] ?? 3) || a.name.localeCompare(b.name));
  }, [mods.env, q, only]);
  const total = mods.env?.data?.length ?? 0;

  return (
    <div className="page">
      <div className="page-head">
        <h1>Modules</h1>
        <span className="muted">{total} deployed · module-manager list · read {since(mods.env?.at)}</span>
      </div>
      <ReadState env={mods.env} failure={mods.failure} what="modules (module-manager list)" />
      <div className="toolbar">
        <input className="search" placeholder="Filter by name, stack, environment, zone, node" value={q} onChange={(e) => setQ(e.target.value)} />
        <label>
          <input type="checkbox" checked={only === "attention"} onChange={(e) => setOnly(e.target.checked ? "attention" : "all")} /> needs attention
        </label>
      </div>
      <table className="table">
        <thead>
          <tr>
            <th>module</th>
            <th>kind</th>
            <th>runs on</th>
            <th>zone</th>
            <th>environment</th>
            <th>stack</th>
            <th>badges</th>
          </tr>
        </thead>
        <tbody>
          {list.map((m) => (
            <tr key={m.name}>
              <td>
                <Dot level={m.badges.run === "running" ? "pass" : m.badges.run === "stopped" ? "fail" : "skip"} title={m.badges.run} />{" "}
                <Link to={`/modules/${encodeURIComponent(m.name)}`}>{m.name}</Link>
              </td>
              <td>
                {m.kind}
                {m.vmid !== null ? <span className="muted"> {m.vmid}</span> : null}
              </td>
              <td>{m.actualNode ?? m.node ?? <span className="muted">—</span>}</td>
              <td>{m.zone0 ?? <span className="muted">—</span>}</td>
              <td>{m.environment ?? <span className="muted">—</span>}</td>
              <td>{m.stack ?? <span className="muted">—</span>}</td>
              <td>
                <ModuleBadges m={m} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
