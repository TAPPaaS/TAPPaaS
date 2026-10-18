// catalog.test.ts — what a registered repository offers (src/catalog.ts): every
// module its catalogue lists whatever the grouping, described from the
// module's own JSON, installed when a deployed instance comes from its
// directory (whatever the instance is called), and why a catalogue that
// cannot be read is not shown.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { catalogEntries, moduleSourceOf, repositoryCatalog } from "../../src/catalog";
import { check, done } from "./check";

const put = (f: string, v: unknown) => {
  mkdirSync(join(f, ".."), { recursive: true });
  writeFileSync(f, typeof v === "string" ? v : JSON.stringify(v));
};

// The TAPPaaS shape: one flat list; description and maturity in each module's JSON.
const tap = mkdtempSync(join(tmpdir(), "cat-tap-"));
put(join(tap, "src/module-catalog.json"), { description: "x", modules: [
  { moduleName: "network", legacyName: "firewall", moduleJson: "src/foundation/network/network.json", stack: "foundation" },
  { moduleName: "deconz", moduleJson: "src/home/deconz/deconz.json", stack: "home" },
  { moduleName: "immich", moduleJson: "src/home/immich/immich.json", stack: "home" },
  { moduleName: "ghost", moduleJson: "src/home/ghost/ghost.json", stack: "home" },
  { moduleName: "templates", moduleJson: "src/foundation/templates/templates.json", stack: "foundation" },
  { moduleName: "tappaas-nixos", moduleJson: "src/foundation/templates/tappaas-nixos.json", stack: "template" },
] });
put(join(tap, "src/home/deconz/deconz.json"), { description: "Zigbee gateway", status: "Testing", stack: "home", vmid: 213 });
put(join(tap, "src/home/immich/immich.json"), { description: "Photos", status: "Production" });
// The Community shape: lists by kind, the maturity in the entry.
const com = mkdtempSync(join(tmpdir(), "cat-com-"));
put(join(com, "src/module-catalog.json"), { applicationModules: [{ moduleName: "unifi-os", moduleJson: "src/larsrossen/network/unifi-os/unifi-os.json", stack: "infrastructure", category: "network", status: "Development" }], testModules: [] });

const instances = [
  { name: "deconz-test", source: `${tap}/src/home/deconz` },
  { name: "immich", source: `${tap}/src/home/immich/` },
  { name: "firewall", source: null },
  { name: "templates", source: `${tap}/src/foundation/templates` },
  { name: "unifi-os", source: `${com}/src/larsrossen/network/unifi-os` },
];
const t = repositoryCatalog({ name: "TAPPaaS", path: tap, catalog: "src/module-catalog.json" }, instances);
const by = (n: string) => t.modules.find((m) => m.name === n)!;
check(t.error === null && t.modules.length === 6, "every module of a flat catalogue");
check(by("templates").instances.join() === "templates" && by("tappaas-nixos").instances.length === 0, "entries sharing a directory: the instance is the one whose JSON is named like it");
check(by("deconz").instances.join() === "deconz-test" && by("deconz").description === "Zigbee gateway" && by("deconz").maturity === "Testing", "installed under another name: matched by its directory; described from its own JSON");
check(by("immich").instances.join() === "immich" && by("immich").stack === "home", "a trailing slash in moduleSource still matches; the catalogue's stack stands in");
check(by("deconz").vmid === 213 && by("immich").vmid === null, "the VM id a module gives its guest, from its own JSON (none: null)");
check(by("network").instances.join() === "firewall", "an instance with no moduleSource matches by name or legacy name");
check(by("ghost").instances.length === 0 && by("ghost").description === null, "not installed; a module JSON that is missing leaves the catalogue's fields");
const c = repositoryCatalog({ name: "Community", path: com, catalog: "src/module-catalog.json" }, instances);
check(c.modules.length === 1 && c.modules[0].maturity === "Development" && c.modules[0].category === "network" && c.modules[0].instances.join() === "unifi-os", "a catalogue grouped by kind; the maturity from the entry");
check(!t.modules.some((m) => m.instances.includes("unifi-os")), "an instance from another repository is not installed here");

const none = repositoryCatalog({ name: "Lost", path: join(tap, "nowhere"), catalog: "src/module-catalog.json" }, instances);
check(none.error !== null && /not found/.test(none.error) && none.modules.length === 0, "a missing catalogue says why");
const bad = mkdtempSync(join(tmpdir(), "cat-bad-"));
put(join(bad, "src/module-catalog.json"), "{ nope");
check(/not valid JSON/.test(repositoryCatalog({ name: "Bad", path: bad }, []).error ?? ""), "an unreadable catalogue says why (the default catalogue path)");
check(/no path/.test(repositoryCatalog({ name: "X" }, []).error ?? ""), "a repository without a path says so");
check(catalogEntries({ a: [{ moduleName: "x", moduleJson: "y" }, { moduleName: "z" }], b: { c: [{ moduleName: "w", moduleJson: "v" }] } }).length === 2, "entries at any depth, only those with a moduleJson");

const cfg = mkdtempSync(join(tmpdir(), "cat-cfg-"));
put(join(cfg, "immich.json"), { moduleSource: "/home/tappaas/TAPPaaS/src/home/immich" });
check(moduleSourceOf(cfg, "immich") === "/home/tappaas/TAPPaaS/src/home/immich" && moduleSourceOf(cfg, "nosuch") === null, "a deployed module's moduleSource from its config");

done("catalog");
