// classsymbol.test.ts — every CMDB class has its own symbol (web/src/
// classsymbol.ts): the metamodel's classes all in the table, no two symbols
// alike, a TAPPaaS node and its server asset apart in shape and family.

import { spawnSync } from "child_process";
import { readFileSync } from "fs";
import { join } from "path";
import { CLASS_SYMBOL, FAMILY_COLOR, assetClassOf, classSymbol } from "../../web/src/classsymbol";
import { check, done } from "./check";

const meta = join(__dirname, "..", "..", "..", "..", "..", "controller", "cmdb-controller", "metamodel");
const defs = ["ci", "place", "resource"].flatMap((f) => Object.entries((JSON.parse(readFileSync(join(meta, `${f}.json`), "utf8")) as { classes: Record<string, { symbol?: string; family?: string; label?: string }> }).classes));
const classes = defs.map(([c]) => c);
const differ = defs.filter(([c, d]) => !CLASS_SYMBOL[c] || CLASS_SYMBOL[c].symbol !== d.symbol || CLASS_SYMBOL[c].family !== d.family || CLASS_SYMBOL[c].word !== d.label).map(([c]) => c);
check(differ.length === 0, `the console's copy is the metamodel's ${differ.join(", ")}`);
const run = spawnSync(process.execPath, [join(meta, "gen-symbols.mjs"), "--check"], { encoding: "utf8" });
const gen = run.status === 0 ? "" : run.stderr || `exit ${run.status}`;
check(gen === "", `gen-symbols --check passes (symbols, families, both copies current) ${gen}`);

check(classes.length >= 40, `the metamodel has its classes (${classes.length})`);
const missing = classes.filter((c) => !CLASS_SYMBOL[c]);
check(missing.length === 0, `every metamodel class has a symbol ${missing.join(", ")}`);
const symbols = Object.values(CLASS_SYMBOL).map((s) => s.symbol);
const twice = symbols.filter((s, i) => symbols.indexOf(s) !== i);
check(twice.length === 0, `no two classes share a symbol ${twice.join(" ")}`);
check(Object.values(FAMILY_COLOR).every((c) => /^var\(--[a-z0-9-]+\)$/.test(c)), "every family colour is a token");
check(!symbols.includes("◎"), "the root-cause marker is no class's symbol");
const m = classSymbol("machine"), s = classSymbol("server");
check(m.symbol !== s.symbol && m.family !== s.family, "a TAPPaaS node and its server differ in shape and family");
check(m.word === "TAPPaaS node", "a TAPPaaS node reads as one");
check(classSymbol("gizmo").symbol === "G" && classSymbol("gizmo").family === "other", "an unknown class falls back to its initial");
check(assetClassOf("switch") === "network-device" && assetClassOf("ups") === "appliance" && assetClassOf("disk") === "disk" && assetClassOf("?") === "asset", "an asset's kind maps to its class");
done("class symbols");
