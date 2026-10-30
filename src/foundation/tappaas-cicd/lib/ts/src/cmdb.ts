// cmdb.ts — the TypeScript managers' client of cmdb-controller (ADR-040 D2,
// D4): report what a verb saw or changed, query, show. The `cmdb` CLI is built
// on it too.
//
// The CMDB is a record, never a gate: a report that cannot be delivered (the
// service is down, the store is) is spooled under config/.cmdb-spool/ and the
// verb carries on; the next call that reaches the service replays the spool
// first, oldest first, so the store sees the reports in the order they were
// made. A report the service refuses (a key conflict, a field its class does
// not have) is a reporter's bug, not an outage: it is not spooled; a spooled
// one refused on replay is moved to .cmdb-spool/refused/ for someone to read.
//
// Synchronous, as the managers are: one curl per call over the service's Unix
// socket (CMDB_SOCKET), or to CMDB_URL with the token in CMDB_TOKEN_FILE.

import { spawnSync } from "child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { defaultConfigDir } from "./config-io";

type Obj = Record<string, unknown>;

export interface CmdbOptions {
  socket?: string; // default CMDB_SOCKET, else /run/cmdb/cmdb.sock
  url?: string; // instead of the socket: CMDB_URL, e.g. http://127.0.0.1:9098
  tokenFile?: string; // with url: CMDB_TOKEN_FILE, else /etc/secrets/cmdb-token
  spoolDir?: string; // default <config>/.cmdb-spool
  timeoutSeconds?: number;
}

/** The service could not be reached, or could not answer (5xx). */
export class CmdbUnavailable extends Error {}

/** The service answered with a refusal (4xx). */
export class CmdbRefused extends Error {
  constructor(
    readonly status: number,
    readonly body: Obj,
  ) {
    super(String(body.error ?? `HTTP ${status}`));
  }
}

/** One object in a report: matched by its class's keys (ADR-040 D5). A
 *  relation-typed attribute takes a reference: a ref earlier in the report,
 *  an id, or a name. */
export interface CmdbObject {
  ref?: string;
  id?: string; // this object by id, instead of its keys
  class: string;
  name: string;
  attributes?: Obj;
  end?: boolean;
  recorded?: boolean; // what no machine can see, recorded by an operator (D7)
}

export type CmdbRef = string | { ref?: string; id?: string; class?: string; name?: string };

export interface CmdbRelation {
  type: string;
  from: CmdbRef;
  to: CmdbRef;
  attributes?: Obj;
  end?: boolean;
  recorded?: boolean;
}

export interface CmdbReport {
  source: string;
  kind?: "observation" | "change";
  time?: string;
  job?: string;
  verb?: string;
  actor?: string;
  assessment?: boolean; // conclusions about objects named by id, not a sighting of them (ADR-041 D2)
  objects?: CmdbObject[];
  relations?: CmdbRelation[];
}

export interface ReportOutcome {
  delivered: boolean;
  spooled?: string; // the spool file, when not delivered
  result?: Obj; // the service's answer, when delivered
}

export function spoolDir(o: CmdbOptions = {}): string {
  return o.spoolDir ?? join(defaultConfigDir(), ".cmdb-spool");
}

/** One API call. Throws CmdbUnavailable or CmdbRefused; returns data. */
export function cmdbRequest(method: "GET" | "POST", path: string, body?: unknown, o: CmdbOptions = {}): unknown {
  const url = o.url ?? process.env.CMDB_URL;
  const args = ["-sS", "--max-time", String(o.timeoutSeconds ?? 60), "-X", method, "-w", "\n%{http_code}"];
  if (url) {
    const tokenFile = o.tokenFile ?? process.env.CMDB_TOKEN_FILE ?? "/etc/secrets/cmdb-token";
    if (!existsSync(tokenFile)) throw new CmdbUnavailable(`no token at ${tokenFile} for ${url}`);
    args.push("-H", `Authorization: Bearer ${readFileSync(tokenFile, "utf8").trim()}`);
  } else {
    const sock = o.socket ?? process.env.CMDB_SOCKET ?? "/run/cmdb/cmdb.sock";
    if (!existsSync(sock)) throw new CmdbUnavailable(`cmdb-controller is not running (no ${sock})`);
    args.push("--unix-socket", sock);
  }
  if (body !== undefined) args.push("-H", "Content-Type: application/json", "--data-binary", "@-");
  args.push(`${url ?? "http://cmdb"}${path}`);
  const r = spawnSync("curl", args, { encoding: "utf8", input: body === undefined ? undefined : JSON.stringify(body), maxBuffer: 256 * 1024 * 1024 });
  if (r.error) throw new CmdbUnavailable(`curl: ${r.error.message}`);
  if (r.status !== 0) throw new CmdbUnavailable(`cmdb-controller did not answer (curl exit ${String(r.status)}: ${(r.stderr ?? "").trim()})`);
  const out = r.stdout ?? "";
  const nl = out.lastIndexOf("\n");
  const status = Number(out.slice(nl + 1));
  let parsed: Obj;
  try {
    parsed = JSON.parse(out.slice(0, nl)) as Obj;
  } catch {
    throw new CmdbUnavailable(`cmdb-controller answered HTTP ${status} with no JSON`);
  }
  if (status >= 500) throw new CmdbUnavailable(String(parsed.error ?? `HTTP ${status}`));
  if (status >= 400 || parsed.ok !== true) throw new CmdbRefused(status, parsed);
  return parsed.data;
}

let spoolSeq = 0;

function spoolFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort();
}

/** Send what the spool holds, oldest first; stop at the first that cannot be
 *  delivered. Returns how many went and how many are left. */
export function replaySpool(o: CmdbOptions = {}): { replayed: number; refused: number; left: number } {
  const dir = spoolDir(o);
  const files = spoolFiles(dir);
  let replayed = 0;
  let refused = 0;
  for (const f of files) {
    const path = join(dir, f);
    let report: unknown;
    try {
      report = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      report = null;
    }
    try {
      if (report === null) throw new CmdbRefused(400, { error: "not JSON" });
      cmdbRequest("POST", "/v1/report", report, o);
      unlinkSync(path);
      replayed++;
    } catch (e) {
      if (e instanceof CmdbRefused) {
        mkdirSync(join(dir, "refused"), { recursive: true });
        writeFileSync(join(dir, "refused", f.replace(/\.json$/, ".why")), `${e.message}\n${JSON.stringify(e.body, null, 2)}\n`, "utf8");
        renameSync(path, join(dir, "refused", f));
        refused++;
        continue;
      }
      return { replayed, refused, left: files.length - replayed - refused };
    }
  }
  return { replayed, refused, left: 0 };
}

function spool(report: CmdbReport, o: CmdbOptions): string {
  const dir = spoolDir(o);
  mkdirSync(dir, { recursive: true });
  const stamped = { ...report, time: report.time ?? new Date().toISOString() };
  const name = `${String(Date.now()).padStart(15, "0")}-${process.pid}-${String(spoolSeq++).padStart(4, "0")}.json`;
  const tmp = join(dir, `.${name}`);
  writeFileSync(tmp, JSON.stringify(stamped) + "\n", "utf8");
  renameSync(tmp, join(dir, name));
  return join(dir, name);
}

/** Report an observation or a change. Never throws for an outage: an
 *  undelivered report is spooled. A refusal throws CmdbRefused. */
export function cmdbReport(report: CmdbReport, o: CmdbOptions = {}): ReportOutcome {
  // The time it happened, not the time it is delivered: a spooled report
  // carries the moment it was made.
  const stamped: CmdbReport = { ...report, time: report.time ?? new Date().toISOString() };
  try {
    if (spoolFiles(spoolDir(o)).length && replaySpool(o).left > 0) return { delivered: false, spooled: spool(stamped, o) };
    return { delivered: true, result: cmdbRequest("POST", "/v1/report", stamped, o) as Obj };
  } catch (e) {
    if (e instanceof CmdbUnavailable) return { delivered: false, spooled: spool(stamped, o) };
    throw e;
  }
}

export interface CmdbQuery {
  class?: string;
  physical?: boolean;
  recorded?: boolean;
  where?: Obj;
  at?: string;
  includeEnded?: boolean;
  limit?: number;
}

/** Objects of a class and its subclasses, by attribute, as of a time. */
export function cmdbQuery(query: CmdbQuery, o: CmdbOptions = {}): Obj[] {
  return cmdbRequest("POST", "/v1/query", query, o) as Obj[];
}

export interface CmdbRelationQuery {
  type?: string;
  from?: CmdbRef; // an id, a name, or class and name
  to?: CmdbRef;
  fromClass?: string; // the end's class, subclasses too
  toClass?: string;
  recorded?: boolean;
  at?: string;
  limit?: number;
}

/** Current relations (or as of a time) by type and either end. */
export function cmdbRelations(query: CmdbRelationQuery, o: CmdbOptions = {}): Obj[] {
  return cmdbRequest("POST", "/v1/relations", query, o) as Obj[];
}

/** One object by id or name (class-qualified where a name is not unique). */
export function cmdbShow(ref: string, opts: { class?: string; at?: string } = {}, o: CmdbOptions = {}): Obj {
  return cmdbRequest("GET", objectPath(ref, "", opts), undefined, o) as Obj;
}

export function objectPath(ref: string, sub: string, params: Record<string, string | number | undefined>): string {
  const qs = Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== "")
    .map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`)
    .join("&");
  return `/v1/objects/${encodeURIComponent(ref)}${sub ? `/${sub}` : ""}${qs ? `?${qs}` : ""}`;
}
