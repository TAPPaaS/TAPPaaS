// Modules — tabs. Installed: every deployed module with its badges (run
// state, health, backup, CVE and maturity), filterable, grouped by stack with
// foundation first (the group heads name the stack, so no column does), one
// row per module with every environment it is installed in. Then one tab per
// registered repository: every module its catalogue lists, by stack where it
// spans several (else flat, with a stack column), with its description and
// maturity, installed (with the instances) or not, and Install for every one,
// into an environment it is chosen for (module-manager add --environment,
// previewed, then applied as a job).

import { Fragment, ReactNode, useMemo, useState } from "react";
import { useRead } from "../api";
import { plainText } from "../forms";
import { ModuleGroup, defaultInstanceName, environmentsOf, freeVmid, groupInstances, installEnvironments, instanceOwners } from "../instances";
import { OperateButton } from "../operate";
import { EnvironmentRow, ModuleSummary, SiteRead } from "../types";
import { Badge, Dot, Link, ReadState, levelOf, since } from "../ui";

interface CatalogModule {
  name: string;
  stack: string | null;
  description: string | null;
  maturity: string | null;
  category: string | null;
  vmid: number | null;
  instances: string[];
}
interface RepositoryCatalog {
  name: string;
  url: string | null;
  path: string | null;
  catalog: string | null;
  error: string | null;
  modules: CatalogModule[];
}

// Stacks in the order a list shows them: foundation first, then by name, none last.
export function byStack<T>(rows: T[], stack: (r: T) => string | null): [string, T[]][] {
  const groups = new Map<string, T[]>();
  for (const r of rows) {
    const k = stack(r) ?? "";
    groups.set(k, [...(groups.get(k) ?? []), r]);
  }
  const rank = (k: string) => (k === "foundation" ? 0 : k === "" ? 2 : 1);
  return [...groups.entries()].sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b));
}

function StackRows({ stack, cols, n, children }: { stack: string; cols: number; n: number; children: ReactNode }) {
  return (
    <>
      <tr className="stack-head">
        <td colSpan={cols}>
          <b>{stack || "no stack"}</b> <span className="muted small">{n} module{n === 1 ? "" : "s"}</span>
        </td>
      </tr>
      {children}
    </>
  );
}

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
const worst = (g: ModuleGroup<ModuleSummary>) => Math.min(...g.instances.map((i) => rank[i.badges.health] ?? 3));
const uniq = (xs: (string | null)[]) => [...new Set(xs.filter((x): x is string => !!x))];

// The Installed row of a module: its instances' places side by side.
function InstalledRow({ g }: { g: ModuleGroup<ModuleSummary> }) {
  const first = g.instances[0];
  const runs = g.instances.map((i) => i.badges.run);
  const run = runs.includes("stopped") ? "fail" : runs.includes("running") ? "pass" : "skip";
  const dash = <span className="muted">—</span>;
  const nodes = uniq(g.instances.map((i) => i.actualNode ?? i.node));
  const zones = uniq(g.instances.map((i) => i.zone0));
  const vmids = g.instances.map((i) => i.vmid).filter((v): v is number => v !== null);
  return (
    <tr>
      <td>
        <Dot level={run} title={runs.join(", ")} /> <Link to={`/modules/${encodeURIComponent(first.name)}`}>{g.module}</Link>
      </td>
      <td>
        {first.kind}
        {vmids.length ? <span className="muted"> {vmids.join(", ")}</span> : null}
      </td>
      <td>{nodes.length ? nodes.join(", ") : dash}</td>
      <td>{zones.length ? zones.join(", ") : dash}</td>
      <td>
        {environmentsOf(g).map((e, n) => (
          <Fragment key={e.environment}>
            {n ? ", " : ""}
            {e.environment}
            {e.instances.length ? (
              <span className="muted">
                {" "}(
                {e.instances.map((i, k) => (
                  <Fragment key={i}>
                    {k ? ", " : ""}
                    <Link to={`/modules/${encodeURIComponent(i)}`}>{i}</Link>
                  </Fragment>
                ))}
                )
              </span>
            ) : null}
          </Fragment>
        ))}
      </td>
      <td>
        {g.instances.length === 1 ? (
          <ModuleBadges m={first} />
        ) : (
          g.instances.map((i) => (
            <div key={i.name}>
              <span className="muted small">{i.name}</span> <ModuleBadges m={i} />
            </div>
          ))
        )}
      </td>
    </tr>
  );
}

export function Modules() {
  const mods = useRead<ModuleSummary[]>("modules");
  const cats = useRead<RepositoryCatalog[]>("catalogs", 600_000);
  const envs = useRead<EnvironmentRow[]>("environments", 600_000);
  const site = useRead<SiteRead>("site", 600_000).env?.data?.site;
  const [tab, setTab] = useState("Installed");
  const repos = cats.env?.data ?? [];
  const repo = repos.find((r) => r.name === tab) ?? null;
  const [q, setQ] = useState("");
  const [only, setOnly] = useState<"all" | "attention">("all");
  const list = useMemo(() => {
    const all = mods.env?.data ?? [];
    return all
      .filter((m) => !q || `${m.name} ${m.stack ?? ""} ${m.environment ?? ""} ${m.zone0 ?? ""} ${m.actualNode ?? m.node ?? ""}`.toLowerCase().includes(q.toLowerCase()))
      .filter((m) => only === "all" || m.badges.health === "fail" || m.badges.health === "warn" || m.badges.cve === "act")
      .sort((a, b) => (rank[a.badges.health] ?? 3) - (rank[b.badges.health] ?? 3) || a.name.localeCompare(b.name));
  }, [mods.env, q, only]);
  // One row per module: the catalogues say which module an instance is.
  const groups = useMemo(() => groupInstances(list, instanceOwners(cats.env?.data ?? [])).sort((a, b) => worst(a) - worst(b) || a.module.localeCompare(b.module)), [list, cats.env]);
  const total = mods.env?.data?.length ?? 0;
  const envOf = new Map((mods.env?.data ?? []).map((m) => [m.name, m.environment]));
  const defaultEnv = (site?.defaultEnvironment as string | undefined) ?? site?.name ?? null;

  return (
    <div className="page">
      <div className="page-head">
        <h1>Modules</h1>
        <span className="muted">{total} deployed · module-manager list · read {since(mods.env?.at)}</span>
      </div>
      <div className="tabs" role="tablist">
        {["Installed", ...repos.map((r) => r.name)].map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "tab tab-on" : "tab"} onClick={() => setTab(t)}>
            {t}
            {t !== "Installed" ? <span className="muted small"> repository</span> : null}
          </button>
        ))}
      </div>
      {tab !== "Installed" ? (
        repo ? <RepositoryTab r={repo} deployed={new Set((mods.env?.data ?? []).map((m) => m.name))} ready={!!mods.env?.data && !!envs.env?.data} envOf={envOf} usedVmids={new Set((mods.env?.data ?? []).map((m) => m.vmid).filter((v): v is number => v !== null))} environments={(envs.env?.data ?? []).map((e) => e.name)} defaultEnv={defaultEnv} at={cats.env?.at ?? null} /> : <ReadState env={cats.env} failure={cats.failure} what="the repositories' catalogues" />
      ) : (
      <>
      <ReadState env={mods.env} failure={mods.failure} what="modules (module-manager list)" />
      <ReadState env={cats.env} failure={cats.failure} what="the repositories' catalogues" />
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
            <th>badges</th>
          </tr>
        </thead>
        <tbody>
          {byStack(groups, (g) => g.stack).map(([stack, rows]) => (
            <StackRows key={stack} stack={stack} cols={6} n={rows.length}>
              {rows.map((g) => (
                <InstalledRow key={g.module} g={g} />
              ))}
            </StackRows>
          ))}
        </tbody>
      </table>
      </>
      )}
    </div>
  );
}

function RepositoryTab({ r, deployed, ready, envOf, usedVmids, environments, defaultEnv, at }: { r: RepositoryCatalog; deployed: Set<string>; ready: boolean; envOf: Map<string, string | null>; usedVmids: Set<number>; environments: string[]; defaultEnv: string | null; at: string | null }) {
  const [q, setQ] = useState("");
  const [only, setOnly] = useState(false);
  const rows = r.modules
    .filter((m) => !q || `${m.name} ${m.stack ?? ""} ${m.description ?? ""} ${m.category ?? ""}`.toLowerCase().includes(q.toLowerCase()))
    .filter((m) => !only || m.instances.length === 0);
  const installed = r.modules.filter((m) => m.instances.length > 0).length;
  // Grouped by stack when the repository spans several; a one-stack repository
  // is a flat list that says its stack in a column instead.
  const grouped = new Set(r.modules.map((m) => m.stack ?? "")).size > 1;
  const cols = grouped ? 5 : 6;
  const row = (m: CatalogModule) => {
    const placed = m.instances.map((i) => ({ instance: i, environment: envOf.get(i) ?? null }));
    const { choices, initial } = installEnvironments(m.stack, environments, uniq(placed.map((p) => p.environment)), defaultEnv);
    const next = initial && m.stack !== "foundation" ? defaultInstanceName(m.name, initial, defaultEnv) : null;
    const where = placed.map((p) => `${p.environment ?? "?"} (${p.instance})`).join(", ");
    const vmid = freeVmid(m.vmid, usedVmids);
    return (
    <tr key={m.name}>
      <td className="mono">{deployed.has(m.name) ? <Link to={`/modules/${encodeURIComponent(m.name)}`}>{m.name}</Link> : m.name}</td>
      {grouped ? null : <td>{m.stack ?? <span className="muted">—</span>}</td>}
      <td className="small">{m.description ? plainText(m.description) : <span className="muted">—</span>}</td>
      <td>{m.maturity ? <Badge level="info">{m.maturity}</Badge> : null}</td>
      <td>
        {m.instances.length ? (
          <>
            <Badge level="pass">installed</Badge>{" "}
            {m.instances.map((i, n) => (
              <Fragment key={i}>
                {n ? ", " : ""}
                <Link to={`/modules/${encodeURIComponent(i)}`}>{i}</Link>
              </Fragment>
            ))}
          </>
        ) : (
          <span className="muted">not installed</span>
        )}
      </td>
      <td>
        {/* Its environment and VM id are chosen from what is installed: not before that is read. */}
        <OperateButton
          disabled={!ready}
          hint={ready ? undefined : "reading the installed modules and the environments…"}
          label={m.instances.length ? "Install again…" : "Install…"}
          title={`Install ${m.name}`}
          steps={[
            {
              title: `module-manager add ${m.name} --environment <environment>`,
              bin: "module-manager",
              verb: "add",
              fixed: [m.name],
              initial: { ...(initial ? { "--environment": initial } : {}), ...(vmid !== null ? { "@extra": [`--vmid ${vmid}`] } : {}) },
              choices: choices.length ? { "--environment": choices } : undefined,
              note: (
                <>
                  Installs {m.name} from {r.name} into the environment chosen
                  {m.stack === "foundation" ? " (a foundation module goes in mgmt only)" : ""}: writes its config, builds and starts its guest, wires the services it depends on. There is no dry run: the preview shows the exact command. Fields of the module go under "more options" as --&lt;field&gt; &lt;value&gt;, one per line.
                  {m.instances.length ? ` Installed now in: ${where}. ` : " "}
                  {m.stack === "foundation"
                    ? m.instances.length ? "Another instance needs its own name: --instance." : ""
                    : `The instance is named ${m.name} in ${defaultEnv ?? "the default environment"}, else ${m.name}-<environment>${next ? ` (here: ${next})` : ""}; in an environment it is already in, name it with --instance.`}
                  {vmid !== null ? ` Its guest's VM id ${m.vmid} is taken: --vmid ${vmid} under more options is the next free one TAPPaaS knows of (the install refuses an id in use).` : ""}
                </>
              ),
            },
          ]}
        />
      </td>
    </tr>
    );
  };
  return (
    <>
      <p className="muted small">
        {r.url ?? r.name} · <span className="mono">{r.path}/{r.catalog}</span> · {r.modules.length} modules, {installed} installed · read {since(at)}
      </p>
      {r.error ? <div className="readstate readstate-fail">The catalogue of {r.name} could not be read: {r.error}</div> : null}
      <div className="toolbar">
        <input className="search" placeholder="Filter by name, stack, description" value={q} onChange={(e) => setQ(e.target.value)} />
        <label>
          <input type="checkbox" checked={only} onChange={(e) => setOnly(e.target.checked)} /> not installed only
        </label>
      </div>
      <table className="table">
        <thead>
          <tr><th>module</th>{grouped ? null : <th>stack</th>}<th>description</th><th>maturity</th><th>installed</th><th /></tr>
        </thead>
        <tbody>
          {grouped
            ? byStack(rows, (m) => m.stack).map(([stack, ms]) => (
                <StackRows key={stack} stack={stack} cols={cols} n={ms.length}>
                  {ms.map(row)}
                </StackRows>
              ))
            : rows.map(row)}
        </tbody>
      </table>
    </>
  );
}
