// sweep.ts — the discovery sweep (ADR-040 D15): ask every source for everything
// it can see, write down what differs, and say whether the site is still what
// config/ says it is. Read-only for every plane: it changes nothing but the
// CMDB.
//
//   1. rescan: `<component> report --discover` for every cmdbSource component
//   2. what changed since the last sweep record, each marked expected (a change
//      report explains it, or it is new: part of what a verb made, or a
//      verb-made object's first observation; see newness; or it is words: a
//      relation's dependency words changed, its ends did not) or drift
//   3. what differs from desired: ADR-020's resolver and differ for the
//      modules (`module-manager drift`), actual without desired, desired
//      without actual
//   4. the record: one change row (verb sweep) with the differences as its
//      body, one journal line per difference, the report as the API's answer
//   5. exit status: 0 only expected changes; 1 drift or unmanaged; 2 desired
//      without actual, or a source that failed
//
// The sources, the differ and the journal are injected, so the logic runs
// against fixtures; server.ts passes the real ones.

import { appendFileSync, existsSync, readFileSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { spawn } from "child_process";
import { RescanResult, runCommand, rescan, rescanSources } from "./rescan";
import { CONTROLLER_SOURCE, ChangeEvent, DEPENDENCY_WORDS, Store } from "./store";
import { Query } from "./pg";
import { CycleRelation, dependencyCycles } from "../../../lib/ts/src/health-rules";

type Obj = Record<string, unknown>;

export type DifferenceKind =
  | "changed" // an attribute or a relation, since the last sweep
  | "appeared"
  | "gone"
  | "desired" // ADR-020's differ: the record says one thing, the plane another
  | "unmanaged" // actual without desired
  | "missing" // desired without actual
  | "unread" // the differ could not read this module
  | "cycle"; // required relations that reach back to where they started

export interface Difference {
  kind: DifferenceKind;
  class: string;
  name: string;
  id?: string;
  source: string;
  attribute: string | null; // an attribute's name, a relation as "→type class/name"; null: the object
  before: unknown;
  after: unknown;
  expected: boolean;
  verb?: string | null; // of the change that explains it
  job?: string | null;
  // "new": no verb wrote this, but it belongs to what a verb just made — a
  // part of a new object (owner: the object it is part of, "class/name"), or
  // the first observation filling a verb-made object's fields. Absent: the
  // verb's own change explains it, or nothing does.
  // "words": a relation whose ends and type stay and whose only change is its
  // dependency words (required, redundancyGroup): words a report classifies
  // the relation with, not an observation that differs, so never drift.
  reason?: "new" | "words" | "lease";
  owner?: string;
}

// An address with a lease and no reservation: one a DHCP server handed out.
// A live one by what it holds now; an ended one by what it last held.
async function leased(pg: Query, id: string, ended = false): Promise<boolean> {
  const r = await pg(
    `SELECT bool_or(name = 'leaseUntil') AS lease, bool_or(name = 'reservation') AS reserved FROM attribute
      WHERE object = $1 AND ${ended ? "NOT isempty(validity)" : "upper_inf(validity)"}`,
    [id],
  );
  return r.rows[0]?.lease === true && r.rows[0]?.reserved !== true;
}

// What makes something a part of its owner, for "new" (from → to: the part
// → its owner): a port of its asset, a guest or pool on its node, a member of
// its cluster, zone or environment, the box allocated to its node.
export const CONTAINMENT = ["part-of", "runs-on", "member-of", "allocated-to"] as const;
// How long after a verb made an object an observation's additions to it are
// still its first sighting, not drift: a discovery that runs after the verb.
export const NEW_WINDOW_MS = 3600 * 1000;

export interface SweepCounts {
  expected: number;
  new: number; // of the expected, those that are new (reason "new")
  words: number; // of the expected, a relation's dependency words (reason "words")
  drift: number;
  desired: number;
  unmanaged: number;
  missing: number;
  unread: number;
  cycles?: number; // dependency cycles over required relations
  sourcesFailed: number;
}

export interface SweepResult {
  id: number;
  time: string;
  since: string | null; // the sweep before; null: this one is the baseline
  counts: SweepCounts;
  status: "healthy" | "warning" | "critical";
  exitCode: 0 | 1 | 2;
  sources: RescanResult[];
  differences: Difference[];
}

export interface DifferOutcome {
  module: string;
  differences: { attribute: string; desired: unknown; actual: unknown }[];
  error?: string;
}

export interface SweepDeps {
  configDir: string;
  log: (line: string) => void;
  // Step 1. Default: rescan with --discover.
  rescanAll?: () => Promise<RescanResult[]>;
  // Step 3's differ for one module. Default: `module-manager drift <module> --json`.
  differ?: (module: string) => Promise<DifferOutcome>;
  // One line per difference. Default: the journal, as cmdb-sweep.
  journal?: (lines: string[]) => void;
  now?: () => Date;
}

/** A relation's attributes without its dependency words: what an observation
 *  of the relation says, the words being a report's classification of it. */
export const withoutWords = (v: unknown): unknown => {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return v;
  return Object.fromEntries(Object.entries(v as Obj).filter(([k]) => !DEPENDENCY_WORDS.includes(k)));
};

const canon = (v: unknown): string => {
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  if (v !== null && typeof v === "object") {
    const o = v as Obj;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canon(o[k])}`).join(",")}}`;
  }
  return JSON.stringify(v) ?? "null";
};

// The source that saw an object last: `seen` is reporter → time.
const latestSource = (seen: unknown): string => {
  const entries = Object.entries((seen ?? {}) as Record<string, string>).sort((a, b) => Date.parse(b[1]) - Date.parse(a[1]));
  return entries[0]?.[0] ?? CONTROLLER_SOURCE;
};

const PLACEHOLDER = (alias: string): string =>
  `EXISTS (SELECT 1 FROM attribute ph WHERE ph.object = ${alias}.id AND ph.name = 'placeholder' AND upper_inf(ph.validity))`;

/** The journal: one JSON line per difference, identifier cmdb-sweep, so Loki
 *  keeps it and a rule can alert on it. CMDB_SWEEP_JOURNAL: a file instead. */
export function journalWriter(log: (line: string) => void): (lines: string[]) => void {
  return (lines) => {
    if (!lines.length) return;
    const file = process.env.CMDB_SWEEP_JOURNAL;
    if (file) return appendFileSync(file, lines.join("\n") + "\n", "utf8");
    const child = spawn("systemd-cat", ["-t", "cmdb-sweep"], { stdio: ["pipe", "ignore", "ignore"] });
    child.on("error", (e) => log(`sweep: no journal (${e.message}); ${lines.length} line(s) lost to it, the record has them`));
    child.stdin?.on("error", () => undefined);
    child.stdin?.end(lines.join("\n") + "\n");
  };
}

/** `module-manager drift <module> --json`: desired against the plane, for
 *  every service of the module that has a field manifest. A read. */
export async function moduleDiffer(module: string): Promise<DifferOutcome> {
  const r = await runCommand(["module-manager", "drift", module, "--json"], 300);
  let doc: { services?: Record<string, Obj> };
  try {
    doc = JSON.parse(r.stdout) as typeof doc;
  } catch {
    return { module, differences: [], error: r.error ?? r.stderr.trim().split("\n").pop() ?? `exit ${String(r.exitCode)}` };
  }
  const differences: DifferOutcome["differences"] = [];
  const errors: string[] = [];
  for (const [coordinate, rec] of Object.entries(doc.services ?? {})) {
    if (rec.error) {
      if ((rec.error as Obj).kind !== "no-manifest") errors.push(`${coordinate}: ${String((rec.error as Obj).kind ?? "failed")}`);
      continue;
    }
    const fields = [
      ...((rec.units ?? []) as Obj[]).flatMap((u) => (u.fields ?? []) as Obj[]),
      ...((rec.unreconciled ?? []) as Obj[]),
      ...((rec.adopt ?? []) as Obj[]),
    ];
    for (const f of fields) differences.push({ attribute: `${coordinate}.${String(f.field)}`, desired: f.desired, actual: f.actual });
  }
  return { module, differences, ...(errors.length ? { error: errors.join("; ") } : {}) };
}

// The records config/ holds that a CI should answer for: a module instance, a
// zone, a share, an environment, an identity. What a reporting manager owns
// and D5 can name; a switch's or an AP's record comes in through its CI's
// `desired`, the second half of the check.
export function desiredRecords(configDir: string): { class: string; name: string; file: string }[] {
  const out: { class: string; name: string; file: string }[] = [];
  const readJson = (f: string): Obj | null => {
    try {
      const v: unknown = JSON.parse(readFileSync(f, "utf8"));
      return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null;
    } catch {
      return null;
    }
  };
  const list = (dir: string): string[] => (existsSync(dir) && statSync(dir).isDirectory() ? readdirSync(dir).filter((f) => f.endsWith(".json")) : []);
  for (const f of list(configDir)) {
    const doc = readJson(join(configDir, f));
    const kind = doc?.kind;
    if (doc?.status === "archived") continue; // no CI any more: its end was reported
    if (kind === "vm" || kind === "lxc" || kind === "machine" || kind === "device") out.push({ class: "node", name: f.slice(0, -5), file: f });
  }
  const zones = readJson(join(configDir, "zones.json"));
  for (const [k, v] of Object.entries(zones ?? {})) {
    if (!k.startsWith("_") && v !== null && typeof v === "object") out.push({ class: "zone", name: k, file: "zones.json" });
  }
  const nfs = readJson(join(configDir, "shares.json"))?.nfs as Obj | undefined;
  for (const k of Object.keys((nfs?.shares ?? {}) as Obj)) out.push({ class: "share", name: k, file: "shares.json" });
  for (const f of list(join(configDir, "environments"))) out.push({ class: "environment", name: f.slice(0, -5), file: `environments/${f}` });
  for (const [dir, cls] of [["organizations", "organization"], ["groups", "group"], ["users", "user"], ["roles", "role"]]) {
    for (const f of list(join(configDir, "identities", dir))) out.push({ class: cls, name: f.slice(0, -5), file: `identities/${dir}/${f}` });
  }
  return out;
}

/** The verb a new object traces back to: the change that made it or, for a
 *  part of one, the change that made its owner. */
export interface Origin {
  verb: string | null;
  job: string | null;
  time: number; // ms
}

interface Known {
  cls: string;
  name: string;
  created: number;
  creator: { kind: string; verb: string | null; job: string | null; time: number } | null;
  owners: string[];
}

/**
 * What is new, not drift (D15): an object nobody's verb wrote is still
 * expected when it is a part of an object a verb made — its CONTAINMENT owner,
 * transitively (a port of the asset of a node `node add` made) — and the verb
 * made that owner since the last sweep, or at most NEW_WINDOW_MS before the
 * part appeared. And a verb-made object's (or such a part's) first
 * observation, the fields it fills that never had a value, is new as well.
 * A later change of a filled field is drift as before. Read lazily, cached.
 */
export function newness(
  pg: { query: Query },
  since: string,
  explained: Map<string, { verb: string | null; job: string | null; time: number }>,
): {
  partOfNew(id: string): Promise<{ origin: Origin; owner: string } | null>;
  firstObservation(id: string, at: number): Promise<Origin | null>;
} {
  const sinceMs = Date.parse(since);
  const known = new Map<string, Promise<Known | null>>();
  const load = async (id: string): Promise<Known | null> => {
    const o = (await pg.query(`SELECT class, name, created FROM object WHERE id = $1`, [id])).rows[0];
    if (!o) return null;
    const c = (await pg.query(`SELECT kind, verb, job, time FROM change WHERE objects @> ARRAY[$1::uuid] ORDER BY time, id LIMIT 1`, [id])).rows[0];
    const owners = (await pg.query(
      `SELECT DISTINCT to_object FROM relation
        WHERE from_object = $1 AND type IN (${CONTAINMENT.map((t) => `'${t}'`).join(", ")}) AND NOT isempty(validity)`,
      [id],
    )).rows.map((r) => String(r.to_object));
    return {
      cls: String(o.class),
      name: String(o.name),
      created: Date.parse(String(o.created)),
      creator: c ? { kind: String(c.kind), verb: c.verb as string | null, job: c.job as string | null, time: Date.parse(String(c.time)) } : null,
      owners,
    };
  };
  const get = (id: string): Promise<Known | null> => {
    let p = known.get(id);
    if (!p) known.set(id, (p = load(id)));
    return p;
  };
  // The owner whose verb makes this object new, and that verb.
  const viaOwner = async (k: Known, seen: Set<string>): Promise<{ origin: Origin; owner: string } | null> => {
    for (const ow of k.owners) {
      const o = await origin(ow, seen);
      if (o && (o.time > sinceMs || k.created - o.time <= NEW_WINDOW_MS)) {
        const ok = await get(ow);
        return { origin: o, owner: ok ? `${ok.cls}/${ok.name}` : ow };
      }
    }
    return null;
  };
  // A verb made it, a verb explains its appearing in this window, or it is a
  // part of such an object.
  const origin = async (id: string, seen: Set<string>): Promise<Origin | null> => {
    if (seen.has(id) || seen.size > 16) return null;
    seen.add(id);
    const k = await get(id);
    if (!k) return null;
    if (k.creator?.kind === "change") return { verb: k.creator.verb, job: k.creator.job, time: k.creator.time };
    const e = explained.get(id);
    if (e && k.created > sinceMs) return e;
    return (await viaOwner(k, seen))?.origin ?? null;
  };
  return {
    async partOfNew(id) {
      const k = await get(id);
      return k ? viaOwner(k, new Set([id])) : null;
    },
    async firstObservation(id, at) {
      const o = await origin(id, new Set());
      const k = await get(id);
      if (!o || !k) return null;
      if (at - k.created <= NEW_WINDOW_MS) return o;
      // Its first observation is the first one that wrote fields: none before
      // the last sweep.
      const earlier = (await pg.query(
        `SELECT 1 FROM attribute a JOIN change c ON c.id = a.change
          WHERE a.object = $1 AND c.kind = 'observation' AND NOT isempty(a.validity) AND lower(a.validity) <= $2
            AND a.name NOT IN ('drift', 'placeholder') LIMIT 1`,
        [id, since],
      )).rows.length;
      return earlier ? null : o;
    },
  };
}

export class Sweep {
  private running = false;

  constructor(
    private readonly store: Store,
    private readonly deps: SweepDeps,
  ) {}

  get busy(): boolean {
    return this.running;
  }

  /** The last sweep record, or null. */
  async last(): Promise<Obj | null> {
    const rows = (await this.store.pg.query(`SELECT id, time, body FROM change WHERE verb = 'sweep' ORDER BY time DESC, id DESC LIMIT 1`)).rows;
    return rows.length ? { id: rows[0].id, time: rows[0].time, ...(rows[0].body as Obj) } : null;
  }

  async run(): Promise<SweepResult> {
    if (this.running) throw new Error("a sweep is already running");
    this.running = true;
    try {
      return await this.sweep();
    } finally {
      this.running = false;
    }
  }

  private async sweep(): Promise<SweepResult> {
    const d = this.deps;
    const now = d.now ?? ((): Date => new Date());
    const prev = await this.last();
    const since = prev ? String(prev.time) : null;
    const started = now().toISOString();

    d.log(`sweep: asking every source${since ? ` (the last sweep: ${since})` : " (the first: this one is the baseline)"}`);
    const sources = await (d.rescanAll ?? (async () => (await rescan(d.log, rescanSources(), { discover: true })).asked))();
    await this.reach(sources, started);
    await this.store.expire(now());
    // What a retired object left behind is retired with it (D7), as a change,
    // so the differences below list it as expected.
    const orphans = await this.store.retire({ orphans: true, apply: true, verb: "sweep: retire orphans" });
    for (const o of orphans.retire) d.log(`sweep: retired ${o.class} ${o.name} (${o.id}): ${o.reason}`);
    const until = now().toISOString();

    const differences: Difference[] = since ? await this.sinceLast(since, until) : [];
    differences.push(...(await this.fromDesired(started, d.differ ?? moduleDiffer)));
    differences.push(...(await this.cycles()));
    differences.push(...this.missedDevices(sources));
    differences.sort((a, b) => a.class.localeCompare(b.class) || a.name.localeCompare(b.name) || (a.attribute ?? "").localeCompare(b.attribute ?? ""));

    const counts: SweepCounts = {
      expected: differences.filter((x) => x.expected).length,
      new: differences.filter((x) => x.reason === "new").length,
      words: differences.filter((x) => x.reason === "words").length,
      drift: differences.filter((x) => !x.expected && ["changed", "appeared", "gone"].includes(x.kind)).length,
      desired: differences.filter((x) => x.kind === "desired").length,
      unmanaged: differences.filter((x) => x.kind === "unmanaged").length,
      missing: differences.filter((x) => x.kind === "missing").length,
      unread: differences.filter((x) => x.kind === "unread").length,
      cycles: differences.filter((x) => x.kind === "cycle").length,
      sourcesFailed: sources.filter((s) => !s.ok).length,
    };
    const exitCode: 0 | 1 | 2 = counts.missing || counts.sourcesFailed ? 2 : counts.drift || counts.desired || counts.unmanaged || counts.unread || counts.cycles ? 1 : 0;
    const status = exitCode === 2 ? "critical" : exitCode === 1 ? "warning" : "healthy";

    const body = { since, counts, status, exitCode, sources, differences };
    const { id, event } = await this.store.pg.tx(async (q) => {
      const c = await q(`INSERT INTO change (kind, source, verb, time, drift, body) VALUES ('observation', $1, 'sweep', $2, $3, $4::jsonb) RETURNING id`, [
        CONTROLLER_SOURCE,
        until,
        exitCode > 0,
        body,
      ]);
      const change = Number(c.rows[0].id);
      const marked = await this.markDrift(q, differences, change, until);
      const ev = await q(
        `UPDATE change SET objects = ARRAY(SELECT (jsonb_array_elements_text($2::jsonb))::uuid) WHERE id = $1
          RETURNING id, kind, source, job, verb, actor, time, to_jsonb(objects) AS objects, to_jsonb(relations) AS relations, drift`,
        [change, marked],
      );
      return { id: change, event: ev.rows[0] as unknown as ChangeEvent };
    });
    this.store.publish(event);

    (d.journal ?? journalWriter(d.log))(
      differences.map((x) =>
        JSON.stringify({
          kind: x.kind,
          class: x.class,
          name: x.name,
          source: x.source,
          attribute: x.attribute,
          before: x.before ?? null,
          after: x.after ?? null,
          expected: x.expected,
          ...(x.reason ? { reason: x.reason, verb: x.verb ?? null, ...(x.owner ? { owner: x.owner } : {}) } : {}),
        }),
      ),
    );
    d.log(`sweep ${id}: ${status} — ${JSON.stringify(counts)}`);
    return { id, time: until, since, counts, status, exitCode, sources, differences };
  }

  // Which devices each source reached (the store's per-source sighting): a
  // source that ran and reached none of what it reported before has failed,
  // however it exited; one that missed some says which. A device is a physical
  // object that is not a part (a port, a disk follow theirs).
  private async reach(sources: RescanResult[], started: string): Promise<void> {
    for (const s of sources) {
      if (!s.ok) continue;
      const rows = (
        await this.store.pg.query(
          `SELECT o.class, o.name, (o.seen->>$1) AS at FROM object o JOIN class c ON c.name = o.class
            WHERE o.ended IS NULL AND o.seen ? $1 AND c.physical AND o.class NOT IN ('port', 'disk')
            ORDER BY o.class, o.name`,
          [s.source],
        )
      ).rows;
      const t0 = Date.parse(started);
      s.reached = rows.filter((r) => Date.parse(String(r.at)) >= t0).length;
      s.missed = rows.filter((r) => Date.parse(String(r.at)) < t0).map((r) => `${String(r.class)}/${String(r.name)}`);
      if (s.reached === 0 && s.missed.length) Object.assign(s, { ok: false, error: `reached none of the ${s.missed.length} device(s) it reported before` });
    }
  }

  private missedDevices(sources: RescanResult[]): Difference[] {
    return sources
      .filter((s) => s.ok && s.missed?.length)
      .flatMap((s) =>
        s.missed!.map((m) => {
          const slash = m.indexOf("/");
          return { kind: "unread" as const, class: m.slice(0, slash), name: m.slice(slash + 1), source: s.source, attribute: null, before: null, after: `not reached by ${s.source}`, expected: false };
        }),
      );
  }

  // A dependency cycle over required relations: a failure on one reaches all
  // of them and comes back, so one stopped guest would take its own host.
  // Listed on the member that sorts first, naming the others.
  private async cycles(): Promise<Difference[]> {
    const rels = (await this.store.relations({})) as unknown as CycleRelation[];
    const meta = [...new Map(this.store.mm.relations.map((r) => [r.name, { name: r.name, dependant: r.dependant, required: r.required }])).values()];
    const label = new Map<string, { class: string; name: string }>();
    for (const r of rels) for (const e of [r.from, r.to]) label.set(e.id, { class: String(e.class), name: String(e.name) });
    return dependencyCycles(rels, meta).map((c) => {
      const first = label.get(c[0])!;
      return {
        kind: "cycle" as const, class: first.class, name: first.name, id: c[0], source: CONTROLLER_SOURCE, attribute: null,
        before: null, after: c.map((id) => `${label.get(id)?.class}/${label.get(id)?.name}`), expected: false,
      };
    });
  }

  // Step 2: every attribute and relation whose value at the last sweep is not
  // its value now, from the history (D6). Volatile and derived attributes are
  // left out: they are not differences anyone should read.
  private async sinceLast(since: string, until: string): Promise<Difference[]> {
    const pg = this.store.pg;
    const mm = this.store.mm;
    const out: Difference[] = [];
    // The objects a verb reported touching in the window: what explains
    // something that has no row of its own to point at (a value that went).
    const explained = new Map<string, { verb: string | null; job: string | null; time: number }>();
    for (const r of (await pg.query(
      `SELECT DISTINCT ON (x) x, c.verb, c.job, c.time FROM change c, unnest(c.objects) AS x
        WHERE c.kind = 'change' AND c.time > $1 AND c.time <= $2 ORDER BY x, c.time DESC`,
      [since, until],
    )).rows) {
      explained.set(String(r.x), { verb: r.verb as string | null, job: r.job as string | null, time: Date.parse(String(r.time)) });
    }
    const why = (id: string): Pick<Difference, "expected" | "verb" | "job"> => {
      const e = explained.get(id);
      return e ? { expected: true, verb: e.verb, job: e.job } : { expected: false };
    };
    const isNew = newness(pg, since, explained);
    // The objects that appeared in this window and are expected (by their own
    // verb or as new): what a relation of theirs that appeared is part of.
    const appearedExpected = new Map<string, Pick<Difference, "verb" | "job">>();
    const leases = new Set<string>(); // the leased addresses that came or went

    const objects = (await pg.query(
      `SELECT o.id, o.class, o.name, o.created, o.ended, o.seen, ${PLACEHOLDER("o")} AS placeholder FROM object o
        WHERE (o.created > $1 AND o.created <= $2) OR (o.ended > $1 AND o.ended <= $2)`,
      [since, until],
    )).rows;
    const fresh = new Set<string>();
    for (const o of objects) {
      const id = String(o.id);
      if (o.created !== null && Date.parse(String(o.created)) > Date.parse(since)) fresh.add(id);
      if (o.placeholder === true) continue;
      const ended = o.ended !== null;
      let verdict: Pick<Difference, "expected" | "verb" | "job" | "reason" | "owner"> = why(id);
      if (!ended && !verdict.expected) {
        const part = await isNew.partOfNew(id);
        if (part) verdict = { expected: true, verb: part.origin.verb, job: part.origin.job, reason: "new", owner: part.owner };
      }
      // A leased address appearing, or going when its lease ran out, is what a
      // DHCP server does: expected, and so is its zone membership with it.
      if (!verdict.expected && String(o.class) === "address" && (await leased((sql, params) => pg.query(sql, params), id, ended))) {
        verdict = { expected: true, reason: "lease" };
        leases.add(id);
      }
      if (!ended && verdict.expected) appearedExpected.set(id, { verb: verdict.verb, job: verdict.job });
      out.push({
        kind: ended ? "gone" : "appeared",
        class: String(o.class),
        name: String(o.name),
        id,
        source: latestSource(o.seen),
        attribute: null,
        before: null,
        after: null,
        ...verdict,
      });
    }

    const attrs = (await pg.query(
      `SELECT a.object, a.name, a.value, a.source, lower(a.validity) AS "from", upper(a.validity) AS "to",
              o.class, o.name AS oname, c.kind AS ckind, c.verb, c.job,
              EXISTS (SELECT 1 FROM attribute p WHERE p.object = a.object AND p.name = a.name AND NOT isempty(p.validity) AND lower(p.validity) <= $1) AS had
         FROM attribute a JOIN object o ON o.id = a.object LEFT JOIN change c ON c.id = a.change
        WHERE NOT isempty(a.validity) AND a.validity && tstzrange($1, $2, '(]') AND a.name NOT IN ('drift', 'placeholder')
        ORDER BY a.object, a.name, lower(a.validity)`,
      [since, until],
    )).rows;
    const groups = new Map<string, typeof attrs>();
    for (const r of attrs) {
      const k = `${String(r.object)}\u0000${String(r.name)}`;
      groups.set(k, [...(groups.get(k) ?? []), r]);
    }
    for (const rows of groups.values()) {
      const first = rows[0];
      const last = rows[rows.length - 1];
      const id = String(first.object);
      const cls = String(first.class);
      if (fresh.has(id)) continue; // the object appeared: that is the one line
      const def = mm.has(cls) ? mm.fields(cls).get(String(first.name)) : undefined;
      if (def?.volatile) continue;
      const before = Date.parse(String(first.from)) <= Date.parse(since) ? first.value : undefined;
      const after = last.to === null || Date.parse(String(last.to)) > Date.parse(until) ? last.value : undefined;
      if (canon(before) === canon(after)) continue;
      const byVerb = after !== undefined && last.ckind === "change";
      // A field that never had a value, filled by the first observation of
      // an object a verb made (or of a part of one): new, not drift.
      const firstFill = before === undefined && after !== undefined && !byVerb && first.had !== true ? await isNew.firstObservation(id, Date.parse(String(first.from))) : null;
      out.push({
        kind: before === undefined ? "appeared" : after === undefined ? "gone" : "changed",
        class: cls,
        name: String(first.oname),
        id,
        source: String(last.source),
        attribute: String(first.name),
        before: before ?? null,
        after: after ?? null,
        ...(byVerb
          ? { expected: true, verb: last.verb as string | null, job: last.job as string | null }
          : firstFill
            ? { expected: true, verb: firstFill.verb, job: firstFill.job, reason: "new" as const }
            : after === undefined
              ? why(id)
              : { expected: false }),
      });
    }

    const rels = (await pg.query(
      `SELECT r.type, r.from_object, r.to_object, r.attributes, r.source, lower(r.validity) AS "from", upper(r.validity) AS "to",
              f.class AS fclass, f.name AS fname, t.class AS tclass, t.name AS tname, c.kind AS ckind, c.verb, c.job,
              ${PLACEHOLDER("t")} AS tph,
              EXISTS (SELECT 1 FROM relation p WHERE p.type = r.type AND p.from_object = r.from_object AND p.to_object = r.to_object
                         AND NOT isempty(p.validity) AND lower(p.validity) <= $1) AS had
         FROM relation r JOIN object f ON f.id = r.from_object JOIN object t ON t.id = r.to_object LEFT JOIN change c ON c.id = r.change
        WHERE NOT isempty(r.validity) AND r.validity && tstzrange($1, $2, '(]')
        ORDER BY r.type, r.from_object, r.to_object, lower(r.validity)`,
      [since, until],
    )).rows;
    const relGroups = new Map<string, typeof rels>();
    for (const r of rels) {
      const k = `${String(r.type)}\u0000${String(r.from_object)}\u0000${String(r.to_object)}`;
      relGroups.set(k, [...(relGroups.get(k) ?? []), r]);
    }
    for (const rows of relGroups.values()) {
      const first = rows[0];
      const last = rows[rows.length - 1];
      const from = String(first.from_object);
      const to = String(first.to_object);
      const before = Date.parse(String(first.from)) <= Date.parse(since) ? first.attributes : undefined;
      const after = last.to === null || Date.parse(String(last.to)) > Date.parse(until) ? last.attributes : undefined;
      if (canon(before) === canon(after)) continue;
      const byVerb = after !== undefined && last.ckind === "change";
      const e = why(from).expected ? why(from) : why(to);
      // A relation that appeared with an object that appeared as expected is
      // part of that appearance; one a verb-made object's first observation
      // filled in is new as well.
      let partOf: Pick<Difference, "expected" | "verb" | "job" | "reason"> | null = null;
      // The ends and the type stay, only the dependency words changed: words.
      if (before !== undefined && after !== undefined && !byVerb && canon(withoutWords(before)) === canon(withoutWords(after))) {
        partOf = { expected: true, verb: null, job: null, reason: "words" };
      }
      if ((before === undefined || after === undefined) && (leases.has(from) || leases.has(to))) partOf = { expected: true, verb: null, job: null, reason: "lease" };
      else if (before === undefined && after !== undefined && !byVerb) {
        const a = appearedExpected.get(from) ?? appearedExpected.get(to);
        if (a) partOf = { expected: true, verb: a.verb, job: a.job, reason: "new" };
        else if (first.had !== true) {
          const o = await isNew.firstObservation(from, Date.parse(String(first.from)));
          if (o) partOf = { expected: true, verb: o.verb, job: o.job, reason: "new" };
        }
      }
      out.push({
        kind: before === undefined ? "appeared" : after === undefined ? "gone" : "changed",
        class: String(first.fclass),
        name: String(first.fname),
        id: from,
        source: String(last.source),
        attribute: `→${String(first.type)} ${String(first.tclass)}/${String(first.tname)}`,
        before: before ?? null,
        after: after ?? null,
        ...(byVerb ? { expected: true, verb: last.verb as string | null, job: last.job as string | null } : (partOf ?? (after === undefined ? e : { expected: false }))),
      });
    }
    return out;
  }

  // Step 3.
  private async fromDesired(started: string, differ: (module: string) => Promise<DifferOutcome>): Promise<Difference[]> {
    const pg = this.store.pg;
    const mm = this.store.mm;
    const out: Difference[] = [];
    const rows = (await pg.query(
      `SELECT o.id, o.class, o.name, o.last_seen, o.seen, d.value AS desired, s.value AS stage, ${PLACEHOLDER("o")} AS placeholder
         FROM object o
         LEFT JOIN attribute d ON d.object = o.id AND d.name = 'desired' AND upper_inf(d.validity)
         LEFT JOIN attribute s ON s.object = o.id AND s.name = 'stage' AND upper_inf(s.validity)
        WHERE o.ended IS NULL ORDER BY o.class, o.name`,
    )).rows;
    const sourceOf = (r: (typeof rows)[number]): string => latestSource(r.seen);
    const seenNow = (r: (typeof rows)[number]): boolean => r.last_seen !== null && Date.parse(String(r.last_seen)) >= Date.parse(started) && r.stage !== "unseen";

    // The differ, once per module record.
    const modules = new Map<string, (typeof rows)[number]>();
    for (const r of rows) {
      const file = (r.desired as Obj | null)?.file;
      if (typeof file === "string" && /^[^/]+\.json$/.test(file) && (r.desired as Obj).key === undefined && mm.isA(String(r.class), "node") && file === `${String(r.name)}.json`) {
        modules.set(String(r.name), r);
      }
    }
    for (const [module, r] of modules) {
      const res = await differ(module);
      if (res.error) out.push({ kind: "unread", class: String(r.class), name: module, id: String(r.id), source: "module-manager", attribute: null, before: null, after: res.error, expected: false });
      for (const f of res.differences) {
        out.push({ kind: "desired", class: String(r.class), name: module, id: String(r.id), source: "module-manager", attribute: f.attribute, before: f.desired, after: f.actual, expected: false });
      }
    }

    // Actual without desired: what can have a record and has none. A class
    // that never has one (a lease, a service derived from its module) is not
    // "unmanaged": it would be every sweep's answer, and hide the rest.
    for (const r of rows) {
      const cls = String(r.class);
      if (r.placeholder === true || r.desired !== null || !mm.has(cls) || !mm.hasDesiredRecord(cls)) continue;
      out.push({ kind: "unmanaged", class: cls, name: String(r.name), id: String(r.id), source: sourceOf(r), attribute: null, before: null, after: null, expected: false });
    }

    // Desired without actual: a CI with a record that no source saw this
    // sweep, or unseen; a record with no CI at all.
    const reported = new Set<string>();
    for (const r of rows) {
      if (r.placeholder === true && r.desired === null) continue;
      const cls = String(r.class);
      for (const a of mm.ancestors(cls)) reported.add(`${a}\u0000${String(r.name)}`);
      if (r.desired !== null && !seenNow(r)) {
        out.push({ kind: "missing", class: cls, name: String(r.name), id: String(r.id), source: sourceOf(r), attribute: null, before: r.desired, after: r.stage ?? null, expected: false });
      }
    }
    for (const rec of desiredRecords(this.deps.configDir)) {
      if (reported.has(`${rec.class}\u0000${rec.name}`)) continue;
      out.push({ kind: "missing", class: rec.class, name: rec.name, source: CONTROLLER_SOURCE, attribute: null, before: { file: rec.file }, after: null, expected: false });
    }
    return out;
  }

  // Objects with unexplained differences are drifted (D6), until a change
  // clears them; one already marked keeps its `since` and gains these.
  private async markDrift(q: Query, differences: Difference[], change: number, t: string): Promise<string[]> {
    const by = new Map<string, Record<string, { was: unknown; now: unknown }>>();
    for (const x of differences) {
      if (x.expected || !x.id || x.attribute === null || !["changed", "appeared", "gone", "desired"].includes(x.kind)) continue;
      by.set(x.id, { ...(by.get(x.id) ?? {}), [x.attribute]: { was: x.before, now: x.after } });
    }
    for (const [id, attributes] of by) {
      const cur = (await q(`SELECT id, value, lower(validity) AS "from" FROM attribute WHERE object = $1 AND name = 'drift' AND upper_inf(validity)`, [id])).rows[0];
      const was = (cur?.value ?? null) as Obj | null;
      const desired = (await q(`SELECT value FROM attribute WHERE object = $1 AND name = 'desired' AND upper_inf(validity)`, [id])).rows[0]?.value ?? null;
      const value = { since: was?.since ?? t, source: "sweep", attributes: { ...((was?.attributes ?? {}) as Obj), ...attributes }, desired };
      const when = cur && Date.parse(String(cur.from)) > Date.parse(t) ? String(cur.from) : t;
      if (cur) await q("UPDATE attribute SET validity = tstzrange(lower(validity), $2) WHERE id = $1", [Number(cur.id), when]);
      await q(`INSERT INTO attribute (object, name, value, source, change, validity) VALUES ($1, 'drift', $2::jsonb, $3, $4, tstzrange($5, NULL))`, [id, value, CONTROLLER_SOURCE, change, when]);
    }
    return [...by.keys()];
  }
}
