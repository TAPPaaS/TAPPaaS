// assistant.ts — the assistant's agent loop (ADR-034 D7, spike §5.9). It runs
// in the backend, so its tools, its trail and its caller's role are the same
// as for a click: a question goes to LiteLLM's chat completions with the tools
// of assistant-tools.ts; each tool call is answered from the console's reads;
// the loop ends when the model answers without one (or after MAX_ROUNDS).
//
// It proposes and never applies: no tool writes, a tool name outside the
// allow-list is refused and recorded, a proposal is a card the operator
// previews and runs through the job model under their own role, and
// open_console moves the operator's console to a wizard, filled in (a
// `navigate` event the drawer follows). The system prompt says so, with the
// site, the caller and the page in view, the tools by name, the console's
// wizards, and the managers' verbs in short form.

import { AssistantStatus, ChatFn, ChatMessage, ToolCall } from "./litellm";
import { ToolContext, runTool, toolDefs, toolLines } from "./assistant-tools";
import { Conversation, Conversations, Focus, Opened, Proposal, Step, Turn, trimHistory, userKey } from "./conversations";
import { catalogText } from "../web/src/consoletargets";
import { Me } from "./access";
import { Manifests } from "./manifest";

export const MAX_ROUNDS = 8;
// What is sent of the history, in characters (hrossen's model reads 32k tokens;
// the system prompt and the tools take about a third of that).
export const HISTORY_CHARS = 40_000;
const OLD_RESULT_CHARS = 1200; // a tool result from an earlier turn, as resent

export interface AssistantDeps {
  status: () => Promise<AssistantStatus>;
  chat: ChatFn;
  tools: ToolContext;
  store: Conversations;
  site: () => Promise<{ name: string; displayName: string | null }>;
  log?: (line: string) => void;
  now?: () => number;
}

export interface ChatInput {
  conversation?: unknown;
  message?: unknown;
  focus?: unknown;
}

export type AssistantEvent =
  | { type: "conversation"; id: string; turn: number; model: string }
  | { type: "step"; step: Step }
  | { type: "delta"; text: string }
  | { type: "proposal"; proposal: Proposal; conversation: string }
  | ({ type: "navigate" } & Opened)
  | { type: "done"; turn: Turn }
  | { type: "error"; message: string };

const ROLE_WORDS: Record<string, string> = {
  installer: "Installer: may run every verb, the destructive ones with the object's name typed",
  admin: "Admin: may run every verb but the destructive ones",
  read: "read only: may preview nothing and run nothing; an Admin or Installer runs what you propose",
};

// The managers' verbs, one line per manager: each verb's usage without its
// optional parts, marked W when it changes the site and D when destructive.
export function shortManifest(ms: Manifests | null): string {
  if (!ms) return "(the verb manifests are still loading: use help(manager))";
  const lines: string[] = [];
  for (const m of [...ms.byBin.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    const verbs = m.verbs.map((v) => {
      let u = v.usage;
      for (let i = 0; i < 4; i++) u = u.replace(/\s*\[[^[\]]*\]/g, "");
      u = u.replace(/\s+/g, " ").trim();
      const mark = v.destructive || v.destructiveWhen.length ? " D" : v.effect === "write" ? " W" : "";
      return `${u}${mark}`;
    });
    lines.push(`${m.name}: ${verbs.join(" · ")}`);
  }
  return lines.join("\n");
}

export function focusText(f: Focus | null): string {
  if (!f) return "nothing in particular";
  const obj = f.kind && f.name ? `${f.kind} ${f.name}` : null;
  return `${obj ? `${obj} on ` : ""}the ${f.page} page${f.detail ? ` (${f.detail})` : ""}`;
}

export function systemPrompt(o: { site: { name: string; displayName: string | null }; me: Me; focus: Focus | null; manifest: string; tools: string; now: Date }): string {
  const who = o.me.user ? `${o.me.name ?? o.me.user} (${o.me.user})` : o.me.via === "local" ? "the operator in a shell on tappaas-cicd (tappaas ask)" : o.me.via;
  return [
    `You are the assistant of the TAPPaaS console for the site ${o.site.name}${o.site.displayName && o.site.displayName !== o.site.name ? ` (${o.site.displayName})` : ""}. TAPPaaS runs the site's services as modules on Proxmox nodes behind an OPNsense firewall; managers on the mothership tappaas-cicd own every change.`,
    `You are talking to ${who}, role ${ROLE_WORDS[o.me.role] ?? o.me.role}.`,
    `In view: ${focusText(o.focus)}. Time: ${o.now.toISOString().slice(0, 16)}Z.`,
    "",
    "Your tools, by their exact names. No other tool exists: any other name is refused.",
    o.tools,
    "There is no tool per manager or per verb (no site_manager_add_node, no module_manager_modify). A manager's verb is only ever proposed: call propose_job with the command as an array of words, the manager first. Example, to take immich to its new release:",
    '  propose_job({"argv": ["module-manager", "update", "immich"], "rationale": "immich is a release behind; the update restarts it once."})',
    "",
    "Choosing the tool for a change: when the console has a wizard or form for it, call open_console, not propose_job. It has one for adding a node, an environment, a stack, a device, WiFi, a backup buddy, a satellite or a user, and for changing any field of a module (memory, cores, disk…) or of a zone: modify-module <module>, modify-zone <zone>. open_console opens that form in the operator's console, filled in, and they preview and apply it there. Read first what the form needs: for add-node nothing; for modify-module call module_show, so the values use the field's real name and unit. Call propose_job only for a verb the console has no form for (update, test, migrate…).",
    "Example, the operator wants a new node:",
    '  open_console({"target": "add-node"})',
    "Example, the operator wants immich at 10 GiB: module_show(immich) lists the field memory in MiB, then",
    '  open_console({"target": "modify-module immich", "values": {"memory": "10240"}})',
    catalogText(),
    "",
    "How you work:",
    "- You read freely with your tools. Answer from what they return and say what you read; never invent a number, a name, a verb or a tool.",
    "- You never run, apply or change anything, and no tool of yours can. When a change would help and the console has no form for it, call propose_job with the exact command and a one-sentence rationale: it becomes a card with Preview and Run in front of the operator. Only their click runs it, under their role, and Activity records it as from the assistant.",
    "- A proposal or an opened form changes nothing, so never ask whether to make one: when the operator asks for a change, call open_console or propose_job in that same turn, with what is risky about it said. Never write a tool call or its JSON in your answer: call the tool.",
    "- When asked to run, apply or do something (\"run it\", \"do it\", \"go ahead\"), do not pretend and do not call any tool to do it: say that you do not run changes yourself, that the card's Run button does, so the record shows a person decided; if there is no card yet, propose one.",
    "- Before proposing a change, read what it touches (the module's fields and their change class, the node's memory commitment) and give the consequence: in-place or a restart, downtime, what it commits.",
    "- Destructive verbs (delete, purge, retire, --remove) need the Installer role and the object's name typed; propose them only when asked, and say so.",
    "- Be brief: the cause with its numbers, at most two ways out with their consequence, the one you suggest. Plain text; short lists; no tables.",
    "- A question about the site's state is answered from a tool you call in this turn, never from memory. Answer in the language the operator writes in.",
    "",
    "What propose_job may propose: the managers' verbs (W changes the site, D destructive; help(manager) gives the options and the README). These are commands for argv, never tool names:",
    o.manifest,
  ].join("\n");
}

// The JSON object that starts at text[i] ("{"), or null: braces balanced
// outside strings.
function objectAt(text: string, i: number): string | null {
  let depth = 0;
  let str = false;
  for (let j = i; j < text.length; j++) {
    const c = text[j];
    if (str) {
      if (c === "\\") j++;
      else if (c === '"') str = false;
    } else if (c === '"') str = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return text.slice(i, j + 1);
  }
  return null;
}

// The calls a model wrote in its answer instead of making them (hrossen's
// model, after a read: "```json open_console({...})```"): an offered tool's
// name with its JSON arguments, or a fenced object shaped as open_console's
// {target, values} or propose_job's {argv, rationale}.
export function writtenCalls(text: string, tools: string[]): { name: string; arguments: string }[] {
  const out: { name: string; arguments: string }[] = [];
  const add = (name: string, args: string) => {
    try {
      const v = JSON.parse(args) as unknown;
      if (!v || typeof v !== "object" || Array.isArray(v)) return;
      const a = JSON.stringify(v);
      if (!out.some((x) => x.name === name && x.arguments === a)) out.push({ name, arguments: a });
    } catch {
      /* not a call */
    }
  };
  const named = new RegExp(`\\b(${tools.join("|")})\\s*\\(\\s*\\{`, "g");
  for (let m = named.exec(text); m; m = named.exec(text)) {
    const o = objectAt(text, m.index + m[0].length - 1);
    if (o) add(m[1], o);
  }
  if (out.length) return out;
  for (const m of text.matchAll(/```(?:json)?\s*(\{)/g)) {
    const o = objectAt(text, (m.index ?? 0) + m[0].length - 1);
    if (!o) continue;
    try {
      const v = JSON.parse(o) as Record<string, unknown>;
      const keys = Object.keys(v).sort().join(",");
      if (tools.includes("open_console") && typeof v.target === "string" && (keys === "target" || keys === "target,values")) add("open_console", o);
      else if (tools.includes("propose_job") && Array.isArray(v.argv) && (keys === "argv" || keys === "argv,rationale")) add("propose_job", o);
    } catch {
      /* not JSON */
    }
  }
  return out;
}

// The history as sent: earlier tool results shortened, the oldest turns
// dropped until it fits, never starting with an answer or a tool result.
export function historyFor(messages: ChatMessage[], currentFrom: number, budget = HISTORY_CHARS): ChatMessage[] {
  const all = messages.map((m, i) =>
    i < currentFrom && m.role === "tool" && (m.content ?? "").length > OLD_RESULT_CHARS ? { ...m, content: `${(m.content ?? "").slice(0, OLD_RESULT_CHARS)}\n… (shortened)` } : m,
  );
  const size = (ms: ChatMessage[]): number => ms.reduce((n, m) => n + (m.content ?? "").length + JSON.stringify(m.tool_calls ?? []).length, 0);
  let start = 0;
  // Whole earlier turns go, oldest first; the current one always stays.
  while (size(all.slice(start)) > budget) {
    const next = all.findIndex((m, i) => i > start && m.role === "user");
    if (next < 0 || next > currentFrom) break;
    start = next;
  }
  return trimHistory(all.slice(start));
}

function parseFocus(v: unknown): Focus | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const s = (k: string, max: number): string | undefined => (typeof o[k] === "string" && (o[k] as string).trim() ? (o[k] as string).trim().slice(0, max) : undefined);
  const page = s("page", 40);
  if (!page) return null;
  return { page, kind: s("kind", 40), name: s("name", 80), detail: s("detail", 400) };
}

export class Assistant {
  constructor(private readonly d: AssistantDeps) {}

  private now(): number {
    return (this.d.now ?? Date.now)();
  }

  list(me: Me) {
    return this.d.store.list(userKey(me.user, me.via));
  }

  get(me: Me, id: string): Conversation | null {
    return this.d.store.get(userKey(me.user, me.via), id);
  }

  // A card's proposal, in the caller's own conversation (jobs.ts asks).
  proposal(me: Me, conversation: string, proposal: string): Proposal | null {
    return this.d.store.proposal(userKey(me.user, me.via), conversation, proposal)?.proposal ?? null;
  }

  // One turn: the question, the tool rounds, the answer. Events as they happen.
  async chat(me: Me, input: ChatInput, emit: (e: AssistantEvent) => void, signal?: AbortSignal): Promise<Turn | null> {
    const message = typeof input.message === "string" ? input.message.trim() : "";
    if (!message) {
      emit({ type: "error", message: "an empty question" });
      return null;
    }
    if (message.length > 4000) {
      emit({ type: "error", message: "the question is longer than 4000 characters" });
      return null;
    }
    const status = await this.d.status();
    if (!status.available || !status.model) {
      emit({ type: "error", message: `the assistant is not available: ${status.reason}` });
      return null;
    }
    const user = userKey(me.user, me.via);
    let conv: Conversation;
    if (typeof input.conversation === "string" && input.conversation) {
      const c = this.d.store.get(user, input.conversation);
      if (!c) {
        emit({ type: "error", message: `no conversation ${input.conversation}` });
        return null;
      }
      conv = c;
    } else conv = this.d.store.create(user);

    const focus = parseFocus(input.focus);
    const turn: Turn = { n: conv.turns.length + 1, at: new Date(this.now()).toISOString(), question: message, focus, steps: [], answer: "", proposals: [], opened: [], model: status.model, error: null };
    emit({ type: "conversation", id: conv.id, turn: turn.n, model: status.model });
    const from = conv.messages.length;
    conv.messages.push({ role: "user", content: message });
    const system: ChatMessage = {
      role: "system",
      content: systemPrompt({ site: await this.d.site(), me, focus, manifest: shortManifest(this.d.tools.manifests()), tools: toolLines(this.d.tools), now: new Date(this.now()) }),
    };
    const tools = toolDefs(this.d.tools);
    const ctx: ToolContext = me.via === "local" ? { ...this.d.tools, shell: true } : this.d.tools;
    let tookWritten = false;
    try {
      for (let round = 0; ; round++) {
        if (round >= MAX_ROUNDS) {
          const note = `\n(I stopped after ${MAX_ROUNDS} rounds of reading; ask again to go on.)`;
          turn.answer += note;
          emit({ type: "delta", text: note });
          conv.messages.push({ role: "assistant", content: note.trim() });
          break;
        }
        const r = await this.d.chat({ model: status.model, messages: [system, ...historyFor(conv.messages, from)], tools }, (t) => emit({ type: "delta", text: t }), signal);
        if (r.content) turn.answer += (turn.answer && !turn.answer.endsWith("\n") ? "\n" : "") + r.content;
        // A call written as text is taken as made, once a turn: it is what
        // the model meant, and its own next round answers from the result.
        const written = r.toolCalls.length === 0 && !tookWritten ? writtenCalls(r.content, tools.map((t) => t.function.name)) : [];
        if (r.toolCalls.length === 0 && written.length === 0) {
          conv.messages.push({ role: "assistant", content: r.content });
          break;
        }
        if (written.length) {
          tookWritten = true;
          this.d.log?.(`assistant: took ${written.map((w) => w.name).join(", ")} written as text for ${user} (conversation ${conv.id}, turn ${turn.n})`);
        }
        const made = written.length ? written.map((w) => ({ id: "", type: "function" as const, function: w })) : r.toolCalls;
        const calls: ToolCall[] = made.map((c, i) => ({ ...c, id: c.id || `call-${turn.n}-${round}-${i}`, type: "function" }));
        conv.messages.push({ role: "assistant", content: r.content || null, tool_calls: calls });
        for (const c of calls) {
          const out = await runTool(ctx, c.function.name, c.function.arguments);
          let args: Record<string, unknown> = {};
          try {
            args = JSON.parse(c.function.arguments || "{}") as Record<string, unknown>;
          } catch {
            args = { raw: c.function.arguments.slice(0, 200) };
          }
          const step: Step = { tool: c.function.name, args, ok: out.ok, summary: out.summary, ...(out.refused ? { refused: true } : {}), ...(written.length ? { written: true } : {}) };
          turn.steps.push(step);
          emit({ type: "step", step });
          if (out.refused) this.d.log?.(`assistant: refused tool '${c.function.name}' for ${user} (conversation ${conv.id}, turn ${turn.n})`);
          let content = out.content;
          if (out.proposal) {
            const p: Proposal = { id: `p${turn.n}-${turn.proposals.length + 1}`, turn: turn.n, ...out.proposal, at: new Date(this.now()).toISOString() };
            turn.proposals.push(p);
            emit({ type: "proposal", proposal: p, conversation: conv.id });
            content = `${content} (card ${p.id})`;
          }
          if (out.navigate) {
            turn.opened!.push(out.navigate);
            emit({ type: "navigate", ...out.navigate });
          }
          conv.messages.push({ role: "tool", tool_call_id: c.id, content });
        }
      }
    } catch (e) {
      const aborted = signal?.aborted;
      turn.error = aborted ? "stopped" : (e as Error).message;
      if (!aborted) emit({ type: "error", message: turn.error });
      // Every call has its result (runTool never throws), so an answer closes
      // the turn and the history can be sent again.
      conv.messages.push({ role: "assistant", content: turn.answer || `(no answer: ${turn.error})` });
    }
    conv.turns.push(turn);
    this.d.store.save(conv);
    emit({ type: "done", turn });
    return turn;
  }
}
