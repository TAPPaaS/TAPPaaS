// consoletargets.test.ts — where the assistant may position the console
// (web/src/consoletargets.ts, one catalog for the backend's open_console and
// the drawer): targets resolved and refused, every wizard taken by a button
// of the front end (opener.ts), and the values a form starts from (argv.ts).

import { readFileSync, readdirSync } from "fs";
import { join } from "path";
import { PAGES, WIZARDS, resolveTarget, wizardForVerb } from "../../web/src/consoletargets";
import { prefillValues } from "../../web/src/argv";
import { ManifestVerb } from "../../web/src/types";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const ok = (t: unknown, v?: unknown) => {
  const r = resolveTarget(t, v);
  return r.ok ? r : null;
};
const why = (t: unknown, v?: unknown): string => {
  const r = resolveTarget(t, v);
  return r.ok ? "" : r.reason;
};

check(ok("add-node")?.path === "/setup/day2" && ok("add-node")?.kind === "wizard" && ok("add-node")?.title === "the Add node wizard", "add-node: Setup's Day 2");
check(ok("  modify-module   immich ", { memory: 10240 })?.target === "modify-module immich" && JSON.stringify(ok("modify-module immich", { memory: 10240 })?.values) === '{"memory":"10240"}', "a Modify: its object after the name, a number as its text");
check(ok("add-wifi", { zone: "home" })?.path === "/setup/day2#wifi-home" && JSON.stringify(ok("add-wifi", { zone: "home" })?.values) === "{}", "the object as a value");
check(JSON.stringify(ok("add-node", { "--mac": "aa", "no-wan": true })?.values) === '{"mac":"aa","no-wan":true}', "a value's leading dashes go");
check(ok("/site/physical/")?.title === "the physical view" && ok("/modules/immich")?.path === "/modules/immich" && ok("/setup/day2#wifi")?.path === "/setup/day2", "pages, with a trailing slash or a fragment");
check(/no page \/nope \(pages: \/, \/setup/.test(why("/nope")) && /takes no values/.test(why("/modules", { a: 1 })), "an unknown page, or values on a page, are refused");
check(/no wizard 'frob'/.test(why("frob")) && /needs the module/.test(why("modify-module")) && /takes no name/.test(why("add-node tappaas3")), "an unknown wizard, a missing object, a stray name");
check(/'\.\.\/etc' is not a module's name/.test(why("modify-module ../etc")) && /not a string, number/.test(why("add-node", { name: { a: 1 } })) && /`values` is an object/.test(why("add-node", ["x"])), "names and values are checked");
check(/add-buddy has no host: its values are kind/.test(why("add-buddy", { host: "x" })) && ok("add-user", { email: "a@b" }) !== null, "a wizard's own keys, or any of an object's fields");
check(wizardForVerb("site-manager", "node add")?.name === "add-node" && wizardForVerb("identity-manager", "user add")?.name === "add-user" && wizardForVerb("network-manager", "wgvpn add-peer")?.name === "enrol-device" && wizardForVerb("module-manager", "show") === null, "the wizard of a manager verb");
check(new Set(WIZARDS.map((w) => w.name)).size === WIZARDS.length && PAGES.every((p) => p.path.startsWith("/")), "names are unique, pages are paths");

// Every wizard has a button on the front end that takes its request.
const web = join(FIX, "..", "..", "web", "src");
const sources = [web, join(web, "pages")].flatMap((d) => readdirSync(d).filter((f) => f.endsWith(".tsx")).map((f) => readFileSync(join(d, f), "utf8"))).join("\n");
const taken = WIZARDS.filter((w) => sources.includes(`wizard: "${w.name}"`) || sources.includes(`useOpenedBy("${w.name}"`));
check(taken.length === WIZARDS.length, `every wizard of the catalog is opened by a page (missing: ${WIZARDS.filter((w) => !taken.includes(w)).map((w) => w.name).join(", ") || "none"})`);

// The values a form starts from.
const verb = (over: Partial<ManifestVerb>): ManifestVerb => ({ verb: "v", keys: [["v"]], usage: "", note: null, details: null, positionals: [], options: [], open: false, effect: "write", preview: { kind: "none", touches: "" }, destructive: false, destructiveWhen: [], readWhen: [], writeWhen: [], disruptions: [], ...over });
const opt = (flag: string, takesValue: boolean) => ({ flag, takesValue, arg: null, choices: null, repeatable: false, description: "" });
const nodeAdd = verb({ positionals: [{ name: "name", optional: false, repeatable: false }], options: [opt("--pxe", false), opt("--mac", true), opt("--no-wan", false)] });
check(JSON.stringify(prefillValues({ bin: "site-manager", fixed: ["tappaas3"] }, nodeAdd, { mac: "aa", "no-wan": true, cores: "4" })) === '{"--mac":"aa","--no-wan":true}', "options by name; a fixed positional and an unknown key are left");
const envAdd = verb({ positionals: [{ name: "env", optional: false, repeatable: false }], options: [opt("--create-zone", false)], open: true });
check(JSON.stringify(prefillValues({ bin: "environment-manager" }, envAdd, { name: "lab", "create-zone": "true", displayName: "Lab" })) === '{"@env":"lab","--create-zone":true,"@extra":["--displayName Lab"]}', "the one positional as `name`; an open verb's other keys as further options");
check(JSON.stringify(prefillValues({ bin: "environment-manager" }, envAdd, { displayName: "Lab" }, true)) === "{}", "…left to the field form when there is one");

done("consoletargets");
