// ModuleConfig.tsx — a module's configuration as a tree: the module's own card
// (its kind, node, environment and zone, and the fields no service of it owns)
// at the top, one card per service it depends on below, joined by lines. Each
// card shows its key values; Modify opens the operate dialog with every field
// the card owns, typed, its value configured or default, its change class.

import { useMemo, useState } from "react";
import { useRead } from "../api";
import { modifyStep } from "../fieldsform";
import { FieldRow, plainText, shortValue } from "../forms";
import { GEdge, GNode, Graph } from "../graph";
import { Operate } from "../operate";
import { ModuleDetail } from "../types";
import { ReadState, Section, canOperate, since, useMe } from "../ui";

interface ModuleFields {
  module: string;
  dependsOn: string[];
  integratesWith: string[];
  fields: FieldRow[];
  warnings: string[];
}

// Where the module sits: always on its own card, whichever service owns them.
const PLACEMENT = ["kind", "node", "environment", "zone0"];
// Shown on a card only when nothing else fits: they describe the module, not its setup.
const QUIET = new Set(["description", "displayName", "icon", "dependsOn", "integratesWith", "provides", "version", "releaseDate", "installTime", "updateTime", "maintainer", "moduleSource", "source", "status"]);
const SHOWN = 6;

export interface CardModel {
  id: string; // "" for the module itself, else the service coordinate
  title: string;
  rows: FieldRow[];
  how: "module" | "depends on" | "integrates with";
}

// The cards: the module's own, then each service in dependsOn and integratesWith.
export function cardsOf(f: ModuleFields): CardModel[] {
  const own = (r: FieldRow) => PLACEMENT.includes(r.field) || r.service === "" || !(f.dependsOn.includes(r.service) || f.integratesWith.includes(r.service));
  const cards: CardModel[] = [{ id: "", title: f.module, rows: f.fields.filter(own), how: "module" }];
  for (const s of f.dependsOn) cards.push({ id: s, title: s, rows: f.fields.filter((r) => !own(r) && r.service === s), how: "depends on" });
  for (const s of f.integratesWith) if (!f.dependsOn.includes(s)) cards.push({ id: s, title: s, rows: f.fields.filter((r) => !own(r) && r.service === s), how: "integrates with" });
  return cards;
}

// The values a card shows: where the module sits, then what is configured, then defaults.
function keyRows(c: CardModel): FieldRow[] {
  const rank = (r: FieldRow) => (PLACEMENT.includes(r.field) ? PLACEMENT.indexOf(r.field) : QUIET.has(r.field) ? 300 : r.configured ? 100 : r.value !== null ? 200 : 400);
  return [...c.rows].filter((r) => r.value !== null || PLACEMENT.includes(r.field)).sort((a, b) => rank(a) - rank(b) || a.field.localeCompare(b.field)).slice(0, SHOWN);
}

const W = 260;
const GRID = { root: "@module", cols: 4 };
const height = (n: number) => 58 + n * 19 + 34;

export function ModuleConfig({ d }: { d: ModuleDetail }) {
  const name = d.summary.name;
  const r = useRead<ModuleFields>(`modules/${encodeURIComponent(name)}/fields`, 600_000);
  const operator = canOperate(useMe());
  const [open, setOpen] = useState<CardModel | null>(null);
  const f = r.env?.data ?? null;
  const cards = useMemo(() => (f ? cardsOf(f) : []), [f]);

  const graph = useMemo(() => {
    const nodes: GNode[] = cards.map((c) => {
      const shown = keyRows(c);
      const settable = c.rows.filter((x) => x.settable).length;
      const configured = c.rows.filter((x) => x.configured).length;
      return {
        id: c.id || "@module",
        w: W,
        h: height(shown.length),
        accent: c.how === "module" ? "#3b6fd4" : c.how === "integrates with" ? "#cbd5e1" : "#94a3b8",
        onClick: operator && c.rows.length ? () => setOpen(c) : undefined,
        content: (
          <div className="mcard">
            <div className="cf-title">
              <span className="mono">{c.title}</span>
              <span className="cf-roles">{c.how === "module" ? "the module" : c.how}</span>
            </div>
            <div className="cf-sub">
              {c.rows.length === 0 ? "no fields of its own" : `${c.rows.length} fields · ${configured} configured · ${settable} can change`}
            </div>
            <table className="mcard-rows">
              <tbody>
                {shown.map((x) => (
                  <tr key={x.field} title={plainText(x.description)}>
                    <td className="mono">{x.field}</td>
                    <td className={`mono${x.configured ? "" : " muted"}`}>
                      {PLACEMENT.includes(x.field) && x.value === null ? placement(d, x.field) : shortValue(x.value, 26)}
                      {!x.configured && x.value !== null ? <span className="dflt"> default</span> : null}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {operator && c.rows.length ? (
              <div className="mcard-foot">
                <button
                  className="btn btn-small"
                  onClick={(e) => {
                    e.stopPropagation();
                    setOpen(c);
                  }}
                >
                  Modify…
                </button>
              </div>
            ) : null}
          </div>
        ),
      };
    });
    const edges: GEdge[] = cards.slice(1).map((c) => ({ source: "@module", target: c.id, dashed: c.how === "integrates with", color: c.how === "integrates with" ? "#cbd5e1" : "#94a3b8" }));
    return { nodes, edges };
  }, [cards, operator, d]);

  const services = cards.length - 1;
  return (
    <Section title="Configuration — the module and the services it uses" aside={`module-manager fields / resolve ${name} · ${since(r.env?.at)}`}>
      <ReadState env={r.env} failure={r.failure} what="the module's fields" />
      {f ? (
        <>
          <p className="muted small">
            Values in grey are the schema's defaults; the rest are configured for {name}. Click a card (or Modify) to change its fields: the preview is module-manager's own dry run, Apply writes the fields and converges the module.
          </p>
          <Graph nodes={graph.nodes} edges={graph.edges} grid={GRID} height={Math.max(380, 250 + Math.ceil(services / 4) * 225)} nodesep={36} ranksep={26} />
        </>
      ) : null}
      {open && f ? (
        <Operate
          title={`Modify ${name}${open.id ? ` · ${open.id}` : ""}`}
          steps={[
            modifyStep({
              title: open.id ? `The fields ${open.id} owns` : `${name}'s own fields`,
              bin: "module-manager",
              fixed: [name],
              rows: [...open.rows].sort((a, b) => a.field.localeCompare(b.field)),
              note: "Change any number of fields: they go to module-manager as one modify, one --set per changed field. The preview checks every one before anything is written; a modify applies all of them or none.",
            }),
          ]}
          onClose={() => setOpen(null)}
        />
      ) : null}
    </Section>
  );
}

function placement(d: ModuleDetail, field: string): string {
  const m = d.summary;
  const v = field === "kind" ? m.kind : field === "node" ? m.node : field === "environment" ? m.environment : field === "zone0" ? m.zone0 : null;
  return v ?? "—";
}

