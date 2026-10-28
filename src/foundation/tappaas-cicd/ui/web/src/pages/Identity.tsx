// Identity — organizations, groups, users and roles as config/identities holds
// them, drawn as a graph of their relations (identity-manager <kind> show for
// each: a group's owning organization, a user's groups, the roles of users and
// groups, an organization's owner and parent), with the list beside it. A click
// opens the object's record and its verbs. A change is staged with
// --no-reconcile and then reconciled, so its preview is the reconcile's plan
// against Authentik.

import { useMemo, useState } from "react";
import { useRead } from "../api";
import { GEdge, GNode, Graph } from "../graph";
import { OperateButton, Step } from "../operate";
import { ResetPasswordButton } from "./ResetPassword";
import { fieldsStep } from "../fields";
import { ID_KINDS, IdKind, IdNode, identityGraph } from "../relations";
import { KV, ReadState, Section, since } from "../ui";
import { identitySpecs } from "../wizards";

const KIND: Record<IdKind, { title: string; one: string; color: string }> = {
  org: { title: "Organizations", one: "organization", color: "#3b6fd4" },
  group: { title: "Groups", one: "group", color: "#2f9e44" },
  user: { title: "Users", one: "user", color: "#e8a317" },
  role: { title: "Roles", one: "role", color: "#7c3aed" },
};

const reconcileNote = "The preview is the plan against Authentik (what would be created, changed, removed); apply pushes it.";
const stagedNote = "Staged in config/identities only; the reconcile below previews what reaches Authentik, then pushes it.";
const reconcile: Step = { bin: "identity-manager", verb: "reconcile", title: "Push to Authentik: identity-manager reconcile", hide: ["--dry-run"], note: reconcileNote };

// A change to an identity object (also Setup's Day 2 "Add a user"): the
// schema-driven field form, staged with --no-reconcile, then the reconcile.
export function identitySteps(kind: string, verb: "add" | "modify" | "delete", name?: string): Step[] {
  const s = identitySpecs(kind, verb, name);
  const title = `1 · config/identities: identity-manager ${kind} ${verb}${name ? ` ${name}` : ""} --no-reconcile`;
  const push: Step = { ...reconcile, ...s.reconcile, title: `2 · ${reconcile.title}` };
  if (verb !== "delete") {
    return [
      fieldsStep({ ...s.change, title, kind, name: name ?? null, mode: verb, hide: ["@field"], note: stagedNote }),
      push,
    ];
  }
  return [{ ...s.change, title, hide: ["--no-reconcile"], note: stagedNote }, push];
}

function show(v: unknown): string {
  if (v === null || v === undefined || v === "") return "";
  if (Array.isArray(v)) return v.join(", ");
  if (typeof v === "object") return JSON.stringify(v);
  return String(v);
}

function Verbs({ kind, name }: { kind: string; name: string }) {
  return (
    <span className="toolbar">
      <OperateButton label="Show" title={`${kind} ${name}`} steps={[{ title: `identity-manager ${kind} show ${name}`, bin: "identity-manager", verb: "<kind> show", words: [kind, "show"], fixed: [name] }]} />
      <OperateButton label="Modify…" title={`Modify ${kind} ${name}`} steps={() => identitySteps(kind, "modify", name)} />
      {kind === "user" ? <ResetPasswordButton user={name} small /> : null}
      <OperateButton label="Delete…" kind="danger" title={`Delete ${kind} ${name}`} steps={identitySteps(kind, "delete", name)} />
    </span>
  );
}

function Detail({ n, close }: { n: IdNode; close: () => void }) {
  const k = KIND[n.kind];
  const rows: [string, string][] = Object.entries(n.record ?? {})
    .filter(([key]) => key !== "name")
    .map(([key, v]) => [key, show(v)]);
  return (
    <aside className="sidepanel id-detail" style={{ borderTop: `4px solid ${k.color}` }}>
      <header>
        <div>
          <div className="muted small">{k.one}</div>
          <h2 className="mono">{n.name}</h2>
        </div>
        <button className="btn-x" onClick={close} aria-label="close">×</button>
      </header>
      {n.record === null ? (
        <p className="readstate readstate-warn">Referenced by another object, but there is no {k.one} named {n.name} in config/identities.</p>
      ) : (
        <>
          <KV rows={rows} />
          <Verbs kind={n.kind} name={n.name} />
        </>
      )}
    </aside>
  );
}

export function Identity() {
  const r = useRead<Record<string, string[]>>("identity");
  const rec = useRead<Partial<Record<IdKind, Record<string, unknown>[]>>>("identity/records");
  const d = r.env?.data ?? {};
  const [sel, setSel] = useState<string | null>(null);
  const g = useMemo(() => identityGraph(rec.env?.data ?? {}), [rec.env]);
  const graph = useMemo(() => {
    const nodes: GNode[] = g.nodes.map((n) => {
      const k = KIND[n.kind];
      const r0 = n.record ?? {};
      const sub = n.kind === "user" ? show(r0.primaryEmail) : n.kind === "group" || n.kind === "org" ? show(r0.type) : show(r0.displayName);
      return {
        id: n.id,
        w: 170,
        h: 52,
        accent: k.color,
        className: `idcard${n.record === null ? " idcard-missing" : ""}${sel === n.id ? " zcard-on" : ""}`,
        onClick: () => setSel(n.id),
        content: (
          <div>
            <div className="cf-title">
              <span className="mono">{n.name}</span>
              <span className="cf-roles" style={{ color: k.color }}>{k.one}</span>
            </div>
            <div className="cf-sub">{n.record === null ? "missing" : sub}</div>
          </div>
        ),
      };
    });
    const edges: GEdge[] = g.edges.map((e) => ({ ...e, arrow: true, color: e.label === "has role" || e.label === "grants" ? "#a78bfa" : e.label === "owner" ? "#e8a317" : "#94a3b8", dashed: e.label === "owner" }));
    return { nodes, edges };
  }, [g, sel]);
  const picked = g.nodes.find((n) => n.id === sel) ?? null;

  return (
    <div className="page page-wide">
      <div className="page-head">
        <h1>Identity</h1>
        <span className="muted">identity-manager · config/identities · read {since(rec.env?.at ?? r.env?.at)}</span>
        <span className="spacer" />
        <OperateButton label="Reconcile with Authentik…" title="identity-manager reconcile" steps={[reconcile]} kind="primary" />
      </div>
      <ReadState env={r.env} failure={r.failure} what="identity" />
      <ReadState env={rec.env} failure={rec.failure} what="the identity records" />
      <p className="muted small">
        The console is for members of <span className="mono">installer</span> only; <span className="mono">admin</span> and <span className="mono">users</span> give no access to it.
      </p>
      <div className="identity-view">
        <div className="identity-graph">
          <Graph nodes={graph.nodes} edges={graph.edges} rankdir="TB" height={560} nodesep={26} ranksep={70} />
          <div className="legend">
            {ID_KINDS.map((k) => (
              <span key={k} className="zone">
                <i style={{ background: KIND[k].color }} />
                {KIND[k].one}
              </span>
            ))}
            <span className="muted">organization → owns its groups · group → its members · user/group → their roles · - - organization → its owner · click an object for its record</span>
          </div>
        </div>
        <div className="identity-side">
          {picked ? <Detail n={picked} close={() => setSel(null)} /> : null}
          {ID_KINDS.map((kind) => (
            <Section key={kind} title={KIND[kind].title} aside={<OperateButton label={`Add ${kind}…`} title={`Add a ${KIND[kind].one}`} steps={() => identitySteps(kind, "add")} />}>
              <table className="table compact">
                <tbody>
                  {(d[kind] ?? []).map((n) => (
                    <tr key={n} className={sel === `${kind}:${n}` ? "row-on" : ""}>
                      <td className="mono">
                        <button className="linkish" onClick={() => setSel(`${kind}:${n}`)}>{n}</button>
                      </td>
                      <td>
                        <Verbs kind={kind} name={n} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Section>
          ))}
        </div>
      </div>
    </div>
  );
}
