#!/usr/bin/env node
// gen-symbols.mjs — the class symbols: each class's `symbol`, `family` and
// `label` in ci.json, place.json and resource.json are the one source. This
// writes the console's copy (ui/web/src/classsymbol.gen.ts) and the table in
// this controller's README.md between its markers.
//
//   node metamodel/gen-symbols.mjs          write both
//   node metamodel/gen-symbols.mjs --check  exit 1 when a class lacks a symbol,
//                                           two share one, or a copy is stale

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const FILES = ["ci.json", "place.json", "resource.json"];
const GEN = join(HERE, "..", "..", "..", "ui", "web", "src", "classsymbol.gen.ts");
const README = join(HERE, "..", "README.md");
const BEGIN = "<!-- class-symbols:begin (metamodel/gen-symbols.mjs writes this table) -->";
const END = "<!-- class-symbols:end -->";

// The families, in the order the table lists them, with what each holds.
const FAMILIES = {
  compute: "what runs software",
  assets: "physical things and their parts",
  network: "what the network is made of",
  storage: "what storage is made of",
  software: "what runs in a node",
  identity: "users, groups, roles",
  places: "where things stand",
  collections: "what groups other objects",
  other: "the roots of the class tree",
};
// Drawn elsewhere in the console with another meaning: the Health tree's root-cause mark.
const RESERVED = { "◎": "the Health tree's root-cause mark" };

const classes = FILES.flatMap((f) =>
  Object.entries(JSON.parse(readFileSync(join(HERE, f), "utf8")).classes).map(([name, c]) => ({ name, file: f, parent: c.parent ?? null, symbol: c.symbol, family: c.family, label: c.label })),
);

const problems = [];
const seen = new Map();
for (const c of classes) {
  if (typeof c.symbol !== "string" || !c.symbol) problems.push(`${c.file}: ${c.name} has no symbol`);
  else if (seen.has(c.symbol)) problems.push(`${c.file}: ${c.name} has ${c.symbol}, as ${seen.get(c.symbol)} has`);
  else if (RESERVED[c.symbol]) problems.push(`${c.file}: ${c.name} has ${c.symbol}, ${RESERVED[c.symbol]}`);
  else seen.set(c.symbol, c.name);
  if (!(c.family in FAMILIES)) problems.push(`${c.file}: ${c.name} has family ${JSON.stringify(c.family)}, not one of ${Object.keys(FAMILIES).join(", ")}`);
  if (typeof c.label !== "string" || !c.label) problems.push(`${c.file}: ${c.name} has no label`);
}
if (problems.length) {
  for (const p of problems) console.error(`gen-symbols: ${p}`);
  process.exit(1);
}

const byFamily = Object.keys(FAMILIES).map((f) => [f, classes.filter((c) => c.family === f)]);

const gen = [
  "// classsymbol.gen.ts — written by controller/cmdb-controller/metamodel/gen-symbols.mjs",
  "// from the metamodel's class symbols. Do not edit: change the class in the",
  "// metamodel and run the script (ui/test.sh fails while this copy is stale).",
  "",
  `export const FAMILIES = ${JSON.stringify(Object.keys(FAMILIES))} as const;`,
  "export type Family = (typeof FAMILIES)[number];",
  "",
  "export const CLASSES: Record<string, { symbol: string; family: Family; label: string }> = {",
  ...byFamily.flatMap(([, cs]) => cs.map((c) => `  ${JSON.stringify(c.name)}: { symbol: ${JSON.stringify(c.symbol)}, family: ${JSON.stringify(c.family)}, label: ${JSON.stringify(c.label)} },`)),
  "};",
  "",
].join("\n");

const cell = (s) => s.replace(/\|/g, "\\|");
const table = [
  BEGIN,
  "",
  "| Symbol | Class | What it is | Family |",
  "|:---:|---|---|---|",
  ...byFamily.flatMap(([f, cs]) => cs.map((c) => `| ${cell(c.symbol)} | \`${c.name}\` | ${cell(c.label)} | ${f}: ${FAMILIES[f]} |`)),
  "",
  END,
].join("\n");

const readme = readFileSync(README, "utf8");
const a = readme.indexOf(BEGIN), b = readme.indexOf(END);
if (a < 0 || b < a) {
  console.error(`gen-symbols: ${relative(process.cwd(), README)} has no class-symbols markers`);
  process.exit(1);
}
const readmeNew = readme.slice(0, a) + table + readme.slice(b + END.length);

const stale = [];
let genOld = "";
try { genOld = readFileSync(GEN, "utf8"); } catch { /* none yet */ }
if (genOld !== gen) stale.push(GEN);
if (readme !== readmeNew) stale.push(README);

if (process.argv.includes("--check")) {
  for (const f of stale) console.error(`gen-symbols: ${relative(process.cwd(), f)} is stale: run node controller/cmdb-controller/metamodel/gen-symbols.mjs`);
  if (stale.length) process.exit(1);
  console.log(`gen-symbols: ${classes.length} classes, each its own symbol; both copies current`);
} else {
  if (stale.includes(GEN)) writeFileSync(GEN, gen);
  if (stale.includes(README)) writeFileSync(README, readmeNew);
  console.log(`gen-symbols: ${classes.length} classes; wrote ${stale.map((f) => relative(process.cwd(), f)).join(", ") || "nothing (current)"}`);
}
