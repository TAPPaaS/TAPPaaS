// server.ts — the console's HTTP surface (ADR-034): /api/v1 (typed reads, and
// from P2 the jobs: every change a manager verb run as a job, jobs.ts) and the
// built front end. Every connection is filtered on arrival (access.ts
// peerAllowed) and every request decided (access.ts decide) before any route
// runs; a job is authorized again as a write (access.ts mayWrite).

import { createServer, IncomingMessage, Server, ServerResponse } from "http";
import { existsSync, readFileSync, statSync } from "fs";
import { join } from "path";
import { AccessConfig, Decision, Me, SETUP_COOKIE, addrMatches, decide, mayWrite, normalizeAddr, peerAllowed, routeHost, setupState } from "./access";
import { linesNaming } from "./activity";
import { attention, findingsFor, moduleSummaries, withConditions } from "./badges";
import { securityView } from "./security";
import { ThreatRow, threatsView } from "./threats";
import { Entry, envelope } from "./cache";
import { SCHEMAS } from "./fields";
import { HealthGraph, TREE_FACETS, filteredCounts, healthEgo, healthPath, healthSummary, healthTree, moduleHealth, treeChildren, treePath, treeSearch } from "./health";
import { operationsDoc } from "./openevents";
import { HealthLive } from "./healthlive";
import { Perf, isRange } from "./perf";
import { JumpKind, ObjectLogs, jumpsFor, objectLogs } from "./jumps";
import { Assistant, AssistantEvent } from "./assistant";
import { LiteLLM } from "./litellm";
import { CreateResult, JobSummary, Jobs, jobsNaming, summary } from "./jobs";
import { Manifests } from "./manifest";
import { MODULE_NAME, NODE_NAME, OBJECT_NAME, Reads } from "./reads";
import { ownerSummary, readConfigs } from "./owner";
import { SECRETS, isSecretName, secretCommand, secretStatus, writeSecret } from "./secrets";
import { StdinRunner, jobEnv, runWithStdin } from "./run";
import { closeSetupToken, recordSetupAnswer, setupCheckModules, setupComplete, setupSteps } from "./setup";
import { FIELD_KINDS, FieldKind } from "./fieldmanifest";

export interface ServerConfig {
  access: AccessConfig;
  webDir: string | null;
  mgmtDomain: string;
  version: string;
  log: (line: string) => void;
  home?: string; // where the Setup wizard's credential files go (secrets.ts)
  runStdin?: StdinRunner; // the verb that takes a secret on stdin (wlan: ap-manager ssid set-passphrase)
  litellm?: LiteLLM | null; // the assistant's LiteLLM (ADR-034 D7); absent: no assistant
  assistant?: Assistant | null; // its agent loop (assistant.ts)
  healthLive?: HealthLive | null; // the health document's freshness and live feed (healthlive.ts)
  perf?: Perf | null; // the performance reads (perf.ts, ADR-046 D7); absent: no Performance menu data
  onSetupClosed?: () => void; // the setup token is gone: close the install-LAN way in
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

// A CMDB object's id, the only thing of a request that reaches its API.
const OBJECT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// A health record's id: <origin>.<kind>.<name>.
const RULE_ID = /^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9_-]*)+$/;
const CI_NAME = /^[^\x00-\x1f]{1,200}$/; // an object's name: a module, an asset tag, <device>:<port>
const CLASS_NAME = /^[a-z][a-z0-9-]{0,63}$/;
const ASSET_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/; // an asset's own name: srv-01, dsk-03

const JUMP_KINDS = new Set<JumpKind>(["node", "module", "switch", "port", "lag", "ap", "zone", "peer", "site", "disk", "pool"]);

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

// The refusal page; it asks for the setup token only while setup is open.
function setupPage(reason: string, askToken: boolean): string {
  const esc = reason.replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" })[c] ?? c);
  return `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TAPPaaS console</title>
<body style="font:15px system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;color:#1f2933">
<h1 style="font-size:1.3rem">TAPPaaS console</h1><p>${esc}</p>${askToken ? `
<form method="get"><label>Setup token<br><input name="token" autocomplete="off" style="width:100%;font:inherit;padding:.4rem"></label>
<p><button style="font:inherit;padding:.4rem 1rem">Continue</button></p></form>
<p style="color:#52606d">The token is in ~/config/console-setup-token on tappaas-cicd (read it with cat); it is never printed.</p>` : ""}</body>`;
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
        if (!peerAllowed(peer, this.cfg.access)) {
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
    let path = req.url ?? "/";
    // Everything a request can make throw is inside the try: an error that
    // escapes handle() is an unhandled rejection, and that ends the process.
    try {
      const url = new URL(req.url ?? "/", "http://console.invalid");
      path = url.pathname;
      const peer = normalizeAddr(req.socket.remoteAddress);
      const setup = setupState(this.cfg.access);
      const gate = this.cfg.access.gate;
      if (gate && this.cfg.access.firewall.some((f) => addrMatches(peer, f))) await gate.ensure(routeHost(req.headers, true) ?? "");
      const d: Decision = decide(peer, req.headers, url.searchParams.get("token"), this.cfg.access, setup);
      if (!d.ok) {
        if (d.forget) gate?.forget(d.forget);
        if (path.startsWith("/api/")) return sendJson(res, d.status, { error: d.reason });
        res.statusCode = d.status;
        res.setHeader("Content-Type", TYPES.html);
        res.end(setupPage(d.reason, setup.active));
        return;
      }
      // A real sign-in through the gate ends setup (D10): the route, a user in
      // the group and the way in all work, so the token is no longer needed.
      if (d.me.via === "gate" && setup.tokenPresent && this.cfg.access.firewall.some((f) => addrMatches(peer, f)) && closeSetupToken(this.cfg.access, this.cfg.log)) this.cfg.onSetupClosed?.();
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
    if (head === "jobs") return this.jobsApi(method, a, b, me, res, req, url);
    if (head === "secrets") return this.secretsApi(method, a, me, res, req);
    if (head === "setup" && a === "check") return this.setupCheck(method, me, res, req);
    if (head === "setup" && a === "answer") return this.setupAnswer(method, me, res, req);
    if (head === "assistant") return this.assistantApi(method, a, b, me, res, req);
    if (head === "assets" && a === "sweep" && parts.length === 2) return this.sweepApi(method, me, res, req);
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
      case "cmdb":
        return this.cmdbApi(a, b, parts[3], parts.length, url, res);
      case "performance":
        return this.perfApi(a, b, parts.length, url, res);
      case "health": {
        if (a !== undefined) return this.healthApi(a, b, parts[3], parts.length, url, res, req);
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
      case "ipv6":
        return sendJson(res, 200, envelope(await r.ipv6.get()));
      case "aps":
        return sendJson(res, 200, envelope(await r.aps.get()));
      case "ssids":
        return sendJson(res, 200, envelope(await r.ssids.get()));
      case "media":
        return sendJson(res, 200, envelope(await r.media.get()));
      case "environments":
        return sendJson(res, 200, envelope(await r.environments.get()));
      case "identity":
        if (a === "records") return sendJson(res, 200, envelope(await r.identityRecords.get()));
        if (a !== undefined) return sendJson(res, 404, { error: `identity/${a}` });
        return sendJson(res, 200, envelope(await r.identity.get()));
      case "nodes": {
        // A node being added: GET nodes/<name>/progress, every ten seconds at
        // most; nodes/<name>/usb: the USB sticks in it (site-manager node usb);
        // nodes/<name>/network: its ports and uplinks (node network show).
        if (!a || !NODE_NAME.test(a) || (b !== "progress" && b !== "usb" && b !== "network")) return sendJson(res, 404, { error: "nodes/<name>/progress | nodes/<name>/usb | nodes/<name>/network" });
        if (b === "usb") return sendJson(res, 200, envelope(await r.nodeUsb.of(a).get()));
        if (b === "network") return sendJson(res, 200, envelope(await r.nodeNetwork.of(a).get()));
        return sendJson(res, 200, envelope(await r.nodeProgress.of(a).get()));
      }
      case "catalogs":
        return sendJson(res, 200, envelope(await r.catalogs.get()));
      case "foundation-placement": {
        // Rest of foundation's proposal: the machines in short, and where each
        // foundation guest goes, with its choices (rest-of-foundation.sh --proposal).
        try {
          const data = await r.foundationPlacement();
          return sendJson(res, 200, { data, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
        } catch (e) {
          return sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: (e as Error).message });
        }
      }
      case "repository-probe": {
        // What repository add would find: repository-probe?url=<host/path>[&branch=<branch>].
        const u = url.searchParams.get("url") ?? "";
        const branch = url.searchParams.get("branch");
        if (!/^(https?:\/\/)?[A-Za-z0-9][A-Za-z0-9._~\/-]{0,200}$/.test(u) || (branch && !/^[A-Za-z0-9][A-Za-z0-9._\/-]{0,100}$/.test(branch))) return sendJson(res, 400, { error: "repository-probe?url=<host/path>[&branch=<branch>]" });
        try {
          const data = await r.repositoryProbe(u, branch);
          return sendJson(res, 200, { data, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
        } catch (e) {
          return sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: (e as Error).message });
        }
      }
      case "stack-plan": {
        // The modules of a stack and what add-stack would do with each: stack-plan/<stack>[?environment=<env>].
        const environment = url.searchParams.get("environment");
        if (!a || !OBJECT_NAME.test(a) || (environment && !OBJECT_NAME.test(environment))) return sendJson(res, 400, { error: "stack-plan/<stack>[?environment=<env>]" });
        try {
          const data = await r.stackPlan(a, environment);
          return sendJson(res, 200, { data, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
        } catch (e) {
          return sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: (e as Error).message });
        }
      }
      case "fields": {
        // The field manifest of an add or modify form: fields/<kind>[/<name>][?mode=add|modify].
        if (!a || !(FIELD_KINDS as readonly string[]).includes(a)) return sendJson(res, 404, { error: `fields/<${FIELD_KINDS.join("|")}>[/<name>]` });
        if (b !== undefined && !OBJECT_NAME.test(b)) return sendJson(res, 400, { error: "not an object name" });
        const mode = url.searchParams.get("mode") === "add" || (b === undefined && a !== "site") ? "add" : "modify";
        try {
          const data = await r.fieldManifest(a as FieldKind, b ?? null, mode);
          return sendJson(res, 200, { data, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
        } catch (e) {
          return sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: (e as Error).message });
        }
      }
      case "schemas": {
        if (!a || !(a in SCHEMAS)) return sendJson(res, 404, { error: `schemas/<${Object.keys(SCHEMAS).join("|")}>` });
        return sendJson(res, 200, envelope(await r.schemas.of(a).get()));
      }
      case "owner": {
        // The owner's view (spike §5.11): the same reads, plainly worded.
        const [h, m, bk, t, st, envs] = await Promise.all([r.health.get(), r.modules.get(), r.backup.get(), r.topology.get(), r.site.get(), r.environments.get()]);
        const mods = m.value?.modules ?? [];
        const site = st.value as { site?: Record<string, unknown>; lastSweep?: Record<string, unknown> | null } | null;
        return sendJson(res, 200, {
          ...envelope(m),
          data: ownerSummary({
            site: site?.site ?? null,
            health: h.value,
            modules: mods,
            backup: bk.value,
            topology: t.value as never,
            configs: await readConfigs(r.configDir, mods.map((x) => x.name), async (n) => {
              // An explicit proxyDomain, else the proxy's default: <vmname>.<environment's primary domain>.
              const v = (await r.moduleResolve.of(n).get()).value as { fields?: Record<string, { value?: string }> } | null;
              const d = v?.fields?.proxyDomain?.value;
              if (d && d !== "null") return d;
              const row = mods.find((x) => x.name === n);
              const dom = (envs.value ?? []).find((e) => e.name === row?.environment)?.domains?.primary;
              return row?.vmname && dom ? `${row.vmname}.${dom}` : null;
            }),
            lastSweep: (site?.lastSweep ?? null) as never,
          }),
        });
      }
      case "setup": {
        // The checklist, derived from the records each time it is read (D10).
        // No test runs here: POST /setup/check, or a Test job.
        const e = await r.setup.get();
        const steps = e.value ? setupSteps(e.value) : null;
        const st = setupState(this.cfg.access);
        return sendJson(res, 200, {
          ...envelope(e),
          data: steps ? { steps, complete: setupComplete(steps), inputs: e.value, token: { active: st.active, present: st.tokenPresent, identityInstalled: st.identityInstalled } } : null,
        });
      }
      case "backup":
        // backup/keys: the key-stick record (backup-manager key status --json).
        if (a === "keys") return sendJson(res, 200, envelope(await r.backupKeys.get()));
        if (a !== undefined) return sendJson(res, 404, { error: "backup | backup/keys" });
        return sendJson(res, 200, envelope(await r.backup.get()));
      case "topology":
        return sendJson(res, 200, envelope(await r.topology.get()));
      case "assets":
        // assets/tree: every asset by where it stands, with its ports, its
        // disks and the CMDB's allocation of it (the Assets view).
        // assets/disk/<disk>/placements: which assets a disk has been in.
        if (a === "disk" && parts.length === 4 && parts[3] === "placements") {
          if (!b || !ASSET_NAME.test(b)) return sendJson(res, 400, { error: "not an asset name" });
          return r.diskPlacementsOf(b).then(
            (data) => sendJson(res, 200, { data, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null }),
            (e: Error) => sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: e.message }),
          );
        }
        if (a !== "tree" || parts.length !== 2) return sendJson(res, 404, { error: "assets/tree | assets/disk/<disk>/placements" });
        return sendJson(res, 200, envelope(await r.assetTree()));
      case "storage":
        return sendJson(res, 200, envelope(await r.storage.get()));
      case "backup-runs":
        return sendJson(res, 200, envelope(await r.backupRuns.get()));
      case "faceplates":
        // The faceplate catalog's keys and kinds (asset-manager faceplates list): a form's suggestions.
        return sendJson(res, 200, envelope(await r.faceplates.get()));
      case "security": {
        if (a === "threats") {
          // The Threats tab: the threat conditions on the CIs, from the health document.
          const [g, m, e] = await Promise.all([this.graph(), r.modules.get(), r.environments.get()]);
          const ctx = { topology: r.topology.peek().value, modules: m.value?.modules ?? [], environments: e.value ?? [], mgmtDomain: this.cfg.mgmtDomain, pbsStore: "" };
          const v = threatsView(g.value, Date.now());
          const withLogs = (row: ThreatRow): ThreatRow & { logs: ObjectLogs } => ({ ...row, logs: objectLogs(ctx, row, [{ type: "threat", ...(row.hits ? { hits: row.hits } : {}) }]) });
          return sendJson(res, 200, env(g, { ...v, open: v.open.map(withLogs), silenced: v.silenced.map(withLogs) }));
        }
        // The risk scores as the Security page shows them; never whether a fix exists.
        const sec = await r.security.get();
        return sendJson(res, 200, env(sec, sec.value ? securityView(sec.value) : null));
      }
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

  private graph(): Promise<Entry<HealthGraph>> {
    return this.cfg.healthLive ? this.cfg.healthLive.read() : this.reads.healthGraph.get();
  }

  // ── the discovery sweep, on the Assets page (ADR-040 D15) ───────────
  //   GET  /assets/sweep   the last discovery sweep's record, and one running from here
  //   POST /assets/sweep   start one (a write: it asks every source; 409 while one runs)
  private async sweepApi(method: string, me: Me, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    const r = this.reads;
    {
      const sweeps = r.sweeps;
      if (method === "GET") {
        if (!sweeps) return sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: "this console has no CMDB client" });
        return sendJson(res, 200, { data: await sweeps.state(), at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
      }
      if (method === "POST") {
        // It writes only the CMDB, but it asks every source for everything: the installer's.
        const w = mayWrite(me, setupState(this.cfg.access));
        if (!w.ok) return sendJson(res, w.status, { error: w.reason });
        // As a job: JSON, which a cross-site form cannot send without CORS.
        const ctype = req ? String(req.headers["content-type"] ?? "") : "";
        if (!/^application\/json\b/i.test(ctype)) return sendJson(res, 415, { error: "a sweep is posted as application/json" });
        if (!sweeps) return sendJson(res, 503, { error: "this console has no CMDB client" });
        const started = await sweeps.start(me.user ?? me.via);
        if (started.status !== 202) return sendJson(res, started.status, { error: started.error });
        this.cfg.log(`discovery sweep started by ${me.user ?? me.via}`);
        return sendJson(res, 202, { data: { running: started.running } });
      }
      return sendJson(res, 405, { error: "assets/sweep is GET or POST" });
    }
  }

  // ── the Health view (ADR-041 D5) ──────────────────────────────────
  //   GET /health/tree[?q=<text>]         the facets, or what a search finds
  //   GET /health/tree/<id>/children      one level of the tree
  //   GET /health/tree/<id>/path          the way down to an object
  //   GET /health/ego/<id>[?depth=&at=]   an object and its neighbours by relation
  //   GET /health/ego/<id>/path?to=root|impact[&at=]  the chain of the derivation
  //   GET /health/object/<id>             the CI panel's data
  //   GET /health/roots                   health-manager roots, else the document's
  //   GET /health/counts?type=&class=&environment=  the header's counts under the filters
  //   GET /health/events                  the open events by root cause (the Overview's alerts)
  //   GET /health/changes                 what changed on each root cause in the last day
  //   GET /health/summary                 the worst per page: counts, types, Attention
  //   GET /health/stream                  what moved, as server-sent events
  //   GET /health/rules                   health-manager rules list and scenario list
  //   GET /health/rules/<id>              one rule: rules show and rules diff
  //   GET /health/why/<id>                rules explain: how each condition came about
  private async healthApi(sub: string, id: string | undefined, tail: string | undefined, depth: number, url: URL, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    const r = this.reads;
    const failed = (e: Error): void => sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: e.message });
    if (sub === "tree") {
      const g = await this.graph();
      const doc = g.value;
      const q = url.searchParams.get("q");
      if (depth === 2) return sendJson(res, 200, { ...envelope(g), data: doc ? (q !== null ? treeSearch(doc, q) : healthTree(doc)) : null });
      if (depth === 4 && id && (tail === "children" || tail === "path")) {
        if (!OBJECT_ID.test(id) && !TREE_FACETS.includes(id)) return sendJson(res, 400, { error: "not an object id" });
        if (!doc) return sendJson(res, 200, { ...envelope(g), data: null });
        const data = tail === "children" ? treeChildren(doc, id) : treePath(doc, id);
        return data ? sendJson(res, 200, { ...envelope(g), data }) : sendJson(res, 404, { error: `no object ${id}` });
      }
    }
    if (sub === "ego" && id && (depth === 3 || (depth === 4 && tail === "path"))) {
      if (!OBJECT_ID.test(id)) return sendJson(res, 400, { error: "not an object id" });
      const at = url.searchParams.get("at");
      if (at !== null && Number.isNaN(Date.parse(at))) return sendJson(res, 400, { error: `at ${at} is not a date` });
      const to = url.searchParams.get("to");
      if (depth === 4 && to !== "root" && to !== "impact") return sendJson(res, 400, { error: "to is root or impact" });
      const hops = Number(url.searchParams.get("depth") ?? 1);
      if (!Number.isInteger(hops) || hops < 1 || hops > 3) return sendJson(res, 400, { error: "depth is 1 to 3" });
      try {
        const g = at === null ? await this.graph() : null;
        const doc = g ? g.value : await r.loadHealthGraph(new Date(at as string).toISOString());
        if (!doc) return sendJson(res, 200, { ...(g ? envelope(g) : {}), data: null });
        const data = depth === 4 ? healthPath(doc, id, to as "root" | "impact") : healthEgo(doc, id, hops);
        if (!data) return sendJson(res, 404, { error: `no object ${id}` });
        return sendJson(res, 200, g ? { ...envelope(g), data } : { data, at: doc.generated, ageSeconds: 0, refreshing: false, error: null });
      } catch (e) {
        return failed(e as Error);
      }
    }
    if (sub === "object" && depth === 3 && id) {
      if (!OBJECT_ID.test(id)) return sendJson(res, 400, { error: "not an object id" });
      return r.healthObjectOf(id).then((d) => sendJson(res, 200, { data: d, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null }), failed);
    }
    if (sub === "roots" && depth === 2) {
      const d = await r.healthRoots();
      return sendJson(res, 200, { data: d, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
    }
    if (sub === "counts" && depth === 2) {
      const g = await this.graph();
      const f = { type: url.searchParams.get("type") ?? "", class: url.searchParams.get("class") ?? "", environment: url.searchParams.get("environment") ?? "" };
      return sendJson(res, 200, { ...envelope(g), data: g.value ? filteredCounts(g.value, f) : null });
    }
    if (sub === "events" && depth === 2) {
      const g = await this.graph();
      return sendJson(res, 200, { ...envelope(g), data: operationsDoc(g.value, new Map(), [], Date.now()) });
    }
    if (sub === "changes" && depth === 2) {
      const g = await this.graph();
      try {
        return sendJson(res, 200, { ...envelope(g), data: await r.rootChanges(g.value) });
      } catch (e) {
        return failed(e as Error);
      }
    }
    if (sub === "summary" && depth === 2) {
      const g = await this.graph();
      return sendJson(res, 200, { ...envelope(g), data: healthSummary(g.value) });
    }
    if (sub === "stream" && depth === 2 && req) return this.streamHealth(req, res);
    const now = (d: unknown): void => sendJson(res, 200, { data: d, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null });
    if (sub === "rules" && depth === 2) return r.healthRules().then(now, failed);
    if (sub === "rules" && depth === 3 && id) {
      if (!RULE_ID.test(id)) return sendJson(res, 400, { error: "not a rule id" });
      return r.healthRule(id).then(now, failed);
    }
    if (sub === "why" && depth === 3 && id) {
      if (!OBJECT_ID.test(id)) return sendJson(res, 400, { error: "not an object id" });
      return r.healthWhy(id).then(now, failed);
    }
    return sendJson(res, 404, { error: "health | health/tree | health/ego/<id> | health/object/<id> | health/roots | health/counts | health/events | health/changes | health/summary | health/stream | health/rules[/<id>] | health/why/<id>" });
  }

  // ── performance (ADR-046 D7) ─────────────────────────────────────
  //   GET /performance/overview            the site at a glance: USE, RED, the performance roots
  //   GET /performance/levels              the cascade: site, environments, modules, with the cost
  //   GET /performance/investigations      the timed raises in force and ended
  //   GET /performance/ci/<id>?range=24h   a CI's numbers over 24h | 7d | 30d | 90d, with change markers
  // Each a fixed query the server builds (perf.ts); the store's credential never leaves it.
  private async perfApi(sub: string | undefined, id: string | undefined, depth: number, url: URL, res: ServerResponse): Promise<void> {
    const p = this.cfg.perf;
    const usage = "performance/overview | performance/levels | performance/investigations | performance/ci/<id>?range=24h|7d|30d|90d";
    if (!p) return sendJson(res, 503, { error: "this console reads no performance data" });
    if (depth === 2 && sub === "overview") return sendJson(res, 200, envelope(await p.overview.get()));
    if (depth === 2 && sub === "levels") return sendJson(res, 200, envelope(await p.levels.get()));
    if (depth === 2 && sub === "investigations") return sendJson(res, 200, envelope(await p.investigations.get()));
    if (depth === 3 && sub === "ci" && id) {
      if (!OBJECT_ID.test(id)) return sendJson(res, 400, { error: "not an object id" });
      const range = url.searchParams.get("range") ?? "24h";
      if (!isRange(range)) return sendJson(res, 400, { error: "range is 24h, 7d, 30d or 90d" });
      return sendJson(res, 200, envelope(await p.ci(id, range)));
    }
    return sendJson(res, 404, { error: usage });
  }

  // ── a CI's panel (ADR-040 D10) ───────────────────────────────────
  //   GET /cmdb/ci/<id>                   attributes with source and since, relations, drift, open events
  //   GET /cmdb/ci?name=<name>[&class=]   the same, found by name (and class, or an ancestor of it)
  //   GET /cmdb/ci/<id>/history           every period and change, the newest first
  //   GET /cmdb/ci/<id>/trace             up the backbone: what it runs on, its desired record, release, module
  private async cmdbApi(sub: string | undefined, id: string | undefined, tail: string | undefined, depth: number, url: URL, res: ServerResponse): Promise<void> {
    const r = this.reads;
    const answer = (p: Promise<unknown>): Promise<void> =>
      p.then(
        (data) => sendJson(res, 200, { data, at: new Date().toISOString(), ageSeconds: 0, refreshing: false, error: null }),
        (e: Error) => sendJson(res, 200, { data: null, at: null, ageSeconds: null, refreshing: false, error: e.message }),
      );
    if (sub === "ci" && depth === 2) {
      const name = url.searchParams.get("name");
      const cls = url.searchParams.get("class") ?? undefined;
      if (!name || !CI_NAME.test(name) || (cls !== undefined && !CLASS_NAME.test(cls))) return sendJson(res, 400, { error: "cmdb/ci?name=<name>[&class=<class>]" });
      return answer(r.ciRecordOf({ name, cls }));
    }
    if (sub === "ci" && id && (depth === 3 || (depth === 4 && (tail === "history" || tail === "trace")))) {
      if (!OBJECT_ID.test(id)) return sendJson(res, 400, { error: "not an object id" });
      return answer(depth === 3 ? r.ciRecordOf({ id }) : tail === "history" ? r.ciHistoryOf(id) : r.ciTraceOf(id));
    }
    return sendJson(res, 404, { error: "cmdb/ci/<id> | cmdb/ci?name=&class= | cmdb/ci/<id>/history | cmdb/ci/<id>/trace" });
  }

  // As a job's output: an event per thing that moved, and a comment now and
  // then so a proxy keeps the quiet stream open.
  private streamHealth(req: IncomingMessage, res: ServerResponse): void {
    const live = this.cfg.healthLive;
    if (!live) return sendJson(res, 503, { error: "this console follows no change stream" });
    res.statusCode = 200;
    res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Accel-Buffering", "no");
    res.write(`event: hello\ndata: ${JSON.stringify({ linked: live.linked })}\n\n`);
    const off = live.subscribe((p) => res.write(`event: health\ndata: ${JSON.stringify(p)}\n\n`));
    const beat = setInterval(() => res.write(": keepalive\n\n"), 25_000);
    req.on("close", () => {
      off();
      clearInterval(beat);
    });
  }

  private async modules(name: string | undefined, sub: string | undefined, url: URL, res: ServerResponse): Promise<void> {
    const r = this.reads;
    const [m, h, bk, g, sec] = await Promise.all([r.modules.get(), r.health.get(), r.backup.get(), this.graph(), r.security.get()]);
    const list = withConditions(moduleSummaries(m.value?.modules ?? [], h.value, bk.value, sec.value), moduleHealth(g.value));
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
    if (sub === "fields") return sendJson(res, 200, envelope(await r.moduleFieldsOf(name)));
    if (sub === "sections") {
      const row = (m.value?.modules ?? []).find((x) => x.name === name);
      if (!row) return sendJson(res, 404, { error: `no deployed module '${name}'` });
      const value = await r.moduleSections(row, this.manifests);
      return sendJson(res, 200, envelope({ value, at: Date.now(), error: null, loading: false }));
    }
    if (sub === "icon") {
      // The module's icon (icons.ts), or 404: the page draws its initial.
      const icon = (await r.moduleIcons.of(name).get()).value;
      if (!icon) return sendJson(res, 404, { error: `no icon for '${name}'` });
      res.statusCode = 200;
      res.setHeader("Content-Type", icon.type);
      res.setHeader("Cache-Control", "private, max-age=600");
      // An SVG opened on its own runs nothing.
      res.setHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox");
      res.end(icon.body);
      return;
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
  //   GET  /jobs                 every job, newest first, and the queue;
  //                              ?bin=&verb=&limit=: one verb's jobs only (a
  //                              wizard looking for its session, Add node's)
  //   POST /jobs {argv, preview}  a preview (or a read); a write never starts here
  //   POST /jobs {argv, apply, confirm?}  the dry run, then the apply on a clean one (one job)
  //   POST /jobs/<id>/apply {confirm?}  the preview's argv with its applying flag
  //   POST /jobs/<id>/cancel     a queued job never runs; a running one is stopped
  //   GET  /jobs/<id>            the job with its output; as text/event-stream,
  //                              the output as it comes (server-sent events)
  private async jobsApi(method: string, id: string | undefined, sub: string | undefined, me: Me, res: ServerResponse, req?: IncomingMessage, url?: URL): Promise<void> {
    const jobs = this.jobs;
    if (!jobs) return sendJson(res, 503, { error: "this console runs no jobs" });
    if (method === "GET" && !id) {
      const q = url?.searchParams;
      const bin = q?.get("bin") ?? null;
      const verb = q?.get("verb") ?? null;
      if (bin !== null || verb !== null) {
        const limit = Math.max(1, Math.min(500, Number(q?.get("limit") ?? "") || 500));
        const list = jobs.list().filter((j) => (bin === null || j.bin === bin) && (verb === null || j.verb === verb)).slice(0, limit);
        return sendJson(res, 200, { data: { jobs: list, queue: jobs.queued() } });
      }
      // busy: a write runs or waits, or a read runs — ui/install.sh defers the
      // service's restart on it (takeRestartMarker in jobs.ts).
      return sendJson(res, 200, { data: { jobs: jobs.list(), queue: jobs.queued(), busy: jobs.busy(), sweep: await jobs.sweep() } });
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
    if (!id) r = await jobs.create(me, setup, { argv: body.argv, preview: body.preview, apply: body.apply, confirm: body.confirm, assistant: body.assistant });
    else if (sub === "apply") r = await jobs.applyPreview(me, setup, id, { confirm: body.confirm });
    else if (sub === "cancel") r = jobs.cancel(me, setup, id);
    else return sendJson(res, 404, { error: `jobs/${id}/${sub ?? ""}` });
    return this.sendJob(res, r);
  }

  private sendJob(res: ServerResponse, r: CreateResult): void {
    if (r.job) this.cfg.log(`job ${r.job.id} ${r.job.kind} ${r.job.state}${r.job.refused ? ` (${r.job.refused})` : ""}: ${r.job.argv.join(" ")}`);
    if (r.status >= 400) return sendJson(res, r.status, { error: r.error, ...(r.job ? { data: summary(r.job) } : {}), ...(r.sweep ? { sweep: r.sweep } : {}) });
    return sendJson(res, r.status, { data: r.job ? (this.jobs?.get(r.job.id) ?? r.job) : null }); // with its output so far
  }

  // ── the Setup page's Check ────────────────────────────────────────
  //   POST /setup/check   the installed foundation modules' tests, a read job
  //                       each; main.ts keeps their results (recordSetupTest).
  // A read, so whoever may read Setup may ask it, the loopback's read role
  // too (the jobs' argv is this route's): JSON only, as no cross-site form can
  // start one.
  private setupCheck(method: string, me: Me, res: ServerResponse, req?: IncomingMessage): void {
    const jobs = this.jobs;
    if (!jobs) return sendJson(res, 503, { error: "this console runs no jobs" });
    if (method !== "POST") return sendJson(res, 405, { error: "setup/check: POST" });
    const ctype = req ? String(req.headers["content-type"] ?? "") : "";
    if (!/^application\/json\b/i.test(ctype)) return sendJson(res, 415, { error: "a check is posted as application/json" });
    const started: JobSummary[] = [];
    for (const m of setupCheckModules(this.reads.configDir, this.reads.stateDir)) {
      const r = jobs.createRead(me, ["module-manager", "test", m]);
      if (!r.job) return sendJson(res, r.status, { error: r.error });
      this.cfg.log(`job ${r.job.id} read by ${me.user ?? me.via}: ${r.job.argv.join(" ")}`);
      started.push(r.job);
    }
    return sendJson(res, 201, { data: started });
  }

  // ── a Day 1 step's plain answer ("none", "no more machines") ─────────
  //   POST /setup/answer {step, answer}   record it; answer null withdraws it
  // A record of the console's own (setup-answers.json in its state directory),
  // which an optional step reads as done. Written by whoever may change the site.
  private async setupAnswer(method: string, me: Me, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    if (method !== "POST") return sendJson(res, 405, { error: "setup/answer: POST" });
    const w = mayWrite(me, setupState(this.cfg.access));
    if (!w.ok) return sendJson(res, w.status, { error: w.reason });
    const ctype = req ? String(req.headers["content-type"] ?? "") : "";
    if (!/^application\/json\b/i.test(ctype)) return sendJson(res, 415, { error: "an answer is posted as application/json" });
    let body: Record<string, unknown>;
    try {
      body = req ? await readJsonBody(req) : {};
    } catch (e) {
      return sendJson(res, 400, { error: (e as Error).message });
    }
    const step = typeof body.step === "string" ? body.step : "";
    const answer = body.answer === null ? null : typeof body.answer === "string" ? body.answer : undefined;
    if (answer === undefined) return sendJson(res, 400, { error: "answer: the step's answer, or null to withdraw it" });
    const err = recordSetupAnswer(this.reads.stateDir, step, answer);
    if (err) return sendJson(res, 400, { error: err });
    this.cfg.log(`setup answer ${step}=${answer ?? "(withdrawn)"} by ${me.user ?? me.via}`);
    await this.reads.setupTestRecorded();
    return sendJson(res, 200, { data: { step, answer } });
  }

  // ── the assistant (ADR-034 D7) ────────────────────────────────────
  //   GET  /assistant/status              whether it is available, and why not
  //   POST /assistant/chat {conversation?, message, focus?}
  //                                       one turn, as server-sent events:
  //                                       conversation, step, delta, proposal, done, error
  //   GET  /assistant/conversations[/<id>]  the caller's own conversations
  // Reads only: a turn changes nothing but the caller's conversation file.
  private async assistantApi(method: string, sub: string | undefined, id: string | undefined, me: Me, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    if (method === "GET" && sub === "status") {
      const at = new Date().toISOString();
      const none = (reason: string) => ({ available: false, reason, model: null, modelFrom: null, endpoint: null, keyFile: null, checkedAt: at });
      if (!this.cfg.litellm) return sendJson(res, 200, { data: none("this console has no assistant") });
      return sendJson(res, 200, { data: await this.cfg.litellm.status() });
    }
    const a = this.cfg.assistant;
    if (!a) return sendJson(res, 503, { error: "this console has no assistant" });
    if (method === "GET" && sub === "conversations") {
      if (!id) return sendJson(res, 200, { data: a.list(me) });
      const c = a.get(me, id);
      if (!c) return sendJson(res, 404, { error: `no conversation ${id}` });
      const { messages: _m, ...rest } = c;
      return sendJson(res, 200, { data: rest });
    }
    if (method === "POST" && sub === "chat" && !id) {
      const ctype = req ? String(req.headers["content-type"] ?? "") : "";
      if (!/^application\/json\b/i.test(ctype)) return sendJson(res, 415, { error: "a question is posted as application/json" });
      let body: Record<string, unknown>;
      try {
        body = req ? await readJsonBody(req) : {};
      } catch (e) {
        return sendJson(res, 400, { error: (e as Error).message });
      }
      res.statusCode = 200;
      res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
      res.setHeader("Cache-Control", "no-store");
      res.setHeader("X-Accel-Buffering", "no");
      const ac = new AbortController();
      let ended = false;
      res.on("close", () => {
        if (!ended) ac.abort();
      });
      const send = (e: AssistantEvent): void => {
        if (!ended) res.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
      };
      try {
        await a.chat(me, body, send, ac.signal);
      } catch (e) {
        send({ type: "error", message: (e as Error).message });
      }
      ended = true;
      res.end();
      return;
    }
    return sendJson(res, 404, { error: `assistant/${sub ?? ""}` });
  }

  // ── the wizard's secrets (secrets.ts) ─────────────────────────────
  //   GET  /secrets          which are set, and which keys (never a value)
  //   POST /secrets/<name>   write it where its script reads it (the installer);
  //                          one its owner's verb takes minutes over: a job, its answer
  private async secretsApi(method: string, name: string | undefined, me: Me, res: ServerResponse, req?: IncomingMessage): Promise<void> {
    const home = this.cfg.home;
    if (!home) return sendJson(res, 503, { error: "this console writes no secrets" });
    if (method === "GET" && !name) {
      return sendJson(res, 200, { data: Object.keys(SECRETS).map((n) => secretStatus(home, n as keyof typeof SECRETS)) });
    }
    if (method !== "POST" || !name) return sendJson(res, 405, { error: "secrets: GET, or POST /secrets/<name>" });
    if (!isSecretName(name)) return sendJson(res, 404, { error: `no secret '${name}' (one of ${Object.keys(SECRETS).join(", ")})` });
    // A credential is the installer's to set (or the setup token's).
    const w = mayWrite(me, setupState(this.cfg.access));
    if (!w.ok) return sendJson(res, w.status, { error: w.reason });
    const ctype = req ? String(req.headers["content-type"] ?? "") : "";
    if (!/^application\/json\b/i.test(ctype)) return sendJson(res, 415, { error: "a secret is posted as application/json" });
    let body: Record<string, unknown>;
    try {
      body = req ? await readJsonBody(req) : {};
    } catch (e) {
      return sendJson(res, 400, { error: (e as Error).message });
    }
    // A secret its owner keeps (wlan: ap-manager, #889) is handed to the owner's
    // verb on stdin: never in argv, never in a log, never in the answer.
    const cmd = secretCommand(name, body);
    if (typeof cmd === "string") return sendJson(res, 400, { error: cmd });
    if (cmd?.job) {
      if (!this.jobs) return sendJson(res, 503, { error: "this console runs no jobs" });
      return this.sendJob(res, await this.jobs.createWithSecret(me, setupState(this.cfg.access), [cmd.bin, ...cmd.args], { input: cmd.input, timeoutMs: cmd.timeoutMs }));
    }
    if (cmd) {
      const run = this.cfg.runStdin ?? runWithStdin;
      // The verb runs as the job its Activity record will be (its CMDB change names it).
      const jobId = this.jobs?.newJobId();
      const out = await run(cmd.bin, cmd.args, cmd.input, cmd.timeoutMs, jobId ? jobEnv(jobId, me) : undefined);
      if (!out.ran || out.rc !== 0) {
        const secret = cmd.input.replace(/\n$/, "");
        const last = (out.stderr || out.stdout).replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n").slice(-1)[0] ?? "";
        const why = (secret && last.includes(secret) ? last.split(secret).join("…") : last) || `exit ${out.rc}`;
        return sendJson(res, out.ran ? 400 : 502, { error: `${cmd.bin} ${cmd.args.join(" ")}: ${why}` });
      }
      const spec = SECRETS[name];
      const file = spec.file !== null ? join(home, spec.file) : cmd.where ?? "its owner";
      if (this.jobs) this.jobs.recordSecret(me, name, file, cmd.keys, `${cmd.bin} ${cmd.args.join(" ")}`, jobId);
      this.cfg.log(`secret ${name} set by ${me.user ?? "?"} (${me.via}) through ${cmd.bin} ${cmd.args.join(" ")}`);
      if (name === "wlan") void this.reads.ssids.refreshAfterChange();
      return sendJson(res, 200, { data: secretStatus(home, name) });
    }
    const r = writeSecret(home, name, body);
    if (!r.ok) return sendJson(res, 400, { error: r.error });
    if (this.jobs) this.jobs.recordSecret(me, name, r.file, r.keys);
    this.cfg.log(`secret ${name} written by ${me.user ?? "?"} (${me.via}): keys ${r.keys.join(", ")}`);
    return sendJson(res, 200, { data: secretStatus(home, name) });
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
