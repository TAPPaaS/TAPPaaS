// portspec.ts — the port spec, as position-manager reads it (lib/ts
// positions.ts parsePortSpec, blockRows, blockX — the same code, which the
// front end's build cannot import): the Add a faceplate form's live preview
// draws what `faceplate add --ports` will record. ui/test's portspec test
// holds the two to the same results.
//
//   groups  side by side, a comma between them, a gap between them on the plate
//   rows    within a group, top to bottom, a slash between them
//   items   within a row, a plus between them: [<n>x]<kind>[@<rows>][:<name>]

import { PlateBlock, PortKind } from "../types";

export const PORT_KINDS = ["rj45", "sfp+", "sfp28", "poe", "console", "power"] as const;
export interface CatalogPort {
  name: string;
  id?: string;
  kind: PortKind;
}

export const SPEC_KINDS = [...PORT_KINDS, "gap"] as const;
// Where groups without a place stand: right of the plate's name, ports at
// most a twentieth of the plate apart.
export const SPEC_AREA: [number, number] = [0.3, 0.97];
const SPEC_MAX_PITCH = 0.05;
const SPEC_MAX_PORTS = 192;
const SPEC_MAX_ROWS = 6;
const ITEM_RE = /\s*(?:(\d+)\s*x\s*)?(sfp28|sfp\+|rj45|poe|console|power|gap)(?:@(\d+))?(?::([^+]*))?\s*(?:\+|$)/y;
const SPAN_RE = /\[\s*(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*\]\s*$/;

// A port spec, read: its blocks, or what is wrong with it.
export function parsePortSpec(spec: string): { blocks: PlateBlock<CatalogPort>[] } | { error: string } {
  const text = (spec ?? "").trim();
  if (!text) return { error: "the port spec is empty" };
  const counters = new Map<string, number>();
  const names = new Set<string>();
  let total = 0;
  const groups: { span: [number, number] | null; rows: (CatalogPort | null)[][] }[] = [];
  for (const raw of text.split(",")) {
    let g = raw.trim();
    if (!g) return { error: "an empty group: two commas, or one at an end" };
    let span: [number, number] | null = null;
    const sm = SPAN_RE.exec(g);
    if (sm) {
      span = [Number(sm[1]) / 100, Number(sm[2]) / 100];
      if (!(span[0] >= 0 && span[0] < span[1] && span[1] <= 1)) return { error: `${sm[0].trim()}: a place is [<from>-<to>] in percent, from less than to, at most 100` };
      g = g.slice(0, sm.index).trim();
    }
    if (!g) return { error: "a group with a place and no ports" };
    const rows: (CatalogPort | null)[][] = [];
    const rowTexts = g.split("/");
    for (const rt of rowTexts) {
      if (!rt.trim()) return { error: `'${g}': an empty row: two slashes, or one at an end` };
      const items: { n: number; kind: string; stack: number; name: string | null }[] = [];
      ITEM_RE.lastIndex = 0;
      const s = rt.trim();
      while (ITEM_RE.lastIndex < s.length) {
        const at = ITEM_RE.lastIndex;
        const m = ITEM_RE.exec(s);
        if (!m || m.index !== at) return { error: `'${s.slice(at)}': not [<n>x]<kind>[@<rows>][:<name>] — a kind is ${SPEC_KINDS.join(", ")}` };
        const n = m[1] === undefined ? 1 : Number(m[1]);
        if (n < 1 || n > 96) return { error: `${m[0].trim()}: a count is 1 to 96` };
        items.push({ n, kind: m[2], stack: m[3] === undefined ? 1 : Number(m[3]), name: m[4] === undefined ? null : m[4].trim() });
        if (m[0].length === 0) break;
      }
      const row: (CatalogPort | null)[] = [];
      for (const it of items) {
        if (it.kind === "gap") {
          if (it.name !== null) return { error: "a gap has no name" };
          for (let i = 0; i < it.n; i++) row.push(null);
          continue;
        }
        if (it.stack !== 1 && (items.length > 1 || rowTexts.length > 1)) return { error: `@${it.stack}: rows of its own only for a group that is that one item` };
        if (it.stack < 1 || it.stack > SPEC_MAX_ROWS) return { error: `@${it.stack}: 1 to ${SPEC_MAX_ROWS} rows` };
        if (it.name === "") return { error: "a name after : is empty" };
        let tpl = it.name ?? "{n}";
        if (it.n > 1 && !tpl.includes("{n}")) tpl += "{n}";
        const ports: CatalogPort[] = [];
        for (let i = 0; i < it.n; i++) {
          let name = tpl;
          if (tpl.includes("{n}")) {
            const k = (counters.get(tpl) ?? 0) + 1;
            counters.set(tpl, k);
            name = tpl.split("{n}").join(String(k));
          }
          if (names.has(name)) return { error: `port ${name} appears twice` };
          names.add(name);
          ports.push({ name, kind: it.kind as PortKind });
        }
        total += ports.length;
        if (it.stack > 1) {
          // Stacked: port 1 over 2, 3 over 4, … — each its own row.
          for (let r = 0; r < it.stack; r++) rows.push(ports.filter((_, i) => i % it.stack === r));
        } else row.push(...ports);
      }
      if (items.every((it) => it.stack === 1)) rows.push(row);
    }
    if (rows.length > SPEC_MAX_ROWS) return { error: `'${g}': at most ${SPEC_MAX_ROWS} rows` };
    groups.push({ span, rows });
  }
  if (total === 0) return { error: "the port spec has no ports" };
  if (total > SPEC_MAX_PORTS) return { error: `${total} ports: at most ${SPEC_MAX_PORTS}` };
  const placed = groups.filter((g) => g.span).length;
  if (placed && placed !== groups.length) return { error: "give every group its place [<from>-<to>], or none" };
  const cols = groups.map((g) => Math.max(1, ...g.rows.map((r) => r.length)));
  if (placed) {
    const spans = groups.map((g) => g.span!).sort((a, b) => a[0] - b[0]);
    for (let i = 1; i < spans.length; i++) if (spans[i][0] < spans[i - 1][1]) return { error: "two groups' places overlap" };
    return { blocks: groups.map((g) => ({ from: g.span![0], to: g.span![1], rows: g.rows })) };
  }
  // Packed to the right of the plate's name: a column's place between groups.
  const slots = cols.reduce((a, b) => a + b, 0) + groups.length - 1;
  const pitch = Math.min(SPEC_MAX_PITCH, (SPEC_AREA[1] - SPEC_AREA[0]) / slots);
  let x = SPEC_AREA[1] - slots * pitch;
  return {
    blocks: groups.map((g, i) => {
      const b = { from: round(x), to: round(x + cols[i] * pitch), rows: g.rows };
      x += (cols[i] + 1) * pitch;
      return b;
    }),
  };
}
const round = (x: number): number => Math.round(x * 10000) / 10000;

// A plate's rows from its blocks: row by row, the blocks' ports side by side,
// a gap between two blocks.
export function blockRows<P>(blocks: PlateBlock<P>[]): (P | null)[][] {
  const n = Math.max(0, ...blocks.map((b) => b.rows.length));
  const rows: (P | null)[][] = [];
  for (let i = 0; i < n; i++) {
    const row: (P | null)[] = [];
    for (const b of blocks) {
      const r = b.rows[i];
      if (!r?.length) continue;
      if (row.length) row.push(null);
      row.push(...r);
    }
    rows.push(row);
  }
  return rows;
}

// Where a block's port is: the centre of its column, as a share of the
// plate's width.
export const blockX = (b: Pick<PlateBlock<unknown>, "from" | "to" | "rows">, col: number): number => {
  const cols = Math.max(1, ...b.rows.map((r) => r.length));
  return b.from + ((col + 0.5) * (b.to - b.from)) / cols;
};
