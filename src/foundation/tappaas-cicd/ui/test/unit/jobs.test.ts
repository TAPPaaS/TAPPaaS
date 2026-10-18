// jobs.test.ts — the job model (ADR-034 D4): the state machine of a job,
// preview before apply (T3), the role table on every write (T1), the setup
// token's write (T6), the destructive confirmation, the sweep refusal, the one
// serial runner, Activity's jobs.jsonl, and the HTTP routes over them
// (application/json only, server-sent events).

import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig, Me, SetupState } from "../../src/access";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { Job, Jobs, parseUnitShow, shellQuote, sweepBlocks } from "../../src/jobs";
import { Manifests } from "../../src/manifest";
import { Reads } from "../../src/reads";
import { Runner, Streamer } from "../../src/run";
import { ConsoleServer } from "../../src/server";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

const SPEC: HelpSpec = {
  name: "module-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "list [--json]" },
    { usage: "test <module> [--deep]", options: [["--deep", "The deep suite."]] },
    { usage: "modify <module> --set field=value... [--allow-disruption]", options: [["--set field=value", "A field."], ["--dry-run", "Pre-gate."], ["--allow-disruption", "Reboot it now."]] },
    { usage: "reconcile <module> [--apply]", options: [["--apply", "Apply."]] },
    { usage: "suspend <module>", effect: { noPreview: "stops the guest and keeps it stopped" } },
    { usage: "delete <module> [--remove]", effect: { noPreview: "destroys the guest" }, options: [["--remove", "Remove the config."]] },
    { usage: "remove-port <switch> <port>", effect: { noPreview: "parks the port" }, object: { positional: "port", within: ["switch"] } },
  ],
};

const me = (over: Partial<Me> = {}): Me => ({ user: "lars", name: "Lars", email: null, groups: ["admin"], role: "admin", via: "gate", route: "console", ...over });
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };
const open_: SetupState = { active: true, identityInstalled: false, tokenPresent: true };

async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await new Promise<void>((r) => setTimeout(r, 1));
}

async function main(): Promise<void> {
  // ── the sweep predicate and the unit's state read ───────────────────
  check(sweepBlocks("active") && sweepBlocks("activating") && sweepBlocks("deactivating\n"), "an active, starting or stopping sweep blocks jobs");
  check(!sweepBlocks("inactive") && !sweepBlocks("failed"), "an inactive or failed unit does not");
  const u = parseUnitShow("ActiveState=activating\nActiveEnterTimestamp=Sat 2026-10-17 03:00:01 CEST\n");
  check(u.state === "activating" && u.since === "Sat 2026-10-17 03:00:01 CEST", "systemctl show is read for state and since");
  check(parseUnitShow("ActiveState=inactive\nActiveEnterTimestamp=n/a\n").since === null, "n/a is no time");
  check(shellQuote(["switch-controller", "update-port", "USW Pro XG 10 PoE", "1"]) === "switch-controller update-port 'USW Pro XG 10 PoE' 1", "the argv as one types it, quoted where it must be");

  // ── a site to run against ───────────────────────────────────────────
  const dir = mkdtempSync(join(tmpdir(), "console-jobs-"));
  let unit = "inactive";
  const ran: string[] = [];
  let release: (() => void) | null = null; // hold a job running until released
  const stream: Streamer = async (bin, args, onOutput) => {
    ran.push([bin, ...args].join(" "));
    onOutput(`ran ${args[0]}\n`);
    if (args.includes("hold")) await new Promise<void>((r) => (release = r));
    return { rc: args.includes("--dry-run") && args.includes("vmid=1") ? 1 : 0, ran: true, error: null };
  };
  const run: Runner = async (bin, args) =>
    bin === "systemctl" && args[0] === "show"
      ? { rc: 0, stdout: `ActiveState=${unit}\nActiveEnterTimestamp=Sat 2026-10-17 03:00:01 CEST\n`, stderr: "", ran: true }
      : { rc: 1, stdout: "", stderr: "", ran: false };
  const ms: Manifests = { byBin: new Map([["module-manager", renderManifest(SPEC)]]), errors: [], loadedAt: "" };
  let now = Date.parse("2026-10-17T12:00:00Z");
  const done_: Job[] = [];
  const jobs = new Jobs({ stateDir: dir, configDir: dir, manifests: () => ms, stream, run, now: () => now, onWriteDone: (j) => done_.push(j) });

  // ── T2 at the door, then T1 on every write ──────────────────────────
  let r = await jobs.create(me(), closed, { argv: ["module-manager", "frob"], preview: true });
  check(r.status === 400 && !r.job, "an undeclared verb never becomes a job (T2)");
  r = await jobs.create(me({ via: "local", user: null, role: "read" }), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 403 && !r.job, "loopback without the gate starts no job");
  r = await jobs.create(me({ role: "read", groups: ["users"] }), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 403, "a member of users starts no job (T1)");
  r = await jobs.create(me({ role: "admin", route: "status" }), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 403, "nothing is started from the status route (T1)");

  // ── preview before apply (T3) ───────────────────────────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "immich", "--apply"] });
  check(r.status === 409 && !r.job, "a write without a preview is refused (T3)");
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "immich", "--apply"], preview: true });
  check(r.status === 201 && r.job?.kind === "preview" && r.job.ran?.join(" ") === "module-manager reconcile immich", "the preview runs the verb without --apply");
  const p1 = r.job!;
  r = await jobs.applyPreview(me(), closed, p1.id, {});
  check(r.status === 409 && /not finished/.test(r.error ?? ""), "apply waits for its preview to finish");
  await settle();
  check(p1.state === "done" && p1.exit === 0 && p1.output.includes("ran reconcile"), "the preview ran and its output is kept");
  r = await jobs.applyPreview(me(), closed, p1.id, {});
  check(r.status === 201 && r.job?.ran?.join(" ") === "module-manager reconcile immich --apply" && r.job.previewOf === p1.id, "apply runs the previewed argv plus --apply (T3)");
  await settle();
  check(done_.length === 1 && done_[0].kind === "apply", "a finished apply asks for the reads to be refreshed");

  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "deconz-test", "--set", "memory=2048"], preview: true });
  check(r.job?.ran?.join(" ") === "module-manager modify deconz-test --set memory=2048 --dry-run", "modify previews through its pre-gate (--dry-run)");
  await settle();
  r = await jobs.applyPreview(me(), closed, r.job!.id, {});
  check(r.job?.ran?.join(" ") === "module-manager modify deconz-test --set memory=2048", "…and applies without it");
  await settle();

  r = await jobs.create(me(), closed, { argv: ["module-manager", "suspend", "deconz-test"], preview: true });
  const ns = r.job!;
  check(ns.state === "done" && ns.ran === null && /no dry run/.test(ns.output) && /stops the guest/.test(ns.output), "no dry run: the preview runs nothing, says what the verb touches and shows the command");
  check(!ran.some((x) => x.includes("suspend")), "…and nothing ran");

  now += 2 * 3600_000;
  r = await jobs.applyPreview(me(), closed, ns.id, {});
  check(r.status === 409 && /hour/.test(r.error ?? ""), "a preview older than an hour does not enable apply");

  // ── destructive: Installer and the typed name (D3) ──────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "delete", "deconz-test", "--remove"], preview: true });
  check(r.status === 201 && r.job?.destructive === true, "an Admin may preview a destructive verb");
  const del = r.job!;
  r = await jobs.applyPreview(me(), closed, del.id, { confirm: "deconz-test" });
  check(r.status === 403, "…but not apply it, name or no name (T1)");
  r = await jobs.applyPreview(me({ role: "installer" }), closed, del.id, { confirm: "deconz-te" });
  check(r.status === 400 && /type 'deconz-test'/.test(r.error ?? ""), "Installer with the wrong name: refused");
  r = await jobs.applyPreview(me({ role: "installer" }), closed, del.id, {});
  check(r.status === 400, "Installer without the name: refused");
  r = await jobs.applyPreview(me({ role: "installer" }), closed, del.id, { confirm: "deconz-test" });
  check(r.status === 201 && r.job?.ran?.join(" ") === "module-manager delete deconz-test --remove", "Installer with the typed name: applied");
  await settle();
  // #855: a verb that names its object is confirmed by it, not by its first positional.
  for (const typed of ["1", "USW Pro XG 10 PoE:1"]) {
    r = await jobs.create(me(), closed, { argv: ["module-manager", "remove-port", "USW Pro XG 10 PoE", "1"], preview: true });
    const rp = r.job!;
    check(rp.object === "1" && rp.objectLabel === "USW Pro XG 10 PoE:1", "the job names the port, shown within its switch");
    r = await jobs.applyPreview(me({ role: "installer" }), closed, rp.id, { confirm: "USW Pro XG 10 PoE" });
    check(r.status === 400 && /type '1' to confirm \(USW Pro XG 10 PoE:1\)/.test(r.error ?? ""), "the switch's name does not confirm a port's removal");
    r = await jobs.applyPreview(me({ role: "installer" }), closed, rp.id, { confirm: typed });
    check(r.status === 201, `typed '${typed}': applied`);
    await settle();
  }

  // ── the setup token (T6) ────────────────────────────────────────────
  const tok = me({ user: "setup", via: "setup-token", role: "installer", groups: [] });
  r = await jobs.create(tok, open_, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 201, "the setup token previews while setup is open");
  await settle();
  r = await jobs.applyPreview(tok, closed, r.job!.id, {});
  check(r.status === 401, "…and applies nothing once identity is installed (T6)");

  // ── reads run at once, beside the queue ─────────────────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "test", "immich"] });
  check(r.status === 201 && r.job?.kind === "read" && r.job.ran?.join(" ") === "module-manager test immich", "a reading verb runs as a read job, no preview");
  await settle();
  // …but test --deep creates and removes guests: a write with no dry run (finding 3)
  r = await jobs.create(me(), closed, { argv: ["module-manager", "test", "immich", "--deep"] });
  check(r.status === 409 && !r.job, "test --deep is not a read: it needs a preview (T3)");
  r = await jobs.create(me(), closed, { argv: ["module-manager", "test", "immich", "--deep"], preview: true });
  const deep = r.job!;
  check(r.status === 201 && deep.kind === "preview" && deep.ran === null && deep.preview.kind === "none" && /runs the deep suite: creates and removes zztest guests/.test(deep.output), "…its preview runs nothing and says it creates and removes guests");
  r = await jobs.applyPreview(me(), closed, deep.id, {});
  check(r.status === 201 && r.job?.kind === "apply" && r.job.ran?.join(" ") === "module-manager test immich --deep", "…and its apply queues the deep suite as a change");
  await settle();

  // ── the sweep (D4) ──────────────────────────────────────────────────
  unit = "active";
  writeFileSync(join(dir, ".update-stage"), "modules\n");
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "immich"], preview: true });
  check(r.status === 409 && r.job?.state === "refused" && /sweep is running/.test(r.job.refused ?? "") && /stage: modules/.test(r.job.refused ?? ""), "while update-tappaas.service runs, no job starts, and it says so");
  check(r.sweep?.active === true, "…with the sweep's state");
  unit = "inactive";

  // ── one at a time, in order ─────────────────────────────────────────
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "hold"], preview: true });
  const a = r.job!;
  r = await jobs.create(me(), closed, { argv: ["module-manager", "reconcile", "second"], preview: true });
  const b = r.job!;
  await settle();
  check(a.state === "running" && b.state === "queued" && jobs.queued().join() === `${a.id},${b.id}`, "a second write queues behind the first, and the queue is visible");
  unit = "active"; // the sweep starts while b waits
  (release as unknown as () => void)();
  await settle();
  check(a.state === "done" && b.state === "refused" && /sweep/.test(b.refused ?? ""), "a queued job is refused if the sweep has started when its turn comes");
  unit = "inactive";

  // ── Activity: jobs.jsonl ────────────────────────────────────────────
  const lines = readFileSync(jobs.file, "utf8").trim().split("\n").map((l) => JSON.parse(l) as Job);
  const first = lines.find((l) => l.id === p1.id)!;
  check(!!first && first.who.user === "lars" && first.who.via === "gate" && first.route === "console" && first.exit === 0 && typeof first.durationMs === "number" && first.output.includes("ran"), "every job is in jobs.jsonl: who, via, route, argv, output, exit, duration");
  check(lines.some((l) => l.state === "refused"), "refused jobs are recorded too");
  const again = new Jobs({ stateDir: dir, configDir: dir, manifests: () => ms, stream, run });
  check(again.list().length === lines.length && again.get(p1.id)?.exit === 0, "a restarted console reads its jobs back");

  // ── the HTTP routes ─────────────────────────────────────────────────
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "tok"), identityFile: join(dir, "identity.json"), trustLocalHeaders: false };
  writeFileSync(access.identityFile, "{}");
  const site = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7 });
  const srv = new ConsoleServer({ access, webDir: null, mgmtDomain: "mgmt.internal", version: "t", log: () => undefined }, reads, jobs);
  srv.manifests = ms;
  const call = async (method: string, url: string, body: unknown, headers: Record<string, string>, peer = "10.0.0.1") => {
    const h: Record<string, string> = {};
    let out = "";
    const res = {
      statusCode: 200,
      headersSent: false,
      setHeader: (n: string, v: string | number | string[]) => (h[n.toLowerCase()] = String(v)),
      write: (d: string) => ((out += d), true),
      end: (d?: string) => ((out += d ?? ""), (res.headersSent = true)),
      on: () => res,
    };
    const handlers: Record<string, ((x?: unknown) => void)[]> = {};
    const req = {
      method,
      url,
      headers: { host: "console.hrossen.dk", ...headers },
      socket: { remoteAddress: peer, destroy: () => undefined },
      on: (ev: string, cb: (x?: unknown) => void) => ((handlers[ev] ??= []).push(cb), req),
    };
    const p = srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    if (body !== undefined) for (const cb of handlers.data ?? []) cb(Buffer.from(JSON.stringify(body)));
    for (const cb of handlers.end ?? []) cb();
    await p;
    return { status: res.statusCode, body: out, headers: h };
  };
  const gateH = (groups: string, host = "console.hrossen.dk") => ({ host, "x-authentik-username": "lars", "x-authentik-groups": groups, "content-type": "application/json" });
  let h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, { ...gateH("admin"), "content-type": "text/plain" });
  check(h.status === 415, "a job posted as anything but JSON is refused (no cross-site form)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, { "content-type": "application/json" }, "127.0.0.1");
  check(h.status === 403, "POST /jobs from loopback without the gate: 403");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, gateH("users"));
  check(h.status === 403, "POST /jobs as users: 403 (T1)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, gateH("installer", "status.hrossen.dk"));
  check(h.status === 403, "POST /jobs on the status route, even as Installer: 403 (T1)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich", "--purge"], preview: true }, gateH("admin"));
  check(h.status === 400 && /unknown option/.test(h.body), "an undeclared option: 400 before a job exists (T2)");
  h = await call("POST", "/api/v1/jobs", { argv: ["module-manager", "reconcile", "immich"], preview: true }, gateH("admin"));
  const pj = JSON.parse(h.body).data as Job;
  check(h.status === 201 && pj.kind === "preview" && pj.who.user === "lars", "POST /jobs as Admin through the gate: the preview starts");
  await settle();
  h = await call("GET", `/api/v1/jobs/${pj.id}`, undefined, { ...gateH("admin"), accept: "text/event-stream" });
  check(h.headers["content-type"]?.startsWith("text/event-stream") && /event: job/.test(h.body) && /event: end/.test(h.body), "GET /jobs/<id> as an event stream: the job, then its end");
  h = await call("POST", `/api/v1/jobs/${pj.id}/apply`, {}, gateH("admin"));
  check(h.status === 201 && (JSON.parse(h.body).data as Job).ran?.includes("--apply") === true, "POST /jobs/<id>/apply runs the preview's argv with --apply");
  await settle();
  h = await call("GET", "/api/v1/jobs", undefined, gateH("users"));
  check(h.status === 200 && (JSON.parse(h.body).data.jobs as Job[]).length > 0, "GET /jobs is a read: users see the jobs");
  h = await call("GET", "/api/v1/activity", undefined, gateH("admin"));
  check(Array.isArray(JSON.parse(h.body).jobs), "Activity lists the jobs beside the sweep's journal");
  check(existsSync(jobs.file), "jobs.jsonl is in the state directory");

  rmSync(dir, { recursive: true, force: true });
  done("jobs");
}

void main();
