// storageview.tsx — the Storage view (storage-manager inventory): the shared
// graph's column mode with the nodes, their boot devices and pools, and each
// pool's disks; every card coloured by its state with the reason on hover, a
// pool's fill bar on its card. A click opens the side card: a disk's records,
// a pool's records and a pie of what it holds, the findings on either.

import { ReactNode, useMemo, useState } from "react";
import { GEdge, GNode, Graph } from "../graph";
import { StorageDisk, StorageInventory, StoragePool, StorageState } from "../types";
import { KV, Link, OpenIn, Tag } from "../ui";
import { Sel } from "./layout";
import { STATE_COLOR, stateClass } from "./state";
import { Slice, StorageNote, bytes, diskKey, findDisk, nodeKey, poolKey, poolPct, poolSlices, stateWith, storageLayout } from "./storage";

const W = { node: 210, mid: 290, disk: 340 };

function Fill({ pct, state }: { pct: number | null; state: StorageState }) {
  return (
    <div className="fillbar" title={pct === null ? "fill unknown" : `${pct.toFixed(1)}% used`}>
      <i style={{ width: `${Math.min(100, Math.max(0, pct ?? 0))}%`, background: STATE_COLOR[state] }} />
    </div>
  );
}

const diskLine = (d: StorageDisk): string =>
  [d.type, d.wearout !== null ? `${d.wearout}% life left` : null, d.smart?.temperature !== null && d.smart?.temperature !== undefined ? `${d.smart.temperature}°C` : null, d.smart?.health ? `SMART ${d.smart.health}` : d.smart?.read === false ? "SMART not read" : null]
    .filter(Boolean)
    .join(" · ");

const hover = (state: StorageState, reasons: string[], notes: StorageNote[] | undefined): string => {
  const all = [...reasons, ...(notes ?? []).map((n) => n.text)].filter((x, i, a) => a.indexOf(x) === i);
  return all.length ? `${state}: ${all.join("; ")}` : state;
};

export function StorageGraph({ inv, notes, sel, pick }: { inv: StorageInventory; notes: Map<string, StorageNote[]>; sel: Sel | null; pick: (s: Sel) => void }) {
  const { nodes, edges } = useMemo(() => {
    const lay = storageLayout(inv);
    const on = (kind: string, node: string, id: string) => sel !== null && sel.kind === kind && (sel.kind === "node" ? sel.id === node : "node" in sel && sel.node === node && sel.id === id);
    const card = (id: string, col: number, w: number, h: number, state: StorageState, title: string, content: ReactNode, onClick?: () => void, selected = false, after?: string): GNode => ({
      id,
      col,
      w,
      h,
      after,
      accent: STATE_COLOR[state],
      className: `${stateClass(state)}${selected ? " gcard-on" : ""}`,
      onClick,
      content: <div className="scard" title={title}>{content}</div>,
    });
    const out: GNode[] = [];
    for (const it of lay.items) {
      switch (it.kind) {
        case "node": {
          const n = inv.nodes.find((x) => x.name === it.node)!;
          const s = stateWith(n.state, notes.get(nodeKey(n.name)));
          const disks = n.boot.length + n.otherDisks.length + n.pools.reduce((a, p) => a + p.vdevs.reduce((b, v) => b + v.disks.length, 0), 0);
          out.push(card(it.id, 0, W.node, 64, s, hover(s, n.reasons, notes.get(nodeKey(n.name))), (
            <>
              <div className="cf-title">{n.name}</div>
              <div className="cf-sub">{n.reachable ? `${n.pools.length} pool(s) · ${disks} disk(s)` : "did not answer"}</div>
            </>
          ), () => pick({ kind: "node", id: n.name }), on("node", n.name, n.name)));
          break;
        }
        case "boot": {
          const d = it.disk;
          const k = diskKey(it.node, d.device);
          const s = stateWith(d.state, notes.get(k));
          out.push(card(it.id, 1, W.mid, 62, s, hover(s, d.reasons, notes.get(k)), (
            <>
              <div className="cf-title">boot {d.device} <span className="muted">{bytes(d.size)}</span></div>
              <div className="cf-sub">{d.model ?? "?"} · {diskLine(d)}</div>
            </>
          ), () => pick({ kind: "disk", node: it.node, id: d.device }), on("disk", it.node, d.device)));
          break;
        }
        case "pool": {
          const p = it.pool;
          const k = poolKey(it.node, p.name);
          const s = stateWith(p.state, notes.get(k));
          const pct = poolPct(p);
          out.push(card(it.id, 1, W.mid, 78, s, hover(s, p.reasons, notes.get(k)), (
            <>
              <div className="cf-title">pool {p.name} <span className="muted">{p.health ?? (p.present ? "" : "not imported")}</span></div>
              <Fill pct={pct} state={s} />
              <div className="cf-sub">
                {bytes(p.totals.total - p.totals.free)} of {bytes(p.totals.total)}{pct !== null ? ` · ${pct.toFixed(0)}%` : ""} · {p.scrub.last ? `scrub ${p.scrub.last.slice(0, 10)}` : "no scrub on record"}
              </div>
            </>
          ), () => pick({ kind: "pool", node: it.node, id: p.name }), on("pool", it.node, p.name)));
          break;
        }
        case "nopool": {
          const s = it.disks.reduce<StorageState>((w, d) => (d.state === "fail" || (d.state === "warn" && w === "ok") ? d.state : w), "ok");
          out.push(card(it.id, 1, W.mid, 58, s, "disks the node has that are in no imported pool", (
            <>
              <div className="cf-title">in no pool</div>
              <div className="cf-sub">{it.disks.length} disk(s)</div>
            </>
          )));
          break;
        }
        case "disk": {
          const d = it.disk;
          const k = diskKey(it.node, d.device);
          const s = stateWith(d.state, notes.get(k));
          const g = it.group;
          const n = card(it.id, 2, W.disk, g?.first ? 92 : 76, s, hover(s, d.reasons, notes.get(k)), (
            <>
              {g?.first ? <div className="vdev-text" title={`vdev ${g.label}`}>{g.label}</div> : null}
              <div className="cf-title">{d.device} <span className="muted">{bytes(d.size)}</span>{d.exportedPool ? <span className="muted"> · pool {d.exportedPool.name} (not imported)</span> : null}</div>
              <div className="cf-sub">{d.model ?? "?"}{d.serial ? ` · ${d.serial}` : ""}</div>
              <div className="cf-sub">{diskLine(d)}</div>
            </>
          ), () => pick({ kind: "disk", node: it.node, id: d.device }), on("disk", it.node, d.device), it.after);
          if (g) n.className += ` in-vdev${g.first ? " vdev-first" : ""}${g.last ? " vdev-last" : ""}`;
          out.push(n);
          break;
        }
        case "missing":
          out.push(card(it.id, 2, W.disk, 60, "fail", `a member of ${it.pool} that is not among the node's disks: ${it.state}`, (
            <>
              <div className="cf-title">{it.name} <span className="muted">missing</span></div>
              <div className="cf-sub">{it.state} — not among the node's disks</div>
            </>
          ), undefined, false, it.after));
          break;
      }
    }
    const lines: GEdge[] = lay.edges.map((e) => ({ source: e.source, target: e.target }));
    return { nodes: out, edges: lines };
  }, [inv, notes, sel, pick]);
  return <Graph nodes={nodes} edges={edges} height="100%" nodesep={14} ranksep={70} />;
}

// ── the side card's bodies ────────────────────────────────────────────

export function NoteList({ list }: { list: StorageNote[] }) {
  if (list.length === 0) return <p className="muted small">No finding on it.</p>;
  return (
    <ul className="findings">
      {list.map((f, i) => (
        <li key={i}>
          <Tag level={f.level} /> <b>{f.source === "inventory" ? "storage-manager" : f.source}</b> {f.text}
        </li>
      ))}
    </ul>
  );
}

const n = (v: number | null | undefined, unit = ""): string | null => (v === null || v === undefined ? null : `${v}${unit}`);

export function DiskBody({ inv, notes, node, device }: { inv: StorageInventory; notes: Map<string, StorageNote[]>; node: string; device: string }): { title: string; body: ReactNode; open: ReactNode } | null {
  const f = findDisk(inv, node, device);
  if (!f) return null;
  const d = f.disk;
  const sm = d.smart;
  const s = stateWith(d.state, notes.get(diskKey(node, device)));
  return {
    title: `${d.device} · ${node}`,
    body: (
      <>
        <p>
          <Tag level={s === "ok" ? "pass" : s} /> {d.reasons.length ? d.reasons.join("; ") : "healthy"}
        </p>
        <KV
          rows={[
            ["where", f.boot ? "the boot device" : f.pool ? `pool ${f.pool.name}, vdev ${f.vdev}` : d.exportedPool ? `pool ${d.exportedPool.name} (not imported${d.exportedPool.health ? `, ${d.exportedPool.health}` : ""})` : "in no pool"],
            ["model", d.model],
            ["serial", d.serial],
            ["size", `${bytes(d.size)} · ${d.type}`],
            ["by-id", d.byId ? <span className="mono small">{d.byId}</span> : null],
            ["SMART", sm ? (sm.read ? sm.health ?? "read" : "not read") : "not read"],
            ["life left", n(d.wearout, "%")],
            ["temperature", n(sm?.temperature, "°C")],
            ["power-on hours", sm?.powerOnHours !== null && sm?.powerOnHours !== undefined ? `${sm.powerOnHours} (${(sm.powerOnHours / 8766).toFixed(1)} years)` : null],
            ["reallocated sectors", n(sm?.reallocated)],
            ["pending sectors", n(sm?.pending)],
            ["uncorrectable sectors", n(sm?.uncorrectable)],
            ["media errors", n(sm?.mediaErrors)],
            ["critical warning", n(sm?.criticalWarning)],
            ["ZFS", d.zfs ? `${d.zfs.state} in ${d.zfs.pool} · errors read ${d.zfs.read}, write ${d.zfs.write}, checksum ${d.zfs.cksum}${d.zfs.msg ? ` · ${d.zfs.msg}` : ""}` : null],
          ]}
        />
        <h3>Findings</h3>
        <NoteList list={notes.get(diskKey(node, device)) ?? []} />
      </>
    ),
    open: <OpenIn kind="disk" id={node} />,
  };
}

// The pie's colours: the guests in the categorical order (never cycled: past
// the fifth they share one "more guests" colour, each still named in the
// list), the rest in greys, the mirror copies hatched.
const GUEST_HUES = ["#2a78d6", "#eb6834", "#1baf7a", "#e87ba4", "#6250d6"];
const MORE_GUESTS = "#8a94a6";
const FIXED: Record<Exclude<Slice["kind"], "guest">, string> = { mirror: "url(#hatch-mirror)", store: "#475569", other: "#b6c0cc", free: "#eef1f4" };

function sliceColor(s: Slice, guestIndex: number): string {
  if (s.kind !== "guest") return FIXED[s.kind];
  return guestIndex < GUEST_HUES.length ? GUEST_HUES[guestIndex] : MORE_GUESTS;
}

function Swatch({ color }: { color: string }) {
  return color.startsWith("url(") ? <i className="pie-sw pie-sw-hatch" /> : <i className="pie-sw" style={{ background: color }} />;
}

export function Pie({ pool }: { pool: StoragePool }) {
  const slices = poolSlices(pool);
  const total = slices.reduce((a, s) => a + s.bytes, 0) || 1;
  const [hot, setHot] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  let gi = 0;
  const colored = slices.map((s) => ({ s, color: sliceColor(s, s.kind === "guest" ? gi++ : -1) }));
  const R = 70;
  const r = 40;
  let a0 = -Math.PI / 2;
  const arcs = colored.map(({ s, color }) => {
    const frac = s.bytes / total;
    const a1 = a0 + frac * 2 * Math.PI;
    const large = a1 - a0 > Math.PI ? 1 : 0;
    const p = (rad: number, a: number) => `${80 + rad * Math.cos(a)},${80 + rad * Math.sin(a)}`;
    const d = frac >= 0.9999
      ? `M ${p(R, 0)} A ${R} ${R} 0 1 1 ${p(R, Math.PI)} A ${R} ${R} 0 1 1 ${p(R, 0)} M ${p(r, 0)} A ${r} ${r} 0 1 0 ${p(r, Math.PI)} A ${r} ${r} 0 1 0 ${p(r, 0)} Z`
      : `M ${p(R, a0)} A ${R} ${R} 0 ${large} 1 ${p(R, a1)} L ${p(r, a1)} A ${r} ${r} 0 ${large} 0 ${p(r, a0)} Z`;
    a0 = a1;
    return { s, color, d, frac };
  });
  const pct = (b: number) => `${((100 * b) / total).toFixed(b / total < 0.01 ? 1 : 0)}%`;
  const h = arcs.find((x) => x.s.key === hot);
  return (
    <div className="pie">
      <svg viewBox="0 0 160 160" width="160" height="160" role="img" aria-label={`what ${pool.name} holds`}>
        <defs>
          <pattern id="hatch-mirror" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
            <rect width="6" height="6" fill="#c7cfe0" />
            <line x1="0" y1="0" x2="0" y2="6" stroke="#5b6b8c" strokeWidth="2.4" />
          </pattern>
        </defs>
        {arcs.map((x) => (
          <path key={x.s.key} d={x.d} fill={x.color} fillRule="evenodd" stroke="var(--panel)" strokeWidth={2} opacity={hot && hot !== x.s.key ? 0.45 : 1} onMouseEnter={() => setHot(x.s.key)} onMouseLeave={() => setHot(null)}>
            <title>{`${x.s.label}: ${bytes(x.s.bytes)} (${pct(x.s.bytes)})`}</title>
          </path>
        ))}
        <text x="80" y="76" textAnchor="middle" className="pie-c1">{h ? h.s.label.slice(0, 16) : bytes(pool.totals.total)}</text>
        <text x="80" y="92" textAnchor="middle" className="pie-c2">{h ? `${bytes(h.s.bytes)} · ${pct(h.s.bytes)}` : `${pct(pool.totals.total - pool.totals.free)} used`}</text>
      </svg>
      <table className="pie-list">
        <tbody>
          {colored.map(({ s, color }) => (
            <PieRow key={s.key} s={s} color={color} pct={pct(s.bytes)} hot={hot === s.key} setHot={setHot} open={open} setOpen={setOpen} />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function PieRow({ s, color, pct, hot, setHot, open, setOpen }: { s: Slice; color: string; pct: string; hot: boolean; setHot: (k: string | null) => void; open: boolean; setOpen: (o: boolean) => void }) {
  const label =
    s.kind === "guest" && s.module ? <Link to={`/modules/${encodeURIComponent(s.module)}`}>{s.label}</Link>
    : s.kind === "mirror" ? <button className="linklike" onClick={() => setOpen(!open)} aria-expanded={open}>{open ? "▾" : "▸"} {s.label} ({s.parts?.length ?? 0})</button>
    : s.label;
  const parts = s.kind === "mirror" ? (open ? s.parts ?? [] : []) : s.kind === "store" || s.kind === "other" ? s.parts ?? [] : [];
  return (
    <>
      <tr className={hot ? "pie-hot" : ""} onMouseEnter={() => setHot(s.key)} onMouseLeave={() => setHot(null)}>
        <td><Swatch color={color} /></td>
        <td>{label}</td>
        <td className="num">{bytes(s.bytes)}</td>
        <td className="num muted">{pct}</td>
      </tr>
      {parts.map((p) => (
        <tr key={s.key + p.label} className="pie-part">
          <td />
          <td>
            {p.module && s.kind === "mirror" ? <Link to={`/modules/${encodeURIComponent(p.module)}`}>{p.label}</Link> : p.label}
            {p.of ? <span className="muted"> · runs on {p.of}</span> : null}
          </td>
          <td className="num">{bytes(p.bytes)}</td>
          <td />
        </tr>
      ))}
    </>
  );
}

export function PoolBody({ inv, notes, node, pool }: { inv: StorageInventory; notes: Map<string, StorageNote[]>; node: string; pool: string }): { title: string; body: ReactNode; open: ReactNode } | null {
  const p = inv.nodes.find((x) => x.name === node)?.pools.find((x) => x.name === pool);
  if (!p) return null;
  const s = stateWith(p.state, notes.get(poolKey(node, pool)));
  const pct = poolPct(p);
  return {
    title: `pool ${p.name} · ${node}`,
    body: (
      <>
        <p>
          <Tag level={s === "ok" ? "pass" : s} /> {p.reasons.length ? p.reasons.join("; ") : "healthy"}
        </p>
        <KV
          rows={[
            ["size", bytes(p.totals.total)],
            ["used", `${bytes(p.totals.total - p.totals.free)}${pct !== null ? ` (${pct.toFixed(1)}%)` : ""}`],
            ["free", bytes(p.totals.free)],
            ["health", p.health ?? (p.present ? null : "not imported")],
            ["status", p.status],
            ["scrub", p.scrub.text ?? (p.scrub.last ? `${p.scrub.state} ${p.scrub.last.slice(0, 10)}` : "no scrub on record")],
            ["fragmentation", n(p.fragmentation, "%")],
            ["compression", p.compression ? `${p.compression}${p.compressRatio ? ` · ${p.compressRatio}x` : ""}` : null],
          ]}
        />
        <h3>Vdevs</h3>
        <ul className="plain small">
          {p.vdevs.map((v) => (
            <li key={v.name}>
              <i className="st-swatch" style={{ background: STATE_COLOR[v.state] }} /> <b>{v.name}</b> {v.type}
              {v.role !== "data" ? ` · ${v.role}` : ""} · {v.health} · {v.disks.map((d) => d.device).concat(v.missing.map((m) => `${m.name} (missing)`)).join(", ")}
            </li>
          ))}
        </ul>
        <h3>What it holds</h3>
        <Pie pool={p} />
        <h3>Findings</h3>
        <NoteList list={notes.get(poolKey(node, pool)) ?? []} />
      </>
    ),
    open: <OpenIn kind="pool" id={node} />,
  };
}

// The storage part of a node's side card.
export function NodeStorage({ inv, notes, node }: { inv: StorageInventory; notes: Map<string, StorageNote[]>; node: string }) {
  const n = inv.nodes.find((x) => x.name === node);
  if (!n) return null;
  return (
    <>
      <h3>Storage</h3>
      <ul className="plain small">
        {n.boot.map((d) => <li key={d.device}><i className="st-swatch" style={{ background: STATE_COLOR[d.state] }} /> boot {d.device} · {d.model ?? "?"} · {bytes(d.size)}</li>)}
        {n.pools.map((p) => <li key={p.name}><i className="st-swatch" style={{ background: STATE_COLOR[p.state] }} /> pool {p.name} · {p.health ?? "?"} · {bytes(p.totals.total - p.totals.free)} of {bytes(p.totals.total)}</li>)}
        {n.otherDisks.map((d) => <li key={d.device}><i className="st-swatch" style={{ background: STATE_COLOR[d.state] }} /> {d.device} in no pool · {d.reasons.join("; ") || d.model}</li>)}
      </ul>
      {n.replication.length ? (
        <>
          <h3>Replication</h3>
          <ul className="plain small">
            {n.replication.map((j) => (
              <li key={j.id}>
                <i className="st-swatch" style={{ background: STATE_COLOR[j.state] }} /> {j.module ?? j.vmid} → {j.target} · {j.schedule ?? ""} · last {j.lastSync ? j.lastSync.slice(11, 16) : "never"}
                {j.reasons.length ? <span className="muted"> · {j.reasons.join("; ")}</span> : null}
              </li>
            ))}
          </ul>
        </>
      ) : null}
      <NoteList list={notes.get(nodeKey(node)) ?? []} />
    </>
  );
}
