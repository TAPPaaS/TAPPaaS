// run.ts — the console's one way to read the site: run a manager verb and take
// its output (ADR-034 D1). Asynchronous, because `health-manager validate`
// takes half a minute and the server must keep answering meanwhile; argv
// arrays, never a shell; the config-root environment from lib/ts exec.ts, so a
// child reads the config the console reads.

import { ChildProcess, spawn } from "child_process";
import { ExecResult, configEnv } from "../../lib/ts/src/exec";

export type Runner = (bin: string, args: string[], timeoutMs?: number) => Promise<ExecResult>;

const MAX_OUTPUT = 64 * 1024 * 1024;

export const runAsync: Runner = (bin, args, timeoutMs = 120_000) =>
  new Promise((resolve) => {
    let child: ChildProcess;
    try {
      child = spawn(bin, args, { env: configEnv(), stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      resolve({ rc: -1, stdout: "", stderr: (e as Error).message, ran: false });
      return;
    }
    const out: NodeBuffer[] = [];
    const err: NodeBuffer[] = [];
    let size = 0;
    let settled = false;
    const done = (r: ExecResult): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(r);
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      done({ rc: -1, stdout: Buffer.concat(out).toString("utf8"), stderr: `timed out after ${timeoutMs / 1000}s`, ran: true });
    }, timeoutMs);
    child.stdout?.on("data", (c) => {
      size += c.length;
      if (size <= MAX_OUTPUT) out.push(c);
    });
    child.stderr?.on("data", (c) => err.push(c));
    child.on("error", (e) => done({ rc: -1, stdout: "", stderr: e.message, ran: false }));
    child.on("close", (code) =>
      done({ rc: code ?? -1, stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8"), ran: true }),
    );
  });

// A verb that reads a secret on stdin (ap-manager ssid set-passphrase, #889):
// the secret never reaches argv, where the process list and the logs see it.
// stdin is written once and closed; the output is captured as for runAsync.
export type StdinRunner = (bin: string, args: string[], input: string, timeoutMs?: number) => Promise<ExecResult>;

export const runWithStdin: StdinRunner = (bin, args, input, timeoutMs = 60_000) =>
  new Promise((resolve) => {
    let child: ChildProcess;
    try {
      child = spawn(bin, args, { env: { ...configEnv(), NO_COLOR: "1", TERM: "dumb" }, stdio: ["pipe", "pipe", "pipe"] });
    } catch (e) {
      resolve({ rc: -1, stdout: "", stderr: (e as Error).message, ran: false });
      return;
    }
    const out: NodeBuffer[] = [];
    const err: NodeBuffer[] = [];
    let settled = false;
    const done = (r: ExecResult): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(r);
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      done({ rc: -1, stdout: Buffer.concat(out).toString("utf8"), stderr: `timed out after ${timeoutMs / 1000}s`, ran: true });
    }, timeoutMs);
    child.stdout?.on("data", (c) => out.push(c));
    child.stderr?.on("data", (c) => err.push(c));
    child.on("error", (e) => done({ rc: -1, stdout: "", stderr: e.message, ran: false }));
    child.on("close", (code) =>
      done({ rc: code ?? -1, stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8"), ran: true }),
    );
    child.stdin?.on("error", () => undefined);
    child.stdin?.end(input);
  });

// A verb's --json document. Some verbs exit 1 with a complete document (validate
// when a gate fails); `okRcs` names the exit codes whose output is the answer.
export async function runJson<T>(run: Runner, bin: string, args: string[], opts: { okRcs?: number[]; timeoutMs?: number } = {}): Promise<T> {
  const r = await run(bin, args, opts.timeoutMs);
  const what = `${bin} ${args.join(" ")}`;
  if (!r.ran) throw new Error(`${what}: ${r.stderr || "not found"}`);
  if (!(opts.okRcs ?? [0]).includes(r.rc)) {
    const last = (r.stderr || r.stdout).replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n").slice(-1)[0] ?? "";
    throw new Error(`${what}: exit ${r.rc}${last ? ` — ${last}` : ""}`);
  }
  try {
    return JSON.parse(r.stdout) as T;
  } catch {
    throw new Error(`${what}: output is not JSON`);
  }
}

// A job's child: its output as it comes (stdout and stderr in one stream, the
// order the child wrote them), its exit code at the end. stdin is closed, so a
// script that would prompt fails rather than waits.
export type Streamer = (bin: string, args: string[], onOutput: (chunk: string) => void, timeoutMs?: number) => Promise<{ rc: number; ran: boolean; error: string | null }>;

export const streamAsync: Streamer = (bin, args, onOutput, timeoutMs = 4 * 3600_000) =>
  new Promise((resolve) => {
    let child: ChildProcess;
    try {
      child = spawn(bin, args, { env: { ...configEnv(), NO_COLOR: "1", TERM: "dumb" }, stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      resolve({ rc: -1, ran: false, error: (e as Error).message });
      return;
    }
    let settled = false;
    const done = (r: { rc: number; ran: boolean; error: string | null }): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(r);
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      onOutput(`\n[console] timed out after ${Math.round(timeoutMs / 60_000)} min: stopped\n`);
      done({ rc: -1, ran: true, error: "timed out" });
    }, timeoutMs);
    child.stdout?.on("data", (c) => onOutput(c.toString("utf8")));
    child.stderr?.on("data", (c) => onOutput(c.toString("utf8")));
    child.on("error", (e) => done({ rc: -1, ran: false, error: e.message }));
    child.on("close", (code) => done({ rc: code ?? -1, ran: true, error: null }));
  });
