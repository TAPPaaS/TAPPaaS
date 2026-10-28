// wizards.test.ts — Setup's Day 2 sequences (web/src/wizards.ts) over hrossen's
// records (fixtures/wizards/zones.json, fixtures/ssids.json, 2026-10-19: home
// 310 and guest 510 active, work 320 inactive, every SSID still the template's
// placeholder; no site-wide SSID yet): which zones get a WiFi button, and the
// argv each step builds through the console's own builder (argv.ts) against the
// verbs' manifests.

import { readFileSync } from "fs";
import { join } from "path";
import { buildArgv, confirmObject } from "../../web/src/argv";
import { ManifestVerb } from "../../web/src/types";
import { BUDDY_KINDS, PASSPHRASE_TEXT, SatellitePlan, SiteSsid, StepSpec, buddyNameProblem, buddySpecs, identitySpecs, satelliteProblems, satelliteSpec, ZoneIn, broadcastText, defaultSsid, isPlaceholderSsid, needsPassphrase, passphraseOf, passphraseProblem, ssidProblem, wifiSpecs, wifiVerb, wifiZones } from "../../web/src/wizards";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const json = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;
const zonesDoc = json<Record<string, Omit<ZoneIn, "name">>>("wizards/zones.json");
const zones: ZoneIn[] = Object.entries(zonesDoc).map(([name, z]) => ({ name, ...z }));
const ssids = json<SiteSsid[]>("ssids.json");
const bash = JSON.parse(readFileSync(join(FIX, "..", "..", "manifest", "bash-verbs.json"), "utf8")) as { manifests: { name: string; verbs: ManifestVerb[] }[] };
const verbOf = (bin: string, verb: string): ManifestVerb => bash.manifests.find((m) => m.name === bin)!.verbs.find((v) => v.verb === verb)!;
const argv = (s: StepSpec, v: ManifestVerb): string => JSON.stringify(buildArgv(s, v, s.initial));

// ── which zones get a WiFi button ─────────────────────────────────────
const wifi = wifiZones(zones, ssids);
check(wifi.map((z) => `${z.zone}:${z.vlan}:${z.type}`).join() === "home:310:Client,iotLocal:410:IoT,iotCloud:420:IoT,iotCams:430:IoT,guest:510:Guest", "hrossen: home, the three active IoT zones and guest, in VLAN order");
check(!wifi.some((z) => z.zone === "work"), "…work (Client, Inactive) gets none");
check(!wifi.some((z) => ["iotUntrust", "rossen", "mgmt"].includes(z.zone)), "…nor a Disabled IoT, a Service or a Management zone");
check(wifi.every((z) => z.declared === null && z.ssid === null), "the template's <HOME_SSID> is not a name: no SSID declared, none site-wide");
check(isPlaceholderSsid("<HOME_SSID>") && !isPlaceholderSsid("rossen-home"), "placeholders are <…>");
const home = wifi[0];
check(wifiVerb(home) === "Add" && defaultSsid("hrossen", home) === "hrossen-home", "home: Add WiFi, the SSID defaults to <site>-<zone>");

// a zone a site-wide SSID bridges to: Change, starting from it
const rossen: SiteSsid = { name: "Rossen", zone: "home", vlan: 310, security: "wpa2-personal", broadcastOn: "all", accessPoints: ["Nano HD"], passphrase: "set" };
const homeServed = wifiZones(zones, [rossen])[0];
check(wifiVerb(homeServed) === "Change" && defaultSsid("hrossen", homeServed) === "Rossen" && homeServed.ssid?.name === "Rossen", "an SSID bridged to home: Change WiFi, starting from it");
check(wifiZones(zones, [rossen])[1].ssid === null, "…guest has none: one SSID per zone");
const declared = wifiZones([{ name: "home", type: "Client", vlantag: 310, SSID: "Rossen-Home" }], [])[0];
check(declared.declared === "Rossen-Home" && wifiVerb(declared) === "Add" && defaultSsid("hrossen", declared) === "Rossen-Home", "a real name in zones.json that ap-manager does not hold: Add, defaulting to that name");
check(wifiZones([{ name: "lab", type: "Client", vlantag: 330 }], []).length === 1, "no state means Active");

// ── the form's checks ─────────────────────────────────────────────────
check(needsPassphrase("wpa2-personal") && needsPassphrase("wpa3-personal") && !needsPassphrase("open") && !needsPassphrase("wpa2-enterprise"), "a personal mode takes a passphrase; open and enterprise do not");
check(ssidProblem("hrossen-home") === null && ssidProblem("") !== null && ssidProblem("a=b") !== null && ssidProblem("x".repeat(33)) !== null && ssidProblem("<HOME_SSID>") !== null, "an SSID: 1–32 characters, no '=', not a placeholder");
check(passphraseProblem("correct horse") === null && passphraseProblem("short") !== null && passphraseProblem("x".repeat(64)) !== null && passphraseProblem("tab\there!!") !== null, "a passphrase: 8–63 printable characters");
const sec = verbOf("ap-manager", "ssid add").options.find((o) => o.flag === "--security")!;
check(JSON.stringify(sec.choices) === '["wpa2-personal","wpa3-personal","open","wpa2-enterprise","wpa3-enterprise"]', "security: the controller's choices, from its manifest");

// ── where and how, in words ───────────────────────────────────────────
check(broadcastText(rossen) === "every access point (Nano HD)" && broadcastText({ ...rossen, broadcastOn: ["U6"], accessPoints: ["U6"] }) === "U6" && /off/.test(broadcastText({ ...rossen, disabled: true })), "where it is broadcast: every AP, the ones it names, or off");
check(broadcastText({ ...rossen, accessPoints: [] }) === "every access point (none registered yet)", "…an SSID declared before any AP");
check(passphraseOf(rossen) === "set" && PASSPHRASE_TEXT.changed.includes("next reconcile") && passphraseOf({ name: "g", zone: "guest", security: "open" }) === "not needed" && passphraseOf({ name: "l", zone: "lab", security: "wpa3-personal" }) === "not set", "the passphrase state: ap-manager's, else from the security");

// ── the argv of each step ─────────────────────────────────────────────
const add = wifiSpecs({ ssid: "hrossen-home", zone: "home", vlan: 310, security: "wpa2-personal", old: null });
check(add.remove === null && add.declare !== null, "Add: nothing to remove, one SSID to declare");
check(argv(add.declare!, verbOf("ap-manager", "ssid add")) === JSON.stringify(["ap-manager", "ssid", "add", "hrossen-home", "--zone", "home", "--security", "wpa2-personal"]), "ssid add: the SSID, --zone, --security — site-wide, no AP, no VLAN (the zone's)");
check(argv(add.reconcile, verbOf("ap-manager", "reconcile")) === JSON.stringify(["ap-manager", "reconcile"]), "reconcile: the preview runs without --apply (the job model adds it)");
check(!JSON.stringify(add).includes("passphrase"), "the passphrase is in no step");
const ch = wifiSpecs({ ssid: "hrossen-home", zone: "home", vlan: 310, security: "wpa3-personal", old: rossen });
check(argv(ch.remove!, verbOf("ap-manager", "ssid remove")) === JSON.stringify(["ap-manager", "ssid", "remove", "Rossen"]) && ch.declare?.verb === "ssid add", "another name: ssid remove of the old SSID first, then ssid add");
check(verbOf("ap-manager", "ssid remove").destructive, "…which is destructive: its name typed, the Installer role");
const sec2 = wifiSpecs({ ssid: "Rossen", zone: "home", vlan: 310, security: "wpa3-personal", old: rossen });
check(sec2.remove === null && argv(sec2.declare!, verbOf("ap-manager", "ssid modify")) === JSON.stringify(["ap-manager", "ssid", "modify", "Rossen", "--security", "wpa3-personal"]), "the same name, a new security: ssid modify --security");
const same = wifiSpecs({ ssid: "Rossen", zone: "home", vlan: 310, security: "wpa2-personal", old: rossen });
check(same.remove === null && same.declare === null, "the same name and security: nothing to declare (a new passphrase and the reconcile)");
const back = wifiSpecs({ ssid: "Rossen", zone: "home", vlan: 310, security: "wpa2-personal", old: { ...rossen, disabled: true } });
check(argv(back.declare!, verbOf("ap-manager", "ssid modify")) === JSON.stringify(["ap-manager", "ssid", "modify", "Rossen", "--enabled"]), "an SSID that was off: ssid modify --enabled");

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
