// nodepools.tsx — a data pool on a node's free disks: the inventory proposes
// the disks, the class and the layout, node storage add builds it.

import { useMemo, useState } from "react";
import { useRead } from "../api";
import { Step, StepView } from "../operate";
import { StorageInventory } from "../types";
import { POOL_CLASSES, PoolClass, diskId, humanSize, poolDisks, proposedDisks, proposedLayout, proposedPoolClass, proposedPoolName } from "../nodeadd";
import { canOperate, useMe } from "../ui";

// A data pool on the node's free disks (Add node's stage 4, and the node's side
// card in Site › Physical). The inventory proposes; the
// operator ticks the disks, may rename the pool or change the layout, and
// node storage add — which refuses what is not precise — builds it.
export function NodePools({ node, onAdded, onSkip }: { node: string; onAdded: () => void; onSkip?: () => void }) {
  const me = useMe();
  const inv = useRead<StorageInventory>("storage").env?.data;
  const here = inv?.nodes.find((n) => n.name === node);
  const disks = useMemo(() => poolDisks(here?.otherDisks ?? []), [here]);
  const taken = (here?.pools ?? []).map((p) => p.name);
  const [ticked, setTicked] = useState<string[] | null>(null);
  const sel = ticked ?? proposedDisks(here?.otherDisks ?? []).map(diskId);
  const first = disks.find((d) => sel.includes(diskId(d)));
  const [cls, setCls] = useState<PoolClass | null>(null);
  const [pool, setPool] = useState<string | null>(null);
  const [layout, setLayout] = useState<string | null>(null);
  const poolClass = cls ?? proposedPoolClass(first?.type ?? "ssd");
  const poolName = pool ?? proposedPoolName(poolClass, taken);
  const lay = layout ?? proposedLayout(sel.length);
  if (!inv) return <p className="muted small">reading the storage inventory…</p>;
  if (!here) return <p className="muted small">{node} is not in the storage inventory yet — it is read every few minutes.</p>;
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
      <p className="small">
        {here.pools.length ? <>Pools now: {here.pools.map((p) => p.name).join(", ")}. </> : <>No data pool yet: its guests go to the boot pool. </>}
        {disks.length ? "Its disks in no pool, healthy:" : "It has no healthy disk in no pool — nothing to propose."}
      </p>
      {disks.length ? (
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
      ) : null}
      {disks.length ? (
        <>
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
          {sel.length ? <StepView key={`${poolName}|${sel.join(",")}|${lay}`} step={step} me={me} onDone={(ok) => ok && onAdded()} /> : <p className="muted small">Tick the disks for the pool.</p>}
        </>
      ) : null}
      {onSkip ? <p className="small"><button className="btn" onClick={onSkip}>No data pool now →</button> <span className="muted">(site-manager node storage add later)</span></p> : null}
    </div>
  );
}

// The node's side card: opens the picker for a node with a healthy disk in no
// pool. Closed only by its ×, never by a click beside it: a pool being built
// keeps its job in view.
export function AddPoolButton({ node }: { node: string }) {
  const [open, setOpen] = useState(false);
  const [added, setAdded] = useState(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(true)}>Add a data pool…</button>
      {open ? (
        <div className="modal-back">
          <div className="modal modal-wide" role="dialog" aria-label={`A data pool on ${node}`}>
            <header className="modal-head">
              <h2>A data pool on {node}</h2>
              <button className="btn-x" onClick={() => setOpen(false)} aria-label="close">×</button>
            </header>
            <NodePools node={node} onAdded={() => setAdded(true)} />
            {added ? <p className="small"><button className="btn" onClick={() => setOpen(false)}>Done</button></p> : null}
          </div>
        </div>
      ) : null}
    </>
  );
}
