// Overview — the site at a glance: four tiles, one per area (Site, Environment,
// Modules, Identity), each summed up from what that area's page reads and
// coloured by the worst condition of the area's objects; below them Health
// (the health line and the gates an operator checks in the morning), and the
// Alerts, the ten open events that matter most. The shaping is overview.ts.

import { SecurityView, securityTile } from "../security";
import { ReactNode, useMemo } from "react";
import { useHealthSummary, useRead } from "../api";
import { ZoneLike } from "../envcards";
import { locationHref } from "../locations";
import { Alerts, bytes, environmentTile, identityTile, modulesTile, siteTile, topAlerts } from "../overview";
import { Activity, Envelope, EnvironmentRow, Health, HealthStatus, HealthSummary, JobSummary, ModuleSummary, Operations, SiteRead, StorageInventory, Topology } from "../types";
import { Badge, Dot, Link, ReadState, Tag, levelOf, since, when } from "../ui";

const CONDITION_LEVEL: Record<HealthStatus, string> = { critical: "fail", warning: "warn", ok: "pass", unknown: "unknown" };
const lvl = (s: HealthStatus) => levelOf(CONDITION_LEVEL[s]);

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

// An area's tile: its header links to the area's page; the colour is its worst.
function Tile({ title, to, status, aside, children }: { title: string; to: string; status: HealthStatus; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className={`ov-tile card-${lvl(status)}`}>
      <header className="ov-tile-head">
        <Dot level={lvl(status)} title={status} />
        <h2><Link to={to}>{title}</Link></h2>
        {aside ? <span className="section-aside">{aside}</span> : null}
      </header>
      {children}
    </section>
  );
}

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

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

export function Overview({ setupIncomplete = false }: { setupIncomplete?: boolean }) {
  const health = useRead<Health>("health");
  const site = useRead<SiteRead>("site");
  const storage = useRead<StorageInventory>("storage");
  const envs = useRead<EnvironmentRow[]>("environments");
  const zones = useRead<ZoneLike[]>("zones");
  const mods = useRead<ModuleSummary[]>("modules");
  const identity = useRead<Record<string, string[]>>("identity");
  const activity = useRead<Activity>("activity");
  const topo = useRead<Topology>("topology");
  const ops = useRead<Operations>("operations");
  const hs = useHealthSummary().env?.data;
  const summary = hs?.available ? hs : null;

  const h = health.env?.data;
  const c = count(h);
  const gate = (n: string) => h?.gates.find((g) => g.name === n);
  const backup = gate("backup-status");
  const sec = useRead<SecurityView>("security", 300_000);
  const secT = securityTile(sec.env?.data);
  const sd = site.env?.data;
  const s = sd?.site;
  const sweep = sd?.lastSweep;
  const t = topo.env?.data;
  const line = summary ? conditionLine(summary) : null;
  const backups = summary?.byType.backup;
  const def = ((s ?? {}) as { defaultEnvironment?: string }).defaultEnvironment ?? null;

  const siteT = useMemo(() => siteTile(sd, storage.env?.data, h?.gates, hs), [sd, storage.env, h, hs]);
  const envT = useMemo(() => environmentTile(envs.env?.data, zones.env?.data, mods.env?.data, def, hs), [envs.env, zones.env, mods.env, def, hs]);
  const modT = useMemo(() => {
    const jobs = (activity.env as (Envelope<Activity> & { jobs?: JobSummary[] }) | null)?.jobs ?? [];
    return modulesTile(mods.env?.data, jobs, activity.env?.data?.sweepActive ?? false, sweep, hs);
  }, [mods.env, activity.env, sweep, hs]);
  const idT = useMemo(() => identityTile(identity.env?.data, mods.env?.data, hs), [identity.env, mods.env, hs]);
  const alerts = useMemo(() => topAlerts(ops.env?.data), [ops.env]);

  return (
    <div className="page">
      <div className="page-head">
        <h1>Overview</h1>
        <span className="muted">site {siteT.name ?? "…"} · health read {since(summary?.generated ?? health.env?.at)}</span>
      </div>
      {setupIncomplete ? (
        <p className="readstate readstate-warn">
          The site's setup is not finished. <Link to="/setup/day1">Continue in the Day 1 setup wizard</Link>
        </p>
      ) : null}

      <div className="ov-grid">
        <Tile title="Site" to="/site" status={siteT.status} aside={siteT.name ?? undefined}>
          <ReadState env={site.env} failure={site.failure} what="site" />
          <p className="small">
            {siteT.locations.length
              ? siteT.locations.map((l, i) => (
                  <span key={l.name}>
                    {i ? " · " : ""}
                    <Link to={locationHref(l.name)}>{l.label}</Link>
                    {l.primary ? <span className="muted"> (primary)</span> : null}
                  </span>
                ))
              : <span className="muted">no location recorded</span>}
          </p>
          <ul className="ov-list">
            {siteT.nodes.map((n) => (
              <li key={n.name}>
                <Dot level={lvl(n.status)} title={n.status} />
                <Link to={`/site/devices?select=node:${encodeURIComponent(n.name)}`} className="mono">{n.name}</Link>
                <span className="muted small">{[n.text, n.location].filter(Boolean).join(" · ")}</span>
              </li>
            ))}
            {sd && siteT.nodes.length === 0 ? <li className="muted">No node is registered yet.</li> : null}
          </ul>
          <p className="small">
            {siteT.quorum ? (
              <>
                <Dot level={lvl(siteT.quorum.status)} /> quorum: {siteT.quorum.text}
              </>
            ) : (
              <span className="muted">quorum: not judged</span>
            )}
            {" · "}
            {siteT.storage ? (
              <Link to="/site/storage">
                storage {bytes(siteT.storage.used)} of {bytes(siteT.storage.total)} used ({siteT.storage.total ? Math.round((siteT.storage.used / siteT.storage.total) * 100) : 0}%, {plural(siteT.storage.pools, "pool")})
              </Link>
            ) : (
              <span className="muted">storage {storage.env ? "not read" : "…"}</span>
            )}
          </p>
        </Tile>

        <Tile title="Environment" to="/environments" status={envT.status} aside={plural(envT.envs.length, "environment")}>
          <ReadState env={envs.env} failure={envs.failure} what="environments" />
          <table className="table compact">
            <thead>
              <tr><th /><th>environment</th><th>zone</th><th>maturity</th><th>modules</th></tr>
            </thead>
            <tbody>
              {envT.envs.map((e) => (
                <tr key={e.name}>
                  <td><Dot level={lvl(e.status)} title={`its modules: ${e.status}`} /></td>
                  <td>
                    <Link to={`/environments?env=${encodeURIComponent(e.name)}`}>{e.label}</Link>
                    {e.isDefault ? <span className="muted small"> default</span> : null}
                  </td>
                  <td className="mono">{e.zone ?? <span className="muted">none</span>}</td>
                  <td className="small">{e.maturity.map((m) => `${m.count} ${m.word}`).join(" · ") || <span className="muted">—</span>}</td>
                  <td>{e.modules}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Tile>

        <Tile title="Modules" to="/modules" status={modT.status} aside={plural(modT.total, "module")}>
          <ReadState env={mods.env} failure={mods.failure} what="modules" />
          <p>
            <b>{modT.running}</b> running · <b>{modT.stopped}</b> stopped · <b>{modT.updating}</b> updating · <b>{modT.archived}</b> archived
            {modT.noGuest ? <span className="muted small"> · {modT.noGuest} without a guest of their own</span> : null}
          </p>
          {modT.sweepActive ? <p className="small readstate readstate-warn">A sweep is running now (update-tappaas).</p> : null}
          <h3>Last updates</h3>
          <ul className="ov-list">
            {modT.lastUpdates.map((u, i) => (
              <li key={`${u.what}-${i}`}>
                <Dot level={u.ok ? "pass" : "fail"} title={u.ok ? "succeeded" : "failed"} />
                {u.sweep ? <Link to="/activity">the sweep</Link> : <Link to={`/modules/${encodeURIComponent(u.what)}`}>{u.what}</Link>}
                <span className="muted small">{when(u.at)}</span>
              </li>
            ))}
            {modT.lastUpdates.length === 0 ? <li className="muted">No update recorded.</li> : null}
          </ul>
          <h3>Needs attention</h3>
          {modT.attention.length ? (
            <p className="ov-chips">
              {modT.attention.map((m) => (
                <Link key={m.name} to={`/modules/${encodeURIComponent(m.name)}`}>
                  <Badge level={m.level}>{m.name}</Badge>
                </Link>
              ))}
            </p>
          ) : (
            <p className="muted small">{mods.env?.data ? "Nothing." : "…"}</p>
          )}
        </Tile>

        <Tile title="Identity" to="/identity" status={idT.status}>
          <ReadState env={identity.env} failure={identity.failure} what="identity" />
          <p>
            {idT.counts ? (
              <>
                <b>{idT.counts.users}</b> users · <b>{idT.counts.groups}</b> groups · <b>{idT.counts.roles}</b> roles
                <span className="muted small"> · {plural(idT.counts.orgs, "organization")}</span>
              </>
            ) : (
              "…"
            )}
          </p>
          <p className="small">
            {idT.provider ? (
              idT.provider.installed ? (
                <>
                  <Dot level={lvl(idT.provider.health)} title={idT.provider.health} /> identity provider (
                  <Link to={`/modules/${idT.provider.module}`}>{idT.provider.module}</Link>): {idT.provider.run === "none" ? "no guest state" : idT.provider.run} · health {idT.provider.health}
                </>
              ) : (
                <>
                  <Dot level="fail" /> identity provider: the <span className="mono">{idT.provider.module}</span> module is not installed
                </>
              )
            ) : (
              "…"
            )}
          </p>
        </Tile>
      </div>

      <h2 className="ov-h">Health</h2>
      <ReadState env={health.env} failure={health.failure} what="health (health-manager validate)" />
      <div className="strip">
        <Card
          title={<Link to="/health">{line ? "Health" : "Health gates"}</Link>}
          value={line?.value ?? (h ? `${c.fail} FAIL · ${c.warn} WARN · ${c.pass} PASS` : "…")}
          sub={line?.sub ?? (h ? `${c.skip} skipped · validate ${since(h.generated)}` : undefined)}
          level={line?.level ?? (c.fail ? "fail" : c.warn ? "warn" : h ? "pass" : "unknown")}
        />
        <Card
          title="Last sweep"
          value={sweep ? `${when(sweep.end_time?.replace(" ", "T"))} · ${sweep.ok ? "succeeded" : "failed"}` : "…"}
          sub={sweep ? `${sweep.total ?? "?"} modules · ${sweep.failed ?? 0} failed · reboot ${sweep.reboot ?? "?"}` : undefined}
          level={sweep ? (sweep.ok ? "pass" : "fail") : "unknown"}
        />
        <Card
          title="Backups"
          value={backups?.items.length ? `${plural(backups.items.length, "object")} not protected` : backup ? backup.detail : "…"}
          sub={(t?.outside ?? []).filter((o) => o.kind === "buddy").map((o) => `buddy ${o.name}: ${o.state ?? "?"}`).join(" · ") || undefined}
          level={summary ? CONDITION_LEVEL[backups?.status ?? "ok"] : backup?.status ?? "unknown"}
        />
        <Card
          title="Release"
          value={s?.channel ? `channel ${s.channel}` : "…"}
          sub={(sd?.repositories ?? []).map((r) => `${r.name} ${r.branch ?? ""}`).join(" · ") || undefined}
          level="pass"
        />
        <Card
          title={<Link to="/security">Security</Link>}
          value={secT?.value ?? (sec.env ? "no scan yet" : "…")}
          sub={secT ? `${secT.sub} · SIEM: not installed` : undefined}
          level={secT?.level ?? "unknown"}
        />
      </div>

      <AlertList alerts={alerts} ops={ops.env?.data ?? null} env={ops.env} failure={ops.failure} />
    </div>
  );
}

// The ten open events that matter most, one line each; a click opens the
// event on the Operations page with its Health panel.
function AlertList({ alerts, ops, env, failure }: { alerts: Alerts; ops: Operations | null; env: Envelope<Operations> | null; failure: string | null }) {
  return (
    <>
      <h2 className="ov-h">
        Alerts <span className="muted small">{ops ? `${alerts.total} open · ${ops.counts.silenced} silenced` : ""}</span>
      </h2>
      <div className="section">
        <ReadState env={env} failure={failure} what="open events (operations)" />
        {ops && !ops.hasConditions ? (
          <p className="muted">The CMDB holds no conditions yet: the gates are on the <Link to="/health">Health</Link> page.</p>
        ) : ops && alerts.total === 0 ? (
          <p className="muted">No open events.</p>
        ) : null}
        <ul className="ov-alerts">
          {alerts.rows.map((e) => {
            const text = e.message ?? e.reason ?? e.type;
            return (
              <li key={e.id}>
                <Link to={`/operations?select=${encodeURIComponent(e.id)}`} className="ov-alert">
                  <Tag level={CONDITION_LEVEL[e.status]} />
                  <span className="mono small ov-alert-what">
                    <span className="muted">{e.class}/</span>
                    {e.label}
                  </span>
                  <span className="ov-alert-text" title={text}>{text}</span>
                  <span className="muted small nowrap">{since(e.since)}</span>
                </Link>
              </li>
            );
          })}
        </ul>
        {alerts.more > 0 ? (
          <p className="small">
            <Link to="/operations">{plural(alerts.more, "more open event")} on the Operations page</Link>
          </p>
        ) : alerts.total > 0 ? (
          <p className="small muted">
            <Link to="/operations">The Operations page</Link> groups them by root cause.
          </p>
        ) : null}
      </div>
    </>
  );
}
