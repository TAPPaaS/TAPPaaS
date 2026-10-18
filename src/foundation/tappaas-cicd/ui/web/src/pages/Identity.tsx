// Identity — organizations, groups, users and roles as config/identities holds
// them (identity-manager <kind> list), and the reconcile that pushes them to
// Authentik, previewed first. A change is staged with --no-reconcile and then
// reconciled, so its preview is the reconcile's plan (ADR-034 D4: identity's
// add and modify preview through reconcile).

import { useRead } from "../api";
import { OperateButton, Step } from "../operate";
import { ReadState, Section, since } from "../ui";

const KINDS: { kind: string; title: string }[] = [
  { kind: "org", title: "Organizations" },
  { kind: "group", title: "Groups" },
  { kind: "user", title: "Users" },
  { kind: "role", title: "Roles" },
];

const reconcile: Step = {
  title: "Push to Authentik: identity-manager reconcile",
  bin: "identity-manager",
  verb: "reconcile",
  hide: ["--dry-run"],
  note: "The preview is the plan against Authentik (what would be created, changed, removed); apply pushes it.",
};

function change(kind: string, verb: "add" | "modify" | "delete", name?: string): Step[] {
  return [
    {
      title: `1 · config/identities: identity-manager ${kind} ${verb}${name ? ` ${name}` : " <name>"} --no-reconcile`,
      bin: "identity-manager",
      verb: `<kind> ${verb}`,
      words: [kind, verb],
      fixed: name ? [name] : [],
      initial: { "--no-reconcile": true },
      hide: ["--no-reconcile"],
      note: "Staged in config/identities only; the reconcile below previews what reaches Authentik, then pushes it.",
    },
    reconcile,
  ];
}

export function Identity() {
  const r = useRead<Record<string, string[]>>("identity");
  const d = r.env?.data ?? {};
  return (
    <div className="page">
      <div className="page-head">
        <h1>Identity</h1>
        <span className="muted">identity-manager · config/identities · read {since(r.env?.at)}</span>
        <span className="spacer" />
        <OperateButton label="Reconcile with Authentik…" title="identity-manager reconcile" steps={[reconcile]} kind="primary" />
      </div>
      <ReadState env={r.env} failure={r.failure} what="identity" />
      <p className="muted small">
        The console's roles come from these groups: <span className="mono">installer</span> (Installer), the <span className="mono">admin</span> role (Admin), <span className="mono">users</span> (read).
      </p>
      <div className="grid2">
        {KINDS.map(({ kind, title }) => (
          <Section key={kind} title={title} aside={<OperateButton label={`Add ${kind}…`} title={`Add a ${kind}`} steps={change(kind, "add")} />}>
            <table className="table compact">
              <tbody>
                {(d[kind] ?? []).map((n) => (
                  <tr key={n}>
                    <td className="mono">{n}</td>
                    <td className="toolbar">
                      <OperateButton label="Show" title={`${kind} ${n}`} steps={[{ title: `identity-manager ${kind} show ${n}`, bin: "identity-manager", verb: "<kind> show", words: [kind, "show"], fixed: [n] }]} />
                      <OperateButton label="Modify…" title={`Modify ${kind} ${n}`} steps={change(kind, "modify", n)} />
                      <OperateButton label="Delete…" kind="danger" title={`Delete ${kind} ${n}`} steps={change(kind, "delete", n)} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>
        ))}
      </div>
    </div>
  );
}
