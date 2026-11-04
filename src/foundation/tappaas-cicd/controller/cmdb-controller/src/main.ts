// main.ts — cmdb-controller (ADR-040 D2): the service that keeps the CMDB.
//
//   cmdb-controller serve    the service (cmdb.service): schema, metamodel, the API
//   cmdb-controller schema   apply the schema and load the metamodel, then exit
//
// The store is PostgreSQL's database cmdb, reached over its Unix socket with
// peer authentication as the user the service runs as (tappaas). Nothing else
// opens it: managers, scripts and the console go through the API.
//
// Environment (the defaults are tappaas-cicd's):
//   CMDB_PGHOST      PostgreSQL's socket directory   /run/postgresql
//   CMDB_PGPORT      its port                        5432
//   CMDB_PGDATABASE  the database                    cmdb
//   CMDB_PGUSER      the role                        tappaas
//   CMDB_SOCKET      the API's Unix socket           /run/cmdb/cmdb.sock
//   CMDB_LISTEN      loopback host:port, "" for none 127.0.0.1:9098
//   CMDB_TOKEN_FILE  the loopback listener's token   /etc/secrets/cmdb-token
//   CMDB_SHARE       where metamodel/ and schema/ are (default: beside the build)
//   CMDB_EXPIRY_CHECK_SECONDS  how often unreported CIs are marked unseen   3600
//   CMDB_COMPONENTS  the components.json whose cmdbSource components `rescan` asks
//                    (default: /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/components.json)
//   CMDB_SOURCE_PATH the PATH a source runs with (default: the managers' ~/bin first)

import { chmodSync, existsSync, readFileSync, readdirSync, unlinkSync } from "fs";
import { dirname, join } from "path";
import { defaultConfigDir } from "../../../lib/ts/src/config-io";
import { Metamodel } from "./metamodel";
import { Pg } from "./pg";
import { Api } from "./server";
import { Store } from "./store";

const env = process.env;

function log(line: string): void {
  console.log(`cmdb-controller: ${line}`);
}

/** The directory holding metamodel/ and schema/: CMDB_SHARE, else the first
 *  ancestor of this file that has both (the nix build copies them beside
 *  lib/, the source tree has them beside src/). */
export function shareDir(): string {
  if (env.CMDB_SHARE) return env.CMDB_SHARE;
  for (let d = __dirname; d !== dirname(d); d = dirname(d)) {
    if (existsSync(join(d, "metamodel")) && existsSync(join(d, "schema"))) return d;
  }
  throw new Error("cannot find metamodel/ and schema/; set CMDB_SHARE");
}

/** Bring the store to the newest schema file: each cmdb-v<N>.sql above the
 *  version the store records, in order. A store newer than this build is
 *  refused: an older controller must not write a newer layout. */
export async function applySchema(pg: Pg, dir: string): Promise<number> {
  const files = readdirSync(dir)
    .map((f) => ({ f, m: /^cmdb-v(\d+)\.sql$/.exec(f) }))
    .filter((x) => x.m)
    .map((x) => ({ file: join(dir, x.f), version: Number(x.m![1]) }))
    .sort((a, b) => a.version - b.version);
  if (!files.length) throw new Error(`no cmdb-v<N>.sql in ${dir}`);
  const r = await pg.query(
    "SELECT CASE WHEN to_regclass('object') IS NULL THEN NULL ELSE obj_description(to_regclass('object'), 'pg_class') END AS comment",
  );
  const m = /cmdb schema (\d+)/.exec(String(r.rows[0]?.comment ?? ""));
  const have = m ? Number(m[1]) : 0;
  const newest = files[files.length - 1].version;
  if (have > newest) throw new Error(`the store is at schema ${have}; this cmdb-controller knows up to ${newest}`);
  for (const f of files) {
    if (f.version <= have && have !== 0) continue;
    await pg.script(readFileSync(f.file, "utf8"));
    if (f.version > have) log(`schema ${f.version} applied`);
  }
  return newest;
}

export async function openStore(): Promise<{ pg: Pg; store: Store }> {
  const share = shareDir();
  const mm = Metamodel.fromDir(join(share, "metamodel"));
  const pg = new Pg({
    socketDir: env.CMDB_PGHOST ?? "/run/postgresql",
    port: Number(env.CMDB_PGPORT ?? "5432"),
    database: env.CMDB_PGDATABASE ?? "cmdb",
    user: env.CMDB_PGUSER ?? "tappaas",
  });
  await pg.connect();
  await applySchema(pg, join(share, "schema"));
  await pg.tx((q) => mm.store(q));
  log(`metamodel loaded: ${mm.classes.size} classes, ${mm.relations.length} relation ends`);
  return { pg, store: new Store(pg, mm) };
}

function readToken(file: string): string | null {
  if (!existsSync(file)) return null;
  const t = readFileSync(file, "utf8").trim();
  return t || null;
}

async function serve(): Promise<void> {
  const { pg, store } = await openStore();
  pg.onClose = () => {
    log("the PostgreSQL connection closed; exiting for a restart");
    process.exit(75);
  };
  const tokenFile = env.CMDB_TOKEN_FILE ?? "/etc/secrets/cmdb-token";
  const token = readToken(tokenFile);
  const api = new Api({ store, token, log, configDir: defaultConfigDir() });

  const sock = env.CMDB_SOCKET ?? "/run/cmdb/cmdb.sock";
  if (existsSync(sock)) unlinkSync(sock); // a socket the last run left behind
  const onSocket = api.server(false);
  onSocket.on("error", (e) => {
    log(`socket ${sock}: ${e.message}`);
    process.exit(1);
  });
  await new Promise<void>((resolve) => onSocket.listen(sock, resolve));
  chmodSync(sock, 0o660);
  log(`listening on ${sock}`);

  const listen = env.CMDB_LISTEN ?? "127.0.0.1:9098";
  let onLoopback: ReturnType<Api["server"]> | null = null;
  if (listen && token) {
    const i = listen.lastIndexOf(":");
    const host = listen.slice(0, i);
    const port = Number(listen.slice(i + 1));
    onLoopback = api.server(true);
    onLoopback.on("error", (e) => log(`${listen}: ${e.message} (the socket still serves)`));
    await new Promise<void>((resolve) => onLoopback!.listen(port, host, resolve));
    log(`listening on ${listen} (bearer token from ${tokenFile})`);
  } else if (listen) {
    log(`no token at ${tokenFile}: not listening on ${listen}`);
  }

  // Unseen CIs (D5): on a timer as well as after each report, so a site whose
  // sources have all gone quiet is still marked.
  const every = Number(env.CMDB_EXPIRY_CHECK_SECONDS ?? "3600");
  const expire = (): void => {
    store.expire().then(
      (n) => n && log(`${n} CI(s) unseen: no source reported them within their class's expiry`),
      (e) => log(`expiry check: ${e instanceof Error ? e.message : String(e)}`),
    );
  };
  expire();
  const timer = every > 0 ? setInterval(expire, every * 1000) : null;

  const stop = (): void => {
    log("stopping");
    if (timer) clearInterval(timer);
    api.close();
    onSocket.close();
    onLoopback?.close();
    pg.close();
    if (existsSync(sock)) unlinkSync(sock);
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

const HELP = `cmdb-controller — keeps the CMDB, the actual state of the site

  cmdb-controller serve    run the service (cmdb.service): apply the schema, load
                           the metamodel, serve the API on the socket and loopback
  cmdb-controller schema   apply the schema and load the metamodel, then exit

The verbs are the cmdb CLI's: cmdb --help.`;

async function main(argv: string[]): Promise<number> {
  const verb = argv[0] ?? "--help";
  if (verb === "--help" || verb === "-h" || verb === "help") {
    console.log(HELP);
    return 0;
  }
  if (verb === "serve") {
    await serve();
    return -1; // keeps running
  }
  if (verb === "schema") {
    const { pg } = await openStore();
    pg.close();
    return 0;
  }
  console.error(`cmdb-controller: unknown verb ${verb}\n\n${HELP}`);
  return 2;
}

if (require.main === module) {
  main(process.argv.slice(2)).then(
    (rc) => {
      if (rc >= 0) process.exit(rc);
    },
    (e) => {
      console.error(`cmdb-controller: ${e instanceof Error ? e.message : String(e)}`);
      process.exit(1);
    },
  );
}
