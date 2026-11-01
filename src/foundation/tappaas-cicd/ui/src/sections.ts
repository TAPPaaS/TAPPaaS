// sections.ts — a module's page as a list of sections (ADR-034 D11), each
// contributed by a layer: generic (every module), kind (kindsections.ts) and
// module (its console.json). The backend resolves the layers and the data; the
// front end draws what it is given, knowing only the generic sections by id.

import { ConsoleFile, DeclaredField, DeclaredOperation, DeclaredSection } from "./consolefile";
import { ManifestVerb, Manifests, Validation, findVerb, validateArgv } from "./manifest";

type Obj = Record<string, unknown>;

export type Layer = "generic" | "kind" | "module";
export type Format = "text" | "bytes" | "mib" | "percent" | "module" | "status";

export interface Column {
  key: string;
  label: string;
  format?: Format;
}
export interface Gauge {
  label: string;
  value: number;
  max: number;
  format?: Format;
  level?: "pass" | "warn" | "fail" | "skip"; // else by how full it is
}
export type Block =
  | { kind: "kv"; title?: string; rows: { label: string; value: unknown; format?: Format }[] }
  | { kind: "table"; title?: string; columns: Column[]; rows: Obj[]; empty?: string }
  | { kind: "gauges"; title?: string; gauges: Gauge[]; empty?: string }
  | { kind: "text"; title?: string; text: string }
  | { kind: "note"; text: string };

export interface Operation {
  label: string;
  bin: string;
  verb: string; // the manifest verb's name
  fixed: string[];
  note: string | null;
  kind: "danger" | null;
}

export interface Section {
  id: string;
  title: string;
  layer: Layer;
  generic: boolean; // drawn by the page itself (health, operate, about)
  source: string | null; // where it reads from
  at: string | null; // how old its read is
  error: string | null; // shown in its place
  summary: Gauge | null; // on the title's line
  blocks: Block[];
  operations: Operation[];
  operationErrors: string[];
}

export const section = (id: string, title: string, layer: Layer, rest: Partial<Section> = {}): Section => ({ id, title, layer, generic: false, source: null, at: null, error: null, summary: null, blocks: [], operations: [], operationErrors: [], ...rest });

export const GENERIC: Section[] = [
  section("health", "Health", "generic", { generic: true }),
  section("operate", "Operate", "generic", { generic: true }),
  section("about", "About the Module template", "generic", { generic: true }),
];

// What a layer places: a section, or a move of one (no section).
export interface Placed<T> {
  id: string;
  before?: string;
  after?: string;
  item: T | null;
}

// Each layer over the ones below: a known id replaces that section where it
// stands, a new one goes before `anchor`, and before/after move either.
export function compose<T>(base: (T & { id: string })[], layers: Placed<T & { id: string }>[][], anchor = "operate"): (T & { id: string })[] {
  const out = [...base];
  for (const layer of layers) {
    for (const p of layer) {
      const at = out.findIndex((x) => x.id === p.id);
      if (p.item) {
        if (at >= 0) out[at] = p.item;
        else {
          const a = out.findIndex((x) => x.id === anchor);
          out.splice(a >= 0 ? a : out.length, 0, p.item);
        }
      }
      const target = p.before ?? p.after;
      if (target === undefined || target === p.id) continue;
      const from = out.findIndex((x) => x.id === p.id);
      if (from < 0 || !out.some((x) => x.id === target)) continue;
      const [moved] = out.splice(from, 1);
      const to = out.findIndex((x) => x.id === target);
      out.splice(p.before !== undefined ? to : to + 1, 0, moved);
    }
  }
  return out;
}

// A dotted path into a verb's answer; an index reads an array.
export function pathIn(doc: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((o, k) => {
    if (Array.isArray(o)) return o[Number(k)];
    return typeof o === "object" && o !== null ? (o as Obj)[k] : undefined;
  }, doc);
}

const plain = (v: unknown): boolean => v === null || ["string", "number", "boolean"].includes(typeof v);
const fmt = (f: string | undefined): Format | undefined => f as Format | undefined;

// A declared section's answer as blocks; a shape it does not have is an error.
export function declaredBlocks(s: DeclaredSection, doc: unknown): Block[] {
  const data = s.rows ? pathIn(doc, s.rows) : doc;
  const missing = new Error(s.rows ? `the answer has no '${s.rows}'` : "the answer is not what this section draws");
  if (s.render === "table") {
    if (!Array.isArray(data)) throw missing;
    const columns = (s.columns ?? []).map((c) => ({ key: c.path, label: c.label, format: fmt(c.format) }));
    const rows = (data as unknown[]).map((r) => Object.fromEntries(columns.map((c) => [c.key, pathIn(r, c.key) ?? null])));
    return [{ kind: "table", columns, rows }];
  }
  if (s.render === "gauges") {
    const list = s.rows ? (Array.isArray(data) ? (data as unknown[]) : null) : [doc];
    if (!list) throw missing;
    const gauge = (f: DeclaredField, row: unknown): Gauge[] => {
      const value = pathIn(row, f.value ?? "");
      const max = pathIn(row, f.max ?? "");
      if (typeof value !== "number" || typeof max !== "number") return [];
      const label = f.labelPath ? String(pathIn(row, f.labelPath) ?? "?") : (f.label ?? f.value ?? "");
      return [{ label, value, max, format: fmt(f.format) }];
    };
    return [{ kind: "gauges", gauges: list.flatMap((row) => (s.fields ?? []).flatMap((f) => gauge(f, row))), empty: "nothing to show" }];
  }
  if (typeof data !== "object" || data === null || Array.isArray(data)) throw missing;
  const rows = s.fields
    ? s.fields.map((f) => ({ label: f.label ?? "", value: pathIn(data, f.path ?? "") ?? null, format: fmt(f.format) }))
    : Object.entries(data as Obj).filter(([, v]) => plain(v)).map(([label, value]) => ({ label, value }));
  return [{ kind: "kv", rows }];
}

// A declared summary from a verb's answer; null when the answer lacks its numbers.
export function declaredSummary(s: DeclaredSection, doc: unknown): Gauge | null {
  const f = s.summary;
  if (!f) return null;
  const value = pathIn(doc, f.value ?? "");
  const max = pathIn(doc, f.max ?? "");
  return typeof value === "number" && typeof max === "number" ? { label: f.label ?? "", value, max, format: fmt(f.format) } : null;
}

const fill = (args: string[] | undefined, module: string): string[] => (args ?? []).map((a) => (a === "$module" ? module : a));

// A declared read as the argv it runs: only a verb a manifest declares as a
// read. console.json is a module's file; it never names a command of its own.
export function readArgv(s: DeclaredSection, module: string, ms: Manifests | null): { argv: string[] } | { refused: string } {
  if (!s.read) return { refused: "no read" };
  if (!ms) return { refused: "the verb manifests are not loaded yet" };
  const argv = [s.read.bin, ...s.read.verb.split(" "), ...fill(s.read.args, module), "--json"];
  const v: Validation = validateArgv(ms, argv);
  if (!v.ok) return { refused: v.reason };
  if (!v.read) return { refused: `${s.read.bin} ${s.read.verb} is not a read` };
  return { argv };
}

// The declared operations that name a verb with a manifest; the rest, why not.
export function resolveOperations(ops: DeclaredOperation[], module: string, ms: Manifests | null): { operations: Operation[]; errors: string[] } {
  const operations: Operation[] = [];
  const errors: string[] = [];
  for (const o of ops) {
    const fixed = fill(o.args, module);
    const m = ms?.byBin.get(o.bin);
    const found: { verb: ManifestVerb; used: number } | null = m ? findVerb(m, [...o.verb.split(" "), ...fixed]) : null;
    if (!ms) errors.push(`${o.label}: the verb manifests are not loaded yet`);
    else if (!found) errors.push(`${o.label}: ${o.bin} ${o.verb} has no manifest`);
    else operations.push({ label: o.label, bin: o.bin, verb: found.verb.verb, fixed, note: o.note ?? null, kind: o.kind ?? null });
  }
  return { operations, errors };
}

// The module layer: its sections, read through `read` (the cached runner), and
// its operations as one section.
export async function moduleLayer(file: ConsoleFile, module: string, ms: Manifests | null, read: (argv: string[]) => Promise<{ value: unknown; at: number | null; error: string | null }>): Promise<Placed<Section>[]> {
  if (file.error) return [{ id: "console-json", item: section("console-json", "console.json", "module", { error: file.error }) }];
  const out = await Promise.all(file.sections.map(async (s): Promise<Placed<Section>> => {
    if ("bad" in s) return { id: s.id, item: section(s.id, `Section ${s.id}`, "module", { error: s.bad }) };
    if (!s.render) return { id: s.id, before: s.before, after: s.after, item: null };
    const made = (rest: Partial<Section>): Placed<Section> => ({ id: s.id, before: s.before, after: s.after, item: section(s.id, s.title ?? s.id, "module", rest) });
    const a = readArgv(s, module, ms);
    if ("refused" in a) return made({ error: a.refused });
    const source = `${s.read!.bin} ${s.read!.verb}`;
    const e = await read(a.argv);
    if (e.value === null || e.value === undefined) return made({ source, error: e.error ?? "reading…" });
    const at = e.at === null ? null : new Date(e.at).toISOString();
    try {
      return made({ source, at, blocks: declaredBlocks(s, e.value), summary: declaredSummary(s, e.value), error: null });
    } catch (x) {
      return made({ source, at, error: (x as Error).message });
    }
  }));
  if (file.operations.length || file.badOperations.length) {
    const { operations, errors } = resolveOperations(file.operations, module, ms);
    out.push({ id: "operations", item: section("operations", "Operations", "module", { operations, operationErrors: [...file.badOperations, ...errors] }) });
  }
  return out;
}
