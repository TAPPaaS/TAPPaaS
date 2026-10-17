// SidePanel.tsx — what the console knows about the object clicked in the
// Physical view: its records as the managers report them, the findings on it,
// and where to open it. Read-only in P1; the actions arrive with P2.

import { ReactNode } from "react";
import { zoneColor } from "../colors";
import { TopoFinding, TopoRef, Topology } from "../types";
import { KV, Link, OpenIn, Tag } from "../ui";
import { Sel, portLabel } from "./layout";

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

export function SidePanel({ t, sel, close }: { t: Topology; sel: Sel; close: () => void }) {
  const about = (kind: string, name: string, sw?: string) => t.findings.filter((f) => refIs(f.on, kind, name, sw) || f.refs.some((r) => refIs(r, kind, name, sw)));
  let title: ReactNode = sel.id;
  let body: ReactNode = null;
  let open: ReactNode = null;

  switch (sel.kind) {
    case "port": {
      const s = t.switches.find((x) => x.name === sel.switch);
      const p = s?.ports.find((x) => x.port === sel.id);
      if (!s || !p) break;
      const lag = p.lag ? s.lags.find((l) => l.name === p.lag) : undefined;
      title = `Port ${p.port} · ${s.name}`;
      body = (
        <>
          <p>
            <Tag level={p.drift === "drift" ? "warn" : "pass"} /> {p.drift === "unmanaged" ? "unmanaged — TAPPaaS does not set its VLANs" : p.drift === "drift" ? "drifts from zones.json" : "in sync with zones.json"}
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
              ["LLDP partner", p.seen ? `${p.seen.node} / ${p.seen.nic}` : null],
              ["description", p.description],
              ["drift", p.drift === "drift" ? `add ${p.add.join(",") || "-"} · remove ${p.remove.join(",") || "-"}` : null],
            ]}
          />
          <h3>Findings</h3>
          <Findings list={about("port", p.port, s.name)} />
        </>
      );
      open = <OpenIn kind="port" id={p.port} sw={s.name} />;
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
              ["ports", `${s.ports.length} · ${s.ports.filter((p) => p.role === "unmanaged").length} unmanaged · ${s.ports.filter((p) => p.drift === "drift").length} drifting`],
              ["LAGs", s.lags.map((l) => `${l.name} (${l.ports.join("+")})`).join(", ")],
            ]}
          />
          <h3>Findings</h3>
          <Findings list={t.findings.filter((f) => f.on.switch === s.name || f.refs.some((r) => r.switch === s.name))} />
        </>
      );
      open = <OpenIn kind="switch" id={s.name} />;
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
              ["storage pools", n.storagePools.join(", ")],
              ["HA", n.ha ? `lrm ${n.ha.lrm}` : null],
              ["corosync", n.corosync ? `${n.corosync.links} link(s), ${n.corosync.disconnected} disconnected` : null],
              ["lldpd", n.lldpd],
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
        </>
      );
      open = <OpenIn kind="node" id={n.name} />;
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
          <KV rows={[["vendor / model", `${a.vendor ?? "?"} · ${a.model ?? "?"}`], ["address", a.address], ["uplink", a.uplink ? `${a.uplink.switch} port ${a.uplink.port}` : null]]} />
          <h3>SSIDs</h3>
          {a.ssids.length === 0 ? <p className="muted small">No SSID mapped to a zone (ap-controller ssid … add).</p> : null}
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
      title = "Internet · ISP";
      body = (
        <>
          <KV
            rows={[
              ["public IP", w.publicIp],
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
  }

  return (
    <aside className="sidepanel">
      <header>
        <h2>{title}</h2>
        <button className="btn-x" onClick={close} aria-label="close">
          ×
        </button>
      </header>
      {body ?? <p className="muted">Not in the current topology.</p>}
      <h3>Open in</h3>
      {open}
      <p className="muted small">For debugging: these open the component UIs in a new tab; nothing is changed there from here.</p>
    </aside>
  );
}
