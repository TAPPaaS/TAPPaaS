// overview.tsx — Physical › Overview: the other three views summed up on one
// page. The site in one line; each rack as a thumbnail of its units (a click
// opens the Rack view); the Device view as counts and the findings on devices;
// the Storage view as each node's pools with their fill and the disks with a
// problem; and every finding of the topology and the inventory, each linked to
// the view and the object it is on.

import { ReactNode } from "react";
import { RackInfo, StorageInventory, TopoFinding, Topology } from "../types";
import { Tag, navigate } from "../ui";
import { publicAddress, publicText } from "../zonegraph";
import { STATE_COLOR, StateLegend } from "./state";
import { VIEW_NAME, viewLink } from "./views";
import { StorageNote, bytes, nodeKey, poolKey, poolPct, stateWith } from "./storage";

type View = "rack" | "device" | "storage";

// Where a finding is drawn: the view, and the object to select there.
interface Place {
  view: View;
  select: string | null;
  what: string;
}

const go = (p: Place) => () => navigate(viewLink(p.view, p.select));

// A topology finding's place: a device in the Device view, a storage object in
// the Storage view.
function topoPlace(t: Topology, f: TopoFinding): Place {
  const on = f.on;
  switch (on.kind) {
    case "node":
      return { view: "device", select: `node:${on.name}`, what: on.name };
    case "switch":
      return { view: "device", select: `switch:${on.name}`, what: on.name };
    case "port":
      return { view: "device", select: on.switch ? `port:${on.switch}:${on.name}` : null, what: `${on.switch ?? "?"} port ${on.name}` };
    case "lag":
      return { view: "device", select: on.switch ? `lag:${on.switch}:${on.name}` : null, what: `LAG ${on.name}` };
    case "ap":
      // An access point mounted nowhere is the Rack view's business.
      return t.racks?.unplaced.some((u) => u.device === on.name) ? { view: "rack", select: `ap:${on.name}`, what: on.name } : { view: "device", select: `ap:${on.name}`, what: on.name };
    case "peer":
      return { view: "device", select: `outside:${on.name}`, what: on.name };
    case "site":
      return { view: "device", select: "isp:isp", what: "the uplink" };
    case "rack":
      return { view: "rack", select: `rack:${on.name}`, what: on.name };
    case "mount":
      return { view: "rack", select: `mount:${on.name}`, what: on.name };
    case "pool":
      return { view: "storage", select: on.name.includes("/") ? `pool:${on.name.replace("/", ":")}` : null, what: on.name };
    case "disk":
      return { view: "storage", select: `disk:${on.name}`, what: on.name };
    case "module":
      return { view: "device", select: `guest:${on.name}`, what: on.name };
    default:
      return { view: "device", select: null, what: on.name };
  }
}

const DEVICE_KINDS = new Set(["node", "switch", "port", "lag", "ap", "peer", "site", "rack", "mount"]);

interface Row {
  on: string; // the kind of object it is on
  level: "warn" | "fail";
  source: string;
  text: string;
  place: Place;
}

// Every finding once: the inventory's, then the topology's not already said.
export function physicalFindings(t: Topology | null, inv: StorageInventory | null): Row[] {
  const rows: Row[] = [];
  for (const f of inv?.findings ?? []) {
    const place: Place =
      f.on.kind === "disk" ? { view: "storage", select: `disk:${f.on.node}:${f.on.name}`, what: `${f.on.node} ${f.on.name}` }
      : f.on.kind === "pool" ? { view: "storage", select: `pool:${f.on.node}:${f.on.name}`, what: `${f.on.node}/${f.on.name}` }
      : { view: "storage", select: `node:${f.on.node}`, what: f.on.node };
    rows.push({ on: f.on.kind, level: f.level, source: "storage-manager", text: f.text, place });
  }
  for (const f of t?.findings ?? []) {
    if (rows.some((r) => r.text === f.text)) continue;
    rows.push({ on: f.on.kind, level: f.level, source: f.gate, text: f.text, place: topoPlace(t!, f) });
  }
  return rows.sort((a, b) => (a.level === b.level ? 0 : a.level === "fail" ? -1 : 1));
}

function Stat({ n, label }: { n: ReactNode; label: string }) {
  return (
    <span className="ov-stat">
      <b>{n}</b> {label}
    </span>
  );
}

// A rack as its units: each mount a block at its height, nothing else.
function RackThumb({ r }: { r: RackInfo }) {
  const px = 5;
  const w = 64;
  const used = r.mounts.filter((m) => m.face === "front").reduce((n, m) => n + (m.width === "full" ? m.height : m.height / (m.width === "half" ? 2 : 3)), 0);
  const top = (u: number, h: number) => (r.numbering === "bottom-up" ? (r.units - (u + h - 1)) * px : (u - 1) * px);
  return (
    <button className="ov-rack" onClick={() => navigate(viewLink("rack", `rack:${r.name}`))} title={`${r.displayName ?? r.name}: ${r.mounts.map((m) => `U${m.u} ${m.device}`).join(", ")}`}>
      <svg width={w + 8} height={r.units * px + 8} role="img" aria-label={`rack ${r.name}`}>
        <rect x={0.5} y={0.5} width={w + 7} height={r.units * px + 7} rx={3} fill="#f1f3f6" stroke="#94a3b8" />
        {r.mounts
          .filter((m) => m.face === "front")
          .map((m) => {
            const mw = m.width === "full" ? w : m.width === "half" ? w / 2 : w / 3;
            return <rect key={m.device} x={4 + (m.width === "full" ? 0 : (m.slot - 1) * mw)} y={4 + top(m.u, m.height)} width={mw - 1} height={m.height * px - 1} rx={1} fill={m.kind === "node" ? "#3b6fd4" : m.kind === "switch" ? "#475569" : "#8a94a6"} />;
          })}
      </svg>
      <span className="ov-rack-name">{r.displayName ?? r.name}</span>
      <span className="muted small">{Math.round(used)} of {r.units}U</span>
    </button>
  );
}

export function PhysicalOverview({ t, inv, notes, storageError, aside, beforeFindings }: { t: Topology | null; inv: StorageInventory | null; notes: Map<string, StorageNote[]>; storageError: string | null; aside?: ReactNode; beforeFindings?: ReactNode }) {
  const racks = t?.racks?.racks ?? [];
  const rooms = t?.racks?.rooms ?? [];
  const disks = inv ? inv.nodes.reduce((s, n) => s + n.boot.length + n.otherDisks.length + n.pools.reduce((a, p) => a + p.vdevs.reduce((b, v) => b + v.disks.length, 0), 0), 0) : null;
  const pools = inv ? inv.nodes.reduce((s, n) => s + n.pools.length, 0) : null;
  const wan = t ? publicText(publicAddress({ network: { publicIp: t.site.wan.publicIp } }, t.site.wan.discovered), true) : "";
  const rows = physicalFindings(t, inv);
  const onDevices = rows.filter((r) => r.place.view !== "storage" && DEVICE_KINDS.has(r.on));
  const ports = t ? t.switches.flatMap((s) => s.ports) : [];
  const cables = t?.racks?.cables ?? [];
  return (
    <div className="ov">
      <div className="ov-line">
        <Stat n={t?.nodes.length ?? "…"} label="nodes" />
        <Stat n={t?.switches.length ?? "…"} label="switches" />
        <Stat n={t?.accessPoints.length ?? "…"} label="APs" />
        <Stat n={t ? racks.length : "…"} label="racks" />
        <Stat n={pools ?? "…"} label="pools" />
        <Stat n={disks ?? "…"} label="disks" />
        <span className="ov-stat">{wan || "public address not recorded"}</span>
        <span className="spacer" />
        {aside}
      </div>
      <div className="ov-grid">
        <section className="section">
          <header className="section-head">
            <h2><button className="linklike" onClick={() => navigate(viewLink("rack"))}>Physical</button></h2>
            <span className="section-aside">{t?.racks ? `${t.racks.unplaced.length} device(s) mounted nowhere` : ""}</span>
          </header>
          {racks.length || rooms.length ? (
            <>
              {rooms.map((room) => (
                <div key={room.name} className="ov-room">
                  <button className="linklike ov-room-name" onClick={() => navigate(viewLink("rack", `room:${room.name}`))}>{room.displayName ?? room.name}</button>
                  <div className="ov-racks">
                    {room.racks.map((n) => racks.find((r) => r.name === n)).filter((r): r is RackInfo => !!r).map((r) => <RackThumb key={r.name} r={r} />)}
                  </div>
                  {room.loose.length ? <div className="muted small">loose: {room.loose.map((m) => m.device).join(", ")}</div> : null}
                </div>
              ))}
              {racks.some((r) => !rooms.some((x) => x.racks.includes(r.name))) ? (
                <div className="ov-room">
                  {rooms.length ? <span className="muted small">in no room</span> : null}
                  <div className="ov-racks">{racks.filter((r) => !rooms.some((x) => x.racks.includes(r.name))).map((r) => <RackThumb key={r.name} r={r} />)}</div>
                </div>
              ) : null}
            </>
          ) : (
            <p className="muted small">{t ? "No rack is recorded yet." : "reading the topology…"}</p>
          )}
        </section>
        <section className="section">
          <header className="section-head">
            <h2><button className="linklike" onClick={() => navigate(viewLink("device"))}>Device</button></h2>
          </header>
          {t ? (
            <>
              <div className="ov-counts">
                <Stat n={t.nodes.length} label="cluster nodes" />
                <Stat n={`${ports.filter((p) => p.link === "up").length}/${ports.length}`} label="switch ports up" />
                <Stat n={ports.filter((p) => p.drift === "drift").length} label="drifting" />
                <Stat n={`${t.switches.flatMap((s) => s.lags).filter((l) => l.formed).length}/${t.switches.flatMap((s) => s.lags).length}`} label="LAGs formed" />
                <Stat n={t.outside.length} label="buddies / satellite" />
                <Stat n={cables.length} label="cables" />
              </div>
              <FindingList rows={onDevices} empty="No finding on a device." />
            </>
          ) : (
            <p className="muted small">reading the topology…</p>
          )}
        </section>
        <section className="section">
          <header className="section-head">
            <h2><button className="linklike" onClick={() => navigate(viewLink("storage"))}>Storage</button></h2>
            <span className="section-aside">{inv ? `inventory ${inv.generated.slice(11, 16)}` : storageError ?? ""}</span>
          </header>
          {inv ? (
            <table className="table compact ov-storage">
              <tbody>
                {inv.nodes.map((n) => {
                  const bad = [...n.boot, ...n.otherDisks, ...n.pools.flatMap((p) => p.vdevs.flatMap((v) => v.disks))].filter((d) => d.state !== "ok");
                  return (
                    <tr key={n.name}>
                      <td>
                        <button className="linklike" onClick={go({ view: "storage", select: `node:${n.name}`, what: n.name })}>
                          <i className="st-swatch" style={{ background: STATE_COLOR[stateWith(n.state, notes.get(nodeKey(n.name)))] }} /> {n.name}
                        </button>
                      </td>
                      <td>
                        {n.pools.map((p) => {
                          const s = stateWith(p.state, notes.get(poolKey(n.name, p.name)));
                          const pct = poolPct(p) ?? 0;
                          return (
                            <button key={p.name} className="ov-pool linklike" onClick={go({ view: "storage", select: `pool:${n.name}:${p.name}`, what: p.name })} title={`${p.name}: ${p.health ?? "?"}, ${bytes(p.totals.total - p.totals.free)} of ${bytes(p.totals.total)}${p.reasons.length ? ` — ${p.reasons.join("; ")}` : ""}`}>
                              <span className="ov-pool-name">{p.name}</span>
                              <span className="fillbar"><i style={{ width: `${Math.min(100, pct)}%`, background: STATE_COLOR[s] }} /></span>
                              <span className="muted small">{pct.toFixed(0)}% of {bytes(p.totals.total)}</span>
                            </button>
                          );
                        })}
                      </td>
                      <td className="small">
                        {bad.length === 0 ? <span className="muted">disks ok</span> : bad.map((d) => (
                          <div key={d.device}>
                            <button className="linklike" onClick={go({ view: "storage", select: `disk:${n.name}:${d.device}`, what: d.device })}>
                              <i className="st-swatch" style={{ background: STATE_COLOR[d.state] }} /> {d.device} {d.serial ?? ""}
                            </button>{" "}
                            <span className="muted">{d.reasons[0] ?? d.state}</span>
                          </div>
                        ))}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          ) : (
            <p className="muted small">{storageError ? `storage-manager inventory: ${storageError}` : "reading the storage inventory (SMART on every disk, ≈15 s)…"}</p>
          )}
        </section>
      </div>
      <div className="ov-legend"><StateLegend /></div>
      {beforeFindings}
      <section className="section">
        <header className="section-head">
          <h2>Findings</h2>
          <span className="section-aside">from the topology and the storage inventory · {rows.filter((r) => r.level === "fail").length} fail · {rows.filter((r) => r.level === "warn").length} warn</span>
        </header>
        <FindingList rows={rows} empty="No finding." />
      </section>
    </div>
  );
}


function FindingList({ rows, empty }: { rows: Row[]; empty: string }) {
  if (rows.length === 0) return <p className="muted small">{empty}</p>;
  return (
    <ul className="findings">
      {rows.map((r, i) => (
        <li key={i}>
          <Tag level={r.level} /> <b>{r.source}</b> {r.text}{" "}
          <button className="linklike small" onClick={go(r.place)}>
            {VIEW_NAME[r.place.view]} › {r.place.what}
          </button>
        </li>
      ))}
    </ul>
  );
}
