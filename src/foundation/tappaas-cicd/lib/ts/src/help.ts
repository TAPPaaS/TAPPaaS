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
}

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
//   1  an option the verb does not accept (named in the error)
// An unknown verb is left to the manager's own dispatch.
export function checkArgs(s: HelpSpec, args: string[]): number | undefined {
  const isHelp = (a: string): boolean => a === "-h" || a === "--help";
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
