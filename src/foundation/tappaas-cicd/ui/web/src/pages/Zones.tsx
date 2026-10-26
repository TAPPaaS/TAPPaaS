// Zones.tsx — the zones as cards joined by what they may reach: a solid arrow
// for `access-to` (the zone may open connections to the other), a dashed one
// for `pinhole-allowed-from` (the other may be let in through a pinhole),
// coloured by zone type and laid out in trust columns. The WAN zone's card
// stands for the internet too. A click opens the zone's
// fields and its verbs; Modify lists every field of zones-fields.json with its
// value, default and change class, several per job.

import { useCallback, useEffect, useMemo, useState } from "react";
import { useOpenRequest } from "../opener";
import { useRead } from "../api";
import { fieldsStep } from "../fields";
import { FieldRow, ZoneFieldSpec, shortValue, zoneFieldRows } from "../forms";
import { GEdge, GNode, Graph } from "../graph";
import { OperateButton, Step } from "../operate";
import { Dot, Link, ReadState, Section, since } from "../ui";
import { EnvironmentRow, SiteRead } from "../types";
import { cardVerbs } from "../zoneverbs";
import { PASSPHRASE_TEXT, SiteSsid, WIFI_ZONE_TYPES, isPlaceholderSsid, passphraseOf } from "../wizards";
import { Ipv6Read, ipv6SubnetText, typeIdText, zoneV6 } from "../zonenet";
import { COLUMN_TITLES, PSEUDO, PublicAddress, environmentsOf, isSharedService, publicAddress, publicText, pseudoPlace, wanZone, zoneColumn, zoneEdges } from "../zonegraph";

export interface ZoneRead {
  name: string;
  type?: string;
  state?: string;
  vlantag?: number;
  ip?: string;
  tier?: number;
  ipv6Subnet?: number;
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

// network-manager add <name>: from an archetype, or from another zone (`from`
// fills --from-zone in).
const addStep = (zoneNames: string[], archetypes: string[], from?: string): Step =>
  fieldsStep({ title: "network-manager add <name>", bin: "network-manager", verb: "add", kind: "zone", name: null, mode: "add", keep: ["--archetype", "--from-zone", "--no-activate"], hide: ["@options"], ...(from ? { initial: { "--from-zone": from } } : {}), choices: { "--from-zone": zoneNames, ...(archetypes.length ? { "--archetype": archetypes } : {}) } });

const live = (z: ZoneRead) => z.state === "Active" || z.state === "Mandatory" || z.state === "Manual";
const dot = (z: ZoneRead) => (z.state === "Active" || z.state === "Mandatory" ? "pass" : z.state === "Manual" ? "info" : "skip");

export function zoneGraph(zones: ZoneRead[], pick: (z: string) => void, selected: string | null, pub: PublicAddress = publicAddress(null)): { nodes: GNode[]; edges: GEdge[] } {
  const color = new Map(zones.map((z) => [z.name, TYPE_COLOR[z.type ?? ""] ?? "#94a3b8"]));
  const wan = wanZone(zones);
  const { edges: lines, pseudo } = zoneEdges(zones);
  const edges: GEdge[] = lines.map((e) =>
    e.kind === "access"
      ? { source: e.source, target: e.target, color: color.get(e.source), arrow: true, ...(e.via ? { label: `serves ${e.via}` } : e.shared ? { label: `shared · ${e.shared.join(", ")}` } : {}) }
      : { source: e.source, target: e.target, color: "#f08c3a", dashed: true, arrow: true, label: e.via ? `pinhole · ${e.via}` : e.shared ? `pinhole · shared · ${e.shared.join(", ")}` : "pinhole" },
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
          <div className="cf-sub">{environmentsOf(z).length ? (isSharedService(z) ? `shared · serves ${environmentsOf(z).join(", ")}` : z.type === "Service" || z.type === "Management" ? `${environmentsOf(z)[0]}'s zone` : `serves ${environmentsOf(z).join(", ")}`) : z.ip ?? ""}</div>
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

// The zone's SSID row: read-only — the WiFi network is ap-manager's (#889), so
// the row names it, how clients join and its passphrase, and links to the WiFi
// step that changes it.
function SsidCell({ z, ssids }: { z: ZoneRead; ssids: SiteSsid[] | null }) {
  const name = typeof z.SSID === "string" ? z.SSID : null;
  const site = ssids?.find((s) => s.zone === z.name) ?? null;
  const to = WIFI_ZONE_TYPES.includes(z.type ?? "") ? `/setup/day2#wifi-${z.name}` : "/setup/day2#wifi";
  return (
    <>
      {name && !isPlaceholderSsid(name) ? name : <span className="muted">{name ? `${name} (not named yet)` : "no WiFi"}</span>}
      {site && site.name === name ? <span className="muted"> · {site.security} · passphrase {PASSPHRASE_TEXT[passphraseOf(site)]}</span> : null}
      {" "}
      <Link to={to} className="small">set from the WiFi step →</Link>
    </>
  );
}

// A field's value in the card: typeId with the type it numbers, ipv6Subnet
// with the /64 it numbers in the site's prefix.
function fieldText(r: FieldRow, z: ZoneRead, v6: Ipv6Read | null): string {
  if (r.field === "typeId") return typeIdText(r.value) ?? "—";
  if (r.field === "ipv6Subnet") return ipv6SubnetText(z, v6);
  return shortValue(r.value, 60);
}

function ZoneDetail({ z, schema, envNames, zoneNames, archetypes, wan, v6, close }: { z: ZoneRead; schema: Record<string, ZoneFieldSpec> | null; envNames: string[]; zoneNames: string[]; archetypes: string[]; wan: PublicAddress | null; v6: Ipv6Read | null; close: () => void }) {
  const rows: FieldRow[] = schema ? zoneFieldRows(z, schema) : [];
  const verbs = cardVerbs(z);
  const ssids = useRead<SiteSsid[]>("ssids", 600_000).env?.data ?? null;
  return (
    <aside className="sidepanel">
      <header>
        <div>
          <h2 className="mono">{z.name}</h2>
          <div className="muted small">{z.type} · {verbs.manual ? "manual" : z.state} · vlan {z.vlantag ?? "—"} · {wan ? publicText(wan) : z.ip ?? ""}</div>
        </div>
        <button className="btn-x" onClick={close} aria-label="close">×</button>
      </header>
      {z.description ? <p className="small">{z.description}</p> : null}
      {wan ? (
        <p className="small">
          This card stands for the internet as well. The site's public address comes from the site record (network.publicIp){wan.auto ? "; auto means the provider assigns it and the firewall's WAN takes it by DHCP, read at each network update" : ""}. The zone's ip <span className="mono">{z.ip ?? "—"}</span> only fills the schema: no interface, DHCP or rule is built from it.
        </p>
      ) : null}
      {verbs.manual ? (
        <p className="small">
          <b>manual</b>: the module that owns this zone keeps it. It is outside the enable/disable lifecycle, so it cannot be enabled, disabled or deleted here; Modify and Reconcile still apply.
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
        {verbs.states.map((w) => (
          <OperateButton
            key={w}
            label={`${w[0].toUpperCase()}${w.slice(1)}…`}
            title={`network-manager ${w} ${z.name}`}
            steps={[{ ...net(`network-manager ${w} ${z.name}`, "enable|disable|manual", { fixed: [z.name], note: "Writes the zone's state into zones.json only; the reconcile after makes it live." }), words: [w] }, reconcile]}
          />
        ))}
        {verbs.bind ? <OperateButton label="Bind…" title={`Bind ${z.name} to an environment`} steps={[net(`network-manager bind ${z.name}`, "bind", { fixed: [z.name], choices: { "--environment": envNames } })]} /> : null}
        <OperateButton label="Reconcile…" title="Reconcile the network" steps={[reconcile]} />
        {verbs.addLike ? <OperateButton label="Add one like it…" title={`Add a zone from ${z.name}`} steps={() => [addStep(zoneNames, archetypes, z.name)]} /> : null}
        {verbs.delete ? <OperateButton label="Delete…" kind="danger" title={`Delete zone ${z.name}`} steps={[net(`network-manager delete ${z.name}`, "delete", { fixed: [z.name] })]} /> : null}
      </div>
      <table className="table compact zfields">
        <tbody>
          {rows.map((r) => (
            <tr key={r.field} title={r.description}>
              <td className="mono">{r.field}</td>
              {r.field === "SSID" ? (
                <td className="mono wrap"><SsidCell z={z} ssids={ssids} /></td>
              ) : (
                <td className={`mono wrap${r.configured ? "" : " muted"}`}>{fieldText(r, z, v6)}{r.configured ? "" : <span className="dflt"> default</span>}</td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </aside>
  );
}

export function ZonesGraph({ zones, envNames, archetypes, v6, sel, setSel }: { zones: ZoneRead[]; envNames: string[]; archetypes: string[]; v6: Ipv6Read | null; sel: string | null; setSel: (z: string | null) => void }) {
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
        {z ? <ZoneDetail key={z.name} z={z} schema={schema} envNames={envNames} zoneNames={zones.map((x) => x.name)} archetypes={archetypes} wan={z.name === wan ? pub : null} v6={v6} close={() => setSel(null)} /> : null}
      </div>
      <div className="legend">
        {Object.entries(TYPE_COLOR).map(([t, c]) => (
          <span key={t} className="zone">
            <i style={{ background: c }} />
            {t}
          </span>
        ))}
        <span className="muted">→ may reach (access-to) · ⇢ may be let in through a pinhole (pinhole-allowed-from) · faded: inactive or disabled · click a zone, or its row below, for its fields and verbs</span>
      </div>
    </>
  );
}

// Where the IPv6 column's networks come from, or why it has none.
function ipv6Note(v6: Ipv6Read | null): string {
  if (!v6) return "IPv6: the site's prefix is being read…";
  if (!v6.on) return "IPv6 is off for the site (site.json ipv6): no zone has an IPv6 network.";
  if (v6.mode === "none") return "The WAN takes no IPv6 (network.wan.ipv6 mode none): no zone has an IPv6 network.";
  if (!v6.prefix) return `IPv6 is on, but no prefix is known${v6.error ? ` (${v6.error})` : ""}: the IPv6 column shows none until the WAN holds one.`;
  return `IPv6: each zone's /64 is its ipv6Subnet within ${v6.prefix} (${v6.source === "site.json" ? "routed to the site, site.json" : "delegated to the WAN, as the firewall holds it now"}); a zone without an ipv6Subnet has none.`;
}

// The Zones page (/zones): the graph with its side card, and the zones' table
// below it. A zone's verbs (network-manager modify / enable|disable /
// bind / reconcile / add from it / delete, each as a job with its preview; a
// delete needs the name typed) are on its card only: a click on its card or
// its row opens it. ?zone=<name> (the assistant's modify-zone, the
// Environments page's zone boxes, a selection here): that zone's card, open.
export function ZonesPage() {
  const envs = useRead<EnvironmentRow[]>("environments");
  const zones = useRead<ZoneRead[]>("zones");
  // The site's IPv6 prefix: each zone's /64 is its ipv6Subnet within it.
  const v6 = useRead<Ipv6Read>("ipv6", 600_000).env?.data ?? null;
  const [zone, setZone] = useState<string | null>(() => new URLSearchParams(window.location.search).get("zone"));
  useEffect(() => {
    const on = () => setZone(new URLSearchParams(window.location.search).get("zone"));
    window.addEventListener("popstate", on);
    return () => window.removeEventListener("popstate", on);
  }, []);
  const pick = useCallback((name: string | null) => {
    setZone(name);
    window.history.replaceState(null, "", name ? `/zones?zone=${encodeURIComponent(name)}` : "/zones");
  }, []);
  const modify = useOpenRequest("modify-zone");
  useEffect(() => {
    if (modify?.arg) pick(modify.arg);
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
            <OperateButton label="Add a zone…" title="Add a zone" steps={() => [addStep(zoneNames, archetypes)]} />
            <OperateButton label="Reconcile the network…" title="Reconcile the network" steps={[net("network-manager reconcile", "reconcile", { note: "The preview runs every plane dry (OPNsense, Proxmox, the switches, the APs); apply converges them all." })]} />
          </span>
        }
      >
        <ReadState env={zones.env} failure={zones.failure} what="zones" />
        {zones.env?.data ? <ZonesGraph zones={zones.env.data} envNames={envNames} archetypes={archetypes} v6={v6} sel={zone} setSel={pick} /> : null}
        <table className="table compact ztable">
          <thead>
            <tr><th>zone</th><th>type</th><th>vlan</th><th>IPv4</th><th>IPv6</th><th>environment</th><th>state</th><th>tier</th></tr>
          </thead>
          <tbody>
            {(zones.env?.data ?? []).map((z) => (
              <tr
                key={z.name}
                className={zone === z.name ? "row-on" : ""}
                title={z.description}
                onClick={() => {
                  pick(z.name);
                  document.querySelector(".zones-view")?.scrollIntoView({ behavior: "smooth", block: "nearest" });
                }}
              >
                <td className="mono">{z.name}</td>
                <td>{z.type ?? ""}</td>
                <td>{z.vlantag ?? ""}</td>
                <td className="mono">{z.ip ?? ""}</td>
                <td className="mono">{zoneV6(z, v6) ?? "-"}</td>
                <td>{environmentsOf(z).join(", ")}</td>
                <td className="nowrap"><Dot level={dot(z)} /> {z.state ?? z.error ?? ""}</td>
                <td>{z.tier ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted small">{ipv6Note(v6)}</p>
      </Section>
    </div>
  );
}
