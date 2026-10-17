// server.ts — the console's HTTP surface (ADR-034): /api/v1 (typed reads, and
// from P2 the jobs: every change a manager verb run as a job, jobs.ts) and the
// built front end. Every connection is filtered on arrival (access.ts
// peerAllowed) and every request decided (access.ts decide) before any route
// runs; a job is authorized again as a write (access.ts mayWrite).

import { createServer, IncomingMessage, Server, ServerResponse } from "http";
import { existsSync, readFileSync, statSync } from "fs";
import { join } from "path";
import { AccessConfig, Decision, Me, SETUP_COOKIE, decide, normalizeAddr, peerAllowed, setupState } from "./access";
import { linesNaming } from "./activity";
import { attention, findingsFor, moduleSummaries } from "./badges";
import { Entry, envelope } from "./cache";
import { JumpKind, jumpsFor } from "./jumps";
import { Jobs, jobsNaming, summary } from "./jobs";
import { Manifests } from "./manifest";
import { MODULE_NAME, Reads } from "./reads";

export interface ServerConfig {
  access: AccessConfig;
  webDir: string | null;
  mgmtDomain: string;
  version: string;
  log: (line: string) => void;
}

const JSON_TYPE = "application/json; charset=utf-8";
const TYPES: Record<string, string> = {
  html: "text/html; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  css: "text/css; charset=utf-8",
  json: JSON_TYPE,
  svg: "image/svg+xml",
  png: "image/png",
  ico: "image/x-icon",
  woff2: "font/woff2",
  map: "application/json; charset=utf-8",
  txt: "text/plain; charset=utf-8",
};

const JUMP_KINDS = new Set<JumpKind>(["node", "module", "switch", "port", "lag", "ap", "zone", "peer", "site"]);

function securityHeaders(res: ServerResponse): void {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Frame-Options", "DENY");
  // React Flow positions its nodes with inline styles; scripts come from 'self' only.
  res.setHeader(
    "Content-Security-Policy",
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
  );
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const s = JSON.stringify(body);
  res.statusCode = status;
  res.setHeader("Content-Type", JSON_TYPE);
  res.setHeader("Cache-Control", "no-store");
  res.end(s);
}

function setupPage(reason: string): string {
  const esc = reason.replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" })[c] ?? c);
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TAPPaaS console</title>
<body style="font:15px system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;color:#1f2933">
<h1 style="font-size:1.3rem">TAPPaaS console</h1><p>${esc}</p>
<form method="get"><label>Setup token<br><input name="token" autocomplete="off" style="width:100%;font:inherit;padding:.4rem"></label>
<p><button style="font:inherit;padding:.4rem 1rem">Continue</button></p></form>
<p style="color:#52606d">bootstrap.sh printed the token in the install summary; it is in ~/config/console-setup-token on tappaas-cicd.</p></body>`;
}

export class ConsoleServer {
  private server: Server | null = null;
  readonly started = Date.now();
  // The verb manifests (manifest.ts), loaded once the console has started.
  manifests: Manifests | null = null;

  constructor(private readonly cfg: ServerConfig, private readonly reads: Reads, readonly jobs: Jobs | null = null) {}

  listen(host: string, port: number): Promise<Server> {
    return new Promise((resolve, reject) => {
      const s = createServer((req, res) => void this.handle(req, res));
      s.on("connection", (sock) => {
        const peer = normalizeAddr(sock.remoteAddress);
        if (!peerAllowed(peer, this.cfg.access, setupState(this.cfg.access))) {
          this.cfg.log(`refused connection from ${peer}`);
          sock.destroy();
        }
      });
      s.on("error", reject);
      s.listen(port, host, () => resolve(s));
      this.server = s;
    });
  }

  close(): void {
    this.server?.close();
  }

  async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    securityHeaders(res);
    const url = new URL(req.url ?? "/", "http://console.invalid");
    const path = url.pathname;
    const peer = normalizeAddr(req.socket.remoteAddress);
    const setup = setupState(this.cfg.access);
    const d: Decision = decide(peer, req.headers, url.searchParams.get("token"), this.cfg.access, setup);
    try {
      if (!d.ok) {
        if (path.startsWith("/api/")) return sendJson(res, d.status, { error: d.reason });
        res.statusCode = d.status;
        res.setHeader("Content-Type", TYPES.html);
        res.end(setupPage(d.reason));
        return;
      }
      // A token given on the address line becomes the session cookie, and the
      // address line loses it.
      if (d.me.via === "setup-token" && url.searchParams.get("token") && !path.startsWith("/api/")) {
        res.statusCode = 302;
        res.setHeader("Set-Cookie", `${SETUP_COOKIE}=${encodeURIComponent(url.searchParams.get("token") ?? "")}; Path=/; HttpOnly; SameSite=Strict`);
        res.setHeader("Location", path);
        res.end();
        return;
      }
      if (path.startsWith("/api/")) return await this.api(req.method ?? "GET", path, url, d.me, res, req);
      return this.serveStatic(path, res);
    } catch (e) {
      this.cfg.log(`${req.method} ${path}: ${(e as Error).message}`);
      if (!res.headersSent) sendJson(res, 500, { error: (e as Error).message });
    }
  }

  private async api(method: string, path: string, url: URL, me: Me, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    const r = this.reads;
    const parts = path.replace(/\/+$/, "").split("/").slice(3).map((p) => decodeURIComponent(p)); // after /api/v1
    if (!path.startsWith("/api/v1/")) return sendJson(res, 404, { error: "unknown API version" });
    const [head, a, b] = parts;

    if (method === "POST" && head === "refresh" && parts.length === 1) {
      // Refreshes the console's own cache: it changes nothing on the site.
      const what = url.searchParams.get("what") ?? "all";
      if (what !== "all" && !r.timed().some((c) => c.name === what)) return sendJson(res, 400, { error: `unknown read '${what}'` });
      r.refresh(what).catch((e: Error) => this.cfg.log(`refresh ${what}: ${e.message}`));
      return sendJson(res, 202, { refreshing: what });
    }
    if (head === "jobs") return this.jobsApi(method, a, b, me, res, req);
    if (method !== "GET") return sendJson(res, 405, { error: `${method} /api/v1/${head ?? ""}: reads are GET; a change is a job (POST /api/v1/jobs)` });

    const env = <T>(e: Entry<T>, data?: unknown): Record<string, unknown> => ({ ...envelope(e), ...(data !== undefined ? { data } : {}) });

    switch (head) {
      case "manifests": {
        const ms = this.manifests;
        if (!ms) return sendJson(res, 503, { error: "the verb manifests are still loading" });
        return sendJson(res, 200, { data: { loadedAt: ms.loadedAt, errors: ms.errors, manifests: [...ms.byBin.values()] } });
      }
      case "me":
        return sendJson(res, 200, { data: me });
      case "status": {
        const s = setupState(this.cfg.access);
        return sendJson(res, 200, {
          data: {
            version: this.cfg.version,
            started: new Date(this.started).toISOString(),
            setup: { tokenActive: s.active, identityInstalled: s.identityInstalled },
            reads: r.timed().map((c) => {
              const p = c.peek();
              return { name: c.name, at: p.at === null ? null : new Date(p.at).toISOString(), error: p.error, refreshing: p.loading, ttlSeconds: c.ttlMs / 1000 };
            }),
          },
        });
      }
      case "health": {
        const h = await r.health.get();
        return sendJson(res, 200, env(h, h.value ? { ...h.value, attention: attention(h.value) } : null));
      }
      case "gates": {
        const h = await r.health.get();
        return sendJson(res, 200, env(h, h.value?.gates ?? null));
      }
      case "pulse": {
        const [h, p] = await Promise.all([r.health.get(), r.peers.get()]);
        const gate = h.value?.gates.find((g) => g.name === "pulse") ?? null;
        return sendJson(res, 200, { ...envelope(h), data: { gate, peers: p.value, peersError: p.error } });
      }
      case "site":
        return sendJson(res, 200, envelope(await r.site.get()));
      case "zones":
        return sendJson(res, 200, envelope(await r.zones.get()));
      case "environments":
        return sendJson(res, 200, envelope(await r.environments.get()));
      case "topology":
        return sendJson(res, 200, envelope(await r.topology.get()));
      case "security":
        return sendJson(res, 200, envelope(await r.security.get()));
      case "activity": {
        // The sweep's journal and the console's own jobs, side by side.
        const act = await r.activity.get();
        const mod = url.searchParams.get("module");
        const jobs = this.jobs ? this.jobs.list() : [];
        if (mod && act.value) return sendJson(res, 200, env(act, { module: mod, lines: linesNaming(act.value.runs, mod), jobs: jobsNaming(jobs, mod) }));
        return sendJson(res, 200, { ...envelope(act), jobs });
      }
      case "modules":
        return this.modules(a, b, url, res);
      case "jumps": {
        if (!a || !JUMP_KINDS.has(a as JumpKind) || !b) return sendJson(res, 400, { error: "jumps/<kind>/<id>" });
        // The status route's zones reach none of the component UIs (D2).
        if (me.route === "status") return sendJson(res, 200, { data: [] });
        // The topology as it stands: a jump never waits for its first read.
        const [m, e] = await Promise.all([r.modules.get(), r.environments.get()]);
        const data = jumpsFor(a as JumpKind, b, {
          topology: r.topology.peek().value,
          modules: m.value?.modules ?? [],
          environments: e.value ?? [],
          mgmtDomain: this.cfg.mgmtDomain,
          pbsStore: "tappaas_backup",
        }, url.searchParams.get("switch") ?? undefined);
        return sendJson(res, 200, { data });
      }
      default:
        return sendJson(res, 404, { error: `no read '${head ?? ""}'` });
    }
  }

  private async modules(name: string | undefined, sub: string | undefined, url: URL, res: ServerResponse): Promise<void> {
    const r = this.reads;
    const [m, h, bk] = await Promise.all([r.modules.get(), r.health.get(), r.backup.get()]);
    const list = moduleSummaries(m.value?.modules ?? [], h.value, bk.value);
    if (!name) return sendJson(res, 200, { ...envelope(m), data: m.value ? list : null, orphans: m.value?.orphans ?? [], healthAt: envelope(h).at });
    // Only a module the list names reaches a manager's argv.
    if (!MODULE_NAME.test(name)) return sendJson(res, 400, { error: "not a module name" });
    const summary = list.find((x) => x.name === name);
    if (!summary) return sendJson(res, 404, { error: `no deployed module '${name}'` });
    if (sub === "drift") {
      const c = r.moduleDrift.of(name);
      if (url.searchParams.get("refresh") === "1") await c.refresh();
      return sendJson(res, 200, envelope(await c.get()));
    }
    if (sub !== undefined) return sendJson(res, 404, { error: `modules/${name}/${sub}` });
    const [show, resolve, backup, act] = await Promise.all([
      r.moduleShow.of(name).get(),
      r.moduleResolve.of(name).get(),
      summary.vmid !== null ? r.moduleBackup.of(name).get() : Promise.resolve(null),
      r.activity.get(),
    ]);
    return sendJson(res, 200, {
      ...envelope(m),
      data: {
        summary,
        findings: findingsFor(h.value, name),
        show: envelope(show),
        resolve: envelope(resolve),
        backup: backup ? envelope(backup) : null,
        activity: act.value ? linesNaming(act.value.runs, name) : null,
        jobs: this.jobs ? jobsNaming(this.jobs.list(), name) : [],
      },
    });
  }

  // ── jobs (ADR-034 D4) ─────────────────────────────────────────────
  //   GET  /jobs                 every job, newest first, and the queue
  //   POST /jobs {argv, preview}  a preview (or a read); a write never starts here
  //   POST /jobs/<id>/apply {confirm?}  the preview's argv with its applying flag
  //   GET  /jobs/<id>            the job with its output; as text/event-stream,
  //                              the output as it comes (server-sent events)
  private async jobsApi(method: string, id: string | undefined, sub: string | undefined, me: Me, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    const jobs = this.jobs;
    if (!jobs) return sendJson(res, 503, { error: "this console runs no jobs" });
    if (method === "GET" && !id) {
      return sendJson(res, 200, { data: { jobs: jobs.list(), queue: jobs.queued(), sweep: await jobs.sweep() } });
    }
    if (method === "GET" && id && !sub) {
      const job = jobs.get(id);
      if (!job) return sendJson(res, 404, { error: `no job ${id}` });
      const accept = req ? String(req.headers["accept"] ?? "") : "";
      if (!accept.includes("text/event-stream") || !req) return sendJson(res, 200, { data: job });
      return this.streamJob(id, req, res);
    }
    if (method !== "POST") return sendJson(res, 405, { error: "jobs: GET or POST" });
    // A write must be JSON: a cross-site form cannot send that without CORS.
    const ctype = req ? String(req.headers["content-type"] ?? "") : "";
    if (!/^application\/json\b/i.test(ctype)) return sendJson(res, 415, { error: "a job is posted as application/json" });
    let body: Record<string, unknown>;
    try {
      body = req ? await readJsonBody(req) : {};
    } catch (e) {
      return sendJson(res, 400, { error: (e as Error).message });
    }
    const setup = setupState(this.cfg.access);
    let r;
    if (!id) r = await jobs.create(me, setup, { argv: body.argv, preview: body.preview });
    else if (sub === "apply") r = await jobs.applyPreview(me, setup, id, { confirm: body.confirm });
    else return sendJson(res, 404, { error: `jobs/${id}/${sub ?? ""}` });
    if (r.job) this.cfg.log(`job ${r.job.id} ${r.job.kind} ${r.job.state}${r.job.refused ? ` (${r.job.refused})` : ""}: ${r.job.argv.join(" ")}`);
    if (r.status >= 400) return sendJson(res, r.status, { error: r.error, ...(r.job ? { data: summary(r.job) } : {}), ...(r.sweep ? { sweep: r.sweep } : {}) });
    return sendJson(res, r.status, { data: r.job });
  }

  private streamJob(id: string, req: IncomingMessage, res: ServerResponse): void {
    const jobs = this.jobs!;
    const job = jobs.get(id)!;
    res.statusCode = 200;
    res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Accel-Buffering", "no");
    const send = (event: string, data: unknown): void => {
      res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    };
    // What has been said so far, then what follows.
    send("job", job);
    if (job.state === "done" || job.state === "refused") {
      send("end", summary(job));
      res.end();
      return;
    }
    const off = jobs.subscribe(id, (ev) => {
      if (ev.type === "output") send("output", ev.chunk);
      else if (ev.type === "state") send("state", ev.job);
      else {
        send("end", ev.job);
        off();
        res.end();
      }
    });
    req.on("close", () => off());
  }

  private serveStatic(path: string, res: ServerResponse): void {
    const web = this.cfg.webDir;
    if (!web || !existsSync(join(web, "index.html"))) {
      res.statusCode = 503;
      res.setHeader("Content-Type", TYPES.txt);
      res.end("The console's front end is not built; the API is at /api/v1/.");
      return;
    }
    const segs = path.split("/").filter((s) => s.length > 0).map((s) => decodeURIComponent(s));
    if (segs.some((s) => s === ".." || s === "." || s.includes("/") || s.includes("\\") || s.includes("\u0000"))) {
      res.statusCode = 400;
      res.end();
      return;
    }
    let file = segs.length ? join(web, ...segs) : join(web, "index.html");
    const isFile = (f: string): boolean => {
      try {
        return statSync(f).isFile();
      } catch {
        return false;
      }
    };
    // Client-side routes (/modules/immich) are the SPA's: answer index.html.
    if (!isFile(file)) {
      if (/\.[a-z0-9]+$/i.test(segs[segs.length - 1] ?? "")) {
        res.statusCode = 404;
        res.end();
        return;
      }
      file = join(web, "index.html");
    }
    const ext = (/\.([a-z0-9]+)$/i.exec(file)?.[1] ?? "").toLowerCase();
    res.statusCode = 200;
    res.setHeader("Content-Type", TYPES[ext] ?? "application/octet-stream");
    // Vite's assets carry a content hash in their names; the page itself does not.
    res.setHeader("Cache-Control", segs[0] === "assets" ? "public, max-age=31536000, immutable" : "no-cache");
    res.end(readFileSync(file));
  }
}

// A request's JSON body, at most 64 KiB.
export function readJsonBody(req: IncomingMessage, limit = 64 * 1024): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const parts: NodeBuffer[] = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size <= limit) parts.push(c);
    });
    req.on("error", (e) => reject(e));
    req.on("end", () => {
      if (size > limit) return reject(new Error("the body is larger than 64 KiB"));
      const text = Buffer.concat(parts).toString("utf8").trim();
      if (!text) return resolve({});
      try {
        const v = JSON.parse(text) as unknown;
        if (v === null || typeof v !== "object" || Array.isArray(v)) return reject(new Error("the body is not a JSON object"));
        resolve(v as Record<string, unknown>);
      } catch {
        reject(new Error("the body is not JSON"));
      }
    });
  });
}
