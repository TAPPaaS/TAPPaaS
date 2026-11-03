// simulate.test.ts — TAPPAAS_SIMULATE=1 (docs/plans/console-gui-pipeline.md §6
// layer B): an apply runs its preview instead and says what it would have run;
// its record and the journal carry simulated: true; a verb with no dry run runs
// nothing; one with a secret is refused; previews and reads run as ever.

import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Me, SetupState } from "../../src/access";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { Jobs, JobSummary } from "../../src/jobs";
import { Manifests } from "../../src/manifest";
import { Runner, SIMULATE_NO_SECRET, Streamer, runWithStdin } from "../../src/run";
import { writeSecret } from "../../src/secrets";
import { check, done } from "./check";

const NET: HelpSpec = { name: "network-manager", version: "1", tagline: "t", verbs: [{ usage: "reconcile [--apply]", options: [["--apply", "Apply."]], effect: { apply: "--apply" } }] };
const MOD: HelpSpec = {
  name: "module-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "modify <module> --set field=value...", options: [["--set field=value", "A field."], ["--dry-run", "Pre-gate."]] },
    { usage: "suspend <module>", effect: { noPreview: "stops the guest and keeps it stopped" } },
    { usage: "show <module> [--json]", options: [["--json", "JSON."]], effect: "read" },
  ],
};
const BACKUP: HelpSpec = { name: "backup-manager", version: "1", tagline: "t", verbs: [{ usage: "key export [--password-stdin]", options: [["--password-stdin", "Stdin."]], effect: { noPreview: "writes the keys" } }] };

const me: Me = { user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console" };
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };

async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise<void>((r) => setTimeout(r, 1));
}

async function main(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-simulate-"));
  const ran: string[] = [];
  let rc = 0;
  let printed = "the plan\n";
  const stream: Streamer = async (bin, args, onOutput) => {
    ran.push([bin, ...args].join(" "));
    onOutput(printed);
    return { rc, ran: true, error: null };
  };
  const run: Runner = async () => ({ rc: 0, stdout: "ActiveState=inactive\n", stderr: "", ran: true });
  const manifests: Manifests = { byBin: new Map([["network-manager", renderManifest(NET)], ["module-manager", renderManifest(MOD)], ["backup-manager", renderManifest(BACKUP)]]), errors: [], loadedAt: "" };
  const jobs = new Jobs({ stateDir: dir, configDir: dir, manifests: () => manifests, stream, run });
  const job = (id: string): JobSummary & { output: string } => jobs.get(id)!;
  const applied = async (argv: string[]): Promise<string> => {
    const r = await jobs.create(me, closed, { argv, apply: true });
    check(r.status === 201, `${argv.join(" ")}: started (${r.error ?? r.status})`);
    await settle();
    return r.job!.id;
  };

  process.env.TAPPAAS_SIMULATE = "1";

  // apply-flag: the verb without --apply; exit 2 is the plan, so exit 0.
  rc = 2;
  let id = await applied(["network-manager", "reconcile"]);
  let j = job(id);
  check(ran.length === 1 && ran[0] === "network-manager reconcile", `apply-flag: the plan ran, once (${ran.join("; ")})`);
  check(j.output.startsWith("simulated: would run network-manager reconcile --apply\n"), "apply-flag: the output starts with what it would run");
  check(j.output.includes("the plan\n"), "apply-flag: the real plan follows");
  check(j.exit === 0 && j.state === "done", "apply-flag: pending changes are a clean plan, exit 0");
  check(j.simulated === true && !j.previewPhase, "apply-flag: simulated, no second phase");
  check(j.ran?.join(" ") === "network-manager reconcile" && j.wouldRun?.join(" ") === "network-manager reconcile --apply", "apply-flag: ran is the plan, wouldRun the apply");

  // apply-flag: exit 1 is a stale read, as it stops a real apply.
  ran.length = 0;
  rc = 1;
  j = job(await applied(["network-manager", "reconcile"]));
  check(j.exit === 1 && j.output.includes("simulated: the dry run refuses this change (exit 1)"), "apply-flag: a failing plan is not clean");

  // dry-run-flag: --dry-run; a refusal in the output is not clean either.
  ran.length = 0;
  rc = 0;
  j = job(await applied(["module-manager", "modify", "foo", "--set", "a=b"]));
  check(ran.length === 1 && ran[0] === "module-manager modify foo --set a=b --dry-run", `dry-run-flag: the --dry-run form ran (${ran.join("; ")})`);
  check(j.output.startsWith("simulated: would run module-manager modify foo --set a=b\n") && j.exit === 0, "dry-run-flag: says so, exit 0");
  printed = "[refused] the zone is off\n";
  j = job(await applied(["module-manager", "modify", "foo", "--set", "a=b"]));
  check(j.exit !== 0 && j.output.includes("the zone is off"), "dry-run-flag: a [refused] line is not clean");
  printed = "the plan\n";

  // From a finished preview: the preview ran, then the apply stands in as well.
  ran.length = 0;
  const p = await jobs.create(me, closed, { argv: ["module-manager", "modify", "foo", "--set", "a=b"], preview: true });
  await settle();
  check(job(p.job!.id).simulated === undefined, "a preview is not marked simulated");
  check(!job(p.job!.id).output.includes("simulated:"), "the preview path is unchanged");
  const a = await jobs.applyPreview(me, closed, p.job!.id, {});
  await settle();
  j = job(a.job!.id);
  check(j.simulated === true && j.exit === 0 && j.previewOf === p.job!.id, "applyPreview: simulated");
  check(ran.filter((r) => r.includes("--dry-run")).length === 2 && ran.length === 2, "applyPreview: only dry runs ran");

  // none: nothing runs at all.
  ran.length = 0;
  j = job(await applied(["module-manager", "suspend", "foo"]));
  check(ran.length === 0, "none: nothing ran");
  check(j.output.startsWith("simulated: would run module-manager suspend foo\n") && j.output.includes("no dry run"), "none: says what it would run");
  check(j.exit === 0 && j.simulated === true && j.ran === null && j.wouldRun?.join(" ") === "module-manager suspend foo", "none: exit 0, simulated");

  // A secret: refused, nothing ran, and the secrets' other two ways too.
  ran.length = 0;
  const s = await jobs.createWithSecret(me, closed, ["backup-manager", "key", "export", "--password-stdin"], { input: "pw\n" });
  check(s.status === 409 && !s.job && /simulate mode.*secret.*refused/.test(s.error ?? ""), `secret: refused with a clear message (${s.error})`);
  check(ran.length === 0, "secret: nothing ran");
  const direct = await runWithStdin("sh", ["-c", `touch ${join(dir, "stdin-ran")}`], "pw\n");
  check(direct.rc !== 0 && direct.stderr === SIMULATE_NO_SECRET && !existsSync(join(dir, "stdin-ran")), "a verb fed a secret directly: not run");
  const w = writeSecret(dir, "unifi", { url: "https://x", username: "a", password: "b" });
  check(!w.ok && w.error === SIMULATE_NO_SECRET && !existsSync(join(dir, ".unifi-os-credentials.txt")), "a secret the console writes: refused");

  // Reads and previews are untouched.
  ran.length = 0;
  const r = await jobs.create(me, closed, { argv: ["module-manager", "show", "foo"] });
  await settle();
  j = job(r.job!.id);
  check(ran[0] === "module-manager show foo" && j.simulated === undefined && !j.output.includes("simulated:"), "a read runs as ever");

  // The journal, read back by a console that starts now.
  const lines = readFileSync(join(dir, "jobs.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l) as JobSummary);
  check(lines.filter((l) => l.id === id).every((l) => l.simulated === true), "the journal carries simulated: true on every record of the job");
  const again = new Jobs({ stateDir: dir, configDir: dir, manifests: () => manifests, stream, run });
  check(again.get(id)?.simulated === true, "and it survives a restart");

  // Off: the same apply really applies, unmarked.
  delete process.env.TAPPAAS_SIMULATE;
  ran.length = 0;
  rc = 0;
  j = job(await applied(["module-manager", "modify", "foo", "--set", "a=b"]));
  check(ran[1] === "module-manager modify foo --set a=b" && j.simulated === undefined && !j.output.includes("simulated:"), "unset: the real apply runs, unmarked");

  rmSync(dir, { recursive: true, force: true });
  done("simulate");
}

void main();
