// owner.test.ts — the site owner's view on status.<domain> (ADR-034 D2, spike
// §5.11, Testing T1): hrossen's records worded for the owner, and the route
// cap: a member of users on the status route reads the owner view and gets
// 403 on every write, the setup and the secrets; no jumps.

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse } from "http";
import { AccessConfig } from "../../src/access";
import { Jobs } from "../../src/jobs";
import { HealthDoc, ModuleList } from "../../src/model";
import { ownerSummary } from "../../src/owner";
import { Reads } from "../../src/reads";
import { ConsoleServer } from "../../src/server";
import { check, done } from "./check";
import { FIX, fakeSite } from "./fake-site";

const j = <T>(f: string): T => JSON.parse(readFileSync(join(FIX, f), "utf8")) as T;

async function main(): Promise<void> {
  const health = j<HealthDoc>("validate.json");
  const modules = j<ModuleList>("modules.json").modules;
  const o = ownerSummary({
    site: { name: "rossen", displayName: "rossen", version: "2.0", channel: "unstable", email: "lars@hrossen.dk", ipv6: true, updateSchedule: { frequency: "daily" } },
    health,
    modules,
    backup: j("backup.json"),
    topology: j("topology.json"),
    configs: { immich: { displayName: "Immich (photos)", proxyDomain: "immich.hrossen.dk" }, nextcloud: { proxyDomain: "nextcloud.hrossen.dk" } },
    lastSweep: { reboot: "none" },
  });
  const immich = o.services.find((s) => s.name === "immich");
  check(!!immich && immich.displayName === "Immich (photos)" && immich.address === "immich.hrossen.dk", "a service carries its displayName and published address");
  check(!!immich && immich.notes.includes("short of memory") && immich.level === "warn", "immich's guest-memory FAIL reads 'short of memory'");
  check(/short of memory/.test(o.sentence) && /operator has been told/.test(o.sentence), "the one sentence says it, and that the operator knows");
  check(o.services.every((s) => !["cluster", "templates", "network", "tappaas-cicd"].includes(s.name)), "the platform's own modules are not the owner's services");
  check(o.services.some((s) => s.notes.includes("backed up")) && o.facts.some((f) => /backed up/.test(f)), "backups are worded per service and in the facts");
  check(o.services.find((s) => s.name === "nomad")?.notes.includes("inside the site only") === true, "a module with no published route is 'inside the site only'");
  check(/3 servers · 1 switch · 1 access point · 1 firewall/.test(o.numbers), "the site in numbers, from the topology");
  check(o.offsite.some((x) => /rasmus/.test(x)) && o.operator === "lars@hrossen.dk" && /Channel unstable · updates nightly/.test(o.release), "off-site copy, operator, release");

  // ── the route cap (T1) ──────────────────────────────────────────────
  const dir = mkdtempSync(join(tmpdir(), "console-owner-"));
  writeFileSync(join(dir, "identity.json"), "{}");
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "tok"), identityFile: join(dir, "identity.json"), trustLocalHeaders: false };
  const site = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7 });
  const jobs = new Jobs({ stateDir: join(dir, "state"), configDir: dir, manifests: () => ({ byBin: new Map(), errors: [], loadedAt: "" }), stream: async () => ({ rc: 0, ran: true, error: null }), run: site.run });
  const srv = new ConsoleServer({ access, webDir: null, mgmtDomain: "mgmt.internal", version: "t", log: () => undefined, home: dir }, reads, jobs);
  const call = async (method: string, url: string, groups: string) => {
    let body = "";
    const res = { statusCode: 200, headersSent: false, setHeader: () => undefined, write: () => true, end: (d?: string) => ((body = d ?? ""), true), on: () => res };
    const req = {
      method,
      url,
      headers: { host: "status.hrossen.dk", "x-authentik-username": "owner", "x-authentik-groups": groups, "content-type": "application/json" },
      socket: { remoteAddress: "10.0.0.1", destroy: () => undefined },
      on: (ev: string, cb: () => void) => (ev === "end" ? cb() : undefined, req),
    };
    await srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    return { status: res.statusCode, body };
  };
  let r = await call("GET", "/api/v1/me", "users");
  check(r.status === 200 && JSON.parse(r.body).data.role === "read" && JSON.parse(r.body).data.route === "status", "users on status.<domain>: read");
  r = await call("GET", "/api/v1/owner", "users");
  check(r.status === 200 && Array.isArray(JSON.parse(r.body).data.services), "…reads the owner view");
  r = await call("POST", "/api/v1/jobs", "users");
  check(r.status === 403, "…a job: 403 (T1)");
  r = await call("POST", "/api/v1/jobs", "installer");
  check(r.status === 403, "even Installer's job on the status route: 403 (the route caps the role)");
  r = await call("GET", "/api/v1/setup", "users");
  check(r.status === 403, "the setup checklist: 403");
  r = await call("POST", "/api/v1/secrets/unifi", "installer");
  check(r.status === 403, "a secret: 403");
  r = await call("GET", "/api/v1/jumps/module/immich", "installer");
  check(r.status === 200 && JSON.parse(r.body).data.length === 0, "no jumps from the status route");

  rmSync(dir, { recursive: true, force: true });
  done("owner");
}

void main();
