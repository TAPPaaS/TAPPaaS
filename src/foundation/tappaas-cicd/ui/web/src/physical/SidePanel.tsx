// SidePanel.tsx — what the console knows about the object clicked in the
// Physical view: its records as the managers report them, the findings on it,
// the day-2 changes it offers (a switch port's zone, spike mockup 3: the port's
// record with switch-manager update-port, then reconcile previewed and
// applied; a node's uplinks: site-manager node network show / set), and where
// to open it. Where the hardware sits (rack-manager): the mount of a node, a
// switch or an access point with Mount…, Move to… and Unmount…, a rack's own
// record, and a passive or outside device's mount and recorded cables. From
// the storage inventory: a disk, a pool with what it holds, a node's storage.

import { ReactNode, useMemo } from "react";
import { useRead } from "../api";
import { zoneColor } from "../colors";
import { Health, RackCable, SiteRead, StorageInventory, TopoFinding, TopoRef, Topology } from "../types";
import { sitePlace } from "./views";
import { OperateButton, Step } from "../operate";
import { KV, Link, OpenIn, Tag, canOperate, useMe } from "../ui";
import { Sel, portLabel } from "./layout";
import { MountActions, cableAddSteps, cableRemoveSteps, rackDeleteSteps, rackModifySteps } from "./rackops";
import { publicAddress } from "../zonegraph";
import { StorageNote } from "./storage";
import { DiskBody, NodeStorage, PoolBody } from "./storageview";
import { DevLink, DevNode, deviceGraph, deviceState, freePanelPorts, selectedDevice } from "./devicegraph";
import { iconOf, kindName } from "./devicecard";
import { DeviceDrawing } from "./devicedrawing";
import { stateClass } from "./states";

function Findings({ list }: { list: TopoFinding[] }) {
  if (list.length === 0) return <p className="muted small">No finding on it.</p>;
  return (
    <ul className="findings">
      {list.map((f, i) => (
        <li key={i}>
          <Tag level={f.level} /> <b>{f.gate}</b> {f.text}
        </li>
      ))}
    </ul>
  );
}

function Zones({ t, vlans }: { t: Topology; vlans: number[] }) {
  return (
    <span className="zones inline">
      {vlans.map((v) => {
        const z = t.zones.find((x) => x.vlan === v);
        return (
          <span key={v} className="zone">
            <i style={{ background: z ? zoneColor(z) : "#cbd5e1" }} />
            {v}
            {z ? ` ${z.name}` : ""}
          </span>
        );
      })}
    </span>
  );
}

const refIs = (r: TopoRef, kind: string, name: string, sw?: string) => r.kind === kind && r.name === name && (sw === undefined || r.switch === undefined || r.switch === sw);

// Where a device sits, as a row of its card.
function mountedAt(t: Topology, device: string): string | null {
  for (const r of t.racks?.racks ?? []) {
    const m = r.mounts.find((x) => x.device === device);
    if (m) return `${r.displayName ?? r.name} · U${m.u}${m.height > 1 ? `-U${m.u + m.height - 1}` : ""} · ${m.face}${m.width === "full" ? "" : ` · ${m.width} width, slot ${m.slot}`} · ${m.faceplate ?? "no plate"}${m.suggested ? " (suggested)" : ""}`;
  }
  for (const r of t.racks?.rooms ?? []) {
    const m = r.loose.find((x) => x.device === device);
    if (m) return `loose in room ${r.displayName ?? r.name} · ${m.faceplate ?? "no plate"}`;
  }
  return t.racks ? "mounted in no rack, in no room" : null;
}

// The ports of a device that a cable joins, and the link each is on.
function portsOf(links: DevLink[], device: string): Map<string, DevLink> {
  const m = new Map<string, DevLink>();
  for (const l of links) for (const c of l.cables) for (const e of [c.from, c.to]) if (e.device === device) m.set(e.port, l);
  return m;
}

// The far end of a link, seen from one device.
const farEnd = (l: DevLink, device: string) => (l.a === device ? l.b : l.a);

export function SidePanel({ t, sel, close, pick, storage }: { t: Topology; sel: Sel; close: () => void; pick: (s: Sel) => void; storage?: { inv: StorageInventory; notes: Map<string, StorageNote[]> } | null }) {
  const operator = canOperate(useMe());
  const health = useRead<Health>("health");
  const place = sitePlace((useRead<SiteRead>("site").env?.data?.site ?? null) as Parameters<typeof sitePlace>[0]);
  const g = useMemo(() => deviceGraph(t), [t]);
  const devOf = (id: string): DevNode | undefined => g.nodes.find((n) => n.id === id);
  // A port clicked in a drawing: a switch's port is selected, any other's link.
  const portClick = (d: DevNode) => (port: string) => {
    if (d.kind === "switch") return pick({ kind: "port", id: port, switch: d.name });
    const l = portsOf(g.links, d.name).get(port);
    if (l) pick({ kind: "link", id: l.id, port: `${d.name}:${port}` });
  };
  const drawing = (d: DevNode, ringed: Set<string>) => <DeviceDrawing key={d.id} t={t} d={d} cabled={new Set(portsOf(g.links, d.name).keys())} ringed={ringed} onPort={portClick(d)} />;
  // A device's neighbours, each a click away.
  const neighbours = (d: DevNode) => {
    const ls = g.links.filter((l) => l.a === d.id || l.b === d.id);
    if (!ls.length) return null;
    return (
      <>
        <h3>Connected to</h3>
        <ul className="plain small">
          {ls.map((l) => {
            const far = devOf(farEnd(l, d.id))!;
            const mine = l.cables.map((c) => (c.from.device === d.name ? c.from.port : c.to.device === d.name ? c.to.port : null)).filter(Boolean);
            return (
              <li key={l.id}>
                <button className="linklike" onClick={() => pick(far.sel)}>{iconOf(far)} {far.name}</button>{" "}
                <span className="muted">{mine.length ? `on ${mine.join(", ")} · ` : ""}{l.kind}{l.cables.length > 1 ? ` · ${l.cables.length} cables` : ""}</span>{" "}
                <button className="linklike small" onClick={() => pick({ kind: "link", id: l.id })}>the link</button>
              </li>
            );
          })}
        </ul>
      </>
    );
  };
  const racks = t.racks ?? null;
  const about = (kind: string, name: string, sw?: string) => t.findings.filter((f) => refIs(f.on, kind, name, sw) || f.refs.some((r) => refIs(r, kind, name, sw)));
  let title: ReactNode = sel.id;
  let body: ReactNode = null;
  let open: ReactNode = null;
  let actions: ReactNode = null;

  switch (sel.kind) {
    case "port": {
      const s = t.switches.find((x) => x.name === sel.switch);
      const p = s?.ports.find((x) => x.port === sel.id);
      if (!s || !p) break;
      const lag = p.lag ? s.lags.find((l) => l.name === p.lag) : undefined;
      const recorded = racks?.cables.find((c) => c.source === "recorded" && [c.from, c.to].some((e) => e.device === s.name && e.port === p.port));
      title = `Port ${p.port} · ${s.name}`;
      body = (
        <>
          <p>
            <Tag level={p.drift === "drift" ? "warn" : "pass"} />{" "}
            {p.lagLead
              ? `follows port ${p.lagLead}, the lead of LAG ${p.lag}: the switch takes the aggregate's VLANs from the lead, and they are shown here`
              : p.parked
                ? p.drift === "drift" ? `parked in ${p.zones[0] ?? "iotLocal"} by its record, the switch has it otherwise: reconcile sets it` : `parked in ${p.zones[0] ?? "iotLocal"}: a device plugged in gets an address and reaches nothing`
                : p.drift === "unmanaged" ? `no record and not parked — on the controller's default profile${p.link === "up" ? "; a link is up" : ""}` : p.drift === "drift" ? "drifts from zones.json" : "in sync with zones.json"}
          </p>
          <KV
            rows={[
              ["role", p.role],
              ["type", p.type],
              ["connects", portLabel(p)],
              ["mode", p.mode],
              ["native / access", p.mode === "access" ? <Zones t={t} vlans={[p.native]} /> : p.native || null],
              ["tagged", p.mode === "trunk" && p.tagged.length ? <Zones t={t} vlans={p.tagged} /> : null],
              ["aggregate", lag ? `${lag.name} · ports ${lag.ports.join("+")} · ${lag.formed ? `live ${lag.live.join("+")}` : "not formed"}` : null],
              ["link", p.link ?? null],
              ["LLDP partner", p.seen ? `${p.seen.node} / ${p.seen.nic}` : null],
              ["description", p.description],
              ["drift", p.drift === "drift" ? `add ${p.add.join(",") || "-"} · remove ${p.remove.join(",") || "-"}` : null],
              ["recorded cable", recorded ? `to ${recorded.from.device === s.name && recorded.from.port === p.port ? `${recorded.to.device}:${recorded.to.port}` : `${recorded.from.device}:${recorded.from.port}`} (${recorded.kind}${recorded.label ? `, ${recorded.label}` : ""})` : null],
            ]}
          />
          {(() => {
            const l = portsOf(g.links, s.name).get(p.port);
            const far = l ? devOf(farEnd(l, s.name)) : undefined;
            return l && far ? (
              <p className="toolbar">
                <button className="btn" onClick={() => pick(far.sel)}>{iconOf(far)} {far.name}</button>
                <button className="btn" onClick={() => pick({ kind: "link", id: l.id, port: `${s.name}:${p.port}` })}>the link</button>
              </p>
            ) : null;
          })()}
          <h3>Findings</h3>
          <Findings list={about("port", p.port, s.name)} />
        </>
      );
      open = <OpenIn kind="port" id={p.port} sw={s.name} />;
      actions = (
        <>
          <PortChange t={t} sw={s.name} port={p.port} type={p.type} parked={p.parked === true} lag={p.lag} mode={p.mode} zone={p.zones[0] ?? ""} description={p.description} />
          {racks && recorded ? <OperateButton label="Remove the cable…" kind="danger" title={`The recorded cable on ${s.name}:${p.port}`} steps={() => cableRemoveSteps(`${s.name}:${p.port}`)} /> : null}
          {racks && !recorded && (!p.target || p.target.kind === "isp" || !p.target.name) ? <OperateButton label="Record a cable…" title={`A cable from ${s.name}:${p.port}`} steps={() => cableAddSteps(`${s.name}:${p.port}`)} /> : null}
        </>
      );
      break;
    }
    case "switch": {
      const s = t.switches.find((x) => x.name === sel.id);
      if (!s) break;
      title = s.name;
      body = (
        <>
          <KV
            rows={[
              ["vendor / model", `${s.vendor ?? "?"} · ${s.model ?? "?"}`],
              ["management", s.managementIp],
              ["managed", s.managed],
              ["controller", s.controller ? `${s.controller}${s.controllerAddress ? ` (${s.controllerAddress})` : ""}` : null],
              ["LLDP name", s.lldpName],
              ["ports", `${s.ports.length} · ${s.ports.filter((p) => p.parked).length} parked · ${s.ports.filter((p) => p.role === "unmanaged").length} unmanaged · ${s.ports.filter((p) => p.drift === "drift").length} drifting`],
              ["LAGs", s.lags.map((l) => `${l.name} (${l.ports.join("+")})`).join(", ")],
              ["mounted", mountedAt(t, s.name)],
            ]}
          />
          <h3>Ports</h3>
          <table className="table compact small">
            <tbody>
              {s.ports.map((p) => (
                <tr key={p.port} className={p.drift === "drift" ? "row-warn" : undefined}>
                  <td><button className="linklike" onClick={() => pick({ kind: "port", id: p.port, switch: s.name })}>{p.port}</button></td>
                  <td className="muted">{p.link ?? ""}</td>
                  <td>{portLabel(p)}</td>
                  <td className="muted">{p.role === "parked" || p.parked ? "parked" : p.mode === "access" ? `access ${p.zones[0] ?? p.native}` : p.mode}{p.lag ? ` · ${p.lag}` : ""}{p.drift === "drift" ? " · drift" : ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <h3>Findings</h3>
          <Findings list={t.findings.filter((f) => f.on.switch === s.name || f.refs.some((r) => r.switch === s.name))} />
        </>
      );
      open = <OpenIn kind="switch" id={s.name} />;
      actions = <MountActions device={s.name} v={racks} />;
      break;
    }
    case "lag": {
      const s = t.switches.find((x) => x.name === sel.switch);
      const l = s?.lags.find((x) => x.name === sel.id);
      if (!s || !l) break;
      title = `LAG ${l.name}`;
      body = (
        <>
          <KV rows={[["switch", s.name], ["ports", l.ports.join(" + ")], ["formed", l.formed ? `yes, live ${l.live.join("+")}` : "no"], ["node", l.node], ["bond", l.bond]]} />
          <h3>Findings</h3>
          <Findings list={about("lag", l.name, s.name)} />
        </>
      );
      open = <OpenIn kind="lag" id={l.name} sw={s.name} />;
      break;
    }
    case "node": {
      const n = t.nodes.find((x) => x.name === sel.id);
      if (!n) break;
      title = n.name;
      body = (
        <>
          <KV
            rows={[
              ["roles", n.roles.join(", ")],
              ["memory", health.env?.data?.gates.find((x) => x.name === "memory-commitment")?.findings.find((f) => f.subject?.kind === "node" && f.subject.name === n.name)?.text ?? null],
              ["storage pools", n.storagePools.join(", ")],
              ["HA", n.ha ? `lrm ${n.ha.lrm}` : null],
              ["corosync", n.corosync ? `${n.corosync.links} link(s), ${n.corosync.disconnected} disconnected` : null],
              ["lldpd", n.lldpd],
              ["mounted", mountedAt(t, n.name)],
            ]}
          />
          <h3>Uplinks</h3>
          {n.uplinks.map((u) => (
            <div key={u.name} className="uplink-detail">
              <b>{u.name}</b> · {u.mode}
              {u.bond ? ` · ${u.bond}` : ""}
              {u.mtu ? ` · mtu ${u.mtu}` : ""}
              {u.declared ? <span className="muted"> · declared {u.declared.mode ?? ""} {u.declared.ports.join(", ")}</span> : null}
              <ul className="plain">
                {u.legs.map((l) => (
                  <li key={l.nic} className="mono">
                    {l.nic} {l.mac} {l.speed ?? ""} {l.up ? "up" : "DOWN"} → {l.peer ? `${l.peer.switch} port ${l.peer.port} (${l.peer.via})` : "no peer known"}
                  </li>
                ))}
              </ul>
            </div>
          ))}
          <h3>Guests ({n.guests.length})</h3>
          <ul className="plain">
            {n.guests.map((g) => (
              <li key={g.module}>
                <Link to={`/modules/${encodeURIComponent(g.module)}`}>{g.module}</Link> <span className="muted">{g.kind} {g.vmid ?? ""} · {g.state} · {g.zone ?? "—"}</span>
              </li>
            ))}
          </ul>
          <h3>Findings</h3>
          <Findings list={t.findings.filter((f) => f.on.kind === "node" && f.on.name === n.name)} />
          {(() => {
            const g = t.findings.filter((f) => f.on.kind === "module" && n.guests.some((x) => x.module === f.on.name)).length;
            return g ? <p className="muted small">and {g} finding(s) on its guests — click a guest chip.</p> : null;
          })()}
          {storage ? <NodeStorage inv={storage.inv} notes={storage.notes} node={n.name} /> : null}
        </>
      );
      open = <OpenIn kind="node" id={n.name} />;
      actions = (
        <>
          <NodeNetwork node={n.name} />
          <MountActions device={n.name} v={racks} />
        </>
      );
      break;
    }
    case "guest": {
      const host = t.nodes.find((n) => n.guests.some((g) => g.module === sel.id));
      const g = host?.guests.find((x) => x.module === sel.id);
      if (!g) break;
      title = g.module;
      body = (
        <>
          <KV
            rows={[
              ["kind", `${g.kind}${g.vmid ? ` ${g.vmid}` : ""}`],
              ["runs on", host?.name],
              ["state", g.state],
              ["zone", g.zone],
              ["environment", g.environment],
              ["stack", g.stack],
              ["maturity", g.maturity],
            ]}
          />
          <p>
            <Link to={`/modules/${encodeURIComponent(g.module)}`}>Open the module page →</Link>
          </p>
          <h3>Findings</h3>
          <Findings list={about("module", g.module)} />
        </>
      );
      open = <OpenIn kind="module" id={g.module} />;
      break;
    }
    case "ap": {
      const a = t.accessPoints.find((x) => x.name === sel.id);
      if (!a) break;
      title = `${a.name} · access point`;
      body = (
        <>
          <KV rows={[["vendor / model", `${a.vendor ?? "?"} · ${a.model ?? "?"}`], ["address", a.address], ["uplink", a.uplink ? `${a.uplink.switch} port ${a.uplink.port}` : null], ["mounted", mountedAt(t, a.name)]]} />
          <h3>SSIDs</h3>
          {a.ssids.length === 0 ? <p className="muted small">No SSID mapped to a zone (ap-manager ssid … add).</p> : null}
          <ul className="plain">
            {a.ssids.map((s) => (
              <li key={s.name}>
                {s.name} · zone {s.zone ?? "?"} · vlan {s.vlan ?? "?"} · {s.security ?? "?"}
                {s.enabled ? "" : " · disabled"}
              </li>
            ))}
          </ul>
        </>
      );
      open = <OpenIn kind="ap" id={a.name} />;
      actions = <MountActions device={a.name} v={racks} />;
      break;
    }
    case "outside": {
      const o = t.outside.find((x) => x.name === sel.id);
      if (!o) break;
      title = `${o.kind} ${o.name}`;
      body = (
        <>
          <KV rows={[["role", o.role], ["location", o.location], ["tunnel", o.tunnel], ["address", o.address], ["pulse", o.state]]} />
          <h3>Findings</h3>
          <Findings list={about("peer", o.name)} />
        </>
      );
      open = <OpenIn kind="peer" id={o.name} />;
      break;
    }
    case "isp": {
      const w = t.site.wan;
      const pa = publicAddress({ network: { publicIp: w.publicIp } }, w.discovered);
      title = "Internet · ISP";
      body = (
        <>
          <KV
            rows={[
              ["public IP", pa.address ? `${pa.address}${pa.auto ? " (auto: what the WAN held)" : ""}` : pa.wan ? `the router's in front of the WAN (the WAN holds ${pa.wan})` : w.publicIp],
              ["WAN read", pa.observed],
              ["IPv6", w.ipv6 ? "on" : "off"],
              ["ISP", w.isp],
              ["WAN zone", w.zone ? `${w.zone} · vlan ${w.vlan ?? "?"}` : null],
              ["hand-off", w.handoff ? `${w.handoff.switch} port ${w.handoff.port}${w.handoff.description ? ` — ${w.handoff.description}` : ""}` : null],
            ]}
          />
          <h3>WAN path</h3>
          <ul className="plain">
            {w.paths.map((p) => (
              <li key={p.node + p.nic}>
                {p.active ? "● " : "○ "}
                {p.node}/{p.nic} ← {p.switch ?? "?"} port {p.port ?? "?"} {p.active ? "(the firewall runs here)" : ""}
              </li>
            ))}
          </ul>
          <Findings list={about("site", "uplink")} />
        </>
      );
      open = <OpenIn kind="site" id="site" />;
      break;
    }
    case "firewall": {
      const w = t.site.wan;
      const fw = w.firewall;
      if (!fw) break;
      title = `${fw.module} · the firewall`;
      body = (
        <>
          <KV rows={[["VM", fw.vmid], ["runs on", fw.node], ["HA standby", fw.standby ?? "none declared"], ["WAN", `vlan ${w.vlan ?? "?"} on ${w.paths.filter((p) => p.active).map((p) => `${p.node}/${p.nic}`).join(", ") || "?"}`]]} />
          <p className="small muted">
            Other nodes with a wan port: {w.paths.filter((p) => !p.active).map((p) => `${p.node}/${p.nic} (port ${p.port ?? "?"})`).join(", ") || "none"} — where the firewall could run.
          </p>
          <p>
            <Link to={`/modules/${encodeURIComponent(fw.module)}`}>Open the module page →</Link>
          </p>
          <h3>Findings</h3>
          <Findings list={about("module", fw.module)} />
        </>
      );
      open = <OpenIn kind="module" id={fw.module} />;
      break;
    }
    case "rack": {
      const r = racks?.racks.find((x) => x.name === sel.id);
      if (!r) break;
      title = `${r.displayName ?? r.name} · rack`;
      const used = r.mounts.reduce((n, m) => n + (m.width === "full" ? m.height : 0), 0);
      body = (
        <>
          <KV
            rows={[
              ["name", r.name],
              ["height", `${r.units}U, ${r.width}, numbered ${r.numbering === "bottom-up" ? "from the bottom" : "from the top"}`],
              ["building", place ? `${place} (the site's)` : null],
              ["room", r.room],
              ["description", r.description],
              ["mounts", `${r.mounts.length} · ${used} of ${r.units} units at full width`],
            ]}
          />
          <h3>Mounted</h3>
          <ul className="plain">
            {r.mounts.map((m) => (
              <li key={m.device} className="small">
                U{m.u}
                {m.height > 1 ? `-${m.u + m.height - 1}` : ""} {m.face} · {m.device}
                {m.description ? <span className="muted"> · {m.description}</span> : null}
              </li>
            ))}
          </ul>
          <h3>Findings</h3>
          <Findings list={about("rack", r.name)} />
        </>
      );
      actions = (
        <>
          <OperateButton label="Change…" title={`Rack ${r.name}`} steps={() => rackModifySteps(r.name)} />
          {r.mounts.length === 0 ? <OperateButton label="Delete…" kind="danger" title={`Delete rack ${r.name}`} steps={() => rackDeleteSteps(r.name)} /> : null}
        </>
      );
      open = <p className="muted small">A rack is a record of config/racks.json only.</p>;
      break;
    }
    case "link": {
      const l = g.links.find((x) => x.id === sel.id);
      if (!l) break;
      const [a, b] = [devOf(l.a)!, devOf(l.b)!];
      title = `${a.name} ↔ ${b.name}`;
      const ends = (d: DevNode) => new Set(l.cables.flatMap((c) => [c.from, c.to]).filter((e) => e.device === d.name).map((e) => e.port));
      body = (
        <>
          {[a, b].map((d) => drawing(d, ends(d)))}
          {/* the patch panels it runs through, their ports ringed */}
          {[...new Set(l.cables.flatMap((c) => c.via ?? []).map((v) => v.device))].map((p) => {
            const pd = devOf(p);
            return pd ? drawing(pd, new Set(l.cables.flatMap((c) => c.via ?? []).filter((v) => v.device === p).map((v) => v.port))) : null;
          })}
          <p>
            <Tag level={l.up === false ? "fail" : "pass"} /> {l.cables.length ? [...new Set(l.cables.map((c) => c.kind))].join(" and ") : l.kind}
            {l.cables.length > 1 ? `, ${l.cables.length} cables` : ""}
            {l.kind === "hand-off" ? ": where the provider's line meets the site" : l.kind === "tunnel" ? ": the buddy's WireGuard tunnel, to the firewall on this node" : ""}
          </p>
          {l.cables.length ? (
            <table className="table compact small">
              <tbody>
                {l.cables.map((c, i) => (
                  <tr key={i} className={sel.port && (sel.port === `${c.from.device}:${c.from.port}` || sel.port === `${c.to.device}:${c.to.port}`) ? "row-on" : undefined}>
                    <td className="mono">{c.from.device}:{c.from.port}</td>
                    <td className="mono">{c.to.device}:{c.to.port}</td>
                    <td className="muted">
                      {[c.up === true ? "up" : c.up === false ? "down" : null, c.lag ? `LAG ${c.lag}` : null, c.zones.length ? c.zones.join(", ") : null, c.source === "recorded" ? "recorded" : null, c.label].filter(Boolean).join(" · ")}
                      {c.segments?.length ? (
                        <ol className="segments">
                          {c.segments.map((w, j) => (
                            <li key={j} className="mono">
                              {w.from.device}:{w.from.port}{w.from.side ? ` (${w.from.side})` : ""} → {w.to.device}:{w.to.port}{w.to.side ? ` (${w.to.side})` : ""}
                            </li>
                          ))}
                        </ol>
                      ) : null}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
          <div className="toolbar">
            <button className="btn" onClick={() => pick(a.sel)}>{iconOf(a)} {a.name}</button>
            <button className="btn" onClick={() => pick(b.sel)}>{iconOf(b)} {b.name}</button>
          </div>
          <h3>Findings</h3>
          <Findings list={t.findings.filter((f) => l.cables.some((c) => [c.from, c.to].some((e) => (f.on.kind === "port" && f.on.switch === e.device && f.on.name === e.port))))} />
        </>
      );
      const recorded = l.cables.find((c) => c.source === "recorded" && !c.segments?.length);
      actions = racks ? (
        <>
          {l.cables.map((c, i) => (c.segments?.length ? <PanelJoin key={i} c={c} /> : <PanelSplit key={i} t={t} c={c} many={l.cables.length > 1} />))}
          {recorded ? <OperateButton label="Remove the cable…" kind="danger" title="Remove a recorded cable" steps={() => cableRemoveSteps(`${recorded.from.device}:${recorded.from.port}`)} /> : null}
        </>
      ) : null;
      open = <p className="muted small">A link is the topology's and the cable records'; its ends have their own jumps.</p>;
      break;
    }
    case "disk":
    case "pool": {
      if (!storage) break;
      const b = sel.kind === "disk" ? DiskBody({ inv: storage.inv, notes: storage.notes, node: sel.node, device: sel.id }) : PoolBody({ inv: storage.inv, notes: storage.notes, node: sel.node, pool: sel.id });
      if (!b) break;
      title = b.title;
      body = b.body;
      open = b.open;
      break;
    }
    case "room": {
      const room = racks?.rooms?.find((x) => x.name === sel.id);
      if (!room) break;
      title = `${room.displayName ?? room.name} · room`;
      body = (
        <>
          <KV rows={[["name", room.name], ["building", place ? `${place} (the site's)` : "the site's location names none"], ["description", room.description], ["recorded", room.recorded ? "yes" : "no — only a rack's text names it (rack-manager room add)"]]} />
          <h3>Racks</h3>
          <ul className="plain small">
            {room.racks.map((r) => (
              <li key={r}><button className="linklike" onClick={() => pick({ kind: "rack", id: r })}>{r}</button></li>
            ))}
            {room.racks.length === 0 ? <li className="muted">none</li> : null}
          </ul>
          <h3>Loose in it</h3>
          <ul className="plain small">
            {room.loose.map((m) => (
              <li key={m.device}><button className="linklike" onClick={() => pick({ kind: "mount", id: m.device })}>{m.device}</button> <span className="muted">{m.plate ? `${m.plate.vendor} ${m.plate.model}` : m.kind}</span></li>
            ))}
            {room.loose.length === 0 ? <li className="muted">nothing</li> : null}
          </ul>
        </>
      );
      const rmStep = (verb: string, t: string, extra: Partial<Step> = {}): Step => ({ title: t, bin: "rack-manager", verb, fixed: [room.name], ...extra });
      actions = room.recorded ? (
        <>
          <OperateButton label="Change…" title={`Room ${room.name}`} steps={[rmStep("room modify", `rack-manager room modify ${room.name}`, { note: "Its display name or description (its building is the site's); --check previews." })]} />
          {room.racks.length === 0 && room.loose.length === 0 ? <OperateButton label="Delete…" kind="danger" title={`Delete room ${room.name}`} steps={[rmStep("room delete", `rack-manager room delete ${room.name}`)]} /> : null}
        </>
      ) : /^[a-z][a-z0-9-]{0,62}$/.test(room.name) ? (
        <OperateButton label="Record the room…" title={`Record room ${room.name}`} steps={[rmStep("room add", `rack-manager room add ${room.name}`)]} />
      ) : (
        // A room name is lower case: record it under one, then point the racks at it.
        <p className="muted small">
          '{room.name}' is no room name (lower case letters, digits, dashes): record it as{" "}
          <span className="mono">rack-manager room add {room.name.toLowerCase().replace(/[^a-z0-9-]+/g, "-")} --display-name '{room.name}'</span>, then set each rack's room to it ({room.racks.map((r) => `rack modify ${r} --set room=…`).join(", ")}).
        </p>
      );
      open = <p className="muted small">A room is a record of config/racks.json only.</p>;
      break;
    }
    case "mount": {
      // A device a node, switch or access point card does not cover: a machine,
      // a device module, a passive plate (patch panel, PDU) or a device a cable
      // record places (the ISP's modem).
      const m = [...(racks?.racks.flatMap((r) => r.mounts) ?? []), ...(racks?.rooms?.flatMap((r) => r.loose) ?? [])].find((x) => x.device === sel.id);
      const out = racks?.outside.find((x) => x.device === sel.id);
      const un = racks?.unplaced.find((x) => x.device === sel.id);
      if (!m && !out && !un) break;
      const cables = (racks?.cables ?? []).filter((c) => c.from.device === sel.id || c.to.device === sel.id);
      const rec = t.devices?.find((x) => x.name === sel.id && x.recorded);
      title = rec?.displayName ? `${rec.displayName} · ${sel.id}` : sel.id;
      body = (
        <>
          <KV
            rows={[
              ["kind", rec ? `${rec.kind} (recorded: nothing can see it)` : m ? (m.kind === "passive" ? `passive (${m.plate?.kind ?? "plate"})` : m.kind) : out ? "placed by a cable record" : un?.kind ?? null],
              ["model", rec?.model ?? null],
              ["ports", rec?.ports?.length ? rec.ports.join(", ") : null],
              ["mounted", m ? mountedAt(t, sel.id) : out ? "outside the racks" : "mounted in no rack"],
              ["faceplate", m?.plate ? `${m.plate.vendor} ${m.plate.model} (${m.faceplate})` : out?.faceplate ?? un?.suggestion ?? null],
              ["label", m?.label ?? null],
              ["description", m?.description ?? rec?.description ?? null],
            ]}
          />
          {rec?.kind === "patch-panel" ? (
            <>
              <h3>Ports</h3>
              <table className="table compact small">
                <thead>
                  <tr><th>port</th><th>front</th><th>rear</th></tr>
                </thead>
                <tbody>
                  {(rec.ports ?? []).map((p) => {
                    const at = (side: "front" | "rear") => {
                      const c = cables.find((x) => [x.from, x.to].some((e) => e.device === sel.id && e.port === p && (e.side ?? "front") === side));
                      if (!c) return <span className="muted">free</span>;
                      const far = c.from.device === sel.id && c.from.port === p ? c.to : c.from;
                      return `${far.device}:${far.port}`;
                    };
                    return (
                      <tr key={p}>
                        <td className="mono">{p}</td>
                        <td>{at("front")}</td>
                        <td>{at("rear")}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </>
          ) : null}
          <h3>Cables</h3>
          {cables.length === 0 ? <p className="muted small">No cable on it.</p> : null}
          <ul className="plain">
            {cables.map((c, i) => (
              <li key={i} className="small mono">
                {c.from.device}:{c.from.port} — {c.to.device}:{c.to.port} <span className="muted">{c.kind}{c.source === "recorded" ? " · recorded" : ""}</span>
              </li>
            ))}
          </ul>
          <h3>Findings</h3>
          <Findings list={t.findings.filter((f) => f.text.includes(sel.id))} />
        </>
      );
      const recActs = rec ? <DeviceRecordActions name={sel.id} cabled={cables.some((c) => c.source === "recorded")} mounted={!!m} /> : null;
      actions = m ? (
        <>
          <MountActions device={sel.id} v={racks} />
          {recActs}
        </>
      ) : out ? (
        <>
          {cables.filter((c) => c.source === "recorded").map((c) => (
            <OperateButton key={`${c.from.device}:${c.from.port}`} label={`Remove the cable on ${c.from.device === sel.id ? c.from.port : c.to.port}…`} kind="danger" title="Remove a recorded cable" steps={() => cableRemoveSteps(c.from.device === sel.id ? `${c.from.device}:${c.from.port}` : `${c.to.device}:${c.to.port}`)} />
          ))}
        </>
      ) : (
        <>
          <MountActions device={sel.id} v={racks} />
          {recActs}
        </>
      );
      open = <p className="muted small">{rec ? "Nothing reports on it: rack-manager records it." : out ? "Nothing reports on it: it is known only by the cable that names it — record it (rack-manager device add) to mount it." : "Its own records are on the module's page."}</p>;
      break;
    }
  }

  // A device's panel: its drawing on top, its neighbours below its records.
  const dev = sel.kind === "link" || sel.kind === "disk" || sel.kind === "pool" || sel.kind === "rack" ? undefined : devOf(selectedDevice(g, sel) ?? "");
  const st = dev ? deviceState(t, dev) : null;
  const ringed = new Set(sel.kind === "port" ? [sel.id] : sel.kind === "lag" ? t.switches.find((x) => x.name === sel.switch)?.lags.find((x) => x.name === sel.id)?.ports ?? [] : []);
  return (
    <aside className="sidepanel">
      <header>
        <h2>
          {dev ? <span className={`dev-badge ${stateClass(st!.state)}`} title={`${kindName(dev)} · ${st!.state}${st!.reasons.length ? `: ${st!.reasons.join("; ")}` : ""}`}>{iconOf(dev)}</span> : null} {title}
        </h2>
        <button className="btn-x" onClick={close} aria-label="close">
          ×
        </button>
      </header>
      {dev ? drawing(dev, ringed) : null}
      {body ?? <p className="muted">Not in the current topology.</p>}
      {dev && sel.kind !== "port" && sel.kind !== "lag" ? neighbours(dev) : null}
      {actions && operator ? (
        <>
          <h3>Change</h3>
          <div className="toolbar">{actions}</div>
        </>
      ) : null}
      <h3>Open in</h3>
      {open}
      <p className="muted small">For debugging: these open the component UIs in a new tab; nothing is changed there from here.</p>
    </aside>
  );
}

// A switch port's change (mockup 3): its record first, then the switch.
function PortChange({ t, sw, port, type, parked, lag, mode, zone, description }: { t: Topology; sw: string; port: string; type: string | null; parked: boolean; lag: string | null; mode: string; zone: string; description: string | null }) {
  const zones = t.zones.filter((z) => z.vlan !== null && z.state !== "Disabled").map((z) => z.name);
  const steps: Step[] = [
    {
      title: `1 · The port's record: switch-manager update-port '${sw}' ${port}`,
      bin: "switch-manager",
      verb: "update-port",
      fixed: [sw, port],
      // The port as it is; a zone only for an access port (a trunk's first VLAN is not "its" zone).
      initial: { "--type": type ?? "device", "--mode": mode === "access" ? "access" : mode || "access", "--zone": mode === "access" ? zone : "", "--description": description ?? "" },
      choices: { "--zone": zones },
      note: "This writes the port's record (switch-configuration-actual.json) and nothing else: the switch is programmed in the next step. An access port carries one zone; a trunk the zones in --tagged.",
    },
    {
      title: "2 · Program the switch: switch-manager reconcile",
      bin: "switch-manager",
      verb: "reconcile",
      note: "The preview is the delta per port (interrogate, update-desired, delta — nothing applied). Apply programs every pending change on every switch, not only this port's: read the preview's list before you apply.",
    },
  ];
  // A port is given back by parking it (#853): remove-port sets it on the switch
  // as an access port in iotLocal, at once, then records it parked. The
  // controller's own default profile is never restored: it is a trunk of every
  // network, the exposure parking removes.
  const park: Step[] = [
    {
      title: `Park port ${port}: switch-manager remove-port '${sw}' ${port}`,
      bin: "switch-manager",
      verb: "remove-port",
      fixed: [sw, port],
      note: "Sets the port on the switch now, alone, as an access port in iotLocal (tier 6, no internet, nothing else reachable), then replaces its record with a parked one. Whatever is plugged in loses what the port carried. Only this port is pushed, nothing else pending on the switch.",
    },
    { title: "Read the switch again: switch-manager reconcile (preview)", bin: "switch-manager", verb: "reconcile", note: "Its preview interrogates the switch: the port shows parked and in sync. Nothing needs applying for it." },
  ];
  return (
    <>
      <OperateButton label={`Change port ${port}…`} title={`Port ${port} · ${sw}`} steps={steps} />
      {!parked && !lag ? <OperateButton label="Park…" kind="danger" title={`Port ${port} · ${sw}: park`} steps={park} /> : null}
    </>
  );
}

// A node's uplinks: read them, or set them (preview without --apply).
function NodeNetwork({ node }: { node: string }) {
  return (
    <>
      <OperateButton label="Network: show" title={`${node} — uplinks`} steps={[{ title: `site-manager node network show ${node}`, bin: "site-manager", verb: "node network show", fixed: [node] }]} />
      <OperateButton
        label="Network: set…"
        title={`${node} — set the uplinks`}
        steps={[
          {
            title: `site-manager node network set ${node}`,
            bin: "site-manager",
            verb: "node network set",
            fixed: [node],
            note: "The preview (without --apply) declares the uplink in config/<node>.json and previews the change on the node: the declaration is written, the node is not touched. Apply drains the node (HA maintenance), moves lan onto the declared ports under a 45 s rollback, confirms and brings the node back. --yes answers the manager's own prompt for the node's name.",
          },
        ]}
      />
    </>
  );
}

// A recorded device's own record: change it, or remove it once nothing names it.
function DeviceRecordActions({ name, cabled, mounted }: { name: string; cabled: boolean; mounted: boolean }) {
  const rm = (verb: string, title: string, extra: Partial<Step> = {}): Step => ({ title, bin: "rack-manager", verb, fixed: [name], ...extra });
  return (
    <>
      <OperateButton label="Change the record…" title={`The record of ${name}`} steps={[rm("device modify", `rack-manager device modify '${name}'`, { note: "Its kind, model, ports (a count or a list), display name or description; --check previews." })]} />
      {!mounted && !cabled ? <OperateButton label="Remove the record…" kind="danger" title={`Remove ${name}`} steps={[rm("device remove", `rack-manager device remove '${name}'`)]} /> : null}
    </>
  );
}

// A wire through a patch panel: rack-manager cable split, its --check the preview.
function PanelSplit({ t, c, many }: { t: Topology; c: RackCable; many: boolean }) {
  const free = freePanelPorts(t);
  if (!free.length) return null;
  const end = `${c.from.device}:${c.from.port}`;
  return (
    <OperateButton
      label={many ? `Attach ${c.from.port} ↔ ${c.to.port} to a patch panel…` : "Attach to patch panel…"}
      title={`${end} — ${c.to.device}:${c.to.port} through a patch panel`}
      steps={[{ title: `rack-manager cable split '${end}' --via <panel:port>`, bin: "rack-manager", verb: "cable split", fixed: [end], only: ["--via"], choices: { "--via": free }, note: "The link becomes two recorded wires: this port to the panel port's front, its rear to the far end. The Device view keeps one link; the racks draw the two wires. Preview: rack-manager's --check." }]}
    />
  );
}

// Undo it: rack-manager cable join at the panel port.
function PanelJoin({ c }: { c: RackCable }) {
  const v = c.via?.[0];
  if (!v) return null;
  return (
    <OperateButton
      label="Remove patch panel"
      title={`${c.from.device}:${c.from.port} — ${c.to.device}:${c.to.port} without ${v.device}`}
      steps={[{ title: `rack-manager cable join '${v.device}:${v.port}'`, bin: "rack-manager", verb: "cable join", fixed: [`${v.device}:${v.port}`], note: "The two wires through the panel port are one link again: the topology's own, or one recorded cable when it was recorded. Preview: rack-manager's --check." }]}
    />
  );
}
