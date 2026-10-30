// server.ts — cmdb-controller's one API (ADR-040 D2): HTTP/JSON on a Unix
// socket for the managers and the bash layer on the same host (the socket's
// file permissions decide who may call), and on loopback with a bearer token
// for the console and the agents behind it. Both serve the same routes.
//
//   GET  /v1/health                        the store answers; counts
//   POST /v1/report                        observations and changes, in a batch
//   POST /v1/query                         by class (and subclasses), physical, attributes, at
//   POST /v1/relations                     by type, either end, classes, recorded, at
//   GET  /v1/objects/<id|name>[?class=&at=]          show
//   GET  /v1/objects/<id|name>/history[?class=&at=]  every period; or as of a time
//   GET  /v1/objects/<id|name>/impact[?hops=&direction=]
//   POST /v1/resolve                       OpenTelemetry resource attributes → object
//   POST /v1/rescan                        ask every cmdbSource component to report again
//   GET  /v1/classes, /v1/classes/<name>   the metamodel
//   GET  /v1/stream                        server-sent events, one per change
//
// Every answer is { ok: true, data } or { ok: false, error, ... }.

import { createServer, IncomingMessage, Server, ServerResponse } from "http";
import { timingSafeEqual } from "crypto";
import { ChangeEvent, HttpError, ReportError, Store } from "./store";
import { rescan } from "./rescan";
import { PgError } from "./pg";

const JSON_TYPE = "application/json; charset=utf-8";
const MAX_BODY = 16 * 1024 * 1024;

type Obj = Record<string, unknown>;

export interface ServeOptions {
  store: Store;
  token: string | null; // required on the loopback listener; never on the socket
  log: (line: string) => void;
}

function send(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader("Content-Type", JSON_TYPE);
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

function readBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: NodeBuffer[] = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new HttpError(413, "the body is larger than 16 MiB"));
        req.socket.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      if (!text.trim()) return resolve({});
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new HttpError(400, "the body is not JSON"));
      }
    });
    req.on("error", reject);
  });
}

function authorized(req: IncomingMessage, token: string): boolean {
  const h = req.headers.authorization;
  const given = typeof h === "string" && h.startsWith("Bearer ") ? h.slice(7).trim() : "";
  const a = Buffer.from(given, "utf8");
  const b = Buffer.from(token, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}

export class Api {
  private streams = new Set<ServerResponse>();
  private heartbeat: unknown = null;

  constructor(private readonly o: ServeOptions) {
    o.store.onChange((e) => this.publish(e));
  }

  private publish(e: ChangeEvent): void {
    const frame = `id: ${e.id}\nevent: change\ndata: ${JSON.stringify(e)}\n\n`;
    for (const res of this.streams) res.write(frame);
  }

  /** A listener: on the socket (no token) or on loopback (the token). */
  server(requireToken: boolean): Server {
    if (!this.heartbeat) {
      this.heartbeat = setInterval(() => {
        for (const res of this.streams) res.write(": keepalive\n\n");
      }, 30000);
    }
    return createServer((req, res) => {
      if (requireToken && (!this.o.token || !authorized(req, this.o.token))) {
        return send(res, 401, { ok: false, error: "a bearer token is required on this listener" });
      }
      this.route(req, res).catch((e) => this.fail(res, e));
    });
  }

  close(): void {
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const res of this.streams) res.end();
    this.streams.clear();
  }

  private fail(res: ServerResponse, e: unknown): void {
    if (res.headersSent) return res.end();
    if (e instanceof ReportError) return send(res, e.status, { ok: false, error: "report refused", problems: e.problems });
    if (e instanceof HttpError) return send(res, e.status, { ok: false, error: e.message, ...(e.extra ?? {}) });
    if (e instanceof PgError) {
      this.o.log(`store error ${e.code}: ${e.message}${e.detail ? ` (${e.detail})` : ""}`);
      // An exclusion constraint (23P01) or a unique one (23505): two writers
      // raced to one period; the reporter may retry.
      const status = e.code === "23P01" || e.code === "23505" ? 409 : 503;
      return send(res, status, { ok: false, error: `store: ${e.message}`, code: e.code });
    }
    this.o.log(`error: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
    send(res, 500, { ok: false, error: e instanceof Error ? e.message : String(e) });
  }

  private async route(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://cmdb");
    const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
    const method = req.method ?? "GET";
    const s = this.o.store;
    const q = (k: string): string | null => url.searchParams.get(k);
    if (parts[0] !== "v1") throw new HttpError(404, `no route ${url.pathname}`);
    const [, what, ref, sub] = parts;

    if (method === "GET" && what === "health" && !ref) {
      return send(res, 200, { ok: true, data: { schema: 3, ...(await s.counts()) } });
    }
    if (method === "POST" && what === "report" && !ref) {
      const body = await readBody(req);
      const r = await s.report(body as never);
      if (r.change !== null) this.o.log(`report ${r.change} from ${String((body as Obj).source)}: ${r.objects.length} object(s), ${r.relations.length} relation(s)`);
      return send(res, 200, { ok: true, data: r });
    }
    if (method === "POST" && what === "query" && !ref) {
      const body = await readBody(req);
      return send(res, 200, { ok: true, data: await s.query((body ?? {}) as Obj) });
    }
    if (method === "POST" && what === "relations" && !ref) {
      const body = await readBody(req);
      return send(res, 200, { ok: true, data: await s.relations((body ?? {}) as Obj) });
    }
    if (method === "GET" && what === "objects" && ref) {
      const at = q("at");
      if (at !== null && Number.isNaN(Date.parse(at))) throw new HttpError(400, `at ${at} is not a date`);
      const atIso = at === null ? null : new Date(at).toISOString();
      if (!sub) return send(res, 200, { ok: true, data: await s.show(ref, q("class"), atIso) });
      if (sub === "history") return send(res, 200, { ok: true, data: await s.history(ref, q("class"), atIso) });
      if (sub === "impact") {
        return send(res, 200, { ok: true, data: await s.impact(ref, q("class"), Number(q("hops") ?? "2"), q("direction") ?? "both") });
      }
    }
    if (method === "POST" && what === "resolve" && !ref) {
      const body = (await readBody(req)) as Obj;
      return send(res, 200, { ok: true, data: await s.resolve((body.attributes ?? body) as Obj) });
    }
    if (method === "POST" && what === "rescan" && !ref) {
      return send(res, 200, { ok: true, data: await rescan(this.o.log) });
    }
    if (method === "GET" && what === "classes") {
      return send(res, 200, { ok: true, data: ref ? s.classInfo(ref) : s.classes() });
    }
    if (method === "GET" && what === "stream" && !ref) {
      res.statusCode = 200;
      res.setHeader("Content-Type", "text/event-stream");
      res.setHeader("Cache-Control", "no-store");
      res.setHeader("Connection", "keep-alive");
      res.flushHeaders();
      res.write(": cmdb change stream\n\n");
      this.streams.add(res);
      res.on("close", () => this.streams.delete(res));
      return;
    }
    throw new HttpError(404, `no route ${method} ${url.pathname}`);
  }
}
