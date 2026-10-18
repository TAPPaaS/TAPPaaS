// tappaas — `tappaas ask`, the assistant in a shell on tappaas-cicd (ADR-034
// D7, "Elsewhere"). A small client of the console's own backend on loopback:
// the same agent loop, the same tools, the same conversations, as the local
// read role. A proposal is printed as the command to run — previewed first —
// and never run: in a shell the operator runs it, as the card's Run would.
//
//   tappaas ask "<question>"     one question, the answer streamed
//   tappaas ask                  a short conversation in the terminal
//
// Without the AI stack (or with the console down) it says why and exits 1.

import { HelpSpec, checkArgs, renderHelp } from "../../lib/ts/src/help";
import { info } from "../../lib/ts/src/cli";
import { shellQuote } from "./jobs";
import { DEFAULT_PORT, VERSION } from "./main";

export const HELP: HelpSpec = {
  name: "tappaas",
  version: VERSION,
  tagline: "the site's assistant in a shell (ADR-034 D7)",
  verbs: [
    {
      usage: "ask [<question>] [--console <url>] [--conversation <id>]",
      options: [
        ["--console <url>", `The console's address (default: $TAPPAAS_CONSOLE_URL or http://127.0.0.1:${DEFAULT_PORT}).`],
        ["--conversation <id>", "Go on with an earlier conversation (its id is printed at the end of each answer)."],
      ],
      details:
        "Asks the console's assistant, which reads the site through the console's reads and proposes\n" +
        "changes; it never runs one. A proposal is printed as the commands to run, preview first.\n" +
        "Without a question: a short conversation, one question per line, an empty line ends it.",
    },
  ],
};

interface Step {
  tool: string;
  summary: string;
  refused?: boolean;
}
interface Proposal {
  id: string;
  argv: string[];
  rationale: string;
  read: boolean;
  destructive: boolean;
  preview: string;
  previewArgv: string[] | null;
  applyArgv: string[];
}
type Event =
  | { type: "conversation"; id: string; turn: number; model: string }
  | { type: "step"; step: Step }
  | { type: "delta"; text: string }
  | { type: "proposal"; proposal: Proposal }
  | { type: "done" }
  | { type: "error"; message: string };

const out = (s: string): void => process.stdout.write(s);
const err = (s: string): void => process.stderr.write(s);

// How a proposal reads in a shell: the commands, preview first.
export function proposalText(p: Proposal): string {
  const lines = [``, `Proposed ${p.read ? "read" : "change"} (${p.id}) — not run:${p.rationale ? ` ${p.rationale}` : ""}`];
  if (p.read) lines.push(`  ${shellQuote(p.applyArgv)}`);
  else {
    if (p.previewArgv) lines.push(`  preview:  ${shellQuote(p.previewArgv)}`);
    else lines.push(`  (no dry run: read \`${p.applyArgv[0]} --help\` for what it touches)`);
    lines.push(`  apply:    ${shellQuote(p.applyArgv)}`);
    if (p.destructive) lines.push("  destructive: it cannot be undone; the console asks the Installer to type its name.");
  }
  lines.push("  Run it yourself, or from the card in the console (Activity records it there).");
  return lines.join("\n") + "\n";
}

// The server-sent events of one answer, as they come.
export function sseEvents(onEvent: (e: Event) => void): { feed: (t: string) => void } {
  let buf = "";
  return {
    feed: (t: string) => {
      buf += t;
      let i: number;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const block = buf.slice(0, i);
        buf = buf.slice(i + 2);
        const data = block.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).join("\n");
        if (data) onEvent(JSON.parse(data) as Event);
      }
    },
  };
}

async function status(base: string): Promise<string | null> {
  let r: FetchResponse;
  try {
    r = await fetch(`${base}/api/v1/assistant/status`, { signal: AbortSignal.timeout(15_000) });
  } catch (e) {
    return `the console does not answer at ${base} (${(e as Error).message}): is tappaas-console.service running?`;
  }
  if (!r.ok) return `the console answered HTTP ${r.status} at ${base}/api/v1/assistant/status`;
  const s = ((await r.json()) as { data?: { available?: boolean; reason?: string } }).data;
  return s?.available ? null : `the assistant is not available: ${s?.reason ?? "unknown"}`;
}

// One question; returns the conversation's id, or null when it failed.
async function askOnce(base: string, question: string, conversation: string | null): Promise<string | null> {
  let conv = conversation;
  let failed = false;
  let atLineStart = true;
  const p = sseEvents((e) => {
    if (e.type === "conversation") conv = e.id;
    else if (e.type === "step") err(`  · ${e.step.refused || e.step.tool === "propose_job" ? "" : "read: "}${e.step.summary}\n`);
    else if (e.type === "delta") {
      out(e.text);
      atLineStart = e.text.endsWith("\n");
    } else if (e.type === "proposal") {
      if (!atLineStart) out("\n");
      out(proposalText(e.proposal));
      atLineStart = true;
    } else if (e.type === "error") {
      failed = true;
      err(`\n[Error] ${e.message}\n`);
    }
  });
  let r: FetchResponse;
  try {
    r = await fetch(`${base}/api/v1/assistant/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "text/event-stream" },
      body: JSON.stringify({ conversation: conv ?? undefined, message: question, focus: { page: "shell" } }),
    });
  } catch (e) {
    err(`[Error] the console does not answer at ${base}: ${(e as Error).message}\n`);
    return null;
  }
  if (!r.ok || !r.body) {
    err(`[Error] ${((await r.json().catch(() => ({}))) as { error?: string }).error ?? `HTTP ${r.status}`}\n`);
    return null;
  }
  const dec = new TextDecoder();
  for await (const part of r.body) p.feed(dec.decode(part, { stream: true }));
  p.feed(dec.decode());
  if (!atLineStart) out("\n");
  return failed ? null : conv;
}

interface LineReader {
  question(q: string, cb: (a: string) => void): void;
  close(): void;
  on(e: "close", cb: () => void): void;
}

async function conversationLoop(base: string, first: string | null): Promise<number> {
  const rl = (require("readline") as { createInterface(o: unknown): LineReader }).createInterface({
    input: (process as unknown as { stdin: unknown }).stdin,
    output: process.stdout,
  });
  let closed = false;
  rl.on("close", () => (closed = true));
  const ask = (): Promise<string | null> => new Promise((res) => (closed ? res(null) : rl.question("\nyou › ", (a) => res(a))));
  let conv = first;
  info("Ask about the site; an empty line ends the conversation.");
  for (;;) {
    const q = (await ask())?.trim();
    if (!q || q === "exit" || q === "quit") break;
    conv = (await askOnce(base, q, conv)) ?? conv;
  }
  rl.close();
  if (conv) info(`(conversation ${conv})`);
  return 0;
}

export async function run(argv: string[]): Promise<number> {
  if (argv.length === 0 || argv[0] === "--version") {
    info(argv.length === 0 ? renderHelp(HELP) : VERSION);
    return 0;
  }
  const gate = checkArgs(HELP, argv);
  if (gate !== undefined) return gate;
  if (argv[0] !== "ask") {
    info(renderHelp(HELP));
    console.error(`[Error] unknown command: ${argv[0]}`);
    return 1;
  }
  let base = process.env.TAPPAAS_CONSOLE_URL ?? `http://127.0.0.1:${DEFAULT_PORT}`;
  let conv: string | null = null;
  const words: string[] = [];
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--console" || a === "--conversation") {
      const v = argv[++i];
      if (v === undefined) {
        console.error(`[Error] ${a} needs a value`);
        return 1;
      }
      if (a === "--console") base = v;
      else conv = v;
    } else words.push(a);
  }
  base = base.replace(/\/+$/, "");
  const why = await status(base);
  if (why) {
    console.error(`[Error] ${why}`);
    return 1;
  }
  if (words.length === 0) return conversationLoop(base, conv);
  const id = await askOnce(base, words.join(" "), conv);
  if (id) err(`(conversation ${id}: tappaas ask --conversation ${id} "…" goes on)\n`);
  return id ? 0 : 1;
}

if (require.main === module) {
  void run(process.argv.slice(2)).then((rc) => {
    process.exitCode = rc;
  });
}
