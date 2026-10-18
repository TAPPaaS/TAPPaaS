// setup.test.ts — the Setup wizard (ADR-034 D10): the done-predicates of its
// checklist over hrossen's records (fixtures/setup, 2026-10-18: every step
// done) and over a fresh install (nothing done), gathered from a config tree;
// the setup token deleting itself once identity is installed (T6); and the
// secrets written where the scripts read them, never echoed back.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { AccessConfig, Me, decide, setupState } from "../../src/access";
import { Jobs } from "../../src/jobs";
import { Runner, Streamer } from "../../src/run";
import { parseKv, secretStatus, writeSecret } from "../../src/secrets";
import { SetupInputs, TESTS_FILE, closeSetupToken, gatherSetup, parseSwitches, parseWgvpnPeers, readSetupTests, recordSetupTest, runSetupTests, setupComplete, setupSteps } from "../../src/setup";
import { check, done } from "./check";
import { FIX } from "./fake-site";

const fx = (f: string): string => readFileSync(join(FIX, "setup", f), "utf8");

async function main(): Promise<void> {
  // ── the parsers ─────────────────────────────────────────────────────
  check(parseWgvpnPeers(fx("wgvpn-list.txt")).join() === "lars-mac", "wgvpn list: the peers under 'peers :'");
  check(parseWgvpnPeers("server : x\npeers  :\n").length === 0, "…none when the list is empty");
  const sw = parseSwitches(JSON.parse(fx("switch-actual.json")))!;
  check(sw.length === 1 && sw[0].ports === 12 && sw[0].discovered === 12 && sw[0].controller === "unifi-controller", "the switch: registered, 12 ports discovered through its controller");
  check(parseSwitches({ switches: { manual: { ports: {} } } })![0].discovered === 0, "a registered switch with no discovered port is not interrogated");

  // ── hrossen: every step done ────────────────────────────────────────
  const hrossen: SetupInputs = {
    defaultEnv: "rossen",
    dnsMode: "per-service",
    certRefids: null,
    modules: { backup: { config: true, test: { rc: 0, tail: "", at: "2026-10-18T09:00:00.000Z" } }, identity: { config: true, test: { rc: 0, tail: "", at: "2026-10-18T09:00:00.000Z" } }, logging: { config: true, test: { rc: 0, tail: "", at: "2026-10-18T09:00:00.000Z" } } },
    identities: { organizations: 1, users: 2 },
    siteNodes: ["tappaas1", "tappaas2", "tappaas3"],
    clusterNodes: ["tappaas1", "tappaas2", "tappaas3"],
    switches: sw,
    vpnPeers: ["lars-mac"],
    stacks: ["home", "test"],
  };
  let steps = setupSteps(hrossen);
  check(steps.every((s) => s.done === true) && setupComplete(steps), "hrossen: every step reads as done");
  check(steps.find((s) => s.id === "tls")!.detail.includes("per-service"), "per-service: TLS needs no wildcard certificate");

  // ── each predicate on its own ───────────────────────────────────────
  const one = (over: Partial<SetupInputs>, id: string) => setupSteps({ ...hrossen, ...over }).find((s) => s.id === id)!;
  check(one({ dnsMode: "wildcard" }, "tls").done === false, "wildcard mode without config/cert-refids.json: TLS not done");
  check(one({ dnsMode: "wildcard", certRefids: { rossen: "5f1c" } }, "tls").done === true, "…with the default environment's refid: done");
  check(one({ modules: { ...hrossen.modules, logging: { config: false, test: null } } }, "logging").done === false, "no config/logging.json: logging not done");
  check(one({ modules: { ...hrossen.modules, backup: { config: true, test: { rc: 1, tail: "FAIL pbs", at: "2026-10-18T09:00:00.000Z" } } } }, "backup").done === false, "installed but its test fails: not done");
  check(/passed \(2026-10-18 09:00:00Z\)/.test(steps.find((s) => s.id === "backup")!.detail), "…and a step says when its test last ran");
  check(one({ modules: { ...hrossen.modules, identity: { config: true, test: null } } }, "identity").done === null, "installed, test not run: unknown");
  check(one({ identities: { organizations: 0, users: 0 } }, "bootstrap").done === false, "an empty config/identities: bootstrap not done");
  const nd = one({ clusterNodes: ["tappaas1", "tappaas2"] }, "nodes");
  check(nd.done === false && nd.detail.includes("tappaas3"), "a declared node outside the cluster: not done, and named");
  check(one({ clusterNodes: null }, "nodes").done === null, "membership unreadable: unknown, not done");
  check(one({ switches: [] }, "switch").done === false && one({ switches: [{ name: "s", ports: 0, discovered: 0, controller: null }] }, "switch").done === false, "no switch, or one not interrogated: not done");
  check(one({ vpnPeers: [] }, "vpn").done === false, "no admin VPN peer: not done");
  check(!one({ stacks: [] }, "stacks").required && setupComplete(setupSteps({ ...hrossen, stacks: [] })), "stacks are optional");

  // ── gathered from a config tree: a fresh install ────────────────────
  const dir = mkdtempSync(join(tmpdir(), "console-setup-"));
  const cfg = join(dir, "config");
  const state = join(dir, "state");
  mkdirSync(join(cfg, "environments"), { recursive: true });
  writeFileSync(join(cfg, "site.json"), JSON.stringify({ name: "acme", defaultEnvironment: "acme", hardware: { nodes: [{ name: "tappaas1" }, { name: "tappaas2" }] } }));
  writeFileSync(join(cfg, "environments", "acme.json"), JSON.stringify({ domains: { primary: "acme.example", dnsMode: "wildcard" } }));
  const ran: string[] = [];
  const run: Runner = async (bin, args) => {
    ran.push(`${bin} ${args.join(" ")}`);
    if (bin === "network-manager") return { rc: 0, stdout: "server : tappaas-admin\npeers  :\n", stderr: "", ran: true };
    return { rc: 0, stdout: "ok", stderr: "", ran: true };
  };
  let inputs = await gatherSetup({ configDir: cfg, stateDir: state, run, clusterNodes: (n) => (n.length ? ["tappaas1"] : null), stacks: async () => [] });
  steps = setupSteps(inputs);
  check(!setupComplete(steps) && steps.filter((s) => s.required && s.done === true).length === 0, "a fresh install: no required step is done");
  check(!ran.some((r) => r.startsWith("module-manager test")), "…and no module test runs on a read");
  await runSetupTests({ configDir: cfg, stateDir: state, run });
  check(!ran.some((r) => r.startsWith("module-manager test")) && Object.keys(readSetupTests(state)).length === 0, "…nor on a refresh, for a module that is not installed");
  check(inputs.siteNodes.join() === "tappaas1,tappaas2" && steps.find((s) => s.id === "nodes")!.detail.includes("tappaas2"), "site.json's nodes are what membership is checked against");

  // the install proceeds: records appear, the checklist follows (resumable for free)
  writeFileSync(join(cfg, "cert-refids.json"), JSON.stringify({ acme: "abc" }));
  for (const m of ["backup", "identity", "logging"]) writeFileSync(join(cfg, `${m}.json`), "{}");
  mkdirSync(join(cfg, "identities", "organizations"), { recursive: true });
  mkdirSync(join(cfg, "identities", "users"), { recursive: true });
  writeFileSync(join(cfg, "identities", "organizations", "acme.json"), "{}");
  writeFileSync(join(cfg, "identities", "users", "ann.json"), "{}");
  writeFileSync(join(cfg, "switch-configuration-actual.json"), fx("switch-actual.json"));
  const gather = () => gatherSetup({ configDir: cfg, stateDir: state, run, clusterNodes: () => ["tappaas1", "tappaas2"], stacks: async () => [] });
  inputs = await gather();
  steps = setupSteps(inputs);
  check(ran.filter((r) => r.startsWith("module-manager test")).length === 0, "a read with the modules installed still runs no test (finding 7)");
  check(steps.filter((s) => s.done === null).map((s) => s.id).join() === "backup,identity,logging" && /Check runs it/.test(steps.find((s) => s.id === "backup")!.detail), "…their steps are unknown until the explicit refresh runs the tests");
  // the explicit refresh (GET /setup?refresh=1): the tests run once, their results are kept
  await runSetupTests({ configDir: cfg, stateDir: state, run }, () => Date.parse("2026-10-18T10:00:00Z"));
  check(ran.filter((r) => r.startsWith("module-manager test")).length === 3, "the explicit refresh tests every installed module once");
  const kept = JSON.parse(readFileSync(join(state, TESTS_FILE), "utf8")) as Record<string, { rc: number; at: string }>;
  check(kept.backup?.rc === 0 && kept.logging?.at === "2026-10-18T10:00:00.000Z", "…and keeps each result, with its time, in the state directory");
  inputs = await gather();
  steps = setupSteps(inputs);
  check(ran.filter((r) => r.startsWith("module-manager test")).length === 3, "the next read is from the kept results: no test ran");
  check(steps.filter((s) => s.done !== true).map((s) => s.id).join() === "vpn,stacks", "with the records in place every step is done but the VPN peer (and the optional stacks)");
  // a module removed: its kept result goes with it on the next refresh
  rmSync(join(cfg, "logging.json"));
  await runSetupTests({ configDir: cfg, stateDir: state, run });
  check(readSetupTests(state).logging === undefined && readSetupTests(state).backup !== undefined, "a module no longer installed keeps no result");

  // ── a test run as a job counts too (the step's Test button) ─────────
  // On hrossen 2026-10-18 `module-manager test identity` ran as a job and
  // passed, and the step still said its test had not run: only the Check's
  // results were kept.
  writeFileSync(join(cfg, "logging.json"), "{}");
  rmSync(join(state, TESTS_FILE));
  check(setupSteps(await gather()).find((s) => s.id === "identity")!.done === null, "no result kept: the identity step is unknown");
  const job = (argv: string[], exit: number | null, state_ = "done") => ({ argv, state: state_, exit, ended: "2026-10-18T16:22:09.765Z" });
  check(recordSetupTest(state, job(["module-manager", "test", "identity"], 0), "[Info] Test Step 4\n[Info] All tests passed for module 'identity'") === "identity", "a finished test job of a foundation module is recorded");
  steps = setupSteps(await gather());
  const idStep = steps.find((s) => s.id === "identity")!;
  check(idStep.done === true && idStep.detail.includes("passed (2026-10-18 16:22:09Z)"), "…and its step is done, with the job's time");
  check(readSetupTests(state).identity?.tail === "[Info] All tests passed for module 'identity'", "…keeping the last line of its output");
  check(steps.find((s) => s.id === "backup")!.done === null, "…the other steps keep what they had");
  recordSetupTest(state, job(["module-manager", "test", "backup"], 1), "FAIL pbs");
  check(setupSteps(await gather()).find((s) => s.id === "backup")!.done === false, "a failed test job marks its step failed");
  check(recordSetupTest(state, job(["module-manager", "test", "immich"], 0), "") === null && recordSetupTest(state, job(["module-manager", "show", "logging"], 0), "") === null, "a test of another module, or another verb, is not a setup result");
  check(recordSetupTest(state, job(["module-manager", "test", "logging"], -1), "could not run") === null && recordSetupTest(state, job(["module-manager", "test", "logging"], null, "running"), "") === null, "a job that could not run, or has not finished, says nothing");
  check(readSetupTests(state).logging === undefined, "…and nothing is kept for it");

  // …through the runner as the console wires it (main.ts onDone)
  const SPEC: HelpSpec = { name: "module-manager", version: "1", tagline: "t", verbs: [{ usage: "test <module> [--deep]", options: [["--deep", "The deep suite."]] }] };
  const stream: Streamer = async (_bin, args, onOutput) => {
    onOutput(`[Info] Test Step 1\n[Info] All tests passed for module '${args[1]}'\n`);
    return { rc: 0, ran: true, error: null };
  };
  const noSweep: Runner = async () => ({ rc: 0, stdout: "ActiveState=inactive\n", stderr: "", ran: true });
  const jobs = new Jobs({ stateDir: join(dir, "jobs"), configDir: cfg, manifests: () => ({ byBin: new Map([["module-manager", renderManifest(SPEC)]]), errors: [], loadedAt: "" }), stream, run: noSweep, onDone: (j, tail) => void recordSetupTest(state, j, tail) });
  const lars: Me = { user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console" };
  const created = await jobs.create(lars, { active: false, identityInstalled: true, tokenPresent: false }, { argv: ["module-manager", "test", "logging"] });
  for (let i = 0; i < 50 && readSetupTests(state).logging === undefined; i++) await new Promise<void>((r) => setTimeout(r, 2));
  check(created.job?.kind === "read" && setupSteps(await gather()).find((s) => s.id === "logging")!.done === true, "a Test job run through the job runner marks the logging step done");

  // ── the setup token closes itself (T6) ──────────────────────────────
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: ["10.0.0.0/24"], tokenFile: join(cfg, "console-setup-token"), identityFile: join(dir, "no-identity.json"), trustLocalHeaders: false };
  writeFileSync(access.tokenFile, "t0k3n\n");
  check(!closeSetupToken(access) && existsSync(access.tokenFile), "before identity: the token stays");
  check(decide("10.0.0.50", { host: "console.acme.example", authorization: "Bearer t0k3n" }, null, access, setupState(access)).ok, "…and is accepted from mgmt");
  const after = { ...access, identityFile: join(cfg, "identity.json") };
  check(closeSetupToken(after) && !existsSync(after.tokenFile), "after the identity step: the token is gone from disk (T6)");
  const d = decide("10.0.0.1", { host: "console.acme.example", authorization: "Bearer t0k3n" }, null, after, setupState(after));
  check(!d.ok && d.status === 401, "…and a request with it gets 401 (T6)");

  // ── secrets: where the scripts read them, never echoed ──────────────
  const home = join(dir, "home");
  mkdirSync(home);
  let w = writeSecret(home, "acme-dns", { provider: "cloudflare", keys: { dns_cf_token: "s3cr3t" } });
  check(w.ok && readFileSync(join(home, ".acme-dns-credentials.txt"), "utf8") === "provider=cloudflare\ndns_cf_token=s3cr3t\n", "acme-dns: provider= and dns_… lines, as acme-setup.sh reads them");
  check((statSync(join(home, ".acme-dns-credentials.txt")) as unknown as { mode: number }).mode % 0o1000 === 0o600, "…mode 0600");
  const st = secretStatus(home, "acme-dns");
  check(st.present && st.keys.join() === "provider,dns_cf_token" && !JSON.stringify(st).includes("s3cr3t"), "the status names the keys and never a value");
  w = writeSecret(home, "acme-dns", { provider: "cloudflare", keys: { token: "x" } });
  check(!w.ok, "a key the provider does not name (dns_…) is refused");
  w = writeSecret(home, "unifi", { url: "https://10.0.0.5:11443", username: "tappaas", password: "pw" });
  check(w.ok && parseKv(readFileSync(join(home, ".unifi-os-credentials.txt"), "utf8")).get("username") === "tappaas", "unifi: url=, username=, password=");
  writeSecret(home, "wlan", { ssid: "home", passphrase: "correct horse" });
  writeSecret(home, "wlan", { ssid: "guest", passphrase: "battery staple" });
  writeSecret(home, "wlan", { ssid: "home", passphrase: "another passphrase" });
  const wl = parseKv(readFileSync(join(home, ".wlan-secrets.txt"), "utf8"));
  check(wl.size === 2 && wl.get("home") === "another passphrase" && wl.get("guest") === "battery staple", "wlan: one SSID=passphrase line per SSID, merged");
  check(!writeSecret(home, "wlan", { ssid: "x", passphrase: "short" }).ok, "a WPA passphrase under 8 characters is refused");
  check(!writeSecret(home, "unifi", { url: "x\ny", username: "a", password: "b" }).ok, "a value with a newline is refused");

  rmSync(dir, { recursive: true, force: true });
  done("setup");
}

void main();
