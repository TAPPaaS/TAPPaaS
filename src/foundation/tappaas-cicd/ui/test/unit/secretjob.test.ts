// secretjob.test.ts — the two long actions that were one blocking call, now
// jobs with their output and Stop. POST /secrets/backup-keys starts
// `backup-manager key export … --password-stdin` as an apply, the password on
// its stdin and in no record; POST /setup/check starts a read job per installed
// foundation module, for whoever could ask the old GET setup?refresh=1.

import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig, Me, SetupState } from "../../src/access";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { HELP as BACKUP } from "../../../manager/backup-manager/src/main";
import { Jobs } from "../../src/jobs";
import { Reads } from "../../src/reads";
import { Runner, Streamer, streamAsync } from "../../src/run";
import { ConsoleServer } from "../../src/server";
import { recordSetupTest } from "../../src/setup";
import { gateHeaders, testGate } from "./gate-fixture";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

const MODULE: HelpSpec = { name: "module-manager", version: "1", tagline: "t", verbs: [{ usage: "test <module> [--deep]", options: [["--deep", "The deep suite."]] }] };
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };
const lars: Me = { user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console" };

async function settle(): Promise<void> {
  for (let i = 0; i < 30; i++) await new Promise<void>((r) => setTimeout(r, 2));
}

async function main(): Promise<void> {
  const PASS = "correct horse battery";
  const dir = mkdtempSync(join(tmpdir(), "console-secretjob-"));
  const state = join(dir, "state");
  mkdirSync(state);
  writeFileSync(join(dir, "identity.json"), "{}");
  writeFileSync(join(dir, "backup.json"), "{}");
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "tok"), identityFile: join(dir, "identity.json"), trustLocalHeaders: false, gate: testGate() };
  const site = fakeSite();
  const noSweep: Runner = async (bin, args) => (bin === "systemctl" ? { rc: 0, stdout: "ActiveState=inactive\n", stderr: "", ran: true } : site.run(bin, args));
  const ran: { argv: string; input?: string; timeoutMs?: number }[] = [];
  let printed = `[Info] keys read back and compared\n[Info] ${PASS}\n`;
  let rc = 0;
  const stream: Streamer = async (bin, args, onOutput, timeoutMs, ctl) => {
    ran.push({ argv: [bin, ...args].join(" "), input: ctl?.input, timeoutMs });
    onOutput(printed);
    return { rc, ran: true, error: null };
  };
  const manifests = { byBin: new Map([["backup-manager", renderManifest(BACKUP)], ["module-manager", renderManifest(MODULE)]]), errors: [], loadedAt: "" };
  const finished: string[] = [];
  const reads = new Reads({ configDir: dir, stateDir: state, run: site.run, journalDays: 7 });
  const jobs = new Jobs({ stateDir: state, configDir: dir, manifests: () => manifests, stream, run: noSweep, onWriteDone: (j) => finished.push(`${j.bin} ${j.verb}`), onDone: (j, tail) => void recordSetupTest(state, j, tail) });
  const logs: string[] = [];
  const srv = new ConsoleServer({ access, webDir: null, mgmtDomain: "mgmt.internal", version: "t", log: (l) => logs.push(l), home: dir }, reads, jobs);
  const call = async (url: string, opts: { groups?: string; body?: unknown; json?: boolean; method?: string }) => {
    let out = "";
    const res = { statusCode: 200, headersSent: false, setHeader: () => undefined, write: () => true, end: (d?: string) => ((out = d ?? ""), true), on: () => res };
    const local = opts.groups === undefined;
    const req = {
      method: opts.method ?? "POST",
      url,
      headers: { ...(local ? { host: "console.acme.example" } : gateHeaders("lars", opts.groups as string)), ...(opts.json === false ? {} : { "content-type": "application/json" }) },
      socket: { remoteAddress: local ? "127.0.0.1" : "10.0.0.1", destroy: () => undefined },
      on: (ev: string, cb: (c?: unknown) => void) => {
        if (ev === "data" && opts.body !== undefined) cb(Buffer.from(JSON.stringify(opts.body)));
        if (ev === "end") cb();
        return req;
      },
    };
    await srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    return { status: res.statusCode, body: out, data: () => (JSON.parse(out) as { data: unknown }).data };
  };
  const stick = { node: "tappaas1", device: "/dev/sdb", password: PASS, format: true };

  // ── the key stick, as a job ─────────────────────────────────────────
  let r = await call("/api/v1/secrets/backup-keys", { groups: "installer", body: stick });
  check(r.status === 201, `the installer starts it: a job (${r.status} ${r.body.slice(0, 160)})`);
  const id = (r.data() as { id: string }).id;
  await settle();
  const job = jobs.get(id)!;
  check(job.kind === "apply" && job.bin === "backup-manager" && job.verb === "key" && job.previewPhase === undefined && job.argv.join(" ") === "backup-manager key export --usb --node tappaas1 --device /dev/sdb --yes --password-stdin --format", "…as the manifest says: an apply of backup-manager key, with no dry run");
  check(job.state === "done" && job.exit === 0 && finished.includes("backup-manager key"), "…it runs through the job runner, and its end is a write's");
  check(ran.length === 1 && ran[0].input === `${PASS}\n` && (ran[0].timeoutMs ?? 0) >= 60_000, "…the password on the verb's stdin, with its minutes");
  const records = readFileSync(join(state, "jobs.jsonl"), "utf8") + readdirSync(join(state, "jobs")).map((f) => readFileSync(join(state, "jobs", f), "utf8")).join("");
  check(!records.includes(PASS) && !r.body.includes(PASS) && !logs.join("\n").includes(PASS), "…and in no record, log or answer, even when the verb prints it");
  check(job.output.includes("keys read back") && job.output.includes("…"), "…the output is what the verb said, the password cut out of it");

  const before = ran.length;
  r = await call("/api/v1/secrets/backup-keys", { body: stick });
  check(r.status === 403 && ran.length === before, "loopback without the gate: 403, as the old call");
  r = await call("/api/v1/secrets/backup-keys", { groups: "users", body: stick });
  check(r.status === 403 && ran.length === before, "a member of users: 403, nothing run");
  r = await call("/api/v1/secrets/backup-keys", { groups: "installer", body: { ...stick, password: "short" } });
  check(r.status === 400 && ran.length === before, "a short password: 400, nothing run");
  r = await call("/api/v1/secrets/backup-keys", { groups: "installer", body: stick, json: false });
  check(r.status === 415 && ran.length === before, "not JSON: 415");
  r = await call("/api/v1/secrets/backup-keys", { groups: "installer", body: { ...stick, device: "/dev/sdc" } });
  check(r.status === 201, "a second write is a job too");
  await settle();
  check((jobs as unknown as { secrets: Map<string, unknown> }).secrets.size === 0, "…and no secret is held once its job has run");

  // A write refused by the sweep answers with the job, and holds no secret.
  const swept = new Jobs({ stateDir: join(dir, "swept"), configDir: dir, manifests: () => manifests, stream, run: async () => ({ rc: 0, stdout: "ActiveState=active\n", stderr: "", ran: true }) });
  const refused = await swept.createWithSecret(lars, closed, ["backup-manager", "key", "export", "--usb", "--node", "tappaas1", "--device", "/dev/sdb", "--yes", "--password-stdin"], { input: `${PASS}\n` });
  check(refused.status === 409 && refused.job?.state === "refused" && (swept as unknown as { secrets: Map<string, unknown> }).secrets.size === 0, "the sweep running: refused like any write, the secret not kept");
  const read = await jobs.createWithSecret(lars, closed, ["backup-manager", "key", "status"], { input: "x\n" });
  check(read.status === 409, "a read is no job with a secret");

  // ── the real child: stdin written and closed ────────────────────────
  let said = "";
  const c = await streamAsync("/bin/sh", ["-c", "read line; echo \"got ${#line}\"; read more || echo closed"], (t) => (said += t), 5000, { input: `${PASS}\n` });
  check(c.rc === 0 && /got 21/.test(said) && /closed/.test(said), `streamAsync hands the child its stdin once and closes it (${said.trim()})`);

  // ── Setup's Check, as read jobs ─────────────────────────────────────
  ran.length = 0;
  printed = "[Info] All tests passed\n";
  r = await call("/api/v1/setup/check", { groups: "installer", body: {} });
  const started = r.data() as { kind: string; argv: string[]; id: string }[];
  check(r.status === 201 && started.map((j) => j.argv.join(" ")).join() === "module-manager test backup,module-manager test identity" && started.every((j) => j.kind === "read"), `a read job per installed module (${r.body.slice(0, 200)})`);
  await settle();
  const tests = JSON.parse(readFileSync(join(state, "setup-tests.json"), "utf8")) as Record<string, { rc: number; tail: string }>;
  check(tests.backup?.rc === 0 && tests.identity?.tail === "[Info] All tests passed", "…whose results land on the Setup steps");

  r = await call("/api/v1/setup/check", { body: {} });
  check(r.status === 201 && (r.data() as { who: { via: string } }[]).every((j) => j.who.via === "local"), "the loopback's read role may ask it, as it could the old GET");
  await settle();
  r = await call("/api/v1/setup/check", { groups: "users", body: {} });
  check(r.status === 403, "someone the console refuses is refused here too");
  r = await call("/api/v1/setup/check", { groups: "installer", body: {}, json: false });
  check(r.status === 415, "not JSON: 415 (no cross-site form starts one)");
  r = await call("/api/v1/setup/check", { groups: "installer", method: "GET" });
  check(r.status === 405, "a GET starts nothing");
  const n = ran.length;
  r = await call("/api/v1/setup?refresh=1", { groups: "installer", method: "GET" });
  await settle();
  check(ran.length === n, "and GET setup runs no test, whatever it asks");
  check(jobs.createRead(lars, ["backup-manager", "key", "export", "--usb"]).status === 409, "createRead runs reads only");

  rmSync(dir, { recursive: true, force: true });
  done("secretjob");
}

void main();
