// nodepools.tsx — data pools on a node's free disks: the inventory proposes
// the disks, the class and the layout, node storage add builds each one.

import { useState } from "react";
import { useRead } from "../api";
import { Step, StepView } from "../operate";
import { StorageDisk, StorageInventory } from "../types";
import { POOL_CLASSES, PoolClass, diskId, humanSize, poolDisks, proposedDisks, proposedLayout, proposedPoolClass, proposedPoolName } from "../nodeadd";
import { canOperate, useMe } from "../ui";

// A pool built here, before the inventory (read every few minutes) has it.
interface Built { name: string; layout: string; disks: string[] }

// Data pools on the node's free disks (Add node's stage 4, and the node's side
// card in Site › Physical), one after another: the pools it has come first
// (the boot pool too), then a proposal from the disks still free, until none
// is left or the operator continues. The inventory proposes; the operator
// ticks the disks, may change the class, name or layout, and node storage add
// — which refuses what is not precise — builds it. `onContinue` gets the
// number of pools built here.
export function NodePools({ node, onContinue, continueLabel = "Continue →" }: { node: string; onContinue: (built: number) => void; continueLabel?: string }) {
  const me = useMe();
  const inv = useRead<StorageInventory>("storage").env?.data;
  const here = inv?.nodes.find((n) => n.name === node);
  const [built, setBuilt] = useState<Built[]>([]);
  // A pool the inventory has caught up with is shown from the inventory.
  const pending = built.filter((b) => !(here?.pools ?? []).some((p) => p.name === b.name));
  const used = new Set(pending.flatMap((b) => b.disks));
  const free: StorageDisk[] = (here?.otherDisks ?? []).filter((d) => !used.has(diskId(d)));
  const disks = poolDisks(free);
  const taken = [...(here?.pools ?? []).map((p) => p.name), ...pending.map((b) => b.name)];
  const [ticked, setTicked] = useState<string[] | null>(null);
  const sel = (ticked ?? proposedDisks(free).map(diskId)).filter((id) => disks.some((d) => diskId(d) === id));
  const first = disks.find((d) => sel.includes(diskId(d)));
  const [cls, setCls] = useState<PoolClass | null>(null);
  const [pool, setPool] = useState<string | null>(null);
  const [layout, setLayout] = useState<string | null>(null);
  const poolClass = cls ?? proposedPoolClass(first?.type ?? "ssd");
  const poolName = pool ?? proposedPoolName(poolClass, taken);
  const lay = layout ?? proposedLayout(sel.length);
  if (!inv) return <p className="muted small">reading the storage inventory…</p>;
  if (!here) return <p className="muted small">{node} is not in the storage inventory yet — it is read every few minutes.</p>;

  // The next proposal starts fresh from the disks left.
  const added = () => {
    setBuilt([...built, { name: poolName, layout: lay, disks: sel }]);
    setTicked(null);
    setCls(null);
    setPool(null);
    setLayout(null);
  };
  const step: Step = {
    title: `site-manager node storage add ${node} ${poolName}`,
    bin: "site-manager",
    verb: "node storage add",
    fixed: [node, poolName],
    only: ["--disks", "--layout", "--wipe"],
    initial: { "--disks": sel.join(","), "--layout": lay },
    choices: { "--layout": ["single", "mirror", "raidz1", "raidz2"] },
    note: "There is no dry run: the preview shows the command. Apply builds the pool on the node and registers it as its storage; a disk that carries data is refused unless --wipe is ticked, and nothing is erased then.",
  };
  return (
    <div>
      <p className="small"><b>Pools on {node}</b></p>
      <ul className="plain small">
        {here.pools.map((p) => (
          <li key={p.name}>
            {p.name}{p.name === "rpool" ? " — the boot pool (storage local-zfs)" : ""} — {p.vdevs.filter((v) => v.role === "data").map((v) => `${v.type} of ${v.disks.length}`).join(" + ") || "?"} · {p.health ?? "?"} · {humanSize(p.totals.total)}
          </li>
        ))}
        {pending.map((b) => <li key={b.name}>{b.name} — {b.layout} of {b.disks.length} · just built (the inventory shows it within a few minutes)</li>)}
      </ul>
      {!here.pools.some((p) => p.name !== "rpool") && !pending.length ? <p className="muted small">No data pool yet: its guests go to the boot pool.</p> : null}
      {disks.length ? (
        <>
          <p className="small"><b>{built.length ? "Another pool" : "A data pool"}</b> — its disks in no pool, healthy:</p>
          <ul className="plain">
            {disks.map((d) => (
              <li key={diskId(d)}>
                <label>
                  <input type="checkbox" checked={sel.includes(diskId(d))}
                    onChange={(e) => setTicked(e.target.checked ? [...sel, diskId(d)] : sel.filter((x) => x !== diskId(d)))} />{" "}
                  <span className="mono">{diskId(d)}</span> · {humanSize(d.size)} · {d.type} · {d.model ?? "?"}
                  {d.exportedPool ? <span className="muted small"> — an old pool '{d.exportedPool.name}' on it: --wipe to reuse</span> : null}
                </label>
              </li>
            ))}
          </ul>
          <label className="form-row">
            <span>what it holds</span>
            <select value={poolClass} onChange={(e) => { setCls(e.target.value as PoolClass); setPool(null); }}>
              {POOL_CLASSES.map((c) => <option key={c.cls} value={c.cls}>{c.label}</option>)}
            </select>
          </label>
          <label className="form-row">
            <span>pool name</span>
            <input type="text" value={poolName} onChange={(e) => setPool(e.target.value.trim())} />
            <small className="muted">tank&lt;class&gt;&lt;N&gt;, the next free number proposed. A name other nodes have extends that storage to {node}: HA replication needs the same tanka name on both nodes.</small>
          </label>
          <label className="form-row">
            <span>layout</span>
            <select value={lay} onChange={(e) => setLayout(e.target.value)}>
              {["single", "mirror", "raidz1", "raidz2"].map((l) => <option key={l} value={l}>{l}</option>)}
            </select>
            <small className="muted">single: 1 disk, no redundancy · mirror: 2 or more · raidz1: 3 or more · raidz2: 4 or more</small>
          </label>
          {sel.length ? <StepView key={`${built.length}|${poolName}|${sel.join(",")}|${lay}`} step={step} me={me} onDone={(ok) => ok && added()} /> : <p className="muted small">Tick the disks for the pool.</p>}
        </>
      ) : (
        <p className="muted small">{built.length ? "No healthy disk is left in no pool." : "It has no healthy disk in no pool — nothing to propose."}</p>
      )}
      <p className="small">
        <button className="btn btn-primary" onClick={() => onContinue(built.length)}>{continueLabel}</button>{" "}
        {disks.length ? <span className="muted">{built.length ? "the disks left stay free" : "no data pool now"} (site-manager node storage add later)</span> : null}
      </p>
    </div>
  );
}

// The node's side card: opens the picker for a node with a healthy disk in no
// pool. Closed by its × or Continue, never by a click beside it: a pool being
// built keeps its job in view.
export function AddPoolButton({ node }: { node: string }) {
  const [open, setOpen] = useState(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Add data pools…</button>
      {open ? (
        <div className="modal-back">
          <div className="modal modal-wide" role="dialog" aria-label={`Data pools on ${node}`}>
            <header className="modal-head">
              <h2>Data pools on {node}</h2>
              <button className="btn-x" onClick={() => setOpen(false)} aria-label="close">×</button>
            </header>
            <NodePools node={node} onContinue={() => setOpen(false)} continueLabel="Done" />
          </div>
        </div>
      ) : null}
    </>
  );
}
