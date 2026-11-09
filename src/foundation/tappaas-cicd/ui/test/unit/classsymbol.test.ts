// classsymbol.test.ts — every CMDB class has its own symbol (web/src/
// classsymbol.ts): the metamodel's classes all in the table, no two symbols
// alike, a TAPPaaS node and its server asset apart in shape and family.

import { readFileSync } from "fs";
import { join } from "path";
import { CLASS_SYMBOL, FAMILY_COLOR, assetClassOf, classSymbol } from "../../web/src/classsymbol";
import { check, done } from "./check";

const meta = join(__dirname, "..", "..", "..", "..", "..", "controller", "cmdb-controller", "metamodel");
const classes = ["ci", "place", "resource"].flatMap((f) => Object.keys((JSON.parse(readFileSync(join(meta, `${f}.json`), "utf8")) as { classes: Record<string, unknown> }).classes));

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
