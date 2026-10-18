// Environments — the environments and their zones (spike §5.2, Appendix A):
// environment-manager add / modify / reconcile / delete, and network-manager
// add / modify / enable|disable|manual / bind / reconcile / delete, each as a
// job with its preview. A delete needs the name typed.

import { useRead, useVerb } from "../api";
import { EnvAddRow, envAddRows } from "../forms";
import { OperateButton, Step, Values } from "../operate";
import { EnvironmentRow } from "../types";
import { Dot, ReadState, Section, since } from "../ui";

interface ZoneRead {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  ip?: string;
  tier?: number;
  serves?: string;
  description?: string;
  error?: string;
}

const env = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "environment-manager", verb, ...extra });
const net = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "network-manager", verb, ...extra });

// The add form: each input says whether it must be given or what the
// manager uses when it is left empty (environment-fields.json and
// environment-manager's own defaults), never a placeholder.
function EnvAddForm({ values, set, onName }: { values: Values; set: (v: Values) => void; onName: (n: string) => void }) {
  const schema = useRead<Record<string, unknown>>("schemas/environment", 600_000).env?.data ?? null;
  const ids = useRead<Record<string, string[]>>("identity").env?.data ?? null;
  const zones = useRead<ZoneRead[]>("zones").env?.data ?? [];
  const verb = useVerb("environment-manager", "add");
  const name = typeof values["@env"] === "string" ? values["@env"].trim() : "";
  const help = Object.fromEntries((verb?.options ?? []).map((o) => [o.flag, o.description.replace(/\s+/g, " ")]));
  if (!schema || !ids) return <p className="muted">reading environment-fields.json and the organizations…</p>;
  const rows = envAddRows(schema, { name, orgs: ids.org ?? [], zones: zones.map((z) => z.name), help });
  const val = (r: EnvAddRow) => values[r.key];
  const put = (r: EnvAddRow, v: string | boolean) => {
    if (r.key === "@env") onName(String(v).trim());
    set({ ...values, [r.key]: v });
  };
  return (
    <div className="form envform">
      {rows.map((r) => (
        <div key={r.key} className="form-row">
          <span>
            <span className="mono">{r.field}</span> {r.required ? <span className="req">required</span> : null}
          </span>
          {r.kind === "boolean" ? (
            <label className="form-check">
              <input type="checkbox" checked={val(r) === true} onChange={(e) => put(r, e.target.checked)} /> <span className="mono">{r.key}</span>
            </label>
          ) : r.kind === "enum" && r.choices ? (
            <select value={typeof val(r) === "string" ? (val(r) as string) : ""} onChange={(e) => put(r, e.target.value)}>
              <option value="">{r.whenEmpty ? `— left empty: ${r.whenEmpty}` : "—"}</option>
              {r.choices.map((c) => (
                <option key={c} value={c}>{c}</option>
              ))}
            </select>
          ) : (
            <>
              <input type="text" list={r.choices ? `dl-${r.key}` : undefined} placeholder={r.required ? "" : r.whenEmpty ? `left empty: ${r.whenEmpty}` : ""} value={typeof val(r) === "string" ? (val(r) as string) : ""} onChange={(e) => put(r, e.target.value)} />
              {r.choices ? (
                <datalist id={`dl-${r.key}`}>
                  {r.choices.map((c) => (
                    <option key={c} value={c} />
                  ))}
                </datalist>
              ) : null}
            </>
          )}
          <small className="muted">
            {r.required ? "Must be given. " : r.kind === "boolean" ? `Left off: ${r.whenEmpty}. ` : <>If left empty: <b>{r.whenEmpty}</b>. </>}
            {r.description}
          </small>
        </div>
      ))}
    </div>
  );
}

// Add an environment: its record, then the reconcile that makes it live (the
// wizard pattern of D10, also offered from Setup). The reconcile takes the
// name given in the first step (one add dialog is open at a time; the steps
// are rebuilt on every render of the page that offers them).
const chosen = { name: "" };
export function addEnvironmentSteps(): Step[] {
  return [
    env("1 · The environment's record", "add", {
      hide: ["@env"],
      only: [],
      render: (values, set) => <EnvAddForm values={values} set={set} onName={(n) => (chosen.name = n)} />,
      note: "Writes the environment's record (config/environments/<name>.json; with --create-zone also its zone). Nothing is live until the reconcile below.",
    }),
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
  const orgs = useRead<Record<string, string[]>>("identity").env?.data?.org ?? [];
  const zoneNames = (zones.env?.data ?? []).map((z) => z.name);
  const envNames = (envs.env?.data ?? []).map((e) => e.name);
  return (
    <div className="page">
      <div className="page-head">
        <h1>Environments</h1>
        <span className="muted">environment-manager · network-manager · read {since(envs.env?.at)}</span>
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
                  <OperateButton label="Modify…" title={`Modify ${e.name}`} steps={[env(`environment-manager modify ${e.name}`, "modify", { fixed: [e.name], choices: { "--zone": zoneNames, "--owner": orgs, "--dns-mode": ["per-service", "wildcard"] }, note: `Only what you fill in changes; the rest of ${e.name}'s record stays as it is.` }), env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
                  <OperateButton label="Reconcile" title={`Reconcile ${e.name}`} steps={[env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
                  <OperateButton label="Delete…" kind="danger" title={`Delete ${e.name}`} steps={[env(`environment-manager delete ${e.name}`, "delete", { fixed: [e.name] })]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
      <Section
        title="Zones"
        aside={
          <span className="toolbar">
            <OperateButton label="Add a zone…" title="Add a zone" steps={[net("network-manager add <name>", "add")]} />
            <OperateButton label="Reconcile the network…" title="Reconcile the network" steps={[net("network-manager reconcile", "reconcile", { note: "The preview runs every plane dry (OPNsense, Proxmox, the switches, the APs); apply converges them all." })]} />
          </span>
        }
      >
        <ReadState env={zones.env} failure={zones.failure} what="zones" />
        <table className="table compact">
          <thead>
            <tr><th>zone</th><th>vlan</th><th>state</th><th>type</th><th>tier</th><th>network</th><th /></tr>
          </thead>
          <tbody>
            {(zones.env?.data ?? []).map((z) => (
              <tr key={z.name}>
                <td className="mono" title={z.description}>{z.name}</td>
                <td>{z.vlantag ?? ""}</td>
                <td><Dot level={z.state === "Active" ? "pass" : "skip"} /> {z.state ?? z.error ?? ""}</td>
                <td>{z.type ?? ""}</td>
                <td>{z.tier ?? ""}</td>
                <td className="mono">{z.ip ?? ""}</td>
                <td className="toolbar">
                  <OperateButton label="Modify…" title={`Modify zone ${z.name}`} steps={[net(`network-manager modify ${z.name}`, "modify", { fixed: [z.name] }), net("network-manager reconcile", "reconcile")]} />
                  {(z.state === "Active" ? ["disable", "manual"] : ["enable"]).map((w) => (
                    <OperateButton
                      key={w}
                      label={`${w[0].toUpperCase()}${w.slice(1)}…`}
                      title={`network-manager ${w} ${z.name}`}
                      steps={[
                        { ...net(`network-manager ${w} ${z.name}`, "enable|disable|manual", { fixed: [z.name], note: "Writes the zone's state into zones.json only; the reconcile after makes it live." }), words: [w] },
                        net("network-manager reconcile", "reconcile"),
                      ]}
                    />
                  ))}
                  <OperateButton label="Bind…" title={`Bind ${z.name} to an environment`} steps={[net(`network-manager bind ${z.name}`, "bind", { fixed: [z.name], choices: { "--environment": envNames } })]} />
                  <OperateButton label="Delete…" kind="danger" title={`Delete zone ${z.name}`} steps={[net(`network-manager delete ${z.name}`, "delete", { fixed: [z.name] })]} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
    </div>
  );
}
