// help.ts — shared --help renderer and argument gate for the TAPPaaS
// TypeScript managers.
//
// SHARED via lib/ts (ADR-007 post-implementation refactor, Phase 3) — the
// former per-manager vendored copies are gone; every manager imports this
// one file so --help renders the SAME way everywhere.
//
// A manager declares a HelpSpec (its verbs + per-verb options) and prints
// `renderHelp(spec)`. Layout (matches the network-manager reference):
//
//   <name> <version> — <tagline>
//
//   Usage:
//     <name> <verb.usage>            (one line per verb)
//
//   <verb> options:                  (one block per verb that HAS options)
//     --flag <arg>   description     (one line per option)
//
//   common:                          (options shared by every verb)
//     --flag <arg>   description
//     -h, --help     Show this help
//
//   <notes...>                       (optional free-text trailing paragraphs)
//
// The same spec is the argument gate (#644): checkArgs() prints a verb's help
// for -h/--help in ANY position and refuses an option the verb does not
// declare, before the manager parses or runs anything. What a verb accepts is
// read from its usage line, its options, `hidden` and the common options — so
// an accepted option is always a documented one.

import { CL, RD, info } from "./cli";

export interface HelpVerb {
  // The usage line WITHOUT the leading CLI name, e.g. "zone add <name> [options]".
  usage: string;
  // Header for this verb's options block, e.g. "zone add". Derived from `usage`
  // (tokens up to the first <arg>/[opt]/--flag) when omitted.
  name?: string;
  // Appended to the usage line, e.g. "(alias: get)".
  note?: string;
  // [flag, description] pairs documented under "<name> options:".
  options?: Array<[string, string]>;
  // The words that select this verb, e.g. "reconcile", "node add",
  // "enable|disable|manual". Derived from `usage` when omitted.
  verb?: string;
  // Other spellings that select this verb, e.g. ["get"] for show.
  aliases?: string[];
  // Accepted but not shown in the help (legacy spellings), e.g. ["--env <e>"].
  hidden?: string[];
  // Accept any --option: the verb forwards them to a tool that checks its own.
  anyOption?: boolean;
  // Longer text printed only by `<cli> <verb> --help`.
  details?: string;
  // ── the verb manifest (`--help --json`, ADR-034 D4) ──
  // What the verb does to the site and how its dry run is spelled. Defaults
  // (defaultEffect): a reading verb (list, show, validate, …) is "read"; a verb
  // that takes --apply previews without it; one that takes --check or
  // --dry-run previews with it; any other has no preview.
  effect?: VerbEffect;
  // Destructive (typed name, Installer): true, or the words/options that make
  // it so when present (["remove-peer"], ["--remove"]). Default: a verb named
  // delete/purge/retire/erase/remove…/discard, and the options --remove,
  // --decommission, --erase, --purge.
  destructive?: boolean | string[];
  // Options that authorize a disruption, with the consequence to show beside
  // the checkbox. Default: --force, --allow-disruption, --yes, with their
  // descriptions.
  disruptive?: Array<[string, string]>;
  // Words or options that make one call of a write verb a read (`wgvpn list`,
  // `key list`, `snapshot-vm --list`): the console runs it without a preview.
  readWhen?: string[];
  // Options that make one call of a READ verb a write with no dry run, with
  // what it then touches: `test --deep` creates and removes guests, so it is
  // previewed, queued and kept clear of the sweep like any change. Default: a
  // read verb's --deep (the deep suite), and the disruption options it accepts.
  writeWhen?: Array<[string, string]>;
  // The object a destructive call acts on, which its typed confirmation names:
  // the positional that identifies it, and those it is within, shown first
  // ("<switch>:<port>"). Default: the first positional (or --name).
  object?: { positional: string; within?: string[] };
}

// A write's preview: `apply` — the verb previews without this flag and applies
// with it (reconcile --apply); `dryRun` — it previews with this flag and
// applies without it (--check, --dry-run); `noPreview` — it has none, and the
// text says what it touches.
export type VerbEffect = "read" | { apply: string } | { dryRun: string } | { noPreview: string };

export interface HelpSpec {
  name: string; // CLI name, e.g. "network-manager"
  version: string;
  tagline: string;
  verbs: HelpVerb[];
  common?: Array<[string, string]>; // options shared by all verbs
  hidden?: string[]; // accepted by every verb, not shown (legacy spellings)
  notes?: string[]; // free-text paragraphs printed after the option blocks
}

const HELP_OPTION: [string, string] = ["-h, --help", "Show this help"];

function deriveName(usage: string): string {
  const out: string[] = [];
  for (const tok of usage.split(/\s+/)) {
    if (tok.startsWith("<") || tok.startsWith("[") || tok.startsWith("-")) break;
    out.push(tok);
  }
  return out.join(" ") || usage;
}

function renderOptions(opts: Array<[string, string]>): string[] {
  if (opts.length === 0) return [];
  const w = Math.max(...opts.map(([f]) => f.length));
  return opts.map(([f, d]) => `  ${f.padEnd(w)}  ${d}`);
}

function render(s: HelpSpec, verbs: HelpVerb[], trailer: string[]): string {
  const lines: string[] = [`${s.name} ${s.version} — ${s.tagline}`, "", "Usage:"];
  for (const v of verbs) {
    lines.push(`  ${s.name} ${v.usage}${v.note ? `   ${v.note}` : ""}`);
  }
  for (const v of verbs) {
    if (!v.options || v.options.length === 0) continue;
    lines.push("", `${v.name ?? deriveName(v.usage)} options:`);
    lines.push(...renderOptions(v.options));
  }
  const common: Array<[string, string]> = [...(s.common ?? []), HELP_OPTION];
  lines.push("", "common:", ...renderOptions(common));
  for (const n of trailer) lines.push("", n);
  return lines.join("\n");
}

export function renderHelp(s: HelpSpec): string {
  return render(s, s.verbs, s.notes ?? []);
}

// ── verb selection ────────────────────────────────────────────────────

// The words that select a verb, alternatives expanded:
// "enable|disable|manual" → [["enable"], ["disable"], ["manual"]].
function verbKeys(v: HelpVerb): string[][] {
  const words = (v.verb ?? deriveName(v.usage)).split(/\s+/).filter((w) => w.length > 0);
  let keys: string[][] = [[]];
  for (const w of words) {
    keys = keys.flatMap((k) => w.split("|").map((alt) => [...k, alt]));
  }
  for (const a of v.aliases ?? []) keys.push(a.split(/\s+/));
  return keys;
}

function isOption(tok: string): boolean {
  return tok.startsWith("-") && tok !== "-" && !/^-\d/.test(tok);
}

// The leading positional words of argv (up to the first option).
function leadingWords(args: string[]): string[] {
  const out: string[] = [];
  for (const a of args) {
    if (isOption(a)) break;
    out.push(a);
  }
  return out;
}

// The verb argv selects (longest matching key wins), and how many words it used.
function matchVerb(s: HelpSpec, words: string[]): { verb: HelpVerb; used: number } | undefined {
  let best: { verb: HelpVerb; used: number } | undefined;
  for (const v of s.verbs) {
    for (const k of verbKeys(v)) {
      if (k.length === 0 || k.length > words.length) continue;
      if (k.every((w, i) => w === words[i]) && (!best || k.length > best.used)) {
        best = { verb: v, used: k.length };
      }
    }
  }
  return best;
}

// renderVerbHelp — what `<cli> <verb> --help` prints: the usage, details and
// options of that verb. Words that only begin a verb (`node`, `snat`) print
// every verb they begin; anything else falls back to the full renderHelp(),
// so a help request always prints SOMETHING useful and exits 0.
export function renderVerbHelp(s: HelpSpec, words: string | string[]): string {
  const w = typeof words === "string" ? words.split(/\s+/).filter((x) => x.length > 0) : words;
  const m = matchVerb(s, w);
  if (m) return render(s, [m.verb], m.verb.details ? [m.verb.details] : []);
  if (w.length > 0) {
    const group = s.verbs.filter((v) => verbKeys(v).some((k) => w.every((x, i) => k[i] === x)));
    if (group.length > 0) {
      return render(s, group, group.flatMap((v) => (v.details ? [v.details] : [])));
    }
  }
  return renderHelp(s);
}

// ── accepted options ──────────────────────────────────────────────────

const FLAG = /^--?[A-Za-z][\w-]*$/;
const OPEN_FLAG = /^--<[^>]+>$/; // "--<field> <value>": any option, forwarded

// Options named in a usage line or an option label, and whether each takes a
// value: a flag followed, inside the same [...] group, by a non-flag word
// ("--zones <file>", "--set field=value", "--managed full|tracked").
function scanOptions(text: string, into: Map<string, boolean>): boolean {
  const toks = text.replace(/[[\](){},|]/g, " | ").split(/\s+/).filter((t) => t.length > 0);
  let open = false;
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (OPEN_FLAG.test(t)) {
      open = true;
      continue;
    }
    if (!FLAG.test(t)) continue;
    const n = toks[i + 1];
    const takesValue = n !== undefined && n !== "|" && n !== "..." && !FLAG.test(n) && !OPEN_FLAG.test(n);
    into.set(t, (into.get(t) ?? false) || takesValue);
  }
  return open;
}

// Every option a verb accepts → whether it takes a value.
export function acceptedOptions(s: HelpSpec, v: HelpVerb): { options: Map<string, boolean>; open: boolean } {
  const options = new Map<string, boolean>();
  let open = v.anyOption === true;
  open = scanOptions(v.usage, options) || open;
  for (const [f] of v.options ?? []) open = scanOptions(f, options) || open;
  for (const h of [...(v.hidden ?? []), ...(s.hidden ?? [])]) scanOptions(h, options);
  for (const [f] of s.common ?? []) scanOptions(f, options);
  scanOptions(HELP_OPTION[0], options);
  return { options, open };
}

// Options a verb's usage line names that neither its options nor the common
// block describe. A manager's unit test asserts this is empty, so every verb's
// --help explains each option it takes.
export function undocumentedOptions(s: HelpSpec): string[] {
  const described = new Map<string, boolean>();
  for (const [f] of s.common ?? []) scanOptions(f, described);
  const out: string[] = [];
  for (const v of s.verbs) {
    const own = new Map(described);
    for (const [f] of v.options ?? []) scanOptions(f, own);
    const named = new Map<string, boolean>();
    scanOptions(v.usage, named);
    for (const f of named.keys()) {
      if (!own.has(f)) out.push(`${v.verb ?? deriveName(v.usage)}: ${f}`);
    }
  }
  return out;
}

// ── the argument gate ─────────────────────────────────────────────────

// checkArgs — run BEFORE a manager parses or dispatches `args` (argv after the
// CLI name, with any optional entity prefix already stripped). Returns the exit
// code when the CLI must stop here, undefined to carry on:
//   0  -h/--help anywhere: the verb's help was printed, nothing ran
//      (`--help --json` with no verb: the verb manifest, renderManifest)
//   1  an option the verb does not accept (named in the error)
// An unknown verb is left to the manager's own dispatch.
export function checkArgs(s: HelpSpec, args: string[]): number | undefined {
  const isHelp = (a: string): boolean => a === "-h" || a === "--help";
  if (args.some(isHelp) && args.includes("--json") && leadingWords(args.filter((a) => !isHelp(a))).length === 0) {
    // `<cli> --help --json`: the verb manifest, for the console (ADR-034 D4).
    info(JSON.stringify(renderManifest(s), null, 2));
    return 0;
  }
  if (args.some(isHelp)) {
    info(renderVerbHelp(s, leadingWords(args.filter((a) => !isHelp(a)))));
    return 0;
  }
  const m = matchVerb(s, leadingWords(args));
  if (!m) return undefined;
  const verbWords = args.slice(0, m.used).join(" ");
  const { options, open } = acceptedOptions(s, m.verb);
  for (let i = m.used; i < args.length; i++) {
    const a = args[i];
    if (!isOption(a)) continue;
    const takesValue = options.get(a);
    if (takesValue !== undefined) {
      if (takesValue) i++;
      continue;
    }
    if (open && a.startsWith("--")) {
      if (args[i + 1] !== undefined && !isOption(args[i + 1])) i++;
      continue;
    }
    const eq = a.indexOf("=");
    const hint = eq > 0 && options.has(a.slice(0, eq)) ? ` — write '${a.slice(0, eq)} ${a.slice(eq + 1)}'` : "";
    console.error(
      `${RD}[Error]${CL} ${s.name} ${verbWords}: unknown option '${a}'${hint} ` +
        `(see '${s.name} ${verbWords} --help')`,
    );
    return 1;
  }
  return undefined;
}

// ── the verb manifest: `<cli> --help --json` (ADR-034 D4, T2) ──────────

export interface ManifestOption {
  flag: string;
  takesValue: boolean;
  arg: string | null; // the value's placeholder, e.g. "<file>", "field=value"
  choices: string[] | null; // a value from a fixed list ("full|tracked")
  repeatable: boolean;
  description: string;
}

export interface ManifestVerb {
  verb: string; // the display name, e.g. "node network set"
  keys: string[][]; // the words that select it (alternatives and aliases expanded)
  usage: string;
  note: string | null;
  details: string | null;
  positionals: { name: string; optional: boolean; repeatable: boolean }[];
  options: ManifestOption[];
  open: boolean; // accepts any --option (forwarded to a tool that checks its own)
  effect: "read" | "write";
  preview: { kind: "read" } | { kind: "apply-flag"; flag: string } | { kind: "dry-run-flag"; flag: string } | { kind: "none"; touches: string };
  destructive: boolean;
  destructiveWhen: string[];
  readWhen: string[];
  // On a read verb: the options that make a call a write with no dry run
  // (`test --deep`), and what such a call touches. Empty on a write verb.
  writeWhen: { flag: string; touches: string }[];
  disruptions: { flag: string; consequence: string }[];
  // Only on a verb that declares it (HelpVerb.object); absent, the object is
  // the first positional — so a manifest without it reads as before.
  object?: { positional: string; within: string[] };
}

export interface Manifest {
  manifest: 1;
  name: string;
  version: string;
  tagline: string;
  common: ManifestOption[];
  verbs: ManifestVerb[];
}

const READ_WORDS = new Set([
  "list", "list-all", "show", "get", "exists", "validate", "resolve", "drift", "topology", "coverage", "peers",
  "pulse", "status", "capacity", "report", "test", "render", "merge", "split-horizon-target", "list-ports", "delta", "fields",
]);
const DESTRUCTIVE_WORD = /^(delete|purge|retire|erase|discard|remove(-[a-z]+)?)$/;
const DESTRUCTIVE_OPTIONS = ["--remove", "--decommission", "--erase", "--purge"];
const DISRUPTIVE_OPTIONS = ["--force", "--allow-disruption", "--yes"];
// What a read verb's --deep does to the site (module test --deep, site test --deep).
const DEEP_TOUCHES = "runs the deep suite: creates and removes zztest guests";

// Options described in a label or usage text, with their placeholders.
function optionShapes(text: string): Map<string, { arg: string | null; repeatable: boolean }> {
  const out = new Map<string, { arg: string | null; repeatable: boolean }>();
  // A <placeholder> is one word whatever it holds ("<a,b>", "<field options>").
  const KEEP = "\u0001";
  const toks = text
    .replace(/<[^<>]*>/g, (m) => m.replace(/[\s,]/g, (c) => (c === "," ? KEEP : "\u0002")))
    .replace(/[[\](){},]/g, " ")
    .split(/\s+/)
    .filter((t) => t.length > 0)
    .map((t) => t.replace(/\u0001/g, ",").replace(/\u0002/g, " "));
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i].replace(/\.\.\.$/, "");
    if (!FLAG.test(t)) continue;
    const n = toks[i + 1];
    const arg = n !== undefined && n !== "|" && n !== "..." && !FLAG.test(n) && !OPEN_FLAG.test(n) ? n.replace(/\.\.\.$/, "") : null;
    const rep = toks[i].endsWith("...") || (n ?? "").endsWith("...") || toks[i + (arg ? 2 : 1)] === "...";
    const prev = out.get(t);
    out.set(t, { arg: prev?.arg ?? arg, repeatable: (prev?.repeatable ?? false) || rep });
  }
  return out;
}

function positionalsOf(v: HelpVerb, keys: string[][]): ManifestVerb["positionals"] {
  // Per alternative of the usage line ("key list | export|import --file DIR"):
  // after the verb's own words, every <name> and every bare sub-word ("list",
  // "export|import") that is not an option or an option's value. The
  // alternative with the most of them is the verb's shape.
  const keyWords = new Set(keys.flat());
  let best: ManifestVerb["positionals"] = [];
  for (const alt of v.usage.split(/\s\|\s/)) {
    const toks = alt.split(/\s+/).filter((t) => t.length > 0);
    const out: ManifestVerb["positionals"] = [];
    // Start after the last of the verb's own words (identity's "<kind> add <name>").
    let start = 0;
    toks.forEach((t, j) => {
      if (t.split("|").every((w) => keyWords.has(w))) start = j + 1;
    });
    let depth = 0;
    for (let i = 0; i < toks.length; i++) {
      const raw = toks[i];
      const opens = (raw.match(/\[/g) ?? []).length;
      const outer = depth;
      depth += opens - (raw.match(/\]/g) ?? []).length;
      if (i < start) continue;
      const bare = raw.replace(/^\[+/, "").replace(/[\].]+$/, "");
      const prev = (toks[i - 1] ?? "").replace(/^\[+/, "");
      if (FLAG.test(bare) || OPEN_FLAG.test(bare) || FLAG.test(prev) || OPEN_FLAG.test(prev)) continue;
      const m = /^<([^<>]+)>$/.exec(bare);
      // A bare sub-word counts at the top level or first in its [group];
      // "[field flags]" is a description, not two arguments.
      if (!m && (!/^[a-z][a-z0-9-]*(\|[a-z][a-z0-9-]*)*$/.test(bare) || (outer > 0 && opens === 0))) continue;
      out.push({ name: m ? m[1] : bare, optional: outer > 0 || opens > 0, repeatable: raw.includes("...") });
    }
    if (out.length > best.length) best = out;
  }
  return best;
}

export function defaultEffect(v: HelpVerb, options: Map<string, boolean>): VerbEffect {
  const keys = verbKeys(v);
  if (keys.length > 0 && keys.every((k) => READ_WORDS.has(k[k.length - 1] ?? ""))) return "read";
  if (options.has("--apply")) return { apply: "--apply" };
  if (options.has("--check")) return { dryRun: "--check" };
  if (options.has("--dry-run")) return { dryRun: "--dry-run" };
  return { noPreview: "" };
}

export function manifestVerb(s: HelpSpec, v: HelpVerb): ManifestVerb {
  const { options, open } = acceptedOptions(s, v);
  const shapes = optionShapes(v.usage);
  const desc = new Map<string, string>();
  for (const [f, d] of [...(v.options ?? []), ...(s.common ?? []), HELP_OPTION]) {
    for (const [flag, shape] of optionShapes(f)) {
      if (!desc.has(flag)) desc.set(flag, d);
      const prev = shapes.get(flag);
      shapes.set(flag, { arg: prev?.arg ?? shape.arg, repeatable: (prev?.repeatable ?? false) || shape.repeatable });
    }
  }
  // Hidden spellings stay accepted by the CLI but are not in the manifest: the
  // console never sends a legacy spelling.
  const hidden = new Map<string, boolean>();
  for (const h of [...(v.hidden ?? []), ...(s.hidden ?? [])]) scanOptions(h, hidden);
  const opts: ManifestOption[] = [];
  for (const [flag, takesValue] of options) {
    if (flag === "-h" || flag === "--help" || (hidden.has(flag) && !desc.has(flag) && !shapes.has(flag))) continue;
    const sh = shapes.get(flag);
    const arg = takesValue ? (sh?.arg ?? "<value>") : null;
    const choices = arg && !arg.startsWith("<") && arg.includes("|") ? arg.split("|") : null;
    opts.push({ flag, takesValue, arg, choices, repeatable: sh?.repeatable ?? false, description: desc.get(flag) ?? "" });
  }
  const effect = v.effect ?? defaultEffect(v, options);
  const keys = verbKeys(v);
  let destructive = false;
  let destructiveWhen: string[] = [];
  if (v.destructive === true) destructive = true;
  else if (Array.isArray(v.destructive)) destructiveWhen = v.destructive;
  else if (v.destructive === undefined) {
    if (keys.some((k) => k.some((w) => DESTRUCTIVE_WORD.test(w)))) destructive = true;
    else {
      const words = v.usage.replace(/[[\]<>(){},|]/g, " ").split(/\s+/);
      destructiveWhen = [...new Set(words.filter((w) => DESTRUCTIVE_WORD.test(w)))];
      destructiveWhen.push(...DESTRUCTIVE_OPTIONS.filter((o) => options.has(o)));
    }
  }
  const disruptions = (v.disruptive ?? DISRUPTIVE_OPTIONS.filter((o) => options.has(o)).map((o): [string, string] => [o, desc.get(o) ?? ""]))
    .map(([flag, consequence]) => ({ flag, consequence }));
  // A read verb's --deep, or a disruption option it accepts, makes that call a
  // write: `test` is a read, `test --deep` is not (console review, finding 3).
  const writeWhen =
    effect !== "read"
      ? []
      : (v.writeWhen ?? [
          ...(options.has("--deep") ? [["--deep", DEEP_TOUCHES] as [string, string]] : []),
          ...DISRUPTIVE_OPTIONS.filter((o) => options.has(o)).map((o): [string, string] => [o, desc.get(o) ?? ""]),
        ]).map(([flag, touches]) => ({ flag, touches }));
  let preview: ManifestVerb["preview"];
  if (effect === "read") preview = { kind: "read" };
  else if ("apply" in effect) preview = { kind: "apply-flag", flag: effect.apply };
  else if ("dryRun" in effect) preview = { kind: "dry-run-flag", flag: effect.dryRun };
  else preview = { kind: "none", touches: effect.noPreview };
  return {
    verb: (v.name ?? deriveName(v.usage.split(/\s\|\s/)[0])).replace(/\s*\(.*$/s, "").trim(),
    keys,
    usage: v.usage.replace(/\s*\n\s*/g, " "),
    note: v.note ?? null,
    details: v.details ?? null,
    positionals: positionalsOf(v, keys),
    options: opts,
    open,
    effect: effect === "read" ? "read" : "write",
    preview,
    destructive,
    destructiveWhen,
    readWhen: v.readWhen ?? [],
    writeWhen,
    disruptions,
    ...(v.object ? { object: { positional: v.object.positional, within: v.object.within ?? [] } } : {}),
  };
}

export function renderManifest(s: HelpSpec): Manifest {
  const common: ManifestOption[] = [];
  for (const [f, d] of s.common ?? []) {
    for (const [flag, sh] of optionShapes(f)) {
      common.push({ flag, takesValue: sh.arg !== null, arg: sh.arg, choices: null, repeatable: sh.repeatable, description: d });
    }
  }
  return { manifest: 1, name: s.name, version: s.version, tagline: s.tagline, common, verbs: s.verbs.map((v) => manifestVerb(s, v)) };
}
