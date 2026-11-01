// exec.ts — shared spawnSync plumbing for the manager → controller/bash FFI
// boundary (ADR-007 post-implementation refactor, Phase 3). Always argv
// arrays, never a shell; the env always carries the resolved config root in
// BOTH spellings so bash children (CONFIG_DIR) and TS children
// (TAPPAAS_CONFIG) agree on where the live config lives.

import { spawnSync } from "child_process";
import { closeSync, existsSync, openSync, readFileSync } from "fs";
import { basename, dirname, join } from "path";
import { defaultConfigDir, simulating } from "./config-io";

export { simulating };

// Capped, generous buffer for captured child output (the historical value
// every manager used).
const MAX_BUFFER = 64 * 1024 * 1024;

// Only a NON-default root is exported: the standard path is what every child
// resolves on its own. Exporting it anyway shadowed a test's fixture — a test
// that sets CONFIG_DIR inherits TAPPAAS_CONFIG, which TS children prefer, so
// under `site-manager test --deep` the storage-manager suite edited the live
// shares.json and quota (hrossen, 2026-10-08).
export function configEnv(): Record<string, string | undefined> {
  const cd = defaultConfigDir();
  if (cd === "/home/tappaas/config") return { ...process.env };
  return { ...process.env, CONFIG_DIR: cd, TAPPAAS_CONFIG: cd };
}

// ── TAPPAAS_SIMULATE=1 ─────────────────────────────────────────────────
// The net under the console's simulated apply (ui/src/jobs.ts runs the preview
// instead): a command on the mutator list is logged and not run, and answers
// exit 0 with empty output. Reads run. lib/simulate-mutators.txt is the list,
// with the reason for each entry; common-install-routines.sh reads the same
// file and matches the same way.

export interface MutatorRule {
  bin: string;
  verbs: string[]; // ["*"]: any verb
}

// A manager's build holds only lib/ts, so the deployed list is the clone's.
const MUTATORS_DEPLOYED = "/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/simulate-mutators.txt";

function mutatorsFile(): string | null {
  if (process.env.TAPPAAS_SIMULATE_MUTATORS) return process.env.TAPPAAS_SIMULATE_MUTATORS;
  for (let d = __dirname; dirname(d) !== d; d = dirname(d)) {
    const f = join(d, "lib", "simulate-mutators.txt");
    if (existsSync(f)) return f;
  }
  return existsSync(MUTATORS_DEPLOYED) ? MUTATORS_DEPLOYED : null;
}

export function parseMutators(text: string): MutatorRule[] {
  const rules: MutatorRule[] = [];
  for (const line of text.split("\n")) {
    const [bin, ...verbs] = line.replace(/#.*/, "").trim().split(/\s+/);
    if (bin) rules.push({ bin, verbs });
  }
  return rules;
}

let loaded: MutatorRule[] | null | undefined;

// The list, or null when it cannot be read: the gate then runs nothing.
export function mutators(): MutatorRule[] | null {
  if (loaded === undefined) {
    const f = mutatorsFile();
    try {
      loaded = f ? parseMutators(readFileSync(f, "utf8")) : null;
    } catch {
      loaded = null;
    }
  }
  return loaded;
}

const SSH_VALUE_OPTS = new Set("-b -c -D -E -e -F -I -i -J -L -l -m -O -o -p -Q -R -S -W -w".split(" "));
const PLAIN_PREFIXES = new Set(["then", "do", "if", "elif", "else", "while", "until", "!", "{", "exec", "nohup", "command", "time"]);

function ruleMatches(rules: MutatorRule[], words: string[]): boolean {
  const bin = basename(words[0]);
  const verb = words.slice(1).find((w) => !w.startsWith("-"));
  return rules.some((r) => r.bin === bin && (r.verbs.includes("*") || (verb !== undefined && r.verbs.includes(verb))));
}

// A shell string: every command in it, split at its separators. Quotes go, so a
// `bash -c "…"` nested in the string is seen; an `echo "a; qm stop 1"` is a false
// hit, which at worst skips an echo.
function shellMatches(rules: MutatorRule[], script: string): boolean {
  return script
    .split(/&&|\|\||\$\(|[\n;|&()`]/)
    .some((seg) => wordsMatch(rules, seg.replace(/['"\\]/g, " ").trim().split(/\s+/).filter(Boolean)));
}

// The command in an argv, behind what only wraps it.
function wordsMatch(rules: MutatorRule[], argv: string[]): boolean {
  let w = argv;
  for (;;) {
    if (w.length === 0) return false;
    const bin = basename(w[0]);
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w[0]) || PLAIN_PREFIXES.has(bin)) {
      w = w.slice(1);
    } else if (bin === "env" || bin === "sudo") {
      w = w.slice(1);
      while (w.length && (w[0].startsWith("-") || (bin === "env" && w[0].includes("=")))) w = w.slice(/^-[ug]$/.test(w[0]) ? 2 : 1);
    } else if (bin === "timeout") {
      w = w.slice(1);
      while (w.length && w[0].startsWith("-")) w = w.slice(1);
      w = w.slice(1); // the duration
    } else if (bin === "ssh") {
      w = w.slice(1);
      while (w.length && w[0].startsWith("-")) w = w.slice(SSH_VALUE_OPTS.has(w[0]) ? 2 : 1);
      return shellMatches(rules, w.slice(1).join(" "));
    } else if ((bin === "bash" || bin === "sh") && w[1] && /^-[a-z]*c$/.test(w[1])) {
      return shellMatches(rules, w.slice(2).join(" "));
    } else {
      return ruleMatches(rules, w);
    }
  }
}

export function isMutator(bin: string, args: string[], rules: MutatorRule[] | null = mutators()): boolean {
  return rules === null || wordsMatch(rules, [bin, ...args]);
}

// True when this command must not run: said on stderr, the caller answers 0.
function simulated(bin: string, args: string[]): boolean {
  if (!simulating() || !isMutator(bin, args)) return false;
  if (mutators() === null) console.error("[simulate] simulate-mutators.txt not found: running nothing");
  console.error(`[simulate] ${[bin, ...args].join(" ")}`);
  return true;
}

export interface ExecResult {
  rc: number;
  stdout: string;
  stderr: string;
  // false when the binary could not be spawned at all (missing on PATH).
  ran: boolean;
}

// Run + capture, never throwing on non-zero exit: callers that need the rc /
// output triple (e.g. scraping a validator's stderr) use this.
export function captureResult(bin: string, args: string[]): ExecResult {
  if (simulated(bin, args)) return { rc: 0, stdout: "", stderr: "", ran: true };
  const r = spawnSync(bin, args, {
    encoding: "utf8",
    env: configEnv(),
    maxBuffer: MAX_BUFFER,
  });
  if (r.error) {
    return { rc: -1, stdout: "", stderr: r.error.message, ran: false };
  }
  return { rc: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ran: true };
}

// Run + capture stdout; THROW on spawn failure or non-zero exit with the
// unified message every manager used to hand-roll.
export function capture(bin: string, args: string[]): string {
  if (simulated(bin, args)) return "";
  const r = spawnSync(bin, args, {
    encoding: "utf8",
    env: configEnv(),
    maxBuffer: MAX_BUFFER,
  });
  if (r.error) throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
  if (r.status !== 0) {
    const stderr = (r.stderr ?? "").trim();
    throw new Error(`${bin} ${args.join(" ")} failed (exit ${r.status}): ${stderr}`);
  }
  return r.stdout ?? "";
}

// Run streaming the child's output to the operator's terminal (stdio inherit)
// — for long-running delegations whose own progress should be visible.
// Returns the exit code; throws only when the binary cannot be spawned.
// opts.cwd runs the child from a specific directory (module-manager reconcile
// runs a module's ./update.sh from the module directory, like the bash did).
// opts.env is merged OVER configEnv() — for delegations that must plumb extra
// environment down to the child (e.g. site-manager update forwarding
// TAPPAAS_MODULE_FORCE / TAPPAAS_NO_GIT_PULL to the update sweep).
export function stream(
  bin: string,
  args: string[],
  opts?: { cwd?: string; env?: Record<string, string | undefined> },
): number {
  if (simulated(bin, args)) return 0;
  const r = spawnSync(bin, args, {
    encoding: "utf8",
    stdio: "inherit",
    env: { ...configEnv(), ...(opts?.env ?? {}) },
    ...(opts?.cwd ? { cwd: opts.cwd } : {}),
  });
  if (r.error) throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
  return r.status ?? -1;
}

// Run with the child's output — stdout and stderr, interleaved as it writes
// them — appended to <file> instead of the terminal: for a long run whose full
// output belongs in a log, while the caller prints a short verdict. Returns the
// exit code; throws only when the binary cannot be spawned.
export function streamToFile(
  bin: string,
  args: string[],
  file: string,
  opts?: { env?: Record<string, string | undefined> },
): number {
  if (simulated(bin, args)) return 0;
  const fd = openSync(file, "a");
  try {
    const r = spawnSync(bin, args, {
      stdio: ["ignore", fd, fd],
      env: { ...configEnv(), ...(opts?.env ?? {}) },
    });
    if (r.error) throw new Error(`${bin} ${args[0] ?? ""}: ${r.error.message}`);
    return r.status ?? -1;
  } finally {
    closeSync(fd);
  }
}

// Ask the operator on the terminal (sync, like every TS manager's loop): the
// answer, or null when nobody can answer — no terminal, or
// TAPPAAS_NONINTERACTIVE=1 (test-module.sh and site-manager test set it: a
// boundary in tmux has a terminal and no one watching it). The caller then
// refuses or names the flag that answers it.
export function askTerminal(question: string): string | null {
  if (process.env.TAPPAAS_NONINTERACTIVE === "1") return null;
  const r = spawnSync("bash", ["-c", 'printf "%s" "$1" > /dev/tty; IFS= read -r v < /dev/tty || exit 1; printf "%s" "$v"', "--", question], {
    encoding: "utf8",
  });
  if (r.status !== 0) return null;
  return (r.stdout ?? "").trim();
}
