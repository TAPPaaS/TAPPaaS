// fixtures.ts — the console with no live system (docs/plans/console-gui-pipeline.md
// §2.1). With CONSOLE_RUNNER=fixtures and CONSOLE_FIXTURES=<dir>, main.ts builds
// the server over what test/fixtures/capture.sh recorded: a Runner, a Streamer
// and a CMDB that answer from those files. Nothing is executed. Every call is
// appended to a journal a test can assert on; a secret on stdin never is. The
// unit tests' fakes (test/unit/fake-site.ts, fake-cmdb.ts) are these classes.
//
//   <dir>/modules.json ...       the reads the fakes have always named
//   <dir>/reads/<slug>.out       any other verb's stdout (<slug>.rc: its exit)
//   <dir>/jobs/<slug>.preview.txt, .apply.txt   what a job says; <slug> is its
//                                argv without the flags, or a prefix of it;
//                                <slug>.<phase>.pace paces it (jobFile)
//   <dir>/cmdb/                  objects, relations, classes, sweep, show/, history/
//   <dir>/config/                the records the console reads directly

import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, utimesSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { ExecResult } from "../../lib/ts/src/exec";
import { Cmdb, CmdbAttributePeriod, CmdbChange, CmdbObject, CmdbQuery, CmdbRelationQuery, CmdbRelationRow } from "./cmdb";
import { RelationType } from "./health";
import { Manifests, validateArgv } from "./manifest";
import { Runner, StdinRunner, StreamControl, Streamer } from "./run";

export type CallKind = "read" | "preview" | "apply";

export interface FixtureOptions {
  recorded?: boolean; // answer from reads/ (the server); the unit tests keep the hand-written answers
  journal?: string | null; // appended with every call; null keeps none
  repoRoot?: string; // where `site-manager repository list` says the repository is
  phaseOf?: (argv: string[]) => CallKind | null; // from the manifests; else by the flags
  overlay?: string; // a variant's reads/ answer before the fixtures' own
}

export interface FixtureSite {
  run: Runner;
  stream: Streamer;
  runStdin: StdinRunner;
  calls: string[];
  fail: Set<string>; // "bin verb" prefixes that exit 1
  note: (kind: CallKind, argv: string[]) => void;
}

// A verb's name on disk: capture.sh's slug, its argv with the rest squeezed out.
export const fixtureSlug = (argv: string[]): string => argv.join(" ").replace(/[^A-Za-z0-9._]+/g, "-").replace(/^-+|-+$/g, "");

const JOB_FLAGS = new Set(["--apply", "--check", "--dry-run", "--json"]);

// Whether a job's argv is its read, its preview or its apply, as the manifest
// says: the same verb is either, by a flag (manifest.ts previewArgv, applyArgv).
export function phaseFrom(ms: Manifests | null, argv: string[]): CallKind | null {
  if (!ms) return null;
  const v = validateArgv(ms, argv);
  if (!v.ok) return null;
  if (v.read) return "read";
  const p = v.preview;
  if (p.kind === "apply-flag") return v.args.includes(p.flag) ? "apply" : "preview";
  if (p.kind === "dry-run-flag") return v.args.includes(p.flag) ? "preview" : "apply";
  return "apply";
}

const phaseByFlags = (args: string[]): CallKind => (args.includes("--apply") ? "apply" : args.includes("--check") || args.includes("--dry-run") ? "preview" : "apply");

export function fixtureSite(dir: string, opts: FixtureOptions = {}): FixtureSite {
  const calls: string[] = [];
  const fail = new Set<string>();
  const file = (f: string): string => readFileSync(join(dir, f), "utf8");
  const ok = (stdout: string): ExecResult => ({ rc: 0, stdout, stderr: "", ran: true });
  const note = (kind: CallKind, argv: string[]): void => {
    if (!opts.journal) return;
    mkdirSync(dirname(opts.journal), { recursive: true });
    appendFileSync(opts.journal, JSON.stringify({ at: new Date().toISOString(), kind, argv }) + "\n");
  };
  const recorded = (argv: string[]): ExecResult | null => {
    // The inverse of the repository-list substitution below: a verb run at the
    // substituted root (git -C <root> …) is the recorded one.
    const slug = fixtureSlug(opts.repoRoot ? argv.map((a) => (a === opts.repoRoot ? "/home/tappaas/TAPPaaS" : a)) : argv);
    const over = opts.overlay ? join(opts.overlay, "reads", slug) : null;
    const f = over && existsSync(`${over}.out`) ? over : join(dir, "reads", slug);
    if (!opts.recorded || !existsSync(`${f}.out`)) return null;
    const rc = existsSync(`${f}.rc`) ? Number(readFileSync(`${f}.rc`, "utf8").trim()) : 0;
    let stdout = readFileSync(`${f}.out`, "utf8");
    if (opts.repoRoot && argv.join(" ").startsWith("site-manager repository list")) stdout = stdout.split("/home/tappaas/TAPPaaS").join(opts.repoRoot);
    return { rc, stdout, stderr: "", ran: true };
  };
  const answer = (bin: string, args: string[]): ExecResult => {
    const cmd = `${bin} ${args.join(" ")}`;
    calls.push(cmd);
    for (const f of fail) if (cmd.startsWith(f)) return { rc: 1, stdout: "", stderr: "[Error] failed on purpose", ran: true };
    const hit = recorded([bin, ...args]);
    if (hit) return hit;
    switch (`${bin} ${args[0]}`) {
      case "health-manager validate":
        return { rc: 1, stdout: file("validate.json"), stderr: "", ran: true }; // a gate fails: exit 1, full document
      case "health-manager report":
        return { rc: 1, stdout: "", stderr: "[Error] no security scan yet — run: health-manager scan security", ran: true };
      case "module-manager list":
        return ok(file("modules.json"));
      case "module-manager show":
        return ok(JSON.stringify({ moduleSource: `/src/${args[1]}`, status: "Testing" }));
      case "module-manager resolve":
        return ok(JSON.stringify({ module: args[1], fields: {} }));
      case "module-manager fields":
        return ok(JSON.stringify({ module: args[1], fields: [{ field: "memory", coordinate: "cluster:vm", class: "in-place", settable: true, reason: null, value: "8192" }], warnings: [] }));
      case "module-manager drift":
        return ok(JSON.stringify({ module: args[1], services: {} }));
      case "health-manager guests": {
        const doc = JSON.parse(file("guests.json")) as { nodes: { node: string }[] };
        return ok(JSON.stringify(args[1] === "--json" ? doc : doc.nodes.find((n) => n.node === args[1])));
      }
      case "module-manager snapshot-vm":
        return ok("\x1b[32mtappaas-20261030\x1b[0m  2026-10-30\n");
      case "backup-manager list":
        return ok(file("backup.json"));
      case "backup-manager key":
        return ok(JSON.stringify({ escrowed: 7, fingerprint: "4c7c", stick: { fingerprint: "4c7c", keys: 7, written: "2026-10-28T17:18:06+01:00", label: "tappaas3: Generic Flash Disk" }, current: true }));
      case "backup-manager show":
        return ok(JSON.stringify({ module: args[1], enabled: true, inPbsJob: true }));
      case "backup-manager coverage":
        return ok(JSON.stringify({ reachable: true, module: args[1], jobs: [] }));
      case "backup-manager restore":
        return ok(file("backup-runs.json"));
      case "backup-manager peers":
        return ok(JSON.stringify([{ name: "rasmus", role: "remote" }]));
      case "network-manager topology":
        return ok(file("topology.json"));
      case "storage-manager inventory":
        return ok(file("storage-inventory.json"));
      case "environment-manager list":
        return ok(file("environments.json"));
      case "site-manager site":
        return ok(JSON.stringify({ name: "rossen", channel: "unstable" }));
      case "site-manager node":
        if (args[1] === "media") return ok(JSON.stringify({ directory: "/var/lib/tappaas-pxe", staged: true, current: false, source: "/home/tappaas/pve-tappaas-netboot.iso", sourcePresent: true, stickImage: { path: "/var/lib/tappaas-pxe/tappaas-usb.iso", present: false, size: 0, modified: null }, xorriso: true, ready: false, problems: ["the netboot assets predate this version's installer hook", "the installer stick image is missing (/var/lib/tappaas-pxe/tappaas-usb.iso)"], prepare: { argv: ["sudo", "node-provisioner", "prepare", "--iso", "/home/tappaas/pve-tappaas-netboot.iso"], minutes: "a few minutes" } }));
        if (args[1] === "usb") return ok(JSON.stringify({ node: args[2], reachable: true, sticks: [{ device: "/dev/sdb", size: 31000000000, vendor: "SanDisk", model: "Ultra", serial: "4C53", inUse: false, why: null, keyStick: args[2] === "tappaas1" }] }));
        return ok(args[1] === "list" ? JSON.stringify([{ name: "tappaas1" }, { name: "tappaas2" }]) : "[]");
      case "site-manager repository":
        return ok("[]");
      case "identity-manager org":
      case "identity-manager group":
      case "identity-manager user":
      case "identity-manager role": {
        const ids: Record<string, Record<string, Record<string, unknown>>> = {
          org: { rossen: { name: "rossen", owner: "lars", parentOrg: null } },
          group: { users: { name: "users", ownerOrg: "rossen", roles: ["user"] }, "authentik Admins": { name: "authentik Admins", ownerOrg: "rossen", roles: [] } },
          user: { lars: { name: "lars", memberOf: ["users", "authentik Admins"], roles: ["admin", "user"] }, "-x": { name: "-x" } },
          role: { admin: { name: "admin" }, user: { name: "user" } },
        };
        // forgejo-admins: a group a module declares (no config file).
        ids.group["forgejo-admins"] = { name: "forgejo-admins", origin: "module forgejo", declaredBy: { file: "forgejo.json", key: "identity" }, editable: false };
        // akadmin: a user Authentik's bootstrap declares.
        ids.user.akadmin = { name: "akadmin", origin: "Authentik built-in", declaredBy: { file: "identity.json", key: "bootstrap" }, editable: false };
        const kind = ids[args[0]];
        if (args[1] === "list" && args[2] === "--declared") return ok(JSON.stringify(args[0] === "group" ? [ids.group["forgejo-admins"]] : args[0] === "user" ? [ids.user.akadmin] : []));
        if (args[1] === "list") return ok(JSON.stringify(Object.keys(kind)));
        if (args[1] === "show" && kind[args[2]]) return ok(JSON.stringify(kind[args[2]]));
        return { rc: 1, stdout: "", stderr: `[Error] no ${args[0]} '${args[2]}'`, ran: true };
      }
      case "rest-of-foundation.sh --proposal": // lab2's on 2026-11-03: one machine, the bootstrap on the boot pool
        return ok(file("foundation-placement.json"));
      case "ap-manager list":
        return ok(file("aps.json"));
      case "ap-manager ssid":
        return ok(file("ssids.json"));
      case "node-provisioner status":
        return { rc: 1, stdout: "PXE: disabled (no TAPPaaS boot entries; zone 'mgmt')\npending registrations: none\n", stderr: "", ran: true };
      case "journalctl -u":
        return ok(file("sweep-journal.txt"));
      case "systemctl is-active":
        return { rc: 3, stdout: "inactive\n", stderr: "", ran: true };
      case "systemctl show":
        return ok("ActiveState=inactive\nActiveEnterTimestamp=\n");
      case "git -C": // the TAPPaaS version the checkout runs (ADR-028 D13), 412 past v2.3.3
        return ok("v2.3.3-412-g1f607aa7\n");
      default:
        return { rc: -1, stdout: "", stderr: `${bin}: not in the fake site`, ran: false };
    }
  };
  const run: Runner = async (bin, args) => {
    note("read", [bin, ...args]);
    return answer(bin, args);
  };
  // What a job says: jobs/<slug>.<phase>.txt, for its argv or the longest prefix
  // of it that was recorded, so one file can stand for a verb on any object.
  // Beside it, <slug>.<phase>.pace ("<first> <ms>") paces it: the first lines at
  // once, then one line every <ms> ms, so a test sees a job that is still running
  // (its status line, Stop, the output following its last line). Stop ends it.
  const jobFile = (phase: "preview" | "apply", argv: string[]): string | null => {
    const words = argv.filter((a) => !JOB_FLAGS.has(a));
    for (let n = words.length; n >= 2; n--) {
      const f = join(dir, "jobs", `${fixtureSlug(words.slice(0, n))}.${phase}`);
      if (existsSync(`${f}.txt`)) return f;
    }
    return null;
  };
  const jobText = (phase: "preview" | "apply", argv: string[]): string | null => {
    const f = jobFile(phase, argv);
    return f ? readFileSync(`${f}.txt`, "utf8") : null;
  };
  const paceOf = (f: string | null): { first: number; ms: number } | null => {
    if (!f || !existsSync(`${f}.pace`)) return null;
    const [first, ms] = readFileSync(`${f}.pace`, "utf8").trim().split(/\s+/).map(Number);
    return Number.isFinite(first) && ms > 0 ? { first, ms } : null;
  };
  const paced = (text: string, pace: { first: number; ms: number }, onOutput: (chunk: string) => void, ctl?: StreamControl): Promise<{ rc: number; ran: boolean; error: string | null }> =>
    new Promise((resolve) => {
      const lines = text.split(/(?<=\n)/);
      let at = Math.min(pace.first, lines.length);
      onOutput(lines.slice(0, at).join(""));
      let timer: ReturnType<typeof setInterval> | null = null;
      const end = (rc: number): void => {
        if (timer) clearInterval(timer);
        timer = null;
        resolve({ rc, ran: true, error: null });
      };
      ctl?.onSpawn?.((s) => {
        if (!timer) return false;
        onOutput(`\n[fixture] stopped by ${s}\n`);
        end(130);
        return true;
      });
      if (at >= lines.length) return end(0);
      timer = setInterval(() => {
        onOutput(lines[at++]);
        if (at >= lines.length) end(0);
      }, pace.ms);
    });
  const stream: Streamer = async (bin, args, onOutput, _timeoutMs, ctl) => {
    const argv = [bin, ...args];
    const phase = opts.phaseOf?.(argv) ?? phaseByFlags(args);
    note(phase, argv);
    if (phase === "read") {
      const r = answer(bin, args);
      onOutput(r.stdout + r.stderr);
      return { rc: r.ran ? r.rc : 0, ran: true, error: null };
    }
    const f = jobFile(phase, argv);
    const said = f ? readFileSync(`${f}.txt`, "utf8") : null;
    const pace = paceOf(f);
    if (said !== null && pace) return paced(said, pace, onOutput, ctl);
    onOutput(said ?? (phase === "apply" ? "applied (fixture)\n" : `${argv.join(" ")}\n`));
    return { rc: 0, ran: true, error: null };
  };
  // argv only: `input` is a secret.
  const runStdin: StdinRunner = async (bin, args) => {
    note("apply", [bin, ...args]);
    return ok(jobText("apply", [bin, ...args]) ?? "applied (fixture)\n");
  };
  return { run, stream, runStdin, calls, fail, note };
}

// ── the CMDB ──────────────────────────────────────────────────────────

type Obj = Record<string, unknown>;

export interface HealthSite {
  objects: CmdbObject[];
  relations: CmdbRelationRow[];
  ids: Record<string, string>;
  history: CmdbAttributePeriod[];
  classes?: { name: string; parent: string | null }[];
  relationTypes?: RelationType[];
  roots?: Obj[];
  sweep?: Obj | null;
  dir?: string; // show/ and history/: an object's whole record, where it was captured
  overlaid?: string[]; // the objects cmdb/overlay.synthetic.json changes: their captured record gets the same attributes
}

// The shipped metamodel's relation types, as /v1/rules serves them.
export function metamodelRelations(controllerDir: string): RelationType[] {
  const doc = JSON.parse(readFileSync(join(controllerDir, "cmdb-controller", "metamodel", "relations.json"), "utf8")) as { relations: Record<string, { dependant?: RelationType["dependant"]; tree?: RelationType["tree"] }> };
  return Object.entries(doc.relations).map(([name, r]) => ({ name, dependant: r.dependant ?? null, tree: r.tree ?? null }));
}

// A hand-kept layer over the capture (cmdb/overlay.synthetic.json): per object
// id, conditions added (one of a type replaces the captured one),
// acknowledgements merged, root causes added. What a capture cannot have yet.
const OVERLAY = "overlay.synthetic.json";
interface Overlay { objects?: Record<string, { conditions?: Obj[]; acknowledgements?: Obj; rootCauses?: Obj[] }> }
export function overlaid(objects: Obj[], o: Overlay | null): Obj[] {
  if (!o?.objects) return objects;
  return objects.map((x) => {
    const add = o.objects![String(x.id)];
    if (!add) return x;
    const a = (x.attributes ?? {}) as Obj;
    const conds = (Array.isArray(a.conditions) ? (a.conditions as Obj[]) : []).filter((c) => !(add.conditions ?? []).some((n) => n.type === c.type));
    return {
      ...x,
      attributes: {
        ...a,
        ...(add.conditions ? { conditions: [...conds, ...add.conditions] } : {}),
        ...(add.acknowledgements ? { acknowledgements: { ...((a.acknowledgements ?? {}) as Obj), ...add.acknowledgements } } : {}),
        ...(add.rootCauses ? { rootCauses: [...(Array.isArray(a.rootCauses) ? (a.rootCauses as Obj[]) : []), ...add.rootCauses] } : {}),
      },
    };
  });
}

// The CMDB capture.sh recorded.
export function capturedCmdb(dir: string, repoRoot: string): HealthSite {
  const json = <T>(f: string): T => JSON.parse(readFileSync(join(dir, "cmdb", f), "utf8")) as T;
  const roots = join(dir, "reads", `${fixtureSlug(["health-manager", "roots", "--json"])}.out`);
  const r = existsSync(roots) ? (JSON.parse(readFileSync(roots, "utf8")) as Obj[] | { roots?: Obj[] }) : [];
  const overlay = existsSync(join(dir, "cmdb", OVERLAY)) ? json<Overlay>(OVERLAY) : null;
  return {
    overlaid: Object.keys(overlay?.objects ?? {}),
    objects: overlaid(json<Obj[]>("objects.json"), overlay) as unknown as HealthSite["objects"],
    relations: json("relations.json"),
    ids: {},
    history: [],
    classes: json("classes.json"),
    relationTypes: metamodelRelations(join(repoRoot, "src", "foundation", "tappaas-cicd", "controller")),
    roots: Array.isArray(r) ? r : r.roots ?? [],
    sweep: json("sweep.json"),
    dir: join(dir, "cmdb"),
  };
}

export class FixtureCmdb {
  calls: string[] = [];
  down = false;
  at: string[] = [];
  onSweep: (() => void) | null = null;
  private onChange: ((c: CmdbChange) => void) | null = null;
  private onLink: ((up: boolean) => void) | null = null;

  constructor(readonly site: HealthSite) {}

  private guard(what: string): void {
    this.calls.push(what);
    if (this.down) throw new Error("the CMDB did not answer");
  }
  private isA(cls: string, want: string): boolean {
    const rows = this.site.classes ?? [];
    for (let c: string | null | undefined = cls; c; c = rows.find((r) => r.name === c)?.parent) if (c === want) return true;
    return false;
  }
  private recordOf<T>(sub: string, id: string): T | null {
    const f = this.site.dir ? join(this.site.dir, sub, `${id}.json`) : null;
    if (!f || !existsSync(f)) return null;
    try {
      return JSON.parse(readFileSync(f, "utf8")) as T;
    } catch {
      return null; // an object the capture could not show
    }
  }
  async query(q: CmdbQuery = {}): Promise<CmdbObject[]> {
    this.guard("query");
    if (q.at) this.at.push(q.at);
    if (!this.site.classes) return this.site.objects; // the hand-built site: a test filters what it reads
    const where = Object.entries(q.where ?? {});
    const hits = this.site.objects.filter((o) => (!q.class || this.isA(o.class, q.class)) && (q.includeEnded || !(o as unknown as { ended?: unknown }).ended) && where.every(([k, v]) => (k === "name" ? o.name === v : o.attributes[k] === v)));
    return q.limit ? hits.slice(0, q.limit) : hits;
  }
  async relations(q: CmdbRelationQuery = {}): Promise<CmdbRelationRow[]> {
    this.guard(`relations ${q.type ?? ""}`);
    return this.site.relations.filter((r) => (!q.type || r.type === q.type) && (!q.from || r.from.id === q.from) && (!q.to || r.to.id === q.to));
  }
  async classes(): Promise<{ name: string; parent: string | null }[]> {
    this.guard("classes");
    return this.site.classes ?? [{ name: "gadget", parent: "device" }];
  }
  async rules(): Promise<{ relations: RelationType[] }> {
    this.guard("rules");
    return { relations: this.site.relationTypes ?? [] };
  }
  async show(id: string): Promise<unknown> {
    this.guard(`show ${id}`);
    const whole = this.recordOf<{ attributes?: Record<string, { value: unknown; source?: string; since?: string }> }>("show", id);
    const o = this.site.objects.find((x) => x.id === id);
    if (whole && o && this.site.overlaid?.includes(id)) {
      // The capture's record, with the overlay's attributes as the objects carry them.
      const attrs = { ...(whole.attributes ?? {}) };
      for (const k of ["conditions", "acknowledgements", "rootCauses"]) if (k in o.attributes) attrs[k] = { ...(attrs[k] ?? { source: "health-manager", since: "2026-11-01T08:50:02.363Z" }), value: o.attributes[k] };
      return { ...whole, attributes: attrs };
    }
    if (whole) return whole;
    if (!o) throw new Error(`no object ${id}`);
    const since = (o as unknown as { created?: string }).created ?? "2026-10-01T00:00:00Z";
    return {
      id, class: o.class, name: o.name, ancestors: [o.class, "ci", "object"], displayName: null, drift: null,
      attributes: Object.fromEntries(Object.entries(o.attributes).map(([k, value]) => [k, { value, source: "x", since }])),
      relations: this.site.relations.flatMap((r) => [
        ...(r.from.id === id ? [{ id: r.id, type: r.type, direction: "out", other: r.to }] : []),
        ...(r.to.id === id ? [{ id: r.id, type: r.type, direction: "in", other: r.from }] : []),
      ]),
    };
  }
  async find(name: string, cls?: string): Promise<unknown> {
    const o = this.site.objects.find((x) => x.name === name && (!cls || this.isA(x.class, cls)));
    if (!o) throw new Error(`no object ${name}`);
    return this.show(o.id);
  }
  async history(id: string): Promise<unknown> {
    this.guard(`history ${id}`);
    const whole = this.recordOf<unknown>("history", id);
    if (whole) return whole;
    const changes = this.site.dir ? [] : [{ id: 7, kind: "observation", source: "health-manager", job: null, verb: null, actor: null, time: "2026-10-30T02:14:00Z", drift: false }];
    return { id, attributes: this.site.history, relations: [], changes };
  }
  async roots(): Promise<Obj[]> {
    this.guard("roots");
    return this.site.roots ?? [{ id: this.site.ids.tappaas2, impacted: 4 }];
  }
  async sweep(): Promise<Obj> {
    this.guard("sweep");
    this.onSweep?.();
    return this.site.sweep ?? { status: "clean" };
  }
  async lastSweep(): Promise<Obj | null> {
    this.guard("lastSweep");
    return this.site.sweep ?? null;
  }
  subscribe(onChange: (c: CmdbChange) => void, onLink: (up: boolean) => void): () => void {
    this.onChange = onChange;
    this.onLink = onLink;
    return () => undefined;
  }
  link(up: boolean): void {
    this.onLink?.(up);
  }
  tell(): void {
    this.onChange?.({ id: 1, kind: "observation", source: "health-manager", time: "2026-10-30T09:00:00Z", objects: [], relations: [], drift: false });
  }
  set(key: string, conditions: unknown[]): void {
    this.site.objects.find((o) => o.id === this.site.ids[key])!.attributes.conditions = conditions;
  }
  asCmdb(): Cmdb {
    return this as unknown as Cmdb;
  }
}

// ── the clock ─────────────────────────────────────────────────────────

// CONSOLE_NOW stops the clock for the whole process, at the one place every
// read of it passes: `Date.now`, as the caches default to it, and `new Date()`.
// A date given as an argument, and every timer, are as ever.
export function fixClock(iso: string): () => void {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) throw new Error(`CONSOLE_NOW ${iso} is not a date`);
  const Real = Date;
  const realNow = Date.now;
  class Fixed extends Real {
    constructor(...a: unknown[]) {
      super(...((a.length === 0 ? [t] : a) as [number]));
    }
    static now(): number {
      return t;
    }
  }
  (globalThis as unknown as { Date: unknown }).Date = Fixed;
  Real.now = () => t;
  return () => {
    Real.now = realNow;
    (globalThis as unknown as { Date: unknown }).Date = Real;
  };
}

// ── the mode ──────────────────────────────────────────────────────────

export interface FixtureMode {
  dir: string;
  configDir: string;
  journal: string;
  site: FixtureSite;
  cmdb: FixtureCmdb;
  actor: string;
}

// The repository a build runs from: up from the build to its schemas.
export function repoAbove(from: string): string | null {
  for (let d = from; d !== dirname(d); d = dirname(d)) if (existsSync(join(d, "src", "foundation", "schemas"))) return d;
  return null;
}

// config/ as this run reads it: a copy, so nothing writes to the fixtures, with
// the site's repository where this machine has it, and one date on every file
// (setup.ts compares them with the last sweep; a checkout's are arbitrary).
function copyConfig(from: string, to: string, repo: string): void {
  mkdirSync(to, { recursive: true });
  for (const f of existsSync(from) ? readdirSync(from) : []) {
    const a = join(from, f);
    const b = join(to, f);
    if (statSync(a).isDirectory()) copyConfig(a, b, repo);
    else if (f.endsWith(".json")) writeFileSync(b, readFileSync(a, "utf8").split("/home/tappaas/TAPPaaS").join(repo));
    else copyFileSync(a, b);
    if (!statSync(a).isDirectory()) utimesSync(b, new Date(0), new Date(0));
  }
}

// CONSOLE_RUNNER=fixtures: the parts main.ts builds the server with, and a
// harmless default for all else the server would otherwise look for on the
// mothership. Under the state directory, so a run leaves no trace elsewhere:
// a wizard's credential file lands there, not in $HOME.
export function openFixtures(env: Record<string, string | undefined>, stateDir: string, phaseOf: (argv: string[]) => CallKind | null, from: string): FixtureMode {
  const dir = env.CONSOLE_FIXTURES;
  if (!dir) throw new Error("CONSOLE_RUNNER=fixtures needs CONSOLE_FIXTURES=<dir>");
  if (!existsSync(join(dir, "modules.json"))) throw new Error(`CONSOLE_FIXTURES ${dir} has no modules.json`);
  if (env.CONSOLE_NOW) fixClock(env.CONSOLE_NOW);
  const real = env.CONSOLE_REPO ?? repoAbove(from);
  if (!real) throw new Error(`no repository above ${from}: set CONSOLE_REPO`);
  mkdirSync(stateDir, { recursive: true });
  // One path for every worktree, so a page that prints it compares equal.
  const repo = join(stateDir, "TAPPaaS");
  if (!existsSync(repo)) symlinkSync(real, repo);
  const configDir = join(stateDir, "config");
  copyConfig(join(dir, "config"), configDir, repo);
  // A variant of the site: its config/ and reads/ over the fixtures' (the
  // `off` site of variants/off: site.json small, no level, no investigation).
  if (env.CONSOLE_FIXTURES_OVERLAY) copyConfig(join(env.CONSOLE_FIXTURES_OVERLAY, "config"), configDir, repo);
  const none = (f: string): string => join(stateDir, f);
  const defaults: Record<string, string> = {
    CONSOLE_REPO: repo,
    CONSOLE_FIREWALL: "192.0.2.1", // TEST-NET: nobody
    CONSOLE_SETUP_ALLOW: "127.0.0.1",
    CONSOLE_SETUP_TOKEN_FILE: none("no-setup-token"),
    CONSOLE_SECRETS_DIR: none("home"),
    CONSOLE_LITELLM_KEY_FILE: none("no-litellm-key"),
    CONSOLE_AUTHENTIK_CREDENTIALS: none("no-authentik-credentials"),
    CONSOLE_LOKI_PASSWORD_FILE: none("no-loki-password"),
    CMDB_URL: "http://127.0.0.1:1",
    CMDB_TOKEN_FILE: none("no-cmdb-token"),
    TAPPAAS_WAN_ADDRESS_FILE: join(configDir, "wan-address.json"),
  };
  for (const [k, v] of Object.entries(defaults)) env[k] ??= v;
  mkdirSync(env.CONSOLE_SECRETS_DIR as string, { recursive: true });
  const journal = env.CONSOLE_FIXTURES_JOURNAL ?? join(dir, "journal.jsonl");
  const site = fixtureSite(dir, { recorded: true, journal, repoRoot: repo, phaseOf, overlay: env.CONSOLE_FIXTURES_OVERLAY });
  const cmdb = new FixtureCmdb(capturedCmdb(dir, real));
  cmdb.onSweep = () => site.note("apply", ["cmdb", "sweep", "--json"]);
  return { dir, configDir, journal, site, cmdb, actor: env.CONSOLE_ACTOR ?? "operator" };
}
