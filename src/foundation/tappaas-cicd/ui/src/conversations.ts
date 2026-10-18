// conversations.ts — the assistant's conversations (ADR-034 D7), kept per user
// in the console's state directory (never in config/: they are the console's
// own records, not the site's), one small JSON file each, mode 0600:
//
//   <state dir>/assistant/<user>/<id>.json
//
// Capped: the newest 50 conversations per user, 40 turns and 256 KiB per
// conversation (the oldest turns and messages go first). A turn keeps what
// was asked, what the assistant read, what it answered and what it proposed;
// the messages are what the model is sent again on the next turn.

import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "fs";
import { randomBytes } from "crypto";
import { join } from "path";
import { ChatMessage } from "./litellm";

// What was in view when the question was asked (sent by the front end).
export interface Focus {
  page: string;
  kind?: string;
  name?: string;
  detail?: string;
}

export interface Proposal {
  id: string; // p<turn>-<n>
  turn: number;
  argv: string[];
  rationale: string;
  verb: string;
  read: boolean; // runs at once (a read verb), no preview
  destructive: boolean;
  preview: string; // how it previews: apply-flag, dry-run-flag, none, read
  at: string;
}

export interface Step {
  tool: string;
  args: Record<string, unknown>;
  ok: boolean;
  summary: string;
  refused?: boolean; // a tool that does not exist (a write the model tried)
}

export interface Turn {
  n: number;
  at: string;
  question: string;
  focus: Focus | null;
  steps: Step[];
  answer: string;
  proposals: Proposal[];
  model: string | null;
  error: string | null;
}

export interface Conversation {
  id: string;
  user: string;
  created: string;
  updated: string;
  title: string;
  turns: Turn[];
  messages: ChatMessage[];
}

export interface ConversationSummary {
  id: string;
  title: string;
  updated: string;
  turns: number;
}

export interface StoreLimits {
  perUser: number;
  turns: number;
  bytes: number;
}

const DEFAULT_LIMITS: StoreLimits = { perUser: 50, turns: 40, bytes: 256 * 1024 };
export const CONVERSATION_ID = /^[0-9]{8}-[0-9a-f]{8}$/;

// A directory name for a caller: the gate's username, else how it came in.
export function userKey(user: string | null, via: string): string {
  const u = user ?? via;
  return u.replace(/[^A-Za-z0-9._@-]/g, "_").replace(/^\.+/, "_").slice(0, 64) || "_";
}

export class Conversations {
  private readonly limits: StoreLimits;

  constructor(private readonly dir: string, limits: Partial<StoreLimits> = {}, private readonly now: () => number = Date.now) {
    this.limits = { ...DEFAULT_LIMITS, ...limits };
  }

  private userDir(user: string): string {
    return join(this.dir, user);
  }

  private file(user: string, id: string): string {
    return join(this.userDir(user), `${id}.json`);
  }

  create(user: string): Conversation {
    const t = new Date(this.now()).toISOString();
    const c: Conversation = {
      id: `${t.slice(0, 10).replace(/-/g, "")}-${randomBytes(4).toString("hex")}`,
      user,
      created: t,
      updated: t,
      title: "",
      turns: [],
      messages: [],
    };
    return c;
  }

  get(user: string, id: string): Conversation | null {
    if (!CONVERSATION_ID.test(id)) return null;
    const f = this.file(user, id);
    if (!existsSync(f)) return null;
    try {
      const c = JSON.parse(readFileSync(f, "utf8")) as Conversation;
      return c.user === user ? c : null;
    } catch {
      return null;
    }
  }

  list(user: string): ConversationSummary[] {
    const d = this.userDir(user);
    if (!existsSync(d)) return [];
    const out: ConversationSummary[] = [];
    for (const f of readdirSync(d)) {
      const id = f.replace(/\.json$/, "");
      if (!CONVERSATION_ID.test(id)) continue;
      const c = this.get(user, id);
      if (c) out.push({ id: c.id, title: c.title, updated: c.updated, turns: c.turns.length });
    }
    return out.sort((a, b) => b.updated.localeCompare(a.updated));
  }

  // The proposal a card names, in the caller's own conversation.
  proposal(user: string, id: string, proposalId: string): { conversation: Conversation; proposal: Proposal } | null {
    const c = this.get(user, id);
    if (!c) return null;
    for (const t of c.turns) {
      const p = t.proposals.find((x) => x.id === proposalId);
      if (p) return { conversation: c, proposal: p };
    }
    return null;
  }

  save(c: Conversation): void {
    c.updated = new Date(this.now()).toISOString();
    if (!c.title && c.turns[0]) c.title = c.turns[0].question.replace(/\s+/g, " ").slice(0, 80);
    // The caps: turns, then size (the oldest go first; a history never starts
    // with an answer to a question that is no longer there).
    if (c.turns.length > this.limits.turns) c.turns = c.turns.slice(-this.limits.turns);
    let text = JSON.stringify(c);
    while (Buffer.byteLength(text) > this.limits.bytes && (c.messages.length > 2 || c.turns.length > 1)) {
      if (c.messages.length > 2) c.messages = trimHistory(c.messages.slice(Math.max(1, Math.floor(c.messages.length / 4))));
      else c.turns = c.turns.slice(1);
      text = JSON.stringify(c);
    }
    const d = this.userDir(c.user);
    mkdirSync(d, { recursive: true });
    const f = this.file(c.user, c.id);
    const tmp = `${f}.tmp-${process.pid}`;
    writeFileSync(tmp, text, { encoding: "utf8", mode: 0o600 });
    renameSync(tmp, f);
    this.prune(c.user);
  }

  // The newest `perUser` conversations stay.
  private prune(user: string): void {
    const all = this.list(user);
    for (const old of all.slice(this.limits.perUser)) {
      try {
        unlinkSync(this.file(user, old.id));
      } catch {
        /* gone already */
      }
    }
  }
}

// A history the model can be sent: it begins with a user's question, never
// with an answer or a tool result whose call is no longer there.
export function trimHistory(messages: ChatMessage[]): ChatMessage[] {
  const i = messages.findIndex((m) => m.role === "user");
  return i < 0 ? [] : messages.slice(i);
}
