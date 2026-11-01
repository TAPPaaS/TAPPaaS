// compare.ts — the capture against the baseline, and the report a model reads.
//
//   node e2e/compare.ts --shots <dir> --baseline <dir> --out <dir> [--allow id,…]
//
// Per <viewport>/<id>: pixelmatch (threshold 0.1) of the two PNGs, the share
// of pixels that differ, diff/<viewport>/<id>.png when it is above 0.1 % or
// the sizes differ (both padded to the larger then), and a unified diff of the
// accessibility text. <out>/report.md: the changed routes first, then the
// route × viewport table, the text diffs, and "N routes differ, M unchanged".
// Exit 1 when a route differs that --allow does not name.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";

const LIMIT = 0.001;

function arg(name: string, dflt?: string): string {
  const i = process.argv.indexOf(`--${name}`);
  if (i > 0 && process.argv[i + 1] !== undefined) return process.argv[i + 1];
  if (dflt === undefined) throw new Error(`compare.ts: --${name} is required`);
  return dflt;
}
const SHOTS = arg("shots");
const BASE = arg("baseline");
const OUT = arg("out");
const ALLOW = new Set(arg("allow", "").split(",").filter(Boolean));
const ORDER = ["phone", "tablet", "laptop", "desktop"];

interface Cell { ratio: number | null; sized: string | null; diff: string | null; text: string | null; note: string | null }
const changed = (c: Cell): boolean => c.note !== null || c.diff !== null || c.text !== null;

const read = (p: string): string | null => (existsSync(p) ? readFileSync(p, "utf8") : null);

// The two images on one canvas of the larger size; what lies outside one of
// them is white.
function pad(img: PNG, w: number, h: number): PNG {
  if (img.width === w && img.height === h) return img;
  const out = new PNG({ width: w, height: h });
  out.data.fill(255);
  PNG.bitblt(img, out, 0, 0, img.width, img.height, 0, 0);
  return out;
}

function pixels(shot: string, base: string, diffPath: string): Pick<Cell, "ratio" | "sized" | "diff"> {
  const a = PNG.sync.read(readFileSync(shot));
  const b = PNG.sync.read(readFileSync(base));
  const w = Math.max(a.width, b.width);
  const h = Math.max(a.height, b.height);
  const diff = new PNG({ width: w, height: h });
  const n = pixelmatch(pad(b, w, h).data, pad(a, w, h).data, diff.data, w, h, { threshold: 0.1 });
  const ratio = n / (w * h);
  const sized = a.width !== b.width || a.height !== b.height ? `${b.width}x${b.height} → ${a.width}x${a.height}` : null;
  if (ratio <= LIMIT && !sized) return { ratio, sized, diff: null };
  mkdirSync(join(diffPath, ".."), { recursive: true });
  writeFileSync(diffPath, PNG.sync.write(diff));
  return { ratio, sized, diff: diffPath };
}

// A unified diff (3 lines of context) of two texts, or null when equal.
function unified(before: string, after: string, label: string): string | null {
  if (before === after) return null;
  const a = before.split("\n");
  const b = after.split("\n");
  const n = a.length;
  const m = b.length;
  const lcs: Uint32Array[] = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const ops: { t: " " | "-" | "+"; s: string; ai: number; bi: number }[] = [];
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) ops.push({ t: " ", s: a[i], ai: i++, bi: j++ });
    else if (i < n && (j === m || lcs[i + 1][j] >= lcs[i][j + 1])) ops.push({ t: "-", s: a[i], ai: i++, bi: j });
    else ops.push({ t: "+", s: b[j], ai: i, bi: j++ });
  }
  const out = [`--- baseline/${label}`, `+++ shots/${label}`];
  for (let k = 0; k < ops.length; ) {
    if (ops[k].t === " ") { k++; continue; }
    const start = Math.max(0, k - 3);
    let end = k;
    while (end < ops.length) {
      if (ops[end].t !== " ") { end++; continue; }
      let run = end;
      while (run < ops.length && ops[run].t === " ") run++;
      if (run === ops.length || run - end > 6) { end = Math.min(ops.length, end + 3); break; }
      end = run;
    }
    const h = ops.slice(start, end);
    const ac = h.filter((o) => o.t !== "+").length;
    const bc = h.filter((o) => o.t !== "-").length;
    out.push(`@@ -${h[0].ai + 1},${ac} +${h[0].bi + 1},${bc} @@`, ...h.map((o) => `${o.t}${o.s}`));
    k = end;
  }
  return out.join("\n");
}

const viewports = existsSync(SHOTS) ? readdirSync(SHOTS).filter((v) => ORDER.includes(v)).sort((x, y) => ORDER.indexOf(x) - ORDER.indexOf(y)) : [];
const ids = [...new Set(viewports.flatMap((v) => readdirSync(join(SHOTS, v)).filter((f) => f.endsWith(".png")).map((f) => f.slice(0, -4))))];
// routes.json's order, the rest after it.
const routeOrder: string[] = JSON.parse(readFileSync(join(import.meta.dirname, "routes.json"), "utf8")).map((r: { id: string }) => r.id);
ids.sort((x, y) => (routeOrder.indexOf(x) + 1 || 1e9) - (routeOrder.indexOf(y) + 1 || 1e9) || x.localeCompare(y));

const cells = new Map<string, Cell>();
for (const id of ids) {
  for (const v of viewports) {
    const shot = join(SHOTS, v, `${id}.png`);
    const base = join(BASE, v, `${id}.png`);
    const c: Cell = { ratio: null, sized: null, diff: null, text: null, note: null };
    if (!existsSync(shot)) c.note = "not captured";
    else if (!existsSync(base)) c.note = "no baseline";
    else Object.assign(c, pixels(shot, base, join(OUT, "diff", v, `${id}.png`)));
    const tb = read(join(BASE, v, `${id}.txt`));
    const ts = read(join(SHOTS, v, `${id}.txt`));
    if (tb !== null && ts !== null) c.text = unified(tb, ts, `${v}/${id}.txt`);
    else if (ts !== null && c.note === null) c.note = "no baseline text";
    cells.set(`${v}/${id}`, c);
  }
}

const differing = ids.filter((id) => viewports.some((v) => changed(cells.get(`${v}/${id}`)!)));
const blocking = differing.filter((id) => !ALLOW.has(id));
const link = (p: string): string => relative(OUT, p);
const pct = (r: number | null): string => (r === null ? "–" : `${(r * 100).toFixed(r > 0 && r < 0.0001 ? 4 : 2)}%`);

const md: string[] = [`# Console capture against the baseline`, ``, `shots \`${SHOTS}\`, baseline \`${BASE}\`, viewports ${viewports.join(", ")}.`, ``, `## Changed routes`, ``];
if (!differing.length) md.push("None.");
for (const id of differing) {
  const what = viewports
    .map((v) => ({ v, c: cells.get(`${v}/${id}`)! }))
    .filter((x) => changed(x.c))
    .map(({ v, c }) => `${v}: ${[c.note, c.diff ? `${pct(c.ratio)}${c.sized ? ` (${c.sized})` : ""} [diff](${link(c.diff)})` : null, c.text ? "text" : null].filter(Boolean).join(", ")}`);
  md.push(`- **${id}**${ALLOW.has(id) ? " (allowed)" : ""}: ${what.join("; ")}`);
}
md.push("", "## Route × viewport", "", "Mismatched pixels; a diff link above 0.1 % or on a size change; T = the accessibility text changed.", "");
md.push(`| route | ${viewports.join(" | ")} |`, `|---|${viewports.map(() => "---").join("|")}|`);
for (const id of ids) {
  const row = viewports.map((v) => {
    const c = cells.get(`${v}/${id}`)!;
    if (c.note) return c.note;
    return [pct(c.ratio), c.sized ?? "", c.diff ? `[diff](${link(c.diff)})` : "", c.text ? "T" : ""].filter(Boolean).join(" ");
  });
  md.push(`| ${differing.includes(id) ? `**${id}**` : id} | ${row.join(" | ")} |`);
}
const texts = ids.flatMap((id) => viewports.map((v) => cells.get(`${v}/${id}`)!.text).filter((t): t is string => t !== null));
if (texts.length) md.push("", "## Text diffs", "", ...texts.flatMap((t) => ["```diff", t, "```", ""]));
md.push("", `${differing.length} routes differ, ${ids.length - differing.length} unchanged`);
mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, "report.md"), `${md.join("\n")}\n`);
console.log(`${differing.length} routes differ, ${ids.length - differing.length} unchanged${blocking.length !== differing.length ? ` (${differing.length - blocking.length} allowed)` : ""}`);
process.exit(blocking.length ? 1 : 0);
