// Environments — one card per environment (envcards.ts): its record in brief
// and, inside it, a box per zone it owns, each with the modules installed
// there as their icons (moduleicon.tsx). environment-manager add / modify /
// reconcile / delete, each as a job with its preview (spike §5.2, Appendix
// A); a delete needs the name typed. The zones have a page of their own
// (Zones.tsx).

import { ReactNode, useEffect, useMemo, useState } from "react";
import { useRead } from "../api";
import { EnvCard, ZoneLike, envCards } from "../envcards";
import { ModuleIcon } from "../moduleicon";
import { StateLegend } from "../physical/state";
import { CardState, stateClass, stateOf } from "../physical/states";
import { TYPE_COLOR, ZoneRead } from "./Zones";
import { fieldsStep } from "../fields";
import { OperateButton, Step } from "../operate";
import { EnvironmentRow, ModuleSummary, SiteRead } from "../types";
import { KV, Link, ReadState, canOperate, navigate, since, useMe } from "../ui";

const env = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "environment-manager", verb, ...extra });

// Add an environment: its record, then the reconcile that makes it live (the
// wizard pattern of D10, also offered from Setup). The reconcile takes the
// name given in the first step (one add dialog is open at a time; the steps
// are rebuilt on every render of the page that offers them).
const chosen = { name: "" };
export function addEnvironmentSteps(): Step[] {
  return [
    (() => {
      const s = fieldsStep({
        title: "1 · The environment's record",
        bin: "environment-manager",
        verb: "add",
        kind: "environment",
        name: null,
        mode: "add",
        keep: ["--create-zone"],
        note: "Writes the environment's record (config/environments/<name>.json; with --create-zone also its zone). Nothing is live until the reconcile below.",
      });
      // The reconcile takes the name typed here.
      return { ...s, render: (values, set, verb) => ((chosen.name = typeof values["@env"] === "string" ? values["@env"].trim() : ""), s.render!(values, set, verb)) } as Step;
    })(),
    {
      ...env("2 · Make it live: environment-manager reconcile", "reconcile", {
        note: "The preview lists what the reconcile would do (DNS, the certificate, the zone); apply does it.",
      }),
      get fixed() {
        return chosen.name ? [chosen.name] : [];
      },
    },
  ];
}

export function Environments() {
  const envs = useRead<EnvironmentRow[]>("environments");
  const zones = useRead<ZoneRead[]>("zones");
  const mods = useRead<ModuleSummary[]>("modules");
  const site = useRead<SiteRead>("site");
  const def = ((site.env?.data?.site ?? {}) as { defaultEnvironment?: string }).defaultEnvironment ?? null;
  const cards = useMemo(() => envCards(envs.env?.data ?? [], (zones.env?.data ?? []) as ZoneLike[], mods.env?.data ?? [], def), [envs.env, zones.env, mods.env, def]);
  // ?env=<name>: that environment's panel, open.
  const [sel, setSel] = useState<string | null>(() => new URLSearchParams(window.location.search).get("env"));
  useEffect(() => {
    const on = () => setSel(new URLSearchParams(window.location.search).get("env"));
    window.addEventListener("popstate", on);
    return () => window.removeEventListener("popstate", on);
  }, []);
  const pick = (name: string | null) => {
    setSel(name);
    window.history.replaceState(null, "", name ? `/environments?env=${encodeURIComponent(name)}` : "/environments");
  };
  const picked = cards.find((c) => c.env.name === sel) ?? null;
  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Environments</h1>
        <span className="muted">environment-manager · read {since(envs.env?.at)}</span>
        <span className="spacer" />
        <OperateButton label="Add an environment…" title="Add an environment" steps={addEnvironmentSteps()} kind="primary" />
      </div>
      <ReadState env={envs.env} failure={envs.failure} what="environments" />
      <div className="env-page">
        {picked ? <EnvPanel c={picked} close={() => pick(null)} /> : null}
        <div className="env-cards">
          {cards.map((c) => (
            <EnvCardView key={c.env.name} c={c} on={c.env.name === sel} pick={() => pick(c.env.name === sel ? null : c.env.name)} />
          ))}
        </div>
      </div>
      <div className="legend">
        <StateLegend extra="a module's colour is its health" />
      </div>
    </div>
  );
}

type Card = EnvCard<EnvironmentRow, ModuleSummary>;

// A module's state on its tile: its health badge.
const modState = (m: ModuleSummary): CardState => (m.badges.health === "fail" ? "fail" : m.badges.health === "warn" ? "warn" : "ok");

// A card: a click on its head opens the panel, on a zone's head the zone on
// the Zones page, on a module its page.
function EnvCardView({ c, on, pick }: { c: Card; on: boolean; pick: () => void }) {
  const e = c.env;
  const state = stateOf(c.boxes.flatMap((b) => b.modules.map(modState)));
  return (
    <section className={`env-card ${stateClass(state)}${on ? " env-on" : ""}`}>
      <header className="env-head" onClick={pick} title="the environment's record and its verbs">
        <div>
          <h2>
            {e.displayName ?? e.name} <span className="muted mono small">{e.name}</span>
          </h2>
          <div className="muted small">
            {[c.type, c.isDefault ? "the default environment" : null, e.domains?.primary ?? "no public domain"].filter(Boolean).join(" · ")}
          </div>
          <div className="small">
            {c.boxes.filter((b) => b.own).length} zone{c.boxes.filter((b) => b.own).length === 1 ? "" : "s"} · {c.modules} module{c.modules === 1 ? "" : "s"}
          </div>
        </div>
        {c.isDefault ? <span className="badge badge-pass">default</span> : null}
      </header>
      <div className="env-zones">
        {c.boxes.map((b) => (
          <div key={b.zone ?? "-"} className={`zone-box${b.own ? "" : " zone-box-shared"}`} style={{ borderTopColor: TYPE_COLOR[b.record?.type ?? ""] ?? "#94a3b8" }}>
            <div className={`zone-box-head${b.zone ? " linkish" : ""}`} onClick={b.zone ? () => navigate(`/zones?zone=${encodeURIComponent(b.zone!)}`) : undefined} title={b.zone ? `open ${b.zone} on the Zones page` : undefined}>
              <b>{b.zone ?? "no zone"}</b>
              <span className="muted small">
                {b.record ? [b.record.vlantag !== undefined ? `vlan ${b.record.vlantag}` : null, b.record.type, b.record.state].filter(Boolean).join(" · ") : b.zone ? "" : "modules without a zone"}
                {b.own ? "" : b.zone ? " · shared" : ""}
              </span>
            </div>
            <div className="zone-mods">
              {b.modules.length === 0 ? <span className="muted small">nothing installed</span> : null}
              {b.modules.map((m) => (
                <button key={m.name} className={`mod-tile st-${modState(m)}`} onClick={() => navigate(`/modules/${encodeURIComponent(m.name)}`)} title={`${m.name} · ${m.kind}${m.vmid ? ` ${m.vmid}` : ""} · health ${m.badges.health} · ${m.badges.run}`}>
                  <ModuleIcon name={m.name} />
                  <span className="mod-name">{m.name}</span>
                </button>
              ))}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

// A record's fields as rows: nested objects by their dotted path, lists
// joined, nothing left out.
function rowsOf(o: Record<string, unknown>, prefix = ""): [string, ReactNode][] {
  return Object.entries(o).flatMap(([k, v]): [string, ReactNode][] => {
    const key = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === "object" && !Array.isArray(v)) return Object.keys(v).length ? rowsOf(v as Record<string, unknown>, key) : [[key, "—"]];
    return [[key, Array.isArray(v) ? (v.length ? v.join(", ") : "—") : v === null ? "not set" : String(v)]];
  });
}

// The environment's panel, left of the cards (the Site pages' panel shell):
// its whole record, its zones and modules, and environment-manager's verbs on
// it.
function EnvPanel({ c, close }: { c: Card; close: () => void }) {
  const e = c.env;
  const operator = canOperate(useMe());
  return (
    <aside className="sidepanel">
      <header>
        <h2>{e.displayName ?? e.name}</h2>
        <button className="btn-x" onClick={close} aria-label="close">
          ×
        </button>
      </header>
      <p className="muted small">
        {[c.type, c.isDefault ? "the default environment" : null].filter(Boolean).join(" · ")}
      </p>
      <h3>Record</h3>
      <KV rows={rowsOf(e as unknown as Record<string, unknown>)} />
      <h3>Zones</h3>
      <ul className="plain small">
        {c.boxes.filter((b) => b.zone).map((b) => (
          <li key={b.zone}>
            <Link to={`/zones?zone=${encodeURIComponent(b.zone!)}`}>{b.zone}</Link>{" "}
            <span className="muted">{[b.record?.type, b.record?.state, b.own ? (b.zone === e.network?.zone ? "its own zone" : "serves it") : "shared, not its own"].filter(Boolean).join(" · ")} · {b.modules.length} module{b.modules.length === 1 ? "" : "s"}</span>
          </li>
        ))}
      </ul>
      <h3>Modules ({c.modules})</h3>
      <p className="small">
        {c.boxes.flatMap((b) => b.modules).map((m, i) => (
          <span key={m.name}>
            {i ? ", " : ""}
            <Link to={`/modules/${encodeURIComponent(m.name)}`}>{m.name}</Link>
          </span>
        ))}
      </p>
      {operator ? (
        <>
          <h3>Change</h3>
          <div className="toolbar">
            <OperateButton label="Modify…" title={`Modify ${e.name}`} steps={() => [fieldsStep({ title: `The fields of ${e.name}`, bin: "environment-manager", verb: "modify", fixed: [e.name], kind: "environment", name: e.name, mode: "modify", note: "Writes the record only; the reconcile below makes it live." }), env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
            <OperateButton label="Reconcile" title={`Reconcile ${e.name}`} steps={[env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
            <OperateButton label="Delete…" kind="danger" title={`Delete ${e.name}`} steps={[env(`environment-manager delete ${e.name}`, "delete", { fixed: [e.name], note: "Deleting needs its name typed after the preview." })]} />
          </div>
        </>
      ) : null}
      <h3>Read</h3>
      <div className="toolbar">
        <OperateButton label="Show" title={`environment-manager show ${e.name}`} steps={[env(`environment-manager show ${e.name}`, "show", { fixed: [e.name] })]} />
      </div>
    </aside>
  );
}
