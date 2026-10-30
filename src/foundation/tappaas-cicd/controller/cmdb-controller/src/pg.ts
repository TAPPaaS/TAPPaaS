// pg.ts — the smallest PostgreSQL client cmdb-controller needs: one
// connection over the server's Unix socket, peer (or trust) authentication,
// the extended protocol for parameterised statements and the simple one for
// the schema file. TAPPaaS's TypeScript builds without npm dependencies
// (lib/nix/ts-manager.nix), so this is the wire protocol (PostgreSQL docs,
// "Frontend/Backend Protocol", v3.0) for exactly what the controller uses —
// text formats only, no password authentication, no COPY.
//
// One connection, one statement at a time: query() and tx() queue on a lock,
// and a transaction holds it from BEGIN to COMMIT. The controller is the only
// writer and its batches are small; a pool would buy nothing.

import { createConnection, Socket } from "net";

export class PgError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly detail?: string,
    readonly constraint?: string,
  ) {
    super(message);
  }
}

export type Row = Record<string, unknown>;
export interface Result {
  rows: Row[];
  rowCount: number;
}
export type Param = string | number | boolean | null | undefined | object;
export type Query = (sql: string, params?: Param[]) => Promise<Result>;

interface Field {
  name: string;
  type: number;
}

// What one round trip collects until ReadyForQuery.
interface Pending {
  fields: Field[];
  rows: Row[];
  rowCount: number;
  error: PgError | null;
  done: (r: Result | PgError) => void;
}

const ZERO = 0;

function cstr(s: string): NodeBuffer {
  return Buffer.concat([Buffer.from(s, "utf8"), Buffer.alloc(1)]);
}

function int32(n: number): NodeBuffer {
  const b = Buffer.alloc(4);
  b.writeInt32BE(n, 0);
  return b;
}

function int16(n: number): NodeBuffer {
  const b = Buffer.alloc(2);
  b.writeInt16BE(n, 0);
  return b;
}

// A typed message: its tag, then its length (counting itself, not the tag).
function message(tag: string, ...parts: NodeBuffer[]): NodeBuffer {
  const body = Buffer.concat(parts);
  return Buffer.concat([Buffer.from(tag, "utf8"), int32(body.length + 4), body]);
}

function encodeParam(v: Param): NodeBuffer {
  if (v === null || v === undefined) return int32(-1);
  let s: string;
  if (typeof v === "string") s = v;
  else if (typeof v === "number") s = String(v);
  else if (typeof v === "boolean") s = v ? "t" : "f";
  else if (v instanceof Date) s = v.toISOString();
  else s = JSON.stringify(v); // a jsonb parameter, cast in the SQL ($1::jsonb)
  const b = Buffer.from(s, "utf8");
  return Buffer.concat([int32(b.length), b]);
}

// PostgreSQL's text output for timestamptz ('2026-10-29 10:00:00.123+00') as ISO 8601.
function isoTime(s: string): string {
  const t = s.replace(" ", "T").replace(/([+-]\d\d)$/, "$1:00");
  const d = new Date(t);
  return Number.isNaN(d.getTime()) ? s : d.toISOString();
}

function decode(type: number, s: string): unknown {
  switch (type) {
    case 16: // bool
      return s === "t";
    case 20: // int8
    case 21: // int2
    case 23: // int4
    case 26: // oid
    case 700: // float4
    case 701: // float8
    case 1700: // numeric
      return Number(s);
    case 114: // json
    case 3802: // jsonb
      return JSON.parse(s);
    case 1184: // timestamptz
      return isoTime(s);
    default:
      return s;
  }
}

export interface PgConfig {
  socketDir: string; // the directory holding .s.PGSQL.<port>
  port: number;
  database: string;
  user: string;
}

export class Pg {
  private sock: Socket | null = null;
  private buf: NodeBuffer = Buffer.alloc(0);
  private queue: Pending[] = [];
  private lock: Promise<unknown> = Promise.resolve();
  private startup: { ok: () => void; fail: (e: Error) => void } | null = null;
  closed = false;
  // Called once when the server ends the connection (cmdb-controller exits,
  // and systemd starts it again).
  onClose: (() => void) | null = null;

  constructor(private readonly cfg: PgConfig) {}

  connect(): Promise<void> {
    const path = `${this.cfg.socketDir}/.s.PGSQL.${this.cfg.port}`;
    return new Promise((resolve, reject) => {
      const sock = createConnection(path);
      this.sock = sock;
      this.startup = { ok: resolve, fail: reject };
      sock.once("error", (e) => {
        if (this.startup) {
          this.startup = null;
          reject(new Error(`cannot reach PostgreSQL at ${path}: ${e.message}`));
        }
      });
      sock.once("connect", () => {
        const params = Buffer.concat([
          cstr("user"), cstr(this.cfg.user),
          cstr("database"), cstr(this.cfg.database),
          cstr("application_name"), cstr("cmdb-controller"),
          cstr("TimeZone"), cstr("UTC"),
          Buffer.alloc(1),
        ]);
        const body = Buffer.concat([int32(196608), params]); // protocol 3.0
        sock.write(Buffer.concat([int32(body.length + 4), body]));
      });
      sock.on("data", (chunk) => this.onData(chunk));
      sock.on("close", () => {
        this.closed = true;
        const err = new PgError("the PostgreSQL connection closed", "08006");
        for (const p of this.queue.splice(0)) p.done(err);
        if (this.startup) {
          this.startup.fail(err);
          this.startup = null;
        } else this.onClose?.();
      });
    });
  }

  close(): void {
    this.onClose = null;
    if (this.sock && !this.closed) {
      this.sock.write(message("X"));
      this.sock.end();
    }
    this.closed = true;
  }

  private onData(chunk: NodeBuffer): void {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    while (this.buf.length >= 5) {
      const len = this.buf.readInt32BE(1);
      if (this.buf.length < len + 1) break;
      const tag = String.fromCharCode(this.buf[0]);
      const body = this.buf.subarray(5, len + 1);
      this.buf = this.buf.subarray(len + 1);
      this.onMessage(tag, body);
    }
  }

  private onMessage(tag: string, body: NodeBuffer): void {
    const p = this.queue[0];
    switch (tag) {
      case "R": {
        const code = body.readInt32BE(0);
        if (code !== 0 && this.startup) {
          this.startup.fail(new Error(`PostgreSQL asks for authentication method ${code}; cmdb-controller uses peer authentication on the socket only`));
          this.startup = null;
          this.sock?.destroy();
        }
        return;
      }
      case "S": // ParameterStatus
      case "K": // BackendKeyData
      case "N": // NoticeResponse
      case "A": // NotificationResponse
      case "1": // ParseComplete
      case "2": // BindComplete
      case "n": // NoData
      case "I": // EmptyQueryResponse
      case "s": // PortalSuspended
        return;
      case "T": {
        if (!p) return;
        const n = body.readInt16BE(0);
        let off = 2;
        p.fields = [];
        for (let i = 0; i < n; i++) {
          const end = body.indexOf(ZERO, off);
          const name = body.toString("utf8", off, end);
          off = end + 1;
          const type = body.readInt32BE(off + 6);
          off += 18;
          p.fields.push({ name, type });
        }
        return;
      }
      case "D": {
        if (!p) return;
        const n = body.readInt16BE(0);
        let off = 2;
        const row: Row = {};
        for (let i = 0; i < n; i++) {
          const len = body.readInt32BE(off);
          off += 4;
          const f = p.fields[i];
          if (len < 0) row[f.name] = null;
          else {
            row[f.name] = decode(f.type, body.toString("utf8", off, off + len));
            off += len;
          }
        }
        p.rows.push(row);
        return;
      }
      case "C": {
        if (!p) return;
        const tagText = body.toString("utf8", 0, body.length - 1);
        const m = /(\d+)$/.exec(tagText);
        p.rowCount += m ? Number(m[1]) : 0;
        return;
      }
      case "E": {
        const f: Record<string, string> = {};
        let off = 0;
        while (off < body.length && body[off] !== 0) {
          const code = String.fromCharCode(body[off]);
          const end = body.indexOf(ZERO, off + 1);
          f[code] = body.toString("utf8", off + 1, end);
          off = end + 1;
        }
        const err = new PgError(f.M ?? "PostgreSQL error", f.C ?? "", f.D, f.n);
        if (this.startup) {
          this.startup.fail(err);
          this.startup = null;
        } else if (p) p.error = err;
        return;
      }
      case "Z": {
        if (this.startup) {
          this.startup.ok();
          this.startup = null;
          return;
        }
        const done = this.queue.shift();
        if (done) done.done(done.error ?? { rows: done.rows, rowCount: done.rowCount });
        return;
      }
      default:
        return;
    }
  }

  // One round trip: the messages, then everything up to ReadyForQuery.
  private send(msgs: NodeBuffer): Promise<Result> {
    if (!this.sock || this.closed) return Promise.reject(new PgError("not connected to PostgreSQL", "08003"));
    return new Promise((resolve, reject) => {
      this.queue.push({
        fields: [],
        rows: [],
        rowCount: 0,
        error: null,
        done: (r) => (r instanceof PgError ? reject(r) : resolve(r)),
      });
      this.sock!.write(msgs);
    });
  }

  // A parameterised statement, unlocked: for use inside tx().
  private raw(sql: string, params: Param[] = []): Promise<Result> {
    return this.send(
      Buffer.concat([
        message("P", cstr(""), cstr(sql), int16(0)),
        message("B", cstr(""), cstr(""), int16(0), int16(params.length), ...params.map(encodeParam), int16(0)),
        message("D", Buffer.from("P", "utf8"), cstr("")),
        message("E", cstr(""), int32(0)),
        message("S"),
      ]),
    );
  }

  private exclusive<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.lock.then(fn, fn);
    this.lock = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  query(sql: string, params: Param[] = []): Promise<Result> {
    return this.exclusive(() => this.raw(sql, params));
  }

  // Several statements in one string (the schema file), no parameters.
  script(sql: string): Promise<Result> {
    return this.exclusive(() => this.send(message("Q", cstr(sql))));
  }

  // fn's statements in one transaction: committed when it resolves, rolled
  // back when it throws.
  tx<T>(fn: (q: Query) => Promise<T>): Promise<T> {
    return this.exclusive(async () => {
      await this.raw("BEGIN");
      try {
        const out = await fn((sql, params) => this.raw(sql, params));
        await this.raw("COMMIT");
        return out;
      } catch (e) {
        await this.raw("ROLLBACK").catch(() => undefined);
        throw e;
      }
    });
  }
}
