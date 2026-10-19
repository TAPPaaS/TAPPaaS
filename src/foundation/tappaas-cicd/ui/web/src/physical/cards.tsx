// cards.tsx — the Physical view's objects as React Flow nodes (homelable's
// grammar: a status dot on every card, ports drawn on the switch, guests as
// chips on their node, a finding as ⚠ where it belongs). A click selects; the
// side panel shows the records.

import { Handle, Node, NodeProps, Position } from "@xyflow/react";
import { MouseEvent } from "react";
import { zoneColor } from "../colors";
import { Dot } from "../ui";
import { publicAddress, publicText } from "../zonegraph";
import { ApData, ClusterData, FirewallData, G, IspData, OutsideData, SwitchData, portLabel, portY, uplinkY } from "./layout";

const stop = (f: () => void) => (e: MouseEvent) => {
  e.stopPropagation();
  f();
};
const hidden = { opacity: 0, width: 6, height: 6, minWidth: 0, minHeight: 0, border: 0 };

function Warn({ n }: { n: number }) {
  return n > 0 ? <span className="warn-mark" title={`${n} finding(s)`}>⚠{n > 1 ? n : ""}</span> : null;
}

// ── the ISP ───────────────────────────────────────────────────────────
export function IspCard({ data }: NodeProps<Node<IspData, "isp">>) {
  const w = data.wan;
  return (
    <div className="card-flow card-isp" onClick={stop(() => data.pick({ kind: "isp", id: "isp" }))}>
      <div className="cf-title">
        <Dot level={data.findings.some((f) => f.level === "warn" || f.level === "fail") ? "warn" : "pass"} /> Internet · ISP
      </div>
      <div className="cf-sub">
        {publicText(publicAddress({ network: { publicIp: w.publicIp } }, w.discovered), true) || `public IP ${w.publicIp ?? "?"}`}
        {w.ipv6 ? " · IPv6" : ""}
      </div>
      <div className="cf-sub">{w.handoff ? `hand-off: ${w.handoff.switch} port ${w.handoff.port}` : "hand-off not on a registered port"}</div>
      <Handle type="source" position={Position.Right} id="out" style={{ ...hidden, top: 40 }} />
    </div>
  );
}

// ── the firewall, a callout on the WAN path ─────────────────────────────
export function FirewallCard({ data }: NodeProps<Node<FirewallData, "firewall">>) {
  const fw = data.wan.firewall!;
  const active = data.wan.paths.find((p) => p.active);
  const others = data.wan.paths.filter((p) => !p.active);
  return (
    <div className="card-flow card-fw" onClick={stop(() => data.pick({ kind: "firewall", id: fw.module }))}>
      <div className="cf-title">
        <Dot level="pass" /> {fw.module} · OPNsense {fw.vmid ? `(VM ${fw.vmid})` : ""} <Warn n={data.findings.length} />
      </div>
      <div className="cf-sub">wan bridge ← vlan {data.wan.vlan ?? "?"}{active ? ` via ${active.node}/${active.nic}` : ""}</div>
      <div className="cf-sub">
        {fw.standby ? `HA: ${fw.node} → ${fw.standby}` : others.length ? `wan also reaches ${others.map((p) => p.node).join(", ")} (no HA standby declared)` : "no second wan path"}
      </div>
      <Handle type="source" position={Position.Right} id="host" style={{ ...hidden, top: 30 }} />
    </div>
  );
}

// ── a switch, its ports and LAGs ───────────────────────────────────────
export function SwitchCard({ data }: NodeProps<Node<SwitchData, "switch">>) {
  const s = data.sw;
  const zoneOf = (name: string) => data.zones.find((z) => z.name === name) ?? { name };
  const portFindings = (p: string) => data.findings.filter((f) => (f.on.kind === "port" && f.on.name === p) || f.refs.some((r) => r.kind === "port" && r.name === p)).length;
  const sel = data.selected;
  return (
    <div className="card-flow card-switch" onClick={stop(() => data.pick({ kind: "switch", id: s.name }))}>
      <div className="cf-title">
        <Dot level={s.ports.some((p) => p.drift === "drift") ? "warn" : "pass"} /> {s.name}
      </div>
      <div className="cf-sub">
        {s.vendor ?? "?"} · {s.managed ?? "?"}
        {s.controller ? ` via ${s.controller}` : ""} · {s.ports.length} ports
      </div>
      <div className="ports">
        {s.ports.map((p) => {
          const n = portFindings(p.port);
          const on = sel?.kind === "port" && sel.switch === s.name && sel.id === p.port;
          return (
            <div
              key={p.port}
              className={`port port-${p.role}${on ? " port-on" : ""}`}
              style={{ height: G.portRow }}
              onClick={stop(() => data.pick({ kind: "port", id: p.port, switch: s.name }))}
              title={`port ${p.port}: ${p.mode} ${p.mode === "access" ? p.native : p.tagged.join(",")}`}
            >
              <span className="port-no">{p.port}</span>
              <span className="port-vlans">
                {p.role === "unmanaged" ? (
                  <i className="vl vl-grey" title="unmanaged" />
                ) : (
                  p.zones.map((z) => <i key={z} className={`vl${p.mode === "access" ? " vl-access" : ""}`} style={{ background: zoneColor(zoneOf(z)) }} title={z} />)
                )}
              </span>
              <span className="port-target">{portLabel(p)}</span>
              {p.lag ? <span className="port-lag" title={p.lagLead ? `follows port ${p.lagLead}: its VLANs are the lead's` : `leads LAG ${p.lag}`}>LAG</span> : null}
              {p.drift === "drift" ? <span className="port-drift" title={`drift: +${p.add.join(",")} -${p.remove.join(",")}`}>drift</span> : null}
              <Warn n={n} />
              <span className="port-mode">{p.role === "unmanaged" ? "—" : p.role === "parked" ? "parked" : p.mode === "access" ? `access ${p.native}` : "trunk"}</span>
            </div>
          );
        })}
      </div>
      {s.lags.map((l) => {
        const n = data.findings.filter((f) => f.refs.some((r) => r.kind === "lag" && r.name === l.name)).length;
        return (
          <div key={l.name} className="lag-row" style={{ height: G.lagRow }} onClick={stop(() => data.pick({ kind: "lag", id: l.name, switch: s.name }))}>
            LAG {l.name} = ports {l.ports.join("+")} {l.formed ? "(live)" : "(not formed)"} <Warn n={n} />
          </div>
        );
      })}
      {s.ports.map((p) => (
        <span key={`h-${p.port}`}>
          <Handle type="target" position={Position.Left} id={`l-${p.port}`} style={{ ...hidden, top: portY(s, p.port) }} />
          <Handle type="source" position={Position.Left} id={`l-${p.port}`} style={{ ...hidden, top: portY(s, p.port) }} />
          <Handle type="source" position={Position.Right} id={`r-${p.port}`} style={{ ...hidden, top: portY(s, p.port) }} />
        </span>
      ))}
    </div>
  );
}

// ── a cluster member, its uplinks and guests ───────────────────────────
export function ClusterCard({ data }: NodeProps<Node<ClusterData, "cluster">>) {
  const n = data.node;
  const pick = data.pick;
  const nodeLevel = data.findings.some((f) => f.level === "fail") ? "fail" : data.findings.length ? "warn" : "pass";
  return (
    <div className="card-flow card-node" onClick={stop(() => pick({ kind: "node", id: n.name }))}>
      <div className="cf-title">
        <Dot level={nodeLevel} title={n.ha ? `HA lrm ${n.ha.lrm}` : undefined} /> {n.name} <Warn n={data.findings.length} />
        <span className="cf-roles">{n.roles.join(" · ")}</span>
      </div>
      <div className="cf-sub">
        {data.memory ? `${data.memory} · ` : ""}
        {n.ha ? `HA ${n.ha.lrm}` : ""}
        {n.storagePools.length ? ` · ${n.storagePools.join(", ")}` : ""}
      </div>
      {n.uplinks.map((u) => (
        <div key={u.name} className="uplink" style={{ height: G.uplinkRow }}>
          <b>{u.name}</b> {u.bond ? `${u.bond} ` : ""}
          {u.mode} · {u.legs.map((l) => `${l.nic}${l.up ? "" : " (down)"}`).join("+")} {u.legs[0]?.speed ?? ""} →{" "}
          {u.legs.map((l) => (l.peer ? `${l.peer.port}` : "?")).join("+")}
        </div>
      ))}
      <div className="cf-sub">{n.guests.length} guest(s)</div>
      {data.showGuests ? (
        <div className="chips">
          {n.guests.map((g) => (
            <button
              key={g.module}
              className={`chip chip-${data.moduleLevel[g.module] ?? "ok"}${g.state !== "running" && g.vmid !== null ? " chip-down" : ""}`}
              onClick={stop(() => pick({ kind: "guest", id: g.module }))}
              title={`${g.module} · ${g.kind}${g.vmid ? ` ${g.vmid}` : ""} · ${g.state} · zone ${g.zone ?? "—"}`}
            >
              {g.module}
              {g.vmid ? <span className="chip-id"> {g.vmid}</span> : <span className="chip-id"> app</span>}
              {g.kind === "lxc" ? <span className="chip-id"> lxc</span> : null}
              {g.module === data.fwModule ? <span className="chip-fw"> fw</span> : null}
            </button>
          ))}
        </div>
      ) : null}
      {n.uplinks.flatMap((u) =>
        u.legs.map((_, i) => <Handle key={`${u.name}-${i}`} type="target" position={Position.Left} id={`leg-${u.name}-${i}`} style={{ ...hidden, top: uplinkY(n, u.name, i) }} />),
      )}
      <Handle type="target" position={Position.Top} id="top" style={{ ...hidden, left: 60 }} />
      <Handle type="target" position={Position.Top} id="tunnel" style={{ ...hidden, left: 200 }} />
    </div>
  );
}

// ── an access point ───────────────────────────────────────────────────
export function ApCard({ data }: NodeProps<Node<ApData, "ap">>) {
  const a = data.ap;
  return (
    <div className="card-flow card-ap" onClick={stop(() => data.pick({ kind: "ap", id: a.name }))}>
      <div className="cf-title">
        <Dot level="pass" /> {a.name} · AP
      </div>
      <div className="cf-sub">
        {a.address ?? "—"} · {a.ssids.length} SSID(s) mapped
      </div>
      <Handle type="target" position={Position.Top} id="up" style={{ ...hidden }} />
    </div>
  );
}

// ── a buddy or the satellite ───────────────────────────────────────────
export function OutsideCard({ data }: NodeProps<Node<OutsideData, "outside">>) {
  const o = data.o;
  if (!o) {
    return (
      <div className="card-flow card-outside card-absent">
        <div className="cf-title">satellite · none installed</div>
        <div className="cf-sub">ADR-010: would show the edge tunnel</div>
      </div>
    );
  }
  return (
    <div className="card-flow card-outside" onClick={stop(() => data.pick({ kind: "outside", id: o.name }))}>
      <div className="cf-title">
        <Dot level={o.state === "down" ? "warn" : o.state === "up" ? "pass" : "unknown"} title={o.state ?? undefined} /> {o.kind} {o.name}{" "}
        <Warn n={data.findings.length} />
      </div>
      <div className="cf-sub">
        {o.location ?? ""}
        {o.role ? ` · ${o.role}` : ""}
      </div>
      {o.tunnel ? <div className="cf-sub mono">tunnel {o.tunnel}</div> : null}
      <Handle type="source" position={Position.Right} id="out" style={{ ...hidden, top: 30 }} />
    </div>
  );
}

export const nodeTypes = {
  isp: IspCard,
  firewall: FirewallCard,
  switch: SwitchCard,
  cluster: ClusterCard,
  ap: ApCard,
  outside: OutsideCard,
};
