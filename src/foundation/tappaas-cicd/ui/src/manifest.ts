// manifest.ts — what the console may run (ADR-034 D4, Testing T2). A job's
// argv must be a verb a manifest declares, with options the verb declares:
// every TypeScript manager's own `--help --json` (lib/ts help.ts renderManifest),
// read when the console starts, and the declared file for the bash controllers
// and scripts (manifest/bash-verbs.json). What is not in a manifest is not in
// the console. The job model (jobs.ts) takes from here how a verb previews and
// whether it is destructive.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { Manifest, ManifestOption, ManifestVerb } from "../../lib/ts/src/help";
import { Runner, runJson } from "./run";

export type { Manifest, ManifestOption, ManifestVerb };

// The TypeScript managers, each answering `--help --json`: the standard nine,
// used when the site has no control-plane registry yet.
export const TS_MANAGERS = [
  "module-manager",
  "site-manager",
  "network-manager",
  "environment-manager",
  "identity-manager",
  "backup-manager",
  "health-manager",
  "storage-manager",
  "rack-manager",
];

// The managers whose `--help --json` the console loads: those the control
// plane's registry (config/control-plane.json, ADR-035 D5) lists with a
// help-json manifest, standard or contributed by a module. Without a registry —
// or one that lists none — the standard nine (TS_MANAGERS).
export function registeredManagers(configDir: string): string[] {
  try {
    const doc = JSON.parse(readFileSync(join(configDir, "control-plane.json"), "utf8")) as {
      components?: { name?: unknown; kind?: unknown; manifest?: unknown }[];
    };
    const names = (doc.components ?? [])
      .filter((c) => c.kind === "manager" && c.manifest === "help-json" && typeof c.name === "string")
      .map((c) => c.name as string);
    return names.length > 0 ? [...new Set(names)] : TS_MANAGERS;
  } catch {
    return TS_MANAGERS;
  }
}

// Options a job may never carry: the console's managers read the config the
// console reads (lib/ts exec.ts configEnv), and a help request is not a job.
const REFUSED_OPTIONS = new Set(["--config-dir", "--help", "-h"]);

export interface Manifests {
  byBin: Map<string, Manifest>;
  errors: { bin: string; error: string }[];
  loadedAt: string;
}

export async function loadManifests(run: Runner, bashFile: string | null, bins: string[] = TS_MANAGERS): Promise<Manifests> {
  const byBin = new Map<string, Manifest>();
  const errors: { bin: string; error: string }[] = [];
  await Promise.all(
    bins.map(async (bin) => {
      try {
        const m = await runJson<Manifest>(run, bin, ["--help", "--json"], { timeoutMs: 60_000 });
        if (m.manifest !== 1 || !Array.isArray(m.verbs)) throw new Error("not a version-1 manifest");
        byBin.set(bin, normalize(m));
      } catch (e) {
        errors.push({ bin, error: (e as Error).message });
      }
    }),
  );
  if (bashFile) {
    try {
      if (!existsSync(bashFile)) throw new Error("not found");
      const doc = JSON.parse(readFileSync(bashFile, "utf8")) as { manifests?: Manifest[] };
      for (const m of doc.manifests ?? []) byBin.set(m.name, normalize(m));
    } catch (e) {
      errors.push({ bin: bashFile, error: (e as Error).message });
    }
  }
  return { byBin, errors, loadedAt: new Date().toISOString() };
}

// A manifest from a manager built before a mark existed, or the declared bash
// verbs, which carry none: every list is present, so a reader never guards.
export function normalize(m: Manifest): Manifest {
  for (const v of m.verbs) {
    v.readWhen ??= [];
    v.writeWhen ??= [];
    v.destructiveWhen ??= [];
    v.disruptions ??= [];
  }
  return m;
}

// ── validating a job's argv ───────────────────────────────────────────

export interface Validated {
  ok: true;
  bin: string;
  manifest: Manifest;
  verb: ManifestVerb;
  args: string[]; // argv without the bin
  keyLength: number; // how many leading words select the verb
  positionals: string[]; // the positional values (after the verb's words)
  read: boolean; // this call changes nothing (a read verb without a writeWhen option, or a readWhen word)
  preview: ManifestVerb["preview"]; // how THIS call previews: the verb's form, or none for a read verb's writeWhen call
  destructive: boolean; // this call needs the typed name and the Installer role
  object: string; // what a typed confirmation must name
  objectLabel: string; // the object as shown: within its container ("<switch>:<port>"); also accepted typed
}
export type Validation = Validated | { ok: false; reason: string };

const isOption = (t: string): boolean => t.startsWith("-") && t !== "-" && !/^-\d/.test(t);
const SAFE = /^[^\u0000-\u001f\u007f]*$/;

function matchKey(keys: string[][], args: string[]): number | null {
  let best: number | null = null;
  for (const k of keys) {
    if (k.length > args.length) continue;
    const hit = k.every((w, i) => (w === "*" ? args[i] !== undefined && !isOption(args[i]) : w === args[i]));
    if (hit && (best === null || k.length > best)) best = k.length;
  }
  return best;
}

export function findVerb(m: Manifest, args: string[]): { verb: ManifestVerb; used: number } | null {
  let best: { verb: ManifestVerb; used: number } | null = null;
  for (const v of m.verbs) {
    const used = matchKey(v.keys, args);
    if (used !== null && (best === null || used > best.used)) best = { verb: v, used };
  }
  return best;
}

export function validateArgv(ms: Manifests, argv: unknown): Validation {
  if (!Array.isArray(argv) || argv.length === 0 || !argv.every((a) => typeof a === "string")) {
    return { ok: false, reason: "argv must be a non-empty array of strings" };
  }
  const a = argv as string[];
  for (const t of a) {
    if (t.length > 4096 || !SAFE.test(t)) return { ok: false, reason: "an argument holds a control character or is too long" };
  }
  const [bin, ...args] = a;
  const m = ms.byBin.get(bin);
  if (!m) return { ok: false, reason: `'${bin}' is not a manager the console runs (no manifest)` };
  const found = findVerb(m, args);
  if (!found) return { ok: false, reason: `${bin} ${args.filter((x) => !isOption(x)).slice(0, 3).join(" ")}: not a verb ${bin} declares` };
  const { verb, used } = found;
  const name = `${bin} ${verb.verb}`;
  const opts = new Map<string, ManifestOption>();
  for (const o of [...verb.options, ...m.common]) opts.set(o.flag, o);
  const positionals: string[] = [];
  const seen = new Set<string>();
  for (let i = used; i < args.length; i++) {
    const t = args[i];
    if (!isOption(t)) {
      positionals.push(t);
      continue;
    }
    if (REFUSED_OPTIONS.has(t)) return { ok: false, reason: `${name}: ${t} is not something a job carries` };
    const o = opts.get(t);
    if (!o) {
      if (verb.open && t.startsWith("--") && !t.includes("=")) {
        if (args[i + 1] !== undefined && !isOption(args[i + 1])) i++;
        continue;
      }
      return { ok: false, reason: `${name}: unknown option '${t}' (not in its --help)` };
    }
    if (seen.has(t) && !o.repeatable && o.takesValue) return { ok: false, reason: `${name}: ${t} given twice` };
    seen.add(t);
    if (o.takesValue) {
      const v = args[i + 1];
      if (v === undefined) return { ok: false, reason: `${name}: ${t} needs a value (${o.arg ?? "value"})` };
      if (o.choices && !o.choices.includes(v)) return { ok: false, reason: `${name}: ${t} is one of ${o.choices.join(", ")}` };
      i++;
    }
  }
  const required = verb.positionals.filter((p) => !p.optional).length;
  const unbounded = verb.open || verb.positionals.some((p) => p.repeatable);
  if (positionals.length < required) {
    return { ok: false, reason: `${name}: expected ${verb.positionals.filter((p) => !p.optional).map((p) => `<${p.name}>`).join(" ")}` };
  }
  if (!unbounded && positionals.length > verb.positionals.length) {
    return { ok: false, reason: `${name}: unexpected argument '${positionals[verb.positionals.length]}'` };
  }
  const tokens = new Set(args);
  // `test --deep` creates and removes guests: a read verb's writeWhen option
  // makes the call a write with no dry run, previewed and queued like any change.
  const writeMark = verb.effect === "read" ? (verb.writeWhen ?? []).find((w) => tokens.has(w.flag)) : undefined;
  const read = !writeMark && (verb.effect === "read" || verb.readWhen.some((w) => tokens.has(w)));
  const preview: ManifestVerb["preview"] = writeMark ? { kind: "none", touches: writeMark.touches } : verb.preview;
  const destructive = !read && (verb.destructive || verb.destructiveWhen.some((w) => tokens.has(w)));
  const marks = new Set([...verb.readWhen, ...verb.destructiveWhen]);
  const nameOpt = args.indexOf("--name");
  let object =
    positionals.find((p) => !marks.has(p)) ??
    (nameOpt >= 0 ? args[nameOpt + 1] : undefined) ??
    verb.verb;
  let objectLabel = object;
  // A verb that names its object's positional (remove-port: the port, within
  // its switch) is confirmed by that, not by the first positional (#855).
  if (verb.object) {
    const at = (name: string): string | undefined => {
      const i = verb.positionals.findIndex((p) => p.name === name);
      return i >= 0 ? positionals[i] : undefined;
    };
    const own = at(verb.object.positional);
    if (own !== undefined) {
      object = own;
      objectLabel = [...verb.object.within.map(at).filter((x): x is string => x !== undefined), own].join(":");
    }
  }
  return { ok: true, bin, manifest: m, verb, args, keyLength: used, positionals, read, preview, destructive, object, objectLabel };
}

// ── preview and apply argv (T3) ───────────────────────────────────────

// The base of a change: the argv with its preview or applying flag taken out.
// A preview and its apply share it, which is how an apply finds its preview.
export function baseArgv(v: Validated): string[] {
  const p = v.preview;
  const flag = p.kind === "apply-flag" || p.kind === "dry-run-flag" ? p.flag : null;
  return [v.bin, ...(flag ? v.args.filter((x) => x !== flag) : v.args)];
}

// What a preview runs: the dry-run form, or nothing (a verb with no dry run:
// the preview is the command and what the manifest says it touches).
export function previewArgv(v: Validated): string[] | null {
  const base = baseArgv(v);
  const p = v.preview;
  if (p.kind === "apply-flag") return base;
  if (p.kind === "dry-run-flag") return [...base, p.flag];
  return null;
}

// What an apply runs: the base plus the applying flag (or minus the dry run).
export function applyArgv(v: Validated): string[] {
  const base = baseArgv(v);
  const p = v.preview;
  return p.kind === "apply-flag" ? [...base, p.flag] : base;
}

export function sameArgv(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}
