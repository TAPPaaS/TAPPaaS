// fixturemode.test.ts — the console with no live system (src/fixtures.ts): what
// the runner answers and journals, the actor header, the stopped clock, and
// the server itself started in the mode over test/fixtures.

import { spawn } from "child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AccessConfig, decide } from "../../src/access";
import { FixtureCmdb, fixClock, fixtureSite, fixtureSlug, phaseFrom } from "../../src/fixtures";
import { Manifest, Manifests, normalize } from "../../src/manifest";
import { check, done } from "./check";
import { FIX } from "./fake-site";

interface Line {
  kind: string;
  argv: string[];
}
const lines = (f: string): Line[] => readFileSync(f, "utf8").split("\n").filter((l) => l).map((l) => JSON.parse(l) as Line);

async function units(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-fixtures-"));
  mkdirSync(join(dir, "reads"));
  mkdirSync(join(dir, "jobs"));
  const journal = join(dir, "journal.jsonl");
  writeFileSync(join(dir, "reads", "thing-manager-list-json.out"), "[1]\n");
  writeFileSync(join(dir, "reads", "thing-manager-broken-json.out"), "{}\n");
  writeFileSync(join(dir, "reads", "thing-manager-broken-json.rc"), "2\n");
  writeFileSync(join(dir, "jobs", "thing-manager-apply-a.preview.txt"), "would change a\n");
  writeFileSync(join(dir, "jobs", "thing-manager-apply-a.apply.txt"), "changed a\n");
  writeFileSync(join(dir, "jobs", "thing-manager-wide.apply.txt"), "changed something\n");
  const site = fixtureSite(dir, { recorded: true, journal });

  check(fixtureSlug(["identity-manager", "group", "show", "authentik Admins", "--json"]) === "identity-manager-group-show-authentik-Admins-json", "a slug is capture.sh's");
  const read = await site.run("thing-manager", ["list", "--json"]);
  check(read.rc === 0 && read.stdout === "[1]\n", "a read answers with its recording");
  check((await site.run("thing-manager", ["broken", "--json"])).rc === 2, "and with its exit");
  check(!(await site.run("nothing-here", ["at-all"])).ran, "what was not recorded did not run");

  const said = async (args: string[]): Promise<string> => {
    let out = "";
    const r = await site.stream("thing-manager", args, (c) => (out += c));
    check(r.rc === 0 && r.ran, `${args.join(" ")} exits 0`);
    return out;
  };
  check((await said(["apply", "a", "--check"])) === "would change a\n", "a preview: its recording, without the flag in the name");
  check((await said(["apply", "a", "--apply"])) === "changed a\n", "an apply: its recording");
  check((await said(["apply", "b", "--check"])) === "thing-manager apply b --check\n", "no recording of a preview: the argv line");
  check((await said(["apply", "b", "--apply"])) === "applied (fixture)\n", "no recording of an apply: applied, exit 0");
  check((await said(["wide", "any-object"])) === "changed something\n", "a recording of the verb stands for any object");

  await site.runStdin("thing-manager", ["set-passphrase", "ssid"], "hunter2-secret\n");
  const j = lines(journal);
  check(j.filter((l) => l.kind === "read").length === 3, "every read is journalled");
  check(j.filter((l) => l.kind === "preview").map((l) => l.argv.join(" ")).join() === "thing-manager apply a --check,thing-manager apply b --check", "the previews, by argv");
  check(j.filter((l) => l.kind === "apply").length === 4, "the applies, the secret's too");
  check(!readFileSync(journal, "utf8").includes("hunter2"), "a secret on stdin is never journalled");

  // preview by the manifest, not by the flag's spelling
  const m = normalize(JSON.parse(readFileSync(join(FIX, "reads", "site-manager-help-json.out"), "utf8")) as Manifest);
  const ms: Manifests = { byBin: new Map([["site-manager", m]]), errors: [], loadedAt: "" };
  const del = ["site-manager", "node", "delete", "tappaas4"];
  check(phaseFrom(ms, del) === "preview" && phaseFrom(ms, [...del, "--apply"]) === "apply", "the manifest says preview or apply");
  check(phaseFrom(ms, ["site-manager", "node", "list"]) === "read", "or read");
  check(phaseFrom(null, del) === null, "no manifests yet: no word");

  // the actor
  const access: AccessConfig = { firewall: [], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "t"), identityFile: join(dir, "i"), trustLocalHeaders: false };
  const setup = { active: false, identityInstalled: true, tokenPresent: false };
  const as = (h: Record<string, string>, c: AccessConfig): string | null => {
    const d = decide("127.0.0.1", h, null, c, setup);
    return d.ok ? `${d.me.user}/${d.me.role}` : null;
  };
  check(as({}, { ...access, fixtureActor: "operator" }) === "operator/installer", "fixture mode: the default actor, an installer");
  check(as({ "x-console-actor": "alice" }, { ...access, fixtureActor: "operator" }) === "alice/installer", "fixture mode: the header says who");
  check(as({ "x-console-actor": "alice" }, access) === "null/read", "outside the mode the header is nothing: loopback reads");
  check(!decide("10.9.9.9", { "x-console-actor": "alice" }, null, access, setup).ok, "and opens nothing for a stranger");

  // the clock
  const stop = fixClock("2026-11-01T08:00:00Z");
  check(new Date().toISOString() === "2026-11-01T08:00:00.000Z" && Date.now() === Date.parse("2026-11-01T08:00:00Z"), "the clock stands");
  check(new Date(0).getTime() === 0 && Date.parse("2000-01-01T00:00:00Z") > 0, "a given date is itself");
  stop();
  check(Math.abs(Date.now() - new Date().getTime()) < 5000 && new Date().getFullYear() !== 1970 && Date.now() !== Date.parse("2026-11-01T08:00:00Z"), "and runs again");
  let threw = false;
  try {
    fixClock("not a date");
  } catch {
    threw = true;
  }
  check(threw, "CONSOLE_NOW must be a date");

  // the captured CMDB filters as the controller does
  const cmdb = new FixtureCmdb({
    objects: [{ id: "1", class: "server", name: "a", attributes: {} }, { id: "2", class: "disk", name: "b", attributes: {} }, { id: "3", class: "server", name: "c", attributes: {}, ended: "2026-01-01" }] as never,
    relations: [],
    ids: {},
    history: [],
    classes: [{ name: "server", parent: "machine" }, { name: "machine", parent: null }, { name: "disk", parent: null }],
    sweep: null,
  });
  check((await cmdb.query({ class: "machine" })).map((o) => o.name).join() === "a", "a class takes its subclasses; an ended object is gone");
  check((await cmdb.query({ class: "machine", includeEnded: true })).length === 2, "unless asked for");
  check((await cmdb.query({ where: { name: "b" } })).map((o) => o.id).join() === "2", "by name");
  check((await cmdb.lastSweep()) === null, "no sweep recorded");
}

// The server itself, as ui/fixture-server.sh starts it.
async function server(): Promise<void> {
  const state = mkdtempSync(join(tmpdir(), "console-fixture-run-"));
  const journal = join(state, "journal.jsonl");
  const port = 20000 + (Date.now() % 20000);
  const base = `http://127.0.0.1:${port}/api/v1`;
  const child = spawn(process.execPath, [join(__dirname, "..", "..", "src", "main.js"), "serve", "--listen", `127.0.0.1:${port}`], {
    env: { ...process.env, CONSOLE_RUNNER: "fixtures", CONSOLE_FIXTURES: FIX, CONSOLE_FIXTURES_JOURNAL: journal, CONSOLE_STATE_DIR: state, CONSOLE_NOW: "2026-11-01T08:54:11Z" },
    stdio: ["ignore", "ignore", "ignore"],
  });
  const wait = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
  const get = async (p: string, headers: Record<string, string> = {}): Promise<{ data: Record<string, unknown> | null } & Record<string, unknown>> => (await fetch(`${base}/${p}`, { headers })).json() as never;
  const post = async (p: string, body: unknown): Promise<{ data: { id: string; state: string } }> => (await fetch(`${base}/${p}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })).json() as never;
  try {
    let up = false;
    for (let i = 0; i < 100 && !up; i++) {
      await wait(100);
      up = await fetch(`${base}/manifests`).then((r) => r.status === 200, () => false);
    }
    check(up, "the server comes up over the fixtures, its manifests loaded");
    check((await get("me")).data?.user === "operator", "signed in with no gate");
    check((await get("me", { "x-console-actor": "alice" })).data?.user === "alice", "X-Console-Actor says who");
    check((await get("status")).data?.started === "2026-11-01T08:54:11.000Z", "CONSOLE_NOW is the server's clock");
    const mods = await get("modules");
    check(Array.isArray(mods.data) && mods.at !== undefined && mods.ageSeconds === 0, "a read answers from the capture, age 0 by the stopped clock");
    check((await get("health/summary")).error === null, "the health graph builds from the captured CMDB");

    const p = await post("jobs", { argv: ["site-manager", "node", "delete", "tappaas4"], preview: true });
    const finished = async (id: string): Promise<Record<string, unknown> | null> => {
      for (let i = 0; i < 50; i++) {
        const j = (await get(`jobs/${id}`)).data;
        if (j?.state === "done") return j;
        await wait(50);
      }
      return null;
    };
    const pj = await finished(p.data.id);
    check(pj?.output === "site-manager node delete tappaas4\n" && pj.exit === 0, "a preview with no recording says its argv");
    const a = await post(`jobs/${p.data.id}/apply`, { confirm: "tappaas4" });
    const aj = await finished(a.data.id);
    check(String(aj?.output).includes("applied (fixture)") && aj?.exit === 0, "the apply answers, exit 0");
    const writes = lines(journal).filter((l) => l.kind !== "read");
    check(writes.map((l) => `${l.kind} ${l.argv.join(" ")}`).join("|") === "preview site-manager node delete tappaas4|apply site-manager node delete tappaas4 --apply", "the journal has the argv of both");
  } finally {
    child.kill("SIGTERM");
  }
}

units()
  .then(server)
  .then(() => done("fixturemode"))
  .catch((e: Error) => {
    console.error(e);
    process.exit(1);
  });
