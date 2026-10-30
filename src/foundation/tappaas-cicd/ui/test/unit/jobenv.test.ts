// jobenv.test.ts — every verb the console runs as a job has the job's id and
// its user in TAPPAAS_JOB_ID and TAPPAAS_ACTOR (ADR-040 D4, D6), so the change
// it reports to the CMDB names its job: the job runner hands them to its
// child (jobs.ts stream), and streamAsync and runWithStdin put them in the
// child's environment. lib/ts job.ts currentJob is how a verb reads them.

import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Me, SetupState } from "../../src/access";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { currentJob, changeJob } from "../../../lib/ts/src/job";
import { Jobs } from "../../src/jobs";
import { Manifests } from "../../src/manifest";
import { JobEnv, Runner, Streamer, jobEnv, runWithStdin, streamAsync } from "../../src/run";
import { check, done } from "./check";

const SPEC: HelpSpec = {
  name: "module-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "modify <module> --set field=value... [--allow-disruption]", options: [["--set field=value", "A field."], ["--dry-run", "Pre-gate."], ["--allow-disruption", "Reboot it now."]] },
    { usage: "suspend <module>", effect: { noPreview: "stops the guest and keeps it stopped" } },
  ],
};

const me = (over: Partial<Me> = {}): Me => ({ user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console", ...over });
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };

async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise<void>((r) => setTimeout(r, 1));
}

async function main(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-jobenv-"));
  const ran: { argv: string; env?: JobEnv }[] = [];
  const stream: Streamer = async (bin, args, onOutput, _t, ctl) => {
    ran.push({ argv: [bin, ...args].join(" "), env: ctl?.env });
    onOutput("ok\n");
    return { rc: 0, ran: true, error: null };
  };
  const run: Runner = async (bin, args) =>
    bin === "systemctl" && args[0] === "show" ? { rc: 0, stdout: "ActiveState=inactive\n", stderr: "", ran: true } : { rc: 1, stdout: "", stderr: "", ran: false };
  const ms: Manifests = { byBin: new Map([["module-manager", renderManifest(SPEC)]]), errors: [], loadedAt: "" };
  const jobs = new Jobs({ stateDir: dir, configDir: dir, manifests: () => ms, stream, run });

  // ── the runner: the job's id and user on each command it runs ───────
  let r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "vm1"], apply: true });
  await settle();
  const a = r.job!;
  check(ran.length === 1 && ran[0].env?.TAPPAAS_JOB_ID === a.id, `a job's verb runs with TAPPAAS_JOB_ID = its Activity id (${JSON.stringify(ran[0]?.env)})`);
  check(ran[0]?.env?.TAPPAAS_ACTOR === "lars", "…and TAPPAAS_ACTOR = the console user");

  ran.length = 0;
  r = await jobs.create(me({ user: "erik", name: "Erik" }), closed, { argv: ["module-manager", "modify", "vm1", "--set", "cores=4"], apply: true });
  await settle();
  const b = r.job!;
  check(ran.length === 2 && ran.every((x) => x.env?.TAPPAAS_JOB_ID === b.id && x.env?.TAPPAAS_ACTOR === "erik"), `an Apply's dry run and its apply both run as the one job, for its user (${JSON.stringify(ran)})`);

  ran.length = 0;
  r = await jobs.create(me({ user: "setup", name: "Setup", via: "setup-token", groups: [] }), { active: true, identityInstalled: false, tokenPresent: true }, { argv: ["module-manager", "suspend", "vm2"], apply: true });
  await settle();
  check(ran[0]?.env?.TAPPAAS_ACTOR === "setup" && ran[0]?.env?.TAPPAAS_JOB_ID === r.job?.id, "the setup token's job: actor `setup`");
  check(jobEnv("x", { user: null, name: "Lars R", via: "gate" }).TAPPAAS_ACTOR === "Lars R" && jobEnv("x", { user: null, name: null, via: "local" }).TAPPAAS_ACTOR === "local", "no user name: the display name, else how it came in");

  // ── the child processes: the variables reach the environment ────────
  let out = "";
  const s = await streamAsync("/bin/sh", ["-c", 'echo "$TAPPAAS_JOB_ID $TAPPAAS_ACTOR"'], (c) => (out += c), 10_000, { env: jobEnv("20261030150000-abcdef", me()) });
  check(s.rc === 0 && out.trim() === "20261030150000-abcdef lars", `streamAsync: the child sees both (${JSON.stringify(out)})`);
  const w = await runWithStdin("/bin/sh", ["-c", 'read x; echo "$TAPPAAS_JOB_ID $TAPPAAS_ACTOR $x"'], "in\n", 10_000, jobEnv("j-1", me()));
  check(w.rc === 0 && w.stdout.trim() === "j-1 lars in", `runWithStdin: the child sees both (${JSON.stringify(w.stdout)})`);

  // ── how a verb reads them (lib/ts job.ts) ────────────────────────────
  const j = currentJob({ TAPPAAS_JOB_ID: "j-2", TAPPAAS_ACTOR: "lars", USER: "tappaas" });
  check(j.id === "j-2" && j.actor === "lars", "currentJob: the console's job and actor");
  const k = currentJob({ USER: "someone" });
  check(k.id === undefined && typeof k.actor === "string" && k.actor.length > 0, `currentJob outside a job: no id, the OS user (${k.actor})`);
  check(JSON.stringify(changeJob({ TAPPAAS_JOB_ID: "j-3", TAPPAAS_ACTOR: "op" })) === '{"job":"j-3","actor":"op"}' && !("job" in changeJob({ TAPPAAS_ACTOR: "op" })), "changeJob: a change report's job and actor, no job outside one");

  rmSync(dir, { recursive: true, force: true });
  done("jobenv");
}

void main();
