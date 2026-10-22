// Environments — the environments (spike §5.2, Appendix A): environment-
// manager add / modify / reconcile / delete, each as a job with its preview. A
// delete needs the name typed. Their zones have a page of their own (Zones.tsx).

import { useRead } from "../api";
import { fieldsStep } from "../fields";
import { OperateButton, Step } from "../operate";
import { EnvironmentRow } from "../types";
import { ReadState, Section, since } from "../ui";

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
  return (
    <div className="page">
      <div className="page-head">
        <h1>Environments</h1>
        <span className="muted">environment-manager · read {since(envs.env?.at)}</span>
      </div>
      <Section
        title="Environments"
        aside={<OperateButton label="Add an environment…" title="Add an environment" steps={addEnvironmentSteps()} kind="primary" />}
      >
        <ReadState env={envs.env} failure={envs.failure} what="environments" />
        <table className="table compact">
          <thead>
            <tr><th>name</th><th>display name</th><th>zone</th><th>domain</th><th /></tr>
          </thead>
          <tbody>
            {(envs.env?.data ?? []).map((e) => (
              <tr key={e.name}>
                <td className="mono">{e.name}</td>
                <td>{e.displayName ?? ""}</td>
                <td className="mono">{e.network?.zone ?? ""}</td>
                <td className="mono">{e.domains?.primary ?? ""}</td>
                <td className="toolbar">
                  <OperateButton label="Modify…" title={`Modify ${e.name}`} steps={() => [fieldsStep({ title: `The fields of ${e.name}`, bin: "environment-manager", verb: "modify", fixed: [e.name], kind: "environment", name: e.name, mode: "modify", note: "Writes the record only; the reconcile below makes it live." }), env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
                  <OperateButton label="Reconcile" title={`Reconcile ${e.name}`} steps={[env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
                  <OperateButton label="Delete…" kind="danger" title={`Delete ${e.name}`} steps={[env(`environment-manager delete ${e.name}`, "delete", { fixed: [e.name] })]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
    </div>
  );
}
