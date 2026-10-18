// assistant.ts — the assistant's agent loop (ADR-034 D7, spike §5.9). It runs
// in the backend, so its tools, its trail and its caller's role are the same
// as for a click: a question goes to LiteLLM's chat completions with the tools
// of assistant-tools.ts; each tool call is answered from the console's reads;
// the loop ends when the model answers without one (or after MAX_ROUNDS).
//
// It proposes and never applies: no tool writes, a tool name outside the
// allow-list is refused and recorded, and a proposal is a card the operator
// previews and runs through the job model under their own role. The system
// prompt says so, with the site, the caller and the page in view, and the
// managers' verbs in short form.

import { AssistantStatus, ChatFn, ChatMessage, ToolCall } from "./litellm";
import { ToolContext, runTool, toolDefs } from "./assistant-tools";
import { Conversation, Conversations, Focus, Proposal, Step, Turn, trimHistory, userKey } from "./conversations";
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

export function systemPrompt(o: { site: { name: string; displayName: string | null }; me: Me; focus: Focus | null; manifest: string; logs: boolean; now: Date }): string {
  const who = o.me.user ? `${o.me.name ?? o.me.user} (${o.me.user})` : o.me.via === "local" ? "the operator in a shell on tappaas-cicd (tappaas ask)" : o.me.via;
  return [
    `You are the assistant of the TAPPaaS console for the site ${o.site.name}${o.site.displayName && o.site.displayName !== o.site.name ? ` (${o.site.displayName})` : ""}. TAPPaaS runs the site's services as modules on Proxmox nodes behind an OPNsense firewall; managers on the mothership tappaas-cicd own every change.`,
    `You are talking to ${who}, role ${ROLE_WORDS[o.me.role] ?? o.me.role}.`,
    `In view: ${focusText(o.focus)}. Time: ${o.now.toISOString().slice(0, 16)}Z.`,
    "",
    "How you work:",
    `- You read freely with your tools (modules, a module's config and fields, drift, zones, environments, topology, the health gates, backup, pulse, activity${o.logs ? ", a host's logs" : ""}, a manager's help). Answer from what they return and say what you read; never invent a number, a name or a verb.`,
    "- You never run, apply or change anything, and no tool of yours can. When a change would help, call propose_job with the exact command and a one-sentence rationale: it becomes a card with Preview and Run in front of the operator. Only their click runs it, under their role, and Activity records it as from the assistant.",
    "- A proposal changes nothing, so never ask whether to make one: when the operator asks for a change or a proposal, call propose_job in that same turn, with what is risky about it in the rationale.",
    "- When asked to run, apply or do something (\"run it\", \"do it\", \"go ahead\"), do not pretend and do not call any tool to do it: say that you do not run changes yourself, that the card's Run button does, so the record shows a person decided; if there is no card yet, propose one.",
    "- Before proposing a change, read what it touches (the module's fields and their change class, the node's memory commitment) and give the consequence: in-place or a restart, downtime, what it commits.",
    "- Destructive verbs (delete, purge, retire, --remove) need the Installer role and the object's name typed; propose them only when asked, and say so.",
    "- Be brief: the cause with its numbers, at most two ways out with their consequence, the one you suggest. Plain text; short lists; no tables.",
    "- A question about the site's state is answered from a tool you call in this turn, never from memory. Answer in the language the operator writes in.",
    "",
    "The managers' verbs (W changes the site, D destructive; help(manager) gives the options and the README):",
    o.manifest,
  ].join("\n");
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
    const turn: Turn = { n: conv.turns.length + 1, at: new Date(this.now()).toISOString(), question: message, focus, steps: [], answer: "", proposals: [], model: status.model, error: null };
    emit({ type: "conversation", id: conv.id, turn: turn.n, model: status.model });
    const from = conv.messages.length;
    conv.messages.push({ role: "user", content: message });
    const system: ChatMessage = {
      role: "system",
      content: systemPrompt({ site: await this.d.site(), me, focus, manifest: shortManifest(this.d.tools.manifests()), logs: this.d.tools.loki !== null, now: new Date(this.now()) }),
    };
    const tools = toolDefs(this.d.tools);
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
        if (r.toolCalls.length === 0) {
          conv.messages.push({ role: "assistant", content: r.content });
          break;
        }
        const calls: ToolCall[] = r.toolCalls.map((c, i) => ({ ...c, id: c.id || `call-${turn.n}-${round}-${i}`, type: "function" }));
        conv.messages.push({ role: "assistant", content: r.content || null, tool_calls: calls });
        for (const c of calls) {
          const out = await runTool(this.d.tools, c.function.name, c.function.arguments);
          let args: Record<string, unknown> = {};
          try {
            args = JSON.parse(c.function.arguments || "{}") as Record<string, unknown>;
          } catch {
            args = { raw: c.function.arguments.slice(0, 200) };
          }
          const step: Step = { tool: c.function.name, args, ok: out.ok, summary: out.summary, ...(out.refused ? { refused: true } : {}) };
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
