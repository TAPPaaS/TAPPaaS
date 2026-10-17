// console — the TAPPaaS console's backend (ADR-034), phase P1 "see".
//
// A service of the mothership, run as `tappaas` by tappaas-console.service
// (tappaas-cicd.nix). It reads the site only through the managers' --json
// (run.ts, reads.ts), caches what they say, and serves it with the built front
// end. It writes nothing on the site; its one file is the health document it
// hands to `network-manager topology --health` under the state directory.
//
//   console serve [--listen <addr:port>[,...]] [--allow <addr>[,...]] [--web <dir>]
//                 [--state-dir <dir>] [--config-dir DIR]
//
// Settings fall back to CONSOLE_* environment variables (the unit sets none, so
// the defaults below are the installed behaviour).

import { existsSync, readFileSync } from "fs";
import { lookup } from "dns";
import { networkInterfaces } from "os";
import { join } from "path";
import { AccessConfig, addrMatches, setupState } from "./access";
import { Reads } from "./reads";
import { runAsync } from "./run";
import { ConsoleServer } from "./server";
import { HelpSpec, checkArgs, renderHelp } from "../../lib/ts/src/help";
import { DieError, die, guarded, info, requireOperator, warn } from "../../lib/ts/src/cli";
import { defaultConfigDir } from "../../lib/ts/src/config-io";
import { mgmtDomain } from "../../lib/ts/src/cluster";

export const VERSION = "0.1.0";
export const DEFAULT_PORT = 9097;

export const HELP: HelpSpec = {
  name: "console",
  version: VERSION,
  tagline: "the TAPPaaS console backend (ADR-034, P1: read-only)",
  verbs: [
    {
      usage: "serve [--listen <addr:port>] [--allow <addr>] [--web <dir>] [--state-dir <dir>] [--trust-local-headers]",
      options: [
        ["--listen <addr:port>", `Where to listen, comma-separated (default: the mothership's mgmt address and 127.0.0.1, port ${DEFAULT_PORT}).`],
        ["--allow <addr>", "Peers accepted besides the firewall, comma-separated addresses or a.b.c.d/n (default: loopback)."],
        ["--web <dir>", "The built front end (default: the one packaged with the console)."],
        ["--state-dir <dir>", "Where the health document for the topology is kept (default: /var/lib/tappaas/console)."],
        ["--trust-local-headers", "Development: believe X-Authentik-* from an --allow peer too, to try the roles."],
      ],
      details:
        "Accepts connections only from the firewall (where Caddy and the Authentik gate run) and from\n" +
        "--allow; the X-Authentik-* headers are believed only from the firewall. Before identity is\n" +
        "installed (no config/identity.json) and while the setup token file exists, the mgmt and\n" +
        "admin networks are accepted too, each request with the token (ADR-034 D10).",
    },
  ],
  common: [["--config-dir DIR", "Config root (default: $TAPPAAS_CONFIG, $CONFIG_DIR or /home/tappaas/config)."]],
  notes: [
    "Environment: CONSOLE_LISTEN, CONSOLE_ALLOW, CONSOLE_WEB_DIR, CONSOLE_STATE_DIR,\n" +
      "CONSOLE_FIREWALL (the firewall's address), CONSOLE_SETUP_ALLOW, CONSOLE_SETUP_TOKEN_FILE\n" +
      "(default <config>/console-setup-token), CONSOLE_JOURNAL_DAYS (default 7).",
  ],
};

export interface ServeOpts {
  configDir: string;
  listen: { host: string; port: number }[] | null; // null: the defaults
  allow: string[];
  webDir: string | null;
  stateDir: string;
  trustLocalHeaders: boolean;
}

const list = (v: string | undefined): string[] => (v ?? "").split(",").map((s) => s.trim()).filter((s) => s.length > 0);

export function parseListen(v: string): { host: string; port: number }[] {
  return list(v).map((e) => {
    const m = /^(.*):(\d+)$/.exec(e);
    if (!m) die(`--listen ${e}: expected <addr>:<port>`);
    const port = Number(m[2]);
    if (port < 1 || port > 65535) die(`--listen ${e}: port out of range`);
    return { host: m[1].replace(/^\[(.*)\]$/, "$1"), port };
  });
}

export function parseServe(args: string[]): ServeOpts {
  const env = process.env;
  const o: ServeOpts = {
    configDir: defaultConfigDir(),
    listen: env.CONSOLE_LISTEN ? parseListen(env.CONSOLE_LISTEN) : null,
    allow: env.CONSOLE_ALLOW ? list(env.CONSOLE_ALLOW) : ["127.0.0.1", "::1"],
    webDir: env.CONSOLE_WEB_DIR ?? null,
    stateDir: env.CONSOLE_STATE_DIR ?? "/var/lib/tappaas/console",
    trustLocalHeaders: env.CONSOLE_TRUST_LOCAL_HEADERS === "1",
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = (): string => {
      const v = args[++i];
      if (v === undefined) die(`${a} requires a value`);
      return v;
    };
    if (a === "--listen") o.listen = parseListen(next());
    else if (a === "--allow") o.allow = list(next());
    else if (a === "--web") o.webDir = next();
    else if (a === "--state-dir") o.stateDir = next();
    else if (a === "--config-dir") o.configDir = next();
    else if (a === "--trust-local-headers") o.trustLocalHeaders = true;
    else die(`serve: unexpected argument ${a}`);
  }
  return o;
}

// A zone's network from zones.json, e.g. mgmt → 10.0.0.0/24.
export function zoneNetwork(configDir: string, zone: string): string | null {
  try {
    const z = JSON.parse(readFileSync(join(configDir, "zones.json"), "utf8")) as Record<string, { ip?: unknown }>;
    const ip = z[zone]?.ip;
    return typeof ip === "string" && /^\d+\.\d+\.\d+\.\d+\/\d+$/.test(ip) ? ip : null;
  } catch {
    return null;
  }
}

// The mothership's own address on mgmt: the interface address inside mgmt's network.
export function mgmtAddress(net: string | null): string | null {
  if (!net) return null;
  for (const addrs of Object.values(networkInterfaces())) {
    for (const a of addrs ?? []) {
      if ((a.family === "IPv4" || a.family === 4) && !a.internal && addrMatches(a.address, net)) return a.address;
    }
  }
  return null;
}

function resolve4(host: string): Promise<string | null> {
  return new Promise((r) => lookup(host, { family: 4 }, (err, address) => r(err ? null : address)));
}

// The firewall's address: CONSOLE_FIREWALL, else firewall.<mgmt domain> (pinned
// in /etc/hosts on the mothership), else the first address of mgmt's network.
export async function firewallAddress(net: string | null): Promise<string[]> {
  if (process.env.CONSOLE_FIREWALL) return list(process.env.CONSOLE_FIREWALL);
  const a = await resolve4(`firewall.${mgmtDomain()}`);
  if (a) return [a];
  const m = net ? /^(\d+\.\d+\.\d+)\.\d+\/\d+$/.exec(net) : null;
  return m ? [`${m[1]}.1`] : [];
}

async function serve(o: ServeOpts): Promise<number> {
  requireOperator(); // as tappaas, never root (#533)
  const mgmtNet = zoneNetwork(o.configDir, "mgmt");
  const adminNet = zoneNetwork(o.configDir, "admin");
  let listen = o.listen;
  if (!listen) {
    const own = mgmtAddress(mgmtNet);
    if (!own) warn(`no interface in mgmt's network (${mgmtNet ?? "zones.json unreadable"}): listening on loopback only`);
    listen = [...(own ? [{ host: own, port: DEFAULT_PORT }] : []), { host: "127.0.0.1", port: DEFAULT_PORT }];
  }
  const access: AccessConfig = {
    firewall: await firewallAddress(mgmtNet),
    allow: o.allow,
    setupAllow: process.env.CONSOLE_SETUP_ALLOW ? list(process.env.CONSOLE_SETUP_ALLOW) : [mgmtNet, adminNet].filter((x): x is string => !!x),
    tokenFile: process.env.CONSOLE_SETUP_TOKEN_FILE ?? join(o.configDir, "console-setup-token"),
    identityFile: join(o.configDir, "identity.json"),
    trustLocalHeaders: o.trustLocalHeaders,
  };
  const webDir = o.webDir ?? join(__dirname, "..", "..", "..", "web", "dist");
  const reads = new Reads({
    configDir: o.configDir,
    stateDir: o.stateDir,
    run: runAsync,
    journalDays: Number(process.env.CONSOLE_JOURNAL_DAYS ?? 7) || 7,
  });
  const log = (l: string): void => console.log(`[console] ${l}`);
  const server = new ConsoleServer({ access, webDir: existsSync(webDir) ? webDir : null, mgmtDomain: mgmtDomain(), version: VERSION, log }, reads);
  for (const l of listen) {
    await server.listen(l.host, l.port).catch((e: Error) => die(`listen ${l.host}:${l.port}: ${e.message}`));
    info(`console ${VERSION} listening on ${l.host}:${l.port}`);
  }
  const s = setupState(access);
  info(`  firewall ${access.firewall.join(", ") || "(unknown)"}; also accepted: ${access.allow.join(", ") || "-"}`);
  if (s.active) info(`  setup token active (${access.tokenFile}): also accepting ${access.setupAllow.join(", ")} with the token`);
  else if (s.tokenPresent && s.identityInstalled) warn(`identity is installed: the setup token is refused — delete ${access.tokenFile}`);
  info(`  front end: ${existsSync(webDir) ? webDir : "not built (API only)"}`);
  reads.start();
  return new Promise<number>(() => undefined); // serve until stopped
}

export function run(argv: string[]): Promise<number> | number {
  if (argv.length === 0) {
    info(renderHelp(HELP));
    return 0;
  }
  if (argv[0] === "--version") {
    info(VERSION);
    return 0;
  }
  const gate = checkArgs(HELP, argv);
  if (gate !== undefined) return gate;
  if (argv[0] !== "serve") {
    info(renderHelp(HELP));
    return guarded(() => die(`Unknown command: ${argv[0]}`));
  }
  let opts: ServeOpts;
  try {
    opts = parseServe(argv.slice(1));
  } catch (e) {
    if (e instanceof DieError) return 1;
    throw e;
  }
  return serve(opts).catch((e: Error) => {
    if (!(e instanceof DieError)) console.error(`[Error] ${e.message}`);
    return 1;
  });
}

if (require.main === module) {
  void Promise.resolve(run(process.argv.slice(2))).then((rc) => {
    process.exitCode = rc;
    if (rc !== 0) process.exit(rc);
  });
}
