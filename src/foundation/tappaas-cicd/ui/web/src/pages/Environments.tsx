// Environments — the environments and their zones (spike §5.2, Appendix A):
// environment-manager add / modify / reconcile / delete, and network-manager
// add / modify / enable|disable|manual / bind / reconcile / delete, each as a
// job with its preview. A delete needs the name typed.

import { useEffect, useState } from "react";
import { useOpenRequest } from "../opener";
import { useRead } from "../api";
import { fieldsStep } from "../fields";
import { OperateButton, Step } from "../operate";
import { EnvironmentRow } from "../types";
import { Dot, ReadState, Section, since } from "../ui";
import { ZoneRead, ZonesGraph } from "./Zones";

const env = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "environment-manager", verb, ...extra });
const net = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "network-manager", verb, ...extra });

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
      return { ...s, render: (values, set) => ((chosen.name = typeof values["@env"] === "string" ? values["@env"].trim() : ""), s.render!(values, set)) } as Step;
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
  // ?zone=<name> (the assistant's modify-zone): that zone's details, open.
  const [zone, setZone] = useState<string | null>(() => new URLSearchParams(window.location.search).get("zone"));
  const modify = useOpenRequest("modify-zone");
  useEffect(() => {
    if (modify?.arg) setZone(modify.arg);
  }, [modify?.n]);
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
                  <OperateButton label="Modify…" title={`Modify ${e.name}`} steps={() => [fieldsStep({ title: `The fields of ${e.name}`, bin: "environment-manager", verb: "modify", fixed: [e.name], kind: "environment", name: e.name, mode: "modify", note: "Writes the record only; the reconcile below makes it live." }), env(`environment-manager reconcile ${e.name}`, "reconcile", { fixed: [e.name] })]} />
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
            <OperateButton label="Add a zone…" title="Add a zone" steps={() => [fieldsStep({ title: "network-manager add <name>", bin: "network-manager", verb: "add", kind: "zone", name: null, mode: "add", keep: ["--archetype", "--serves", "--from-zone", "--no-activate"], hide: ["@options"], choices: { "--serves": envNames, "--from-zone": zoneNames } })]} />
            <OperateButton label="Reconcile the network…" title="Reconcile the network" steps={[net("network-manager reconcile", "reconcile", { note: "The preview runs every plane dry (OPNsense, Proxmox, the switches, the APs); apply converges them all." })]} />
          </span>
        }
      >
        <ReadState env={zones.env} failure={zones.failure} what="zones" />
        {zones.env?.data ? <ZonesGraph zones={zones.env.data} envNames={envNames} sel={zone} setSel={setZone} /> : null}
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
                  <button className="btn" onClick={() => { setZone(z.name); document.querySelector(".zones-view")?.scrollIntoView({ behavior: "smooth" }); }}>Details · Modify…</button>
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
