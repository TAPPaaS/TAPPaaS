// cmdb.ts — the console's read client of cmdb-controller (ADR-040 D10, ADR-041
// D5): the loopback API with the bearer token, and its change stream. Reads
// only: the console changes the site by running verbs (jobs.ts), never through
// here. The managers' client (lib/ts cmdb.ts) is synchronous, one curl per
// call, which a server cannot be; this one is fetch, as litellm.ts is.
//
// The CMDB is a record, never a gate: a page that reads through here says the
// CMDB did not answer and falls back; nothing else in the console needs it.

import { existsSync, readFileSync } from "fs";
import { Runner, runJson } from "./run";

type Obj = Record<string, unknown>;

export interface CmdbObject {
  id: string;
  class: string;
  name: string;
  displayName?: string | null;
  physical?: boolean;
  attributes: Obj;
}

export interface CmdbEnd {
  id: string;
  class: string;
  name: string;
}

export interface CmdbRelationRow {
  id: number | string;
  type: string;
  from: CmdbEnd;
  to: CmdbEnd;
  attributes?: Obj | null;
}

// GET /v1/objects/<id>: an attribute with its source and since; each relation
// from this object's side.
export interface CmdbShow {
  id: string;
  class: string;
  ancestors?: string[];
  name: string;
  displayName?: string | null;
  attributes: Record<string, { value: unknown; source: string; since: string }>;
  drift: unknown;
  relations: { id: number | string; type: string; direction: "in" | "out"; other: CmdbEnd; source?: string; since?: string }[];
}

// GET /v1/objects/<id>/history: every period of every attribute.
export interface CmdbAttributePeriod {
  name: string;
  value: unknown;
  source: string;
  from: string;
  to: string | null;
  change?: number | null; // the change that opened the period
}
// Every period of every relation, from this object's side.
export interface CmdbRelationPeriod {
  id: number | string;
  type: string;
  direction: "in" | "out";
  other: CmdbEnd;
  attributes?: Obj | null;
  source?: string;
  change?: number | null;
  from: string;
  to: string | null;
}
export interface CmdbHistory {
  id: string;
  attributes: CmdbAttributePeriod[];
  relations?: CmdbRelationPeriod[];
  changes: { id: number; kind: string; source: string; job: string | null; verb: string | null; actor: string | null; time: string; drift: boolean }[];
}
// `event: change` on /v1/stream (cmdb-controller store.ts ChangeEvent).
export interface CmdbChange {
  id: number;
  kind: string;
  source: string;
  time: string;
  objects: string[];
  relations: number[];
  drift: boolean;
}

export interface CmdbQuery {
  class?: string;
  where?: Obj;
  at?: string;
  includeEnded?: boolean;
  limit?: number;
}

export interface CmdbRelationQuery {
  type?: string;
  from?: string;
  to?: string;
  at?: string;
  limit?: number;
}

export interface CmdbClassRow {
  name: string;
  parent: string | null;
}

// GET /v1/rules: what a reader needs of the relation types.
export interface CmdbRules {
  relations: { name: string; dependant?: "from" | "to" | "both" | null; tree?: "from" | "to" | "both" | null }[];
}

export interface CmdbConfig {
  url?: string; // default CMDB_URL, else http://127.0.0.1:9098
  tokenFile?: string; // default CMDB_TOKEN_FILE, else /etc/secrets/cmdb-token
  run?: Runner; // for the one read that is a verb: health-manager roots
  timeoutMs?: number;
  retryMs?: number; // how long the stream waits before it reconnects
  log?: (line: string) => void;
}

export class CmdbError extends Error {
  constructor(message: string, readonly status: number | null = null) {
    super(message);
  }
}

// One SSE frame: its event name and its data lines joined.
export function parseFrame(frame: string): { event: string; data: string } | null {
  let event = "message";
  const data: string[] = [];
  for (const line of frame.split("\n")) {
    if (line.startsWith(":")) continue;
    const at = line.indexOf(":");
    const field = at < 0 ? line : line.slice(0, at);
    const value = at < 0 ? "" : line.slice(at + 1).replace(/^ /, "");
    if (field === "event") event = value;
    else if (field === "data") data.push(value);
  }
  return data.length ? { event, data: data.join("\n") } : null;
}

// The frames a chunk completes, and what is left for the next chunk.
export function splitFrames(buffer: string): { frames: string[]; rest: string } {
  const parts = buffer.replace(/\r\n/g, "\n").split("\n\n");
  return { rest: parts.pop() ?? "", frames: parts };
}

export class Cmdb {
  private readonly url: string;
  private readonly tokenFile: string;
  private readonly timeoutMs: number;

  constructor(private readonly cfg: CmdbConfig = {}) {
    const env = process.env;
    this.url = (cfg.url ?? env.CMDB_URL ?? "http://127.0.0.1:9098").replace(/\/+$/, "");
    this.tokenFile = cfg.tokenFile ?? env.CMDB_TOKEN_FILE ?? "/etc/secrets/cmdb-token";
    this.timeoutMs = cfg.timeoutMs ?? 30_000;
  }

  // Read each time: the token may be rotated under a running console.
  private headers(): Record<string, string> {
    if (!existsSync(this.tokenFile)) throw new CmdbError(`no token at ${this.tokenFile}`);
    return { Authorization: `Bearer ${readFileSync(this.tokenFile, "utf8").trim()}`, "Content-Type": "application/json" };
  }

  private async request<T>(method: "GET" | "POST", path: string, body?: unknown, timeoutMs = this.timeoutMs): Promise<T> {
    let r: FetchResponse;
    try {
      r = await fetch(`${this.url}${path}`, { method, headers: this.headers(), body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
    } catch (e) {
      if (e instanceof CmdbError) throw e;
      throw new CmdbError(`the CMDB did not answer: ${(e as Error).message}`);
    }
    const parsed = (await r.json().catch(() => null)) as { ok?: boolean; data?: T; error?: string } | null;
    if (!r.ok || parsed?.ok !== true) throw new CmdbError(parsed?.error ?? `the CMDB answered HTTP ${r.status}`, r.status);
    return parsed.data as T;
  }

  query(q: CmdbQuery = {}): Promise<CmdbObject[]> {
    return this.request("POST", "/v1/query", q);
  }

  relations(q: CmdbRelationQuery = {}): Promise<CmdbRelationRow[]> {
    return this.request("POST", "/v1/relations", q);
  }

  show(id: string, at?: string): Promise<CmdbShow> {
    return this.request("GET", `/v1/objects/${encodeURIComponent(id)}${at ? `?at=${encodeURIComponent(at)}` : ""}`);
  }

  // By name, with the class (or an ancestor of it) where the name is not
  // unique: the controller answers 409 with the candidates otherwise.
  find(name: string, cls?: string): Promise<CmdbShow> {
    return this.request("GET", `/v1/objects/${encodeURIComponent(name)}${cls ? `?class=${encodeURIComponent(cls)}` : ""}`);
  }

  history(id: string): Promise<CmdbHistory> {
    return this.request("GET", `/v1/objects/${encodeURIComponent(id)}/history`);
  }

  // The discovery sweep (ADR-040 D15), run as `cmdb sweep --json`: it answers
  // only when it has finished, hours on a big site, longer than fetch waits for
  // an answer's headers; the CLI's curl waits 4 hours. Its exit is the sweep's
  // status (0, 1, 2) with the record on stdout; 4 with "already running" is the
  // controller's 409.
  async sweep(): Promise<Obj> {
    if (!this.cfg.run) throw new CmdbError("no runner for cmdb sweep");
    const r = await this.cfg.run("cmdb", ["sweep", "--json"], 4 * 3600_000 + 60_000);
    if (r.rc >= 0 && r.rc <= 2) {
      try {
        const d = JSON.parse(r.stdout) as Obj;
        if (d && typeof d === "object") return d;
      } catch {
        // not a record: below
      }
    }
    const why = (r.stderr || r.stdout).trim().split("\n").slice(-3).join(" ").replace(/^cmdb: /, "") || `cmdb sweep exited ${r.rc}`;
    throw new CmdbError(why, r.rc === 4 && /already running/i.test(why) ? 409 : null);
  }

  // The last sweep's record; null when none has run (404).
  async lastSweep(): Promise<Obj | null> {
    try {
      return await this.request<Obj>("GET", "/v1/sweep");
    } catch (e) {
      if (e instanceof CmdbError && e.status === 404) return null;
      throw e;
    }
  }

  classes(): Promise<CmdbClassRow[]> {
    return this.request("GET", "/v1/classes");
  }

  rules(): Promise<CmdbRules> {
    return this.request("GET", "/v1/rules");
  }

  // The verb's answer, a list or { roots: [...] }; health-emit's verb. The
  // caller falls back on what the graph holds when it fails.
  async roots(): Promise<Obj[]> {
    if (!this.cfg.run) throw new CmdbError("no runner for health-manager roots");
    const d = await runJson<Obj[] | { roots?: Obj[] }>(this.cfg.run, "health-manager", ["roots", "--json"], { timeoutMs: 60_000 });
    return Array.isArray(d) ? d : Array.isArray(d?.roots) ? d.roots : [];
  }

  // Follow the change stream until stop(): each change to onChange, and
  // onLink(true) on every connect (what passed while away is unknown, so the
  // caller reads again), onLink(false) when the stream is lost. It never
  // throws and never gives up: the CMDB may be installed after the console.
  subscribe(onChange: (c: CmdbChange) => void, onLink: (up: boolean) => void): () => void {
    let stopped = false;
    let ac: AbortController | null = null;
    let timer: unknown = null;
    const retry = this.cfg.retryMs ?? 10_000;
    const follow = async (): Promise<void> => {
      let linked = false;
      try {
        ac = new AbortController();
        const r = await fetch(`${this.url}/v1/stream`, { headers: this.headers(), signal: ac.signal });
        if (!r.ok || !r.body) throw new CmdbError(`the stream answered HTTP ${r.status}`, r.status);
        linked = true;
        onLink(true);
        const dec = new TextDecoder();
        let buffer = "";
        for await (const part of r.body) {
          const { frames, rest } = splitFrames(buffer + dec.decode(part, { stream: true }));
          buffer = rest;
          for (const f of frames) {
            const e = parseFrame(f);
            if (e?.event !== "change") continue;
            try {
              onChange(JSON.parse(e.data) as CmdbChange);
            } catch (x) {
              this.cfg.log?.(`cmdb stream: a change that is not JSON: ${(x as Error).message}`);
            }
          }
        }
      } catch (e) {
        if (!stopped && linked) this.cfg.log?.(`cmdb stream lost: ${(e as Error).message}`);
      }
      if (linked) onLink(false);
      if (!stopped) timer = setTimeout(() => void follow(), retry);
    };
    void follow();
    return () => {
      stopped = true;
      ac?.abort();
      if (timer !== null) clearTimeout(timer);
    };
  }
}
