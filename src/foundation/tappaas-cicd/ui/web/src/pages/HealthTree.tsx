// HealthTree.tsx — the Health view's left pane (ADR-041 D5): the facets as a
// tree over the CMDB's containment, a level read at a time, each row carrying
// the roll-up of what is under it; a search; the current root causes above.
// What is open is remembered in this browser.

import { useCallback, useEffect, useRef, useState } from "react";
import { get, useRead } from "../api";
import { Filters, keptRollup, patchRows } from "../healthgraph";
import { ClassIcon } from "../moduleicon";
import { HealthRoot, HealthStatus, HealthTree, TreeMatch, TreeNode, TreeRollup } from "../types";
import { Dot, Level, Tag, when } from "../ui";

const LEVEL: Record<HealthStatus, Level> = { ok: "pass", warning: "warn", critical: "fail", unknown: "skip" };
const OPEN_KEY = "tappaas.health.tree.open";

function storedOpen(): Set<string> {
  try {
    const v = JSON.parse(window.localStorage.getItem(OPEN_KEY) ?? "null") as unknown;
    if (Array.isArray(v)) return new Set(v.filter((x): x is string => typeof x === "string"));
  } catch {
    // no storage here: the tree simply opens as new
  }
  return new Set(["physical"]);
}

function storeOpen(open: Set<string>): void {
  try {
    window.localStorage.setItem(OPEN_KEY, JSON.stringify([...open]));
  } catch {
    // the same
  }
}

export interface TreeModel {
  doc: HealthTree | null;
  read: ReturnType<typeof useRead<HealthTree>>;
  kids: Record<string, TreeNode[]>;
  open: Set<string>;
  toggle: (id: string) => void;
  reveal: (id: string) => Promise<void>;
  revealed: string | null;
  patch: (rollups: Record<string, TreeRollup>, roots: HealthTree["roots"], counts: HealthTree["counts"], hasConditions: boolean) => void;
  reload: () => void;
}

export function useTree(): TreeModel {
  const read = useRead<HealthTree>("health/tree", 60_000);
  const [doc, setDoc] = useState<HealthTree | null>(null);
  const [kids, setKids] = useState<Record<string, TreeNode[]>>({});
  const [open, setOpen] = useState<Set<string>>(storedOpen);
  const [revealed, setRevealed] = useState<string | null>(null);
  const known = useRef(kids);
  known.current = kids;
  const load = useCallback((ids: string[]) => {
    for (const id of ids) {
      void get<TreeNode[]>(`health/tree/${encodeURIComponent(id)}/children`).then(
        (e) => e.data && setKids((k) => ({ ...k, [id]: e.data as TreeNode[] })),
        () => undefined, // gone since it was opened: its row is gone too
      );
    }
  }, []);
  // Every read of the facets is one of what is open too: a stream that is down
  // leaves the rows a minute behind, no more.
  useEffect(() => {
    if (!read.env?.data) return;
    setDoc(read.env.data);
    load(Object.keys(known.current));
  }, [read.env, load]);
  useEffect(() => {
    storeOpen(open);
    load([...open].filter((id) => !known.current[id]));
  }, [open, load]);
  const toggle = useCallback((id: string) => setOpen((o) => {
    const n = new Set(o);
    if (!n.delete(id)) n.add(id);
    return n;
  }), []);
  const reveal = useCallback(async (id: string) => {
    const e = await get<string[]>(`health/tree/${encodeURIComponent(id)}/path`).catch(() => null);
    if (!e?.data) return;
    const way = e.data.slice(0, -1);
    setOpen((o) => new Set([...o, ...way]));
    setRevealed(id);
  }, []);
  const patch: TreeModel["patch"] = useCallback((rollups, roots, counts, hasConditions) => {
    setDoc((d) => (d ? { ...d, roots, counts, hasConditions, facets: patchRows(d.facets, rollups) } : d));
    setKids((k) => Object.fromEntries(Object.entries(k).map(([id, rows]) => [id, patchRows(rows, rollups)])));
  }, []);
  return { doc, read, kids, open, toggle, reveal, revealed, patch, reload: read.reload };
}

function Row({ n, depth, trail, m, selected, select, filters }: { n: TreeNode; depth: number; trail: string[]; m: TreeModel; selected: string | null; select: (id: string) => void; filters: Filters }) {
  const facet = n.class === "facet";
  const isOpen = m.open.has(n.id);
  const here = useRef<HTMLDivElement>(null);
  const on = selected === n.id && !facet;
  useEffect(() => {
    if (on && m.revealed === n.id) here.current?.scrollIntoView({ block: "nearest" });
  }, [on, m.revealed, n.id]);
  // A loop in the data is not walked twice.
  const rows = isOpen ? (m.kids[n.id] ?? []).filter((c) => !trail.includes(c.id)) : [];
  const title = `${n.status}${n.notOk ? ` · ${n.notOk} need a look` : ""}${n.unknown ? ` · ${n.unknown} unknown` : ""}`;
  return (
    <li>
      <div ref={here} className={`ht-row${on ? " ht-on" : ""}${keptRollup(n, filters) ? "" : " ht-dim"}`} style={{ paddingLeft: 4 + depth * 14 }}>
        {n.children ? <button className="ht-caret" onClick={() => m.toggle(n.id)} aria-label={isOpen ? `Close ${n.label}` : `Open ${n.label}`} aria-expanded={isOpen}>{isOpen ? "▾" : "▸"}</button> : <span className="ht-caret" />}
        <button className={`ht-name${facet ? " ht-facet" : ""}`} onClick={() => (facet ? m.toggle(n.id) : select(n.id))} title={title}>
          <Dot level={LEVEL[n.status]} title={title} />
          {facet ? null : <ClassIcon cls={n.class} size={15} />}
          <span className="hc-name">{n.label}</span>
          {n.isRoot ? <span className="ht-root" title="a root cause">◎</span> : null}
          {n.flapping ? <span className="hc-mark" title="flapping">↯</span> : null}
          {n.acknowledged ? <span className="hc-mark" title="acknowledged">✓</span> : null}
          {n.maintenance ? <span className="hc-mark" title="in a maintenance window">⏸</span> : null}
        </button>
        {n.notOk ? <span className={`ht-count ht-count-${n.status}`}>{n.notOk}</span> : null}
      </div>
      {isOpen && rows.length ? (
        <ul className="ht-list">
          {rows.map((c) => <Row key={c.id} n={c} depth={depth + 1} trail={[...trail, n.id]} m={m} selected={selected} select={select} filters={filters} />)}
        </ul>
      ) : null}
    </li>
  );
}

function RootList({ roots, selected, choose }: { roots: HealthRoot[]; selected: string | null; choose: (id: string) => void }) {
  return (
    <ul className="health-roots">
      {roots.map((r) => (
        <li key={r.id}>
          <button className={`hroot${selected === r.id ? " hroot-on" : ""}${r.acknowledged ? " hroot-ack" : ""}`} onClick={() => choose(r.id)}>
            <span className="hroot-head"><Dot level={LEVEL[r.status]} title={r.status} /> <b>{r.label}</b> <span className="muted small">{r.class}</span></span>
            <span className="small">{r.message ?? r.reason ?? r.type}</span>
            <span className="muted small">
              {r.impactedCount} impacted{r.environments.length ? ` · ${r.environments.join(", ")}` : ""}{r.since ? ` · ${when(r.since)}` : ""}{r.acknowledged ? " · acknowledged" : ""}{r.flapping ? " · flapping" : ""}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function Matches({ q, selected, select }: { q: string; selected: string | null; select: (id: string) => void }) {
  const found = useRead<TreeMatch[]>(`health/tree?q=${encodeURIComponent(q)}`, 600_000);
  const rows = found.env?.data ?? null;
  if (!rows) return <p className="muted small">Searching…</p>;
  if (!rows.length) return <p className="muted small">Nothing by that name.</p>;
  return (
    <ul className="ht-list">
      {rows.map((n) => (
        <li key={n.id}>
          <button className={`ht-match${selected === n.id ? " ht-on" : ""}`} onClick={() => select(n.id)}>
            <span className="ht-name"><Dot level={LEVEL[n.status]} title={n.status} /> <ClassIcon cls={n.class} size={15} /> <span className="hc-name">{n.label}</span></span>
            <span className="muted small">{n.where || n.class}</span>
          </button>
        </li>
      ))}
    </ul>
  );
}

export function TreePane({ m, selected, select, chooseRoot, filters, open }: { m: TreeModel; selected: string | null; select: (id: string) => void; chooseRoot: (id: string) => void; filters: Filters; open: boolean }) {
  const [text, setText] = useState("");
  const [q, setQ] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setQ(text.trim()), 250);
    return () => clearTimeout(t);
  }, [text]);
  const doc = m.doc;
  return (
    <div className={`health-side${open ? " health-side-open" : ""}`}>
      <input className="ht-search" type="search" value={text} onChange={(e) => setText(e.target.value)} placeholder="Find an object" aria-label="find an object in the CMDB" />
      {q ? <Matches q={q} selected={selected} select={select} /> : (
        <>
          {doc?.roots.length ? (
            <>
              <h3>Root causes ({doc.roots.length})</h3>
              <RootList roots={doc.roots} selected={selected} choose={chooseRoot} />
            </>
          ) : doc?.hasConditions ? <p className="muted"><Tag level="ok" /> Nothing is wrong.</p> : null}
          <ul className="ht-list ht-top">
            {(doc?.facets ?? []).map((f) => <Row key={f.id} n={f} depth={0} trail={[]} m={m} selected={selected} select={select} filters={filters} />)}
          </ul>
        </>
      )}
    </div>
  );
}
