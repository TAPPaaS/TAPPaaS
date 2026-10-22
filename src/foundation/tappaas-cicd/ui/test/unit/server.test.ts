// server.test.ts — the HTTP surface, driven without a socket: routes, the
// reads-are-GET rule (a change is a job, jobs.test.ts), the route cap on jumps, argument
// hygiene on module names, the static front end and the setup-token cookie.

import { mkdirSync, mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig } from "../../src/access";
import { Reads } from "../../src/reads";
import { ConsoleServer } from "../../src/server";
import { check, done } from "./check";
import { fakeSite } from "./fake-site";

interface Reply {
  status: number;
  headers: Record<string, string>;
  body: string;
  json: () => { data?: unknown; error?: string } & Record<string, unknown>;
}

async function main(): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "console-server-"));
  const web = join(dir, "web");
  mkdirSync(join(web, "assets"), { recursive: true });
  writeFileSync(join(web, "index.html"), "<!doctype html><title>console</title>");
  writeFileSync(join(web, "assets", "app-1234.js"), "console.log(1)");
  const access: AccessConfig = {
    firewall: ["10.0.0.1"],
    allow: ["127.0.0.1"],
    setupAllow: ["10.0.0.0/24"],
    tokenFile: join(dir, "console-setup-token"),
    identityFile: join(dir, "identity.json"),
    trustLocalHeaders: false,
  };
  const site = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7 });
  const srv = new ConsoleServer({ access, webDir: web, mgmtDomain: "mgmt.internal", version: "test", log: () => undefined }, reads);

  const call = async (method: string, url: string, headers: Record<string, string> = {}, peer = "127.0.0.1"): Promise<Reply> => {
    const h: Record<string, string> = {};
    let body = "";
    const res = {
      statusCode: 200,
      headersSent: false,
      setHeader(n: string, v: string | number | string[]) {
        h[n.toLowerCase()] = String(v);
      },
      end(d?: string | NodeBuffer) {
        body = d === undefined ? "" : typeof d === "string" ? d : d.toString("utf8");
        this.headersSent = true;
      },
    };
    const req = { method, url, headers: { host: "console.hrossen.dk", ...headers }, socket: { remoteAddress: peer, destroy: () => undefined } };
    await srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    return { status: res.statusCode, headers: h, body, json: () => JSON.parse(body) };
  };
  const gate = (groups: string, host = "console.hrossen.dk") => ({ host, "x-authentik-username": "lars", "x-authentik-groups": groups });

  let r = await call("GET", "/api/v1/me");
  check(r.status === 200 && (r.json().data as { via: string }).via === "local", "/api/v1/me from loopback");
  r = await call("GET", "/api/v1/me", gate("Admin|users"), "10.0.0.1");
  check((r.json().data as { user: string; role: string }).user === "lars" && (r.json().data as { role: string }).role === "admin", "/api/v1/me through the gate: the user and the role");
  r = await call("GET", "/api/v1/me", {}, "10.0.0.1");
  check(r.status === 401, "from the firewall without the gate: 401");
  r = await call("GET", "/api/v1/health", {}, "10.0.0.77");
  check(r.status === 403 && /not accepted/.test(r.json().error ?? ""), "another mgmt address: 403");

  r = await call("GET", "/api/v1/health");
  const hd = r.json().data as { gates: unknown[]; attention: { gate: string }[] };
  check(r.status === 200 && hd.gates.length > 10 && hd.attention.length > 0 && typeof r.json().at === "string", "/api/v1/health: gates, Attention, and when it was read");
  check(r.headers["cache-control"] === "no-store" && /default-src 'self'/.test(r.headers["content-security-policy"] ?? ""), "API answers are not cached; a CSP is set");
  r = await call("GET", "/api/v1/gates");
  check(Array.isArray(r.json().data), "/api/v1/gates");
  r = await call("GET", "/api/v1/pulse");
  check(((r.json().data as { gate: { name: string } }).gate.name) === "pulse", "/api/v1/pulse");
  for (const p of ["site", "zones", "aps", "environments", "topology", "storage", "backup-runs", "activity", "security", "status"]) {
    r = await call("GET", `/api/v1/${p}`);
    check(r.status === 200, `/api/v1/${p} answers`);
  }

  r = await call("GET", "/api/v1/modules");
  const mods = r.json().data as { name: string; badges: { health: string } }[];
  check(mods.length === 25 && mods.find((m) => m.name === "immich")?.badges.health === "fail", "/api/v1/modules: 25 with badges, immich FAIL");
  r = await call("GET", "/api/v1/modules/immich");
  const det = r.json().data as { summary: { name: string }; show: { data: unknown }; backup: { data: unknown } };
  check(r.status === 200 && det.summary.name === "immich" && det.show.data !== null && det.backup.data !== null, "/api/v1/modules/immich: summary, show, resolve, backup");
  r = await call("GET", "/api/v1/modules/immich/drift");
  check(r.status === 200 && (r.json().data as { module: string }).module === "immich", "/api/v1/modules/immich/drift on demand");
  mkdirSync(join(dir, "src-immich"));
  writeFileSync(join(dir, "src-immich", "icon.svg"), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  writeFileSync(join(dir, "immich.json"), JSON.stringify({ moduleSource: join(dir, "src-immich") }));
  r = await call("GET", "/api/v1/modules/immich/icon");
  check(r.status === 200 && r.headers["content-type"] === "image/svg+xml" && /sandbox/.test(r.headers["content-security-policy"] ?? "") && r.body.startsWith("<svg"), "/api/v1/modules/immich/icon: its icon.svg, sandboxed");
  r = await call("GET", "/api/v1/modules/jellyfin/icon");
  check(r.status === 404, "a module without an icon: 404 (the page draws its initial)");
  r = await call("GET", "/api/v1/modules/immich/fields");
  const mf = r.json().data as { fields: { field: string; service: string; settable: boolean }[] };
  check(r.status === 200 && mf.fields[0].field === "memory" && mf.fields[0].service === "cluster:vm" && mf.fields[0].settable, "/api/v1/modules/immich/fields: the Modify form's rows");
  r = await call("GET", "/api/v1/nodes/tappaas1/progress");
  check(r.status === 200 && (r.json().data as { inSite: boolean }).inSite === true, "/api/v1/nodes/<name>/progress");
  r = await call("GET", "/api/v1/nodes/--x/progress");
  check(r.status === 404, "a node name site-manager would refuse reads nothing");
  r = await call("GET", "/api/v1/catalogs");
  check(r.status === 200 && Array.isArray(r.json().data), "/api/v1/catalogs: one entry per registered repository");
  r = await call("GET", "/api/v1/schemas/passwd");
  check(r.status === 404, "/api/v1/schemas/<name>: only the listed schemas");
  r = await call("GET", "/api/v1/modules/nosuch");
  check(r.status === 404, "an unknown module: 404");
  r = await call("GET", "/api/v1/modules/--json");
  check(r.status === 400, "a name that is no module name never reaches an argv");
  check(!site.calls.some((c) => c.includes("nosuch") || c.includes("show --json --json")), "…neither one ran a verb");

  r = await call("GET", "/api/v1/jumps/module/immich");
  const j = r.json().data as { target: string; url: string }[];
  check(j.some((x) => x.target === "proxmox" && x.url === "https://tappaas1.mgmt.internal:8006/#v1:0:=qemu/361"), "jump: Proxmox at immich's VM on the node it runs on");
  check(j.some((x) => x.target === "grafana" && x.url.startsWith("https://logging.hrossen.dk/explore?") && decodeURIComponent(x.url).includes('{host=\\"immich\\"}')), "jump: Grafana Explore on immich's logs");
  r = await call("GET", "/api/v1/jumps/port/11?switch=USW%20Pro%20XG%2010%20PoE");
  check((r.json().data as { url: string }[]).some((x) => x.url === "https://unifi-os.mgmt.internal:11443/network/default/devices"), "jump: a port opens the UniFi controller");
  r = await call("GET", "/api/v1/jumps/module/immich", gate("Installer", "status.hrossen.dk"), "10.0.0.1");
  check(r.status === 200 && (r.json().data as unknown[]).length === 0, "the status route offers no jumps");
  r = await call("GET", "/api/v1/jumps/bogus/x");
  check(r.status === 400, "an unknown jump kind: 400");

  r = await call("POST", "/api/v1/modules/immich");
  check(r.status === 405, "a read is GET; a change is a job: 405");
  r = await call("DELETE", "/api/v1/modules/immich");
  check(r.status === 405, "…nor delete");
  r = await call("POST", "/api/v1/refresh?what=modules");
  check(r.status === 202, "refresh of the console's own cache is accepted");
  r = await call("POST", "/api/v1/refresh?what=bogus");
  check(r.status === 400, "refresh of an unknown read: 400");
  r = await call("GET", "/api/v2/health");
  check(r.status === 404, "an unknown API version: 404");

  r = await call("GET", "/");
  check(r.status === 200 && r.body.includes("<title>console") && r.headers["cache-control"] === "no-cache", "/ serves the front end");
  r = await call("GET", "/modules/immich");
  check(r.status === 200 && r.body.includes("<title>console"), "a client route answers index.html");
  r = await call("GET", "/assets/app-1234.js");
  check(r.status === 200 && /javascript/.test(r.headers["content-type"] ?? "") && /immutable/.test(r.headers["cache-control"] ?? ""), "hashed assets are long-cached");
  r = await call("GET", "/assets/missing.js");
  check(r.status === 404, "a missing asset is 404, not index.html");
  r = await call("GET", "/assets/..%2f..%2f..%2fetc%2fpasswd");
  check(r.status === 400, "an encoded path out of the front end is refused");
  r = await call("GET", "/%2e%2e/%2e%2e/etc/passwd");
  check(!r.body.includes("root:"), "dot segments resolve inside the front end, never above it");

  // ── the setup token's cookie ────────────────────────────────────────
  writeFileSync(access.tokenFile, "tok-123");
  r = await call("GET", "/?token=tok-123", {}, "10.0.0.50");
  check(r.status === 302 && /^tappaas_setup=tok-123; .*HttpOnly; SameSite=Strict/.test(r.headers["set-cookie"] ?? "") && r.headers.location === "/", "the token on the address line becomes an HttpOnly cookie");
  r = await call("GET", "/api/v1/me", { cookie: "tappaas_setup=tok-123" }, "10.0.0.50");
  check((r.json().data as { via: string }).via === "setup-token", "…which the API then accepts");
  r = await call("GET", "/", {}, "10.0.0.50");
  check(r.status === 401 && r.body.includes("Setup token"), "without it, a page asking for the token");
  writeFileSync(access.identityFile, "{}");
  r = await call("GET", "/api/v1/me", { cookie: "tappaas_setup=tok-123" }, "10.0.0.50");
  check(r.status === 403 || r.status === 401, "once identity is installed the cookie no longer opens anything");

  reads.stop();
  done("server");
}

void main();
