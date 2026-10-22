// envcards.test.ts — the Environments page's cards (web/src/envcards.ts) over
// hrossen's environments, zones and modules (test/fixtures).

import { readFileSync } from "fs";
import { join } from "path";
import { EnvLike, ModuleLike, ZoneLike, envCards } from "../../web/src/envcards";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const read = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;
const envs = read<EnvLike[]>("environments.json");
const zones = read<ZoneLike[]>("zones.json");
const modules = read<{ modules: ModuleLike[] }>("modules.json").modules;
const cards = envCards(envs, zones, modules, "rossen");
const card = (n: string) => cards.find((c) => c.env.name === n)!;
const boxes = (n: string) => card(n).boxes.map((b) => `${b.zone ?? "-"}${b.own ? "" : "*"}`).join(" ");

check(cards.map((c) => c.env.name).join(" ") === "mgmt rossen test", "one card per environment");
check(card("rossen").isDefault && !card("mgmt").isDefault && card("rossen").type === "Service" && card("mgmt").type === "Management", "the default one marked; the type is its own zone's");
check(boxes("rossen").startsWith("rossen home iotCams iotCloud iotLocal"), `rossen owns its zone and the zones that serve it (${boxes("rossen")})`);
check(/dmz\*/.test(boxes("rossen")) && /mgmt\*/.test(boxes("rossen")), "a zone it uses but does not own (the DMZ, mgmt for unifi-os) is a shared box");
check(boxes("mgmt").endsWith("-*") && card("mgmt").boxes.find((b) => b.zone === null)!.modules.map((m) => m.name).join() === "cluster,templates", "modules with no zone: a box of their own");
const r = card("rossen").boxes.find((b) => b.zone === "rossen")!;
check(r.modules.some((m) => m.name === "immich") && card("rossen").boxes.find((b) => b.zone === "dmz")!.modules.map((m) => m.name).join() === "coturn,nomad,vaultwarden", "each module in its zone's box, in its own environment's card");
check(cards.reduce((s, c) => s + c.modules, 0) === modules.length, "every module drawn once");
check(card("rossen").boxes.find((b) => b.zone === "home")!.modules.length === 0, "an owned zone with nothing installed is still a box");
done("envcards");
