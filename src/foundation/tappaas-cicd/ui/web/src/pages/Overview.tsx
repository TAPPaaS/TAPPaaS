// Overview — the site's health at a glance (ADR-034 U1, mockup ui-01): the strip
// of what an operator checks in the morning, Attention (every FAIL and WARN,
// read-only in P1, each with where to look), the nodes and the zones.

import { ReactNode } from "react";
import { useHealthSummary, useRead } from "../api";
import { AskAbout } from "../assistant";
import { zoneColor } from "../colors";
import { Gate, Health, HealthStatus, HealthSummary, ModuleSummary, SiteRead, Topology } from "../types";
import { Badge, Link, OpenIn, ReadState, Section, Tag, levelOf, since, when } from "../ui";

function count(h: Health | null | undefined) {
  const c = { fail: 0, warn: 0, pass: 0, skip: 0 };
  for (const g of h?.gates ?? []) c[g.status]++;
  return c;
}

function Card({ title, value, sub, level }: { title: ReactNode; value: string; sub?: string; level: string }) {
  return (
    <div className={`card card-${levelOf(level)}`}>
      <div className="card-title">{title}</div>
      <div className="card-value">{value}</div>
      {sub ? <div className="card-sub">{sub}</div> : null}
    </div>
  );
}

const CONDITION_LEVEL: Record<HealthStatus, string> = { critical: "fail", warning: "warn", ok: "pass", unknown: "unknown" };

// The health line from the worst conditions (ADR-041), the gates' otherwise.
function conditionLine(s: HealthSummary): { value: string; sub: string; level: string } {
  const c = s.counts;
  const roots = s.roots.filter((r) => !r.acknowledged).length;
  return {
    value: `${c.critical} critical · ${c.warning} warning · ${c.ok} ok`,
    sub: `${roots} root cause${roots === 1 ? "" : "s"} · ${c.acknowledged} silenced · ${c.unknown} unknown`,
    level: c.critical ? "fail" : c.warning ? "warn" : "pass",
  };
}

// Where Attention points: the page inside the console, then the component UIs.
function Where({ kind, name }: { kind: string; name: string }) {
  if (kind === "module") {
    return (
      <>
        <Link to={`/modules/${encodeURIComponent(name)}`} className="jump jump-in">module {name}</Link>
        <OpenIn kind="module" id={name} compact />
      </>
    );
  }
  if (kind === "node") {
    return (
      <>
        <Link to={`/site/device?select=node:${encodeURIComponent(name)}`} className="jump jump-in">Device · {name}</Link>
        <OpenIn kind="node" id={name} compact />
      </>
    );
  }
  if (kind === "peer") return <Link to={`/site/device?select=outside:${encodeURIComponent(name)}`} className="jump jump-in">Device · buddy {name}</Link>;
  return null;
}

export function Overview({ setupIncomplete = false }: { setupIncomplete?: boolean }) {
  const health = useRead<Health>("health");
  const site = useRead<SiteRead>("site");
  const mods = useRead<ModuleSummary[]>("modules");
  const topo = useRead<Topology>("topology");
  const h = health.env?.data;
  const c = count(h);
  const gate = (n: string): Gate | undefined => h?.gates.find((g) => g.name === n);
  const pulse = gate("pulse");
  const backup = gate("backup-status");
  const cve = gate("cve-status");
  const sweep = site.env?.data?.lastSweep;
  const s = site.env?.data?.site;
  const t = topo.env?.data;
  const memFor = (node: string) => gate("memory-commitment")?.findings.find((f) => f.subject?.kind === "node" && f.subject.name === node);
  const pulseUp = pulse?.findings.filter((f) => f.status === "pass").length ?? 0;
  const modules = mods.env?.data ?? [];
  const hs = useHealthSummary().env?.data;
  const conditions = hs?.available ? hs : null;
  const line = conditions ? conditionLine(conditions) : null;
  const backups = conditions?.byType.backup;

  return (
    <div className="page">
      <div className="page-head">
        <h1>Overview</h1>
        <span className="muted">
          site {s?.name ?? "…"} · {t?.nodes.length ?? "…"} nodes · {modules.length || "…"} modules · health read {since(health.env?.at)}
        </span>
      </div>
      {setupIncomplete ? (
        <p className="readstate readstate-warn">
          The site's setup is not finished. <Link to="/setup/day1">Continue in the Day 1 setup wizard</Link>
        </p>
      ) : null}
      <ReadState env={health.env} failure={health.failure} what="health (health-manager validate)" />

      <div className="strip">
        <Card
          title={<Link to="/health">{line ? "Health" : "Health gates"}</Link>}
          value={line?.value ?? (h ? `${c.fail} FAIL · ${c.warn} WARN · ${c.pass} PASS` : "…")}
          sub={line?.sub ?? (h ? `${c.skip} skipped · validate ${since(h.generated)}` : undefined)}
          level={line?.level ?? (c.fail ? "fail" : c.warn ? "warn" : h ? "pass" : "unknown")}
        />
        <Card
          title="Pulse"
          value={pulse ? `${pulseUp} of ${pulse.findings.length} targets up` : "…"}
          sub={pulse?.detail}
          level={pulse?.status ?? "unknown"}
        />
        <Card
          title="Last sweep"
          value={sweep ? `${when(sweep.end_time?.replace(" ", "T"))} · ${sweep.ok ? "succeeded" : "failed"}` : "…"}
          sub={sweep ? `${sweep.total ?? "?"} modules · ${sweep.failed ?? 0} failed · reboot ${sweep.reboot ?? "?"}` : undefined}
          level={sweep ? (sweep.ok ? "pass" : "fail") : "unknown"}
        />
        <Card
          title="Backups"
          value={backups?.items.length ? `${backups.items.length} object${backups.items.length === 1 ? "" : "s"} not protected` : backup ? backup.detail : "…"}
          sub={(t?.outside ?? []).filter((o) => o.kind === "buddy").map((o) => `buddy ${o.name}: ${o.state ?? "?"}`).join(" · ") || undefined}
          level={conditions ? CONDITION_LEVEL[backups?.status ?? "ok"] : backup?.status ?? "unknown"}
        />
        <Card
          title="Release"
          value={s?.channel ? `channel ${s.channel}` : "…"}
          sub={(site.env?.data?.repositories ?? []).map((r) => `${r.name} ${r.branch ?? ""}`).join(" · ") || undefined}
          level="pass"
        />
        <Card
          title="Security"
          value={cve ? cve.detail.split(" — ")[0] : "…"}
          sub={cve ? `${cve.findings.length} to act on · SIEM: not installed` : undefined}
          level={cve?.status ?? "unknown"}
        />
      </div>

      <Section title="Attention — what needs a person" aside={conditions ? <>{conditions.attention.length} item(s) · <Link to="/health">the Health view</Link></> : h ? `${h.attention.length} item(s) · read-only in this phase` : undefined}>
        {(conditions ? conditions.attention.length === 0 : h?.attention.length === 0) ? <p className="muted">Nothing needs a person.</p> : null}
        <ul className="attention">
          {(conditions?.attention ?? []).map((a) => (
            <li key={`${a.id}-${a.type}`} className={`att att-${CONDITION_LEVEL[a.status]}`}>
              <Tag level={CONDITION_LEVEL[a.status]} />
              <span className="att-gate">{a.root ? "root cause" : a.type}</span>
              <span className="att-text"><b>{a.label}</b> {a.text}</span>
              <span className="att-where">
                <Link to={`/health?select=${encodeURIComponent(a.id)}`} className="jump jump-in">Health · {a.label}</Link>
                {a.module ? <Where kind="module" name={a.module} /> : null}
              </span>
            </li>
          ))}
          {(conditions ? [] : h?.attention ?? []).map((a, i) => (
            <li key={`${a.gate}-${i}`} className={`att att-${a.level}`}>
              <Tag level={a.level} />
              <span className="att-gate">{a.gate}</span>
              <span className="att-text">
                {a.subject && a.subject.kind !== "site" ? <b>{a.subject.name}</b> : null}{" "}
                {a.subject && a.text.startsWith(a.subject.name) ? a.text.slice(a.subject.name.length).trim() : a.text}
              </span>
              <span className="att-where">
                {a.subject ? <Where kind={a.subject.kind} name={a.subject.name} /> : null}
                <AskAbout
                  question={`Why does ${a.subject && a.subject.kind !== "site" ? `${a.subject.name}` : "the site"} ${a.level === "fail" ? "fail" : "warn on"} the ${a.gate} gate, and what should I do about it?`}
                  focus={{ page: "overview", kind: "finding", name: a.subject?.name ?? a.gate, detail: `${a.gate} ${a.level}: ${a.text}` }}
                >
                  ✦ Ask
                </AskAbout>
              </span>
            </li>
          ))}
        </ul>
      </Section>

      <div className="two">
        <Section title="Nodes" aside="site.json · node network show · validate">
          <ReadState env={topo.env} failure={topo.failure} what="topology" />
          <ul className="nodes-list">
            {(t?.nodes ?? []).map((n) => {
              const lan = n.uplinks.find((u) => u.name === "lan");
              const mem = memFor(n.name);
              const findings = conditions ? conditions.attention.filter((a) => a.class === "machine" && a.label === n.name) : t?.findings.filter((f) => f.on.kind === "node" && f.on.name === n.name) ?? [];
              return (
                <li key={n.name}>
                  <Link to={`/site/device?select=node:${encodeURIComponent(n.name)}`} className="node-name">{n.name}</Link>
                  {findings.length ? <Badge level="warn">⚠ {findings.length}</Badge> : null}
                  <div className="muted">
                    {mem ? `${mem.text} · ` : ""}
                    {n.guests.filter((g) => g.vmid !== null).length} guests
                    {n.roles.length ? ` · ${n.roles.join(", ")}` : ""}
                    {lan ? ` · lan ${lan.mode} ${lan.legs.length}×${lan.legs[0]?.speed ?? "?"}` : ""}
                  </div>
                </li>
              );
            })}
          </ul>
        </Section>
        <Section title="Zones" aside="zones.json">
          <div className="zones">
            {(t?.zones ?? [])
              .filter((z) => z.vlan && z.vlan > 0)
              .sort((a, b) => (a.vlan ?? 0) - (b.vlan ?? 0))
              .map((z) => (
                <span key={z.name} className={`zone ${z.state === "Active" || z.state === "Mandatory" || z.state === "Manual" ? "" : "zone-off"}`} title={`${z.type ?? ""} · ${z.state ?? ""}`}>
                  <i style={{ background: zoneColor(z) }} />
                  {z.name} {z.vlan}
                  {z.state && !["Active", "Mandatory", "Manual"].includes(z.state) ? ` · ${z.state.toLowerCase()}` : ""}
                </span>
              ))}
          </div>
          <p className="muted small">
            untagged: {(t?.zones ?? []).filter((z) => !z.vlan).map((z) => z.name).join(", ")}
          </p>
        </Section>
      </div>
    </div>
  );
}
