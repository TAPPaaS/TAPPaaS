// Zones.tsx — the zones as cards joined by what they may reach: a solid arrow
// for `access-to` (the zone may open connections to the other), a dashed one
// for `pinhole-allowed-from` (the other may be let in through a pinhole),
// coloured by zone type and laid out in trust columns. The WAN zone's card
// stands for the internet too. A click opens the zone's
// fields and its verbs; Modify lists every field of zones-fields.json with its
// value, default and change class, several per job.

import { useEffect, useMemo, useState } from "react";
import { useOpenRequest } from "../opener";
import { useRead } from "../api";
import { fieldsStep } from "../fields";
import { FieldRow, ZoneFieldSpec, shortValue, zoneFieldRows } from "../forms";
import { GEdge, GNode, Graph } from "../graph";
import { OperateButton, Step } from "../operate";
import { Dot, ReadState, Section, since } from "../ui";
import { EnvironmentRow, SiteRead } from "../types";
import { COLUMN_TITLES, PSEUDO, PublicAddress, environmentsOf, publicAddress, publicText, pseudoPlace, wanZone, zoneColumn, zoneEdges } from "../zonegraph";

export interface ZoneRead {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  ip?: string;
  tier?: number;
  environment?: string | string[];
  description?: string;
  error?: string;
  "access-to"?: string[];
  "pinhole-allowed-from"?: string[];
  [k: string]: unknown;
}

export const TYPE_COLOR: Record<string, string> = {
  Management: "#475569",
  Service: "#3b6fd4",
  Client: "#2f9e44",
  IoT: "#e8a317",
  Guest: "#0ea5a4",
  DMZ: "#d64545",
  Overlay: "#7c3aed",
  WAN: "#8e8e8e",
};

const net = (title: string, verb: string, extra: Partial<Step> = {}): Step => ({ title, bin: "network-manager", verb, ...extra });
const reconcile = net("network-manager reconcile", "reconcile", { note: "The preview runs every plane dry (OPNsense, Proxmox, the switches, the APs); apply makes the change live." });

const live = (z: ZoneRead) => z.state === "Active" || z.state === "Mandatory" || z.state === "Manual";
const dot = (z: ZoneRead) => (z.state === "Active" || z.state === "Mandatory" ? "pass" : z.state === "Manual" ? "info" : "skip");

export function zoneGraph(zones: ZoneRead[], pick: (z: string) => void, selected: string | null, pub: PublicAddress = publicAddress(null)): { nodes: GNode[]; edges: GEdge[] } {
  const color = new Map(zones.map((z) => [z.name, TYPE_COLOR[z.type ?? ""] ?? "#94a3b8"]));
  const wan = wanZone(zones);
  const { edges: lines, pseudo } = zoneEdges(zones);
  const edges: GEdge[] = lines.map((e) =>
    e.kind === "access"
      ? { source: e.source, target: e.target, color: color.get(e.source), arrow: true, ...(e.via ? { label: `serves ${e.via}` } : {}) }
      : { source: e.source, target: e.target, color: "#f08c3a", dashed: true, arrow: true, label: e.via ? `pinhole · ${e.via}` : "pinhole" },
  );
  const nodes: GNode[] = zones.map((z) => ({
    id: z.name,
    w: 190,
    h: 74,
    col: zoneColumn(z),
    order: z.vlantag ?? 0,
    accent: TYPE_COLOR[z.type ?? ""] ?? "#94a3b8",
    className: `zcard${live(z) ? "" : " zcard-off"}${selected === z.name ? " zcard-on" : ""}`,
    onClick: () => pick(z.name),
    content:
      z.name === wan ? (
        <div>
          <div className="cf-title">
            <Dot level={dot(z)} />
            <span>WAN / internet</span>
            <span className="cf-roles">{z.vlantag ? `vlan ${z.vlantag}` : ""}</span>
          </div>
          <div className="cf-sub">
            <span className="mono">{z.name}</span> · {z.state ?? "?"}
          </div>
          <div className="cf-sub">{publicText(pub, true)}</div>
        </div>
      ) : (
        <div>
          <div className="cf-title">
            <Dot level={dot(z)} />
            <span className="mono">{z.name}</span>
            <span className="cf-roles">{z.vlantag ? `vlan ${z.vlantag}` : ""}</span>
          </div>
          <div className="cf-sub">{z.type ?? "?"} · {z.state ?? "?"}{z.tier !== undefined ? ` · tier ${z.tier}` : ""}</div>
          <div className="cf-sub">{environmentsOf(z).length ? (z.type === "Service" || z.type === "Management" ? `${environmentsOf(z)[0]}'s zone` : `serves ${environmentsOf(z).join(", ")}`) : z.ip ?? ""}</div>
        </div>
      ),
  }));
  for (const p of pseudo) {
    nodes.push({ id: p, w: 130, h: 44, ...pseudoPlace(p, zones), className: "zcard-pseudo", content: <div className="cf-title">{PSEUDO[p] ?? p}</div> });
  }
  // A title above each column in use.
  for (const c of new Set(nodes.map((n) => n.col ?? 0))) {
    nodes.push({ id: `col-${c}`, w: 190, h: 22, col: c, head: true, className: "zcard-head", content: <div className="cf-sub">{COLUMN_TITLES[c] ?? `column ${c}`}</div> });
  }
  return { nodes, edges };
}

function ZoneDetail({ z, schema, envNames, wan, close }: { z: ZoneRead; schema: Record<string, ZoneFieldSpec> | null; envNames: string[]; wan: PublicAddress | null; close: () => void }) {
  const rows: FieldRow[] = schema ? zoneFieldRows(z, schema) : [];
  return (
    <aside className="sidepanel">
      <header>
        <div>
          <h2 className="mono">{z.name}</h2>
          <div className="muted small">{z.type} · {z.state} · vlan {z.vlantag ?? "—"} · {wan ? publicText(wan) : z.ip ?? ""}</div>
        </div>
        <button className="btn-x" onClick={close} aria-label="close">×</button>
      </header>
      {z.description ? <p className="small">{z.description}</p> : null}
      {wan ? (
        <p className="small">
          This card stands for the internet as well. The site's public address comes from the site record (network.publicIp){wan.auto ? "; auto means the provider assigns it and the firewall's WAN takes it by DHCP, read at each network update" : ""}. The zone's ip <span className="mono">{z.ip ?? "—"}</span> only fills the schema: no interface, DHCP or rule is built from it.
        </p>
      ) : null}
      <div className="toolbar">
        <OperateButton
          label="Modify…"
          kind="primary"
          title={`Modify zone ${z.name}`}
          opens={{ wizard: "modify-zone", arg: z.name }}
          steps={() => [
            fieldsStep({
              title: `The fields of ${z.name}`,
              bin: "network-manager",
              verb: "modify",
              fixed: [z.name],
              kind: "zone",
              name: z.name,
              mode: "modify",
              note: "One modify for every field changed, all or none. It writes zones.json only; the reconcile after makes it live.",
            }),
            reconcile,
          ]}
        />
        {(z.state === "Active" ? ["disable", "manual"] : ["enable"]).map((w) => (
          <OperateButton
            key={w}
            label={`${w[0].toUpperCase()}${w.slice(1)}…`}
            title={`network-manager ${w} ${z.name}`}
            steps={[{ ...net(`network-manager ${w} ${z.name}`, "enable|disable|manual", { fixed: [z.name], note: "Writes the zone's state into zones.json only; the reconcile after makes it live." }), words: [w] }, reconcile]}
          />
        ))}
        <OperateButton label="Bind…" title={`Bind ${z.name} to an environment`} steps={[net(`network-manager bind ${z.name}`, "bind", { fixed: [z.name], choices: { "--environment": envNames } })]} />
        <OperateButton label="Delete…" kind="danger" title={`Delete zone ${z.name}`} steps={[net(`network-manager delete ${z.name}`, "delete", { fixed: [z.name] })]} />
      </div>
      <table className="table compact zfields">
        <tbody>
          {rows.map((r) => (
            <tr key={r.field} title={r.description}>
              <td className="mono">{r.field}</td>
              <td className={`mono wrap${r.configured ? "" : " muted"}`}>{shortValue(r.value, 60)}{r.configured ? "" : <span className="dflt"> default</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </aside>
  );
}

export function ZonesGraph({ zones, envNames, sel, setSel }: { zones: ZoneRead[]; envNames: string[]; sel: string | null; setSel: (z: string | null) => void }) {
  const schemaR = useRead<{ fields?: Record<string, ZoneFieldSpec> }>("schemas/zones", 600_000);
  const schema = schemaR.env?.data?.fields ?? null;
  const siteR = useRead<SiteRead>("site", 600_000).env?.data;
  const pub = useMemo(() => publicAddress(siteR?.site, siteR?.wan), [siteR]);
  const graph = useMemo(() => zoneGraph(zones, setSel, sel, pub), [zones, sel, setSel, pub]);
  const z = zones.find((x) => x.name === sel) ?? null;
  const wan = wanZone(zones);
  return (
    <>
      <ReadState env={schemaR.env} failure={schemaR.failure} what="zones-fields.json" />
      <div className="zones-view">
        <div className="zones-canvas">
          <Graph nodes={graph.nodes} edges={graph.edges} rankdir="LR" height={560} nodesep={60} ranksep={90} />
        </div>
        {z ? <ZoneDetail key={z.name} z={z} schema={schema} envNames={envNames} wan={z.name === wan ? pub : null} close={() => setSel(null)} /> : null}
      </div>
      <div className="legend">
        {Object.entries(TYPE_COLOR).map(([t, c]) => (
          <span key={t} className="zone">
            <i style={{ background: c }} />
            {t}
          </span>
        ))}
        <span className="muted">→ may reach (access-to) · ⇢ may be let in through a pinhole (pinhole-allowed-from) · faded: inactive or disabled · click a zone for its fields and Modify</span>
      </div>
    </>
  );
}

// The Zones page (/zones): the graph with its side card, the zones' table and
// their verbs (network-manager add / modify / enable|disable|manual / bind /
// reconcile / delete, each as a job with its preview; a delete needs the name
// typed). ?zone=<name> (the assistant's modify-zone, the Environments page's
// zone boxes): that zone's details, open.
export function ZonesPage() {
  const envs = useRead<EnvironmentRow[]>("environments");
  const zones = useRead<ZoneRead[]>("zones");
  const [zone, setZone] = useState<string | null>(() => new URLSearchParams(window.location.search).get("zone"));
  useEffect(() => {
    const on = () => setZone(new URLSearchParams(window.location.search).get("zone"));
    window.addEventListener("popstate", on);
    return () => window.removeEventListener("popstate", on);
  }, []);
  const modify = useOpenRequest("modify-zone");
  useEffect(() => {
    if (modify?.arg) setZone(modify.arg);
  }, [modify?.n]);
  const zoneNames = (zones.env?.data ?? []).map((z) => z.name);
  const envNames = (envs.env?.data ?? []).map((e) => e.name);
  // network-manager add --archetype: the catalogue zones-fields.json holds.
  const archetypes = Object.keys(useRead<{ archetypes?: { catalog?: Record<string, unknown> } }>("schemas/zones", 600_000).env?.data?.archetypes?.catalog ?? {});
  return (
    <div className="page">
      <div className="page-head">
        <h1>Zones</h1>
        <span className="muted">network-manager · read {since(zones.env?.at)}</span>
      </div>
      <Section
        title="Zones"
        aside={
          <span className="toolbar">
            <OperateButton label="Add a zone…" title="Add a zone" steps={() => [fieldsStep({ title: "network-manager add <name>", bin: "network-manager", verb: "add", kind: "zone", name: null, mode: "add", keep: ["--archetype", "--from-zone", "--no-activate"], hide: ["@options"], choices: { "--from-zone": zoneNames, ...(archetypes.length ? { "--archetype": archetypes } : {}) } })]} />
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
