// rescan.ts — `cmdb rescan` (ADR-040 D2): ask every source again, so the
// actual state can be recreated from what the sources see. A source is a
// component that answers `<component> report`: it interrogates its plane
// (read-only, as its validate or reconcile already does) and reports what it
// saw back to this service (D4).
//
// The sources are the components components.json marks "cmdbSource": true,
// read at each rescan, so a manager that gains a report verb is asked from the
// next rescan on. They run one at a time and asynchronously — each reports to
// this same service while it runs — as the service's user (tappaas), with the
// PATH the managers get from ~/bin.

import { ChildProcess, spawn } from "child_process";
import { existsSync, readFileSync } from "fs";

export interface RescanSource {
  name: string; // the component, as components.json names it
  argv: string[]; // its report verb: [name, "report"]
}

export interface RescanResult {
  source: string;
  ok: boolean;
  exitCode: number | null;
  seconds: number;
  error?: string;
  stderr?: string; // the last lines it wrote, when it failed
  fallback?: boolean; // its report verb does not know --discover (D15): asked plainly
  reached?: number; // the sweep: the devices it reported this time
  missed?: string[]; // the sweep: the devices it reported before and not this time ("class/name")
}

export interface CommandResult {
  ok: boolean;
  exitCode: number | null;
  seconds: number;
  error?: string;
  stdout: string;
  stderr: string;
}

const env = process.env;

export const DEFAULT_COMPONENTS = "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/components.json";

// What a login shell of tappaas has: ~/bin first, then the NixOS profiles.
const MANAGER_PATH = [
  "/home/tappaas/bin",
  "/run/wrappers/bin",
  "/home/tappaas/.nix-profile/bin",
  "/etc/profiles/per-user/tappaas/bin",
  "/nix/var/nix/profiles/default/bin",
  "/run/current-system/sw/bin",
].join(":");

/** The components marked cmdbSource in components.json. A missing or broken
 *  file is an error the caller sees: a rescan that silently asked no one
 *  would look like an empty site. */
export function rescanSources(file: string = env.CMDB_COMPONENTS ?? DEFAULT_COMPONENTS): RescanSource[] {
  if (!existsSync(file)) throw new Error(`no components list at ${file} (CMDB_COMPONENTS)`);
  let doc: unknown;
  try {
    doc = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    throw new Error(`${file}: ${e instanceof Error ? e.message : String(e)}`);
  }
  const list = doc !== null && typeof doc === "object" ? (doc as { components?: unknown }).components : undefined;
  if (!Array.isArray(list)) throw new Error(`${file}: no components[]`);
  return list
    .filter((c): c is { name: string; cmdbSource: true } => c !== null && typeof c === "object" && c.cmdbSource === true && typeof c.name === "string")
    .map((c) => ({ name: c.name, argv: [c.name, "report"] }));
}

/** A verb, alongside the server, with the managers' PATH. */
export function runCommand(argv: string[], timeoutSeconds: number): Promise<CommandResult> {
  const started = Date.now();
  const secs = (): number => Math.round((Date.now() - started) / 100) / 10;
  return new Promise((resolve) => {
    let child: ChildProcess;
    let tail = "";
    let out = "";
    const done = (r: Pick<CommandResult, "ok" | "exitCode" | "error">): void => {
      clearTimeout(timer);
      resolve({ seconds: secs(), ...r, stdout: out, stderr: tail.trim().split("\n").slice(-10).join("\n") });
    };
    const timer = setTimeout(() => {
      child?.kill("SIGTERM");
      done({ ok: false, exitCode: null, error: `no answer within ${timeoutSeconds}s` });
    }, timeoutSeconds * 1000);
    try {
      child = spawn(argv[0], argv.slice(1), {
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...env, PATH: env.CMDB_SOURCE_PATH ?? `${MANAGER_PATH}:${env.PATH ?? ""}`, HOME: env.HOME ?? "/home/tappaas" },
      });
    } catch (e) {
      return done({ ok: false, exitCode: null, error: e instanceof Error ? e.message : String(e) });
    }
    child.stdout?.on("data", (c) => {
      out += c.toString("utf8");
    });
    child.stderr?.on("data", (c) => {
      tail = (tail + c.toString("utf8")).slice(-4000);
    });
    child.on("error", (e) => done({ ok: false, exitCode: null, error: e.message }));
    child.on("close", (code) => done({ ok: code === 0, exitCode: code }));
  });
}

async function run(src: RescanSource, timeoutSeconds: number, discover: boolean): Promise<RescanResult> {
  const argv = discover ? [...src.argv, "--discover"] : src.argv;
  let r = await runCommand(argv, timeoutSeconds);
  // A source that does not know the flag reports as it does today (D15): the
  // argument gates refuse it by name before anything runs.
  const fallback = discover && !r.ok && /unknown option.*--discover/.test(r.stderr);
  if (fallback) r = await runCommand(src.argv, timeoutSeconds);
  return {
    source: src.name,
    ok: r.ok,
    exitCode: r.exitCode,
    seconds: r.seconds,
    ...(r.error ? { error: r.error } : {}),
    ...(r.ok ? {} : { stderr: r.stderr }),
    ...(fallback ? { fallback: true } : {}),
  };
}

export async function rescan(
  log: (line: string) => void,
  sources: RescanSource[] = rescanSources(),
  opts: { discover?: boolean } = {},
): Promise<{ asked: RescanResult[] }> {
  const timeout = Number(env.CMDB_RESCAN_TIMEOUT_SECONDS ?? "900");
  const asked: RescanResult[] = [];
  for (const src of sources) {
    log(`rescan: asking ${src.name} (${src.argv.join(" ")}${opts.discover ? " --discover" : ""})`);
    const r = await run(src, timeout, opts.discover === true);
    if (!r.ok) log(`rescan: ${src.name} failed (${r.error ?? `exit ${String(r.exitCode)}`})`);
    asked.push(r);
  }
  return { asked };
}
