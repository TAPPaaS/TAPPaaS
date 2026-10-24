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
check(card("rossen").zone === "rossen" && card("mgmt").zone === "mgmt" && card("test").zone === "test", "an environment's own zone is the zone naming it (the record names none)");
check(card("rossen").isDefault && !card("mgmt").isDefault && card("rossen").type === "Service" && card("mgmt").type === "Management", "the default one marked; the type is its own zone's");
check(boxes("rossen").startsWith("rossen home iotCams iotCloud iotLocal"), `rossen owns its zone and the zones that serve it (${boxes("rossen")})`);
check(/dmz\*/.test(boxes("rossen")) && /mgmt\*/.test(boxes("rossen")), "a zone it uses but does not own (the DMZ, mgmt for unifi-os) is a shared box");
check(boxes("mgmt").endsWith("-*") && card("mgmt").boxes.find((b) => b.zone === null)!.modules.map((m) => m.name).join() === "cluster,templates", "modules with no zone: a box of their own");
const r = card("rossen").boxes.find((b) => b.zone === "rossen")!;
check(r.modules.some((m) => m.name === "immich") && card("rossen").boxes.find((b) => b.zone === "dmz")!.modules.map((m) => m.name).join() === "coturn,nomad,vaultwarden", "each module in its zone's box, in its own environment's card");
check(cards.reduce((s, c) => s + c.modules, 0) === modules.length, "every module drawn once");
check(card("rossen").boxes.find((b) => b.zone === "home")!.modules.length === 0, "an owned zone with nothing installed is still a box");
// A zone serving several environments is owned in each of their cards.
const multi = envCards(
  [{ name: "acme" }, { name: "lab" }],
  [{ name: "acme", type: "Service", environment: "acme" }, { name: "lab", type: "Service", environment: "lab" }, { name: "work", type: "Client", environment: ["acme", "lab"] }],
  [], null,
);
check(multi.every((c) => c.boxes.some((b) => b.zone === "work" && b.own)) && multi.map((c) => c.zone).join() === "acme,lab",
  "a zone serving two environments is an owned box in both cards; each card's own zone is its Service zone");
// #876: a shared service zone is a box in each card it lists, after the own
// zone, marked with the others; it is no card's own zone, and the modules
// installed there sit in their own environment's card.
{
  const erik = envCards(
    [{ name: "gridtefy" }, { name: "acmeco" }, { name: "erik" }],
    [
      { name: "erik", type: "Service", environment: "erik" },
      { name: "gridtefy", type: "Service", environment: "gridtefy" },
      { name: "acmeco", type: "Service", environment: "acmeco" },
      { name: "srvWork", type: "Service", environment: ["gridtefy", "acmeco"] },
      { name: "work", type: "Client", environment: ["gridtefy", "acmeco"] },
    ],
    [{ name: "git-gridtefy", zone0: "srvWork", environment: "gridtefy" }, { name: "crm-acmeco", zone0: "acmeco", environment: "acmeco" }],
    null,
  );
  const g = erik.find((c) => c.env.name === "gridtefy")!;
  const a = erik.find((c) => c.env.name === "acmeco")!;
  const tags = (c: typeof g) => c.boxes.map((b) => `${b.zone}${b.sharedWith ? `(shared with ${b.sharedWith.join(",")})` : b.own ? "" : "*"}`).join(" ");
  check(tags(g) === "gridtefy srvWork(shared with acmeco) work" && tags(a) === "acmeco srvWork(shared with gridtefy) work",
    `#876: own zone first, then the shared service zone marked with the others (${tags(g)} / ${tags(a)})`);
  check(g.zone === "gridtefy" && a.zone === "acmeco" && g.boxes.find((b) => b.zone === "srvWork")!.own === false, "#876: the shared zone is neither card's own zone");
  check(g.boxes.find((b) => b.zone === "srvWork")!.modules.map((m) => m.name).join() === "git-gridtefy" && a.boxes.find((b) => b.zone === "srvWork")!.modules.length === 0,
    "#876: a module in the shared zone sits in its own environment's card");
  check(!erik.find((c) => c.env.name === "erik")!.boxes.some((b) => b.zone === "srvWork"), "#876: an environment the shared zone does not list gets no box for it");
}
done("envcards");
