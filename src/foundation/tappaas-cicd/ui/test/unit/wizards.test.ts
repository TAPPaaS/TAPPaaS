// wizards.test.ts — Setup's Day 2 sequences (web/src/wizards.ts) over hrossen's
// records (fixtures/wizards/zones.json, fixtures/aps.json, 2026-10-19: home
// 310 and guest 510 active, work 320 inactive, every SSID still the template's
// placeholder; one AP "Nano HD" with no SSID): which zones get a WiFi button,
// and the argv each step builds through the console's own builder (argv.ts)
// against the verbs' manifests.

import { readFileSync } from "fs";
import { join } from "path";
import { buildArgv, confirmObject } from "../../web/src/argv";
import { ManifestVerb } from "../../web/src/types";
import { ApIn, BUDDY_KINDS, SatellitePlan, StepSpec, buddyNameProblem, buddySpecs, identitySpecs, satelliteProblems, satelliteSpec, ZoneIn, defaultAp, defaultSsid, isPlaceholderSsid, needsPassphrase, ssidProblem, wifiSpecs, wifiVerb, wifiZones } from "../../web/src/wizards";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const json = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;
const zonesDoc = json<Record<string, Omit<ZoneIn, "name">>>("wizards/zones.json");
const zones: ZoneIn[] = Object.entries(zonesDoc).map(([name, z]) => ({ name, ...z }));
const aps = json<ApIn[]>("aps.json");
const bash = JSON.parse(readFileSync(join(FIX, "..", "..", "manifest", "bash-verbs.json"), "utf8")) as { manifests: { name: string; verbs: ManifestVerb[] }[] };
const verbOf = (bin: string, verb: string): ManifestVerb => bash.manifests.find((m) => m.name === bin)!.verbs.find((v) => v.verb === verb)!;
const argv = (s: StepSpec, v: ManifestVerb): string => JSON.stringify(buildArgv(s, v, s.initial));

// ── which zones get a WiFi button ─────────────────────────────────────
const wifi = wifiZones(zones, aps);
check(wifi.map((z) => `${z.zone}:${z.vlan}:${z.type}`).join() === "home:310:Client,guest:510:Guest", "hrossen: home (Client, 310) and guest (Guest, 510), in VLAN order");
check(!wifi.some((z) => z.zone === "work"), "…work (Client, Inactive) gets none");
check(!wifi.some((z) => ["iotLocal", "iotCloud", "rossen", "mgmt"].includes(z.zone)), "…nor an IoT, Service or Management zone");
check(wifi.every((z) => z.declared === null && z.ssids.length === 0), "the template's <HOME_SSID> is not a name: no SSID declared, none mapped");
check(isPlaceholderSsid("<HOME_SSID>") && !isPlaceholderSsid("rossen-home"), "placeholders are <…>");
const home = wifi[0];
check(wifiVerb(home) === "Add" && defaultSsid("hrossen", home) === "hrossen-home", "home: Add WiFi, the SSID defaults to <site>-<zone>");
check(defaultAp(home, aps) === "Nano HD", "…on the only access point, preselected");
check(defaultAp(home, [...aps, { name: "U6", ssids: [] }]) === "", "two access points: none preselected");

// a zone an AP already serves: Change, with its name and AP
const served: ApIn[] = [{ name: "Nano HD", ssids: [{ name: "Rossen", zone: "home", vlan: 310, security: "wpa2-personal", enabled: true }] }];
const homeServed = wifiZones(zones, served)[0];
check(wifiVerb(homeServed) === "Change" && defaultSsid("hrossen", homeServed) === "Rossen" && defaultAp(homeServed, [...served, { name: "U6" }]) === "Nano HD", "an SSID mapped to home: Change WiFi, starting from it and its AP");
const declared = wifiZones([{ name: "home", type: "Client", vlantag: 310, SSID: "Rossen-Home" }], aps)[0];
check(declared.declared === "Rossen-Home" && wifiVerb(declared) === "Add" && defaultSsid("hrossen", declared) === "Rossen-Home", "a real name in zones.json and no AP broadcasting it: Add, defaulting to that name");
check(wifiZones([{ name: "lab", type: "Client", vlantag: 330 }], aps).length === 1, "no state means Active");

// ── the form's checks ─────────────────────────────────────────────────
check(needsPassphrase("wpa2-personal") && needsPassphrase("wpa3-personal") && !needsPassphrase("open") && !needsPassphrase("wpa2-enterprise"), "a personal mode takes a passphrase; open and enterprise do not");
check(ssidProblem("hrossen-home") === null && ssidProblem("") !== null && ssidProblem("a=b") !== null && ssidProblem("x".repeat(33)) !== null && ssidProblem("<HOME_SSID>") !== null, "an SSID: 1–32 characters, no '=', not a placeholder");
const sec = verbOf("ap-manager", "ssid add").options.find((o) => o.flag === "--security")!;
check(JSON.stringify(sec.choices) === '["wpa2-personal","wpa3-personal","open","wpa2-enterprise","wpa3-enterprise"]', "security: the controller's choices, from its manifest");

// ── the argv of each step ─────────────────────────────────────────────
const add = wifiSpecs({ ap: "Nano HD", ssid: "hrossen-home", zone: "home", vlan: 310, security: "wpa2-personal", replace: null });
check(add.remove === null, "Add: nothing to remove");
check(argv(add.add, verbOf("ap-manager", "ssid add")) === JSON.stringify(["ap-manager", "ssid", "Nano HD", "add", "hrossen-home", "--zone", "home", "--security", "wpa2-personal", "--vlan", "310"]), "ssid add: the AP as its word, the SSID, --zone, --security, --vlan");
check(argv(add.reconcile, verbOf("ap-manager", "reconcile")) === JSON.stringify(["ap-manager", "reconcile"]), "reconcile: the preview runs without --apply (the job model adds it)");
check(!JSON.stringify(add).includes("passphrase"), "the passphrase is in no step");
const ch = wifiSpecs({ ap: "Nano HD", ssid: "hrossen-home", zone: "home", vlan: 310, security: "wpa3-personal", replace: { ap: "Nano HD", ssid: "Rossen" } });
check(argv(ch.remove!, verbOf("ap-manager", "ssid remove")) === JSON.stringify(["ap-manager", "ssid", "Nano HD", "remove", "Rossen"]), "Change: ssid remove of the old SSID first");
check(verbOf("ap-manager", "ssid remove").destructive, "…which is destructive: its name typed, the Installer role");
const noVlan = wifiSpecs({ ap: "Nano HD", ssid: "x", zone: "home", vlan: null, security: "open", replace: null });
check(!buildArgv(noVlan.add, verbOf("ap-manager", "ssid add"), noVlan.add.initial).includes("--vlan"), "no VLAN known: the controller takes it from the zone");

// ── a backup buddy ────────────────────────────────────────────────────
const bm = json<{ verbs: ManifestVerb[] }>("wizards/backup-manager.json");
const bmVerb = (v: string): ManifestVerb => bm.verbs.find((x) => x.verb === v)!;
const pull = buddySpecs("pull", "rossen-dk");
check(JSON.stringify(buildArgv(pull.add, bmVerb("peer add"), { ...pull.add.initial, "--host": "10.255.2.1", "--contact": "ops@buddy.example", "--namespace": "buddy/rossen", "--endpoint": "buddy.example:51830" })) === JSON.stringify(["backup-manager", "peer", "add", "pull", "rossen-dk", "--host", "10.255.2.1", "--namespace", "buddy/rossen", "--contact", "ops@buddy.example", "--tunnel", "dial", "--endpoint", "buddy.example:51830", "--config-only"]), "peer add pull <name>: host, namespace, contact, a dialled tunnel, config only");
const remote = buddySpecs("remote", "rossen-dk");
check(JSON.stringify(buildArgv(remote.add, bmVerb("peer add"), { ...remote.add.initial, "--contact": "ops@buddy.example" })) === JSON.stringify(["backup-manager", "peer", "add", "remote", "rossen-dk", "--contact", "ops@buddy.example", "--tunnel", "serve", "--config-only"]), "peer add remote <name>: this site serves the tunnel");
check(!buildArgv(pull.add, bmVerb("peer add"), { ...pull.add.initial, "--config-only": false }).includes("--config-only"), "…unticked, peer add onboards too");
check(pull.add.only.every((f) => bmVerb("peer add").options.some((o) => o.flag === f)) && remote.add.only.every((f) => bmVerb("peer add").options.some((o) => o.flag === f)), "every option the forms offer is peer add's own");
check(!pull.add.only.includes("--propagate") && !remote.add.only.includes("--propagate") && !remote.add.only.includes("--force"), "…but not --propagate or --force");
check(JSON.stringify(buildArgv(pull.check, bmVerb("peer check"), {})) === JSON.stringify(["backup-manager", "peer", "check", "pull", "rossen-dk"]) && bmVerb("peer check").effect === "read", "the result: peer check pull <name>, a read");
check(/dials/.test(BUDDY_KINDS.pull) && /serves/.test(BUDDY_KINDS.remote), "pull and remote said in one line each");
check(buddyNameProblem("rossen-dk") === null && buddyNameProblem("Rossen_DK") === null && buddyNameProblem("rossen dk") !== null && buddyNameProblem("-x") !== null && buddyNameProblem("") !== null, "a buddy's name as peer add takes it: letters, digits, '-', '_'");

// ── a satellite ───────────────────────────────────────────────────────
const mmAdd = json<{ verbs: ManifestVerb[] }>("wizards/module-manager.json").verbs[0];
const sat: SatellitePlan = { address: "37.27.5.237", environment: "mgmt", roles: ["reverse-proxy", "admin-vpn"], country: "FI", city: "Helsinki", instance: "" };
const satSpec = satelliteSpec(sat);
check(JSON.stringify(buildArgv(satSpec, mmAdd, satSpec.initial)) === JSON.stringify(["module-manager", "add", "satellite", "--environment", "mgmt", "--address", "37.27.5.237", "--roles", '["reverse-proxy","admin-vpn"]', "--country", "FI", "--city", "Helsinki"]), "add satellite: --environment, then --address, --roles and its place as INSTALL.md gives them");
const satAt = satelliteSpec({ ...sat, location: "hetzner-hel1" });
check(JSON.stringify(buildArgv(satAt, mmAdd, satAt.initial).slice(-2)) === JSON.stringify(["--location", "hetzner-hel1"]), "…or the site's location it names");
const sat2 = satelliteSpec({ ...sat, roles: ["reverse-proxy"], country: "", city: "", instance: "satellite-hel1" });
check(JSON.stringify(buildArgv(sat2, mmAdd, sat2.initial)) === JSON.stringify(["module-manager", "add", "satellite", "--environment", "mgmt", "--instance", "satellite-hel1", "--address", "37.27.5.237", "--roles", '["reverse-proxy"]']), "a second satellite: its --instance; one role; no location given, none passed");
check(Object.keys(satelliteProblems(sat)).length === 0, "a public IPv4, an environment, a role: nothing to fix");
check(satelliteProblems({ ...sat, address: "10.0.0.5" }).address !== undefined && satelliteProblems({ ...sat, address: "100.64.1.1" }).address !== undefined && satelliteProblems({ ...sat, address: "1.2.3" }).address !== undefined, "a private, CGNAT or malformed address is refused");
check(satelliteProblems({ ...sat, roles: [] }).roles !== undefined && satelliteProblems({ ...sat, roles: ["backup"] }).roles !== undefined, "no role, or backup (lockdown's, never at add), is refused");
check(satelliteProblems({ ...sat, country: "Finland" }).country !== undefined, "the country is its ISO code");

// ── a user ────────────────────────────────────────────────────────────
// identity-manager's verbs as hrossen's manifest declares them (an open verb:
// the field form's own tokens follow the positionals).
const idAdd: ManifestVerb = { ...mmAdd, verb: "<kind> add", keys: [["user", "add"]], positionals: [{ name: "name", optional: false, repeatable: false }, { name: "field", optional: true, repeatable: false }], options: [{ flag: "--force", takesValue: false, arg: null, choices: null, repeatable: false, description: "" }, { flag: "--no-reconcile", takesValue: false, arg: null, choices: null, repeatable: false, description: "" }], open: true };
const idRec: ManifestVerb = { ...mmAdd, verb: "reconcile", keys: [["reconcile"]], positionals: [], options: [{ flag: "--apply", takesValue: false, arg: null, choices: null, repeatable: false, description: "" }], open: false, preview: { kind: "apply-flag", flag: "--apply" } };
const user = identitySpecs("user", "add");
const fields = ["--displayName", "Ann Rossen", "--email", "ann@rossen.dk", "--state", "active", "--groups", "users", "--roles", "user"];
check(JSON.stringify(buildArgv(user.change, idAdd, { ...user.change.initial, "@name": "ann", "@fields": fields })) === JSON.stringify(["identity-manager", "user", "add", "ann", "--no-reconcile", ...fields]), "user add <name> --no-reconcile, then the field form's flags");
check(JSON.stringify(buildArgv(user.reconcile, idRec, {})) === JSON.stringify(["identity-manager", "reconcile"]), "…then reconcile: its preview is the plan against Authentik");
check(JSON.stringify(identitySpecs("group", "modify", "users").change.fixed) === '["users"]', "a modify names its object");

// The typed name of a destructive Apply, known before any job (the console's rule).
const delVerb = { verb: "delete", keys: [["delete"]], positionals: [{ name: "module", optional: false, repeatable: false }], readWhen: [], destructiveWhen: [] } as unknown as ManifestVerb;
check(confirmObject({ bin: "module-manager" }, delVerb, { "@module": " deconz " }, ["module-manager", "delete", "deconz"]).object === "deconz", "a destructive Apply names its first positional");
const rpVerb = { verb: "remove-port", keys: [["remove-port"]], positionals: [{ name: "switch", optional: false, repeatable: false }, { name: "port", optional: false, repeatable: false }], readWhen: [], destructiveWhen: [], object: { positional: "port", within: ["switch"] } } as unknown as ManifestVerb;
const rp = confirmObject({ bin: "switch-manager", fixed: ["crs-a"] }, rpVerb, { "@port": "7" }, ["switch-manager", "remove-port", "crs-a", "7"]);
check(rp.object === "7" && rp.label === "crs-a:7", "…or the positional its verb declares, within its container");

done("wizards");
