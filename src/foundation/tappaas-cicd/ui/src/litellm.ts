// litellm.ts — the console's connection to the site's AI stack (ADR-034 D7):
// LiteLLM's OpenAI-compatible API with the virtual key `litellm:models`
// provisions for the console, as it does for Open WebUI. The assistant exists
// only when that works; otherwise the drawer is absent and `tappaas ask` says
// why (status()).
//
//   the key     /etc/secrets/litellm-svckey.env on the mothership, written by
//               litellm:models' install-service (LITELLM_API_KEY,
//               LITELLM_BASE_URL), root-owned 0600: read directly when the
//               console may, else through `sudo -n cat` (the unit's sudo, as
//               the verbs use it). Read again while unavailable, so a key that
//               arrives with `module-manager update console` needs no restart.
//   the reach   mgmt → litellm:4000: mgmt's access-to covers every zone, so
//               rules-manager writes no pinhole (console.json declares
//               network:rules and litellm:models all the same).
//   the model   console.json `assistantModel` when set; else LiteLLM's model
//               named `default` when the key may use one (an alias the
//               operator defines in LiteLLM); else the first model LiteLLM
//               lists for the key.
//   the chat    POST <base>/chat/completions, streamed, with tool calling
//               (chat()); the agent loop around it is assistant.ts.

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { Runner } from "./run";

export const KEY_FILE = "/etc/secrets/litellm-svckey.env";

export interface Credentials {
  key: string;
  baseUrl: string; // e.g. http://litellm.rossen.internal:4000/v1
}

// ── the OpenAI-compatible chat, as LiteLLM speaks it ──────────────────

export interface ToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

export interface ToolDef {
  type: "function";
  function: { name: string; description: string; parameters: Record<string, unknown> };
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  tools: ToolDef[];
}

export interface ChatResult {
  content: string;
  toolCalls: ToolCall[];
  finish: string | null;
}

// One completion, streamed: each piece of text as it comes (onDelta), the
// tool calls assembled from their fragments.
export type ChatFn = (req: ChatRequest, onDelta: (text: string) => void, signal?: AbortSignal) => Promise<ChatResult>;

// The server-sent events of a streamed completion, fed as they arrive.
export class StreamParser {
  private buf = "";
  readonly result: ChatResult = { content: "", toolCalls: [], finish: null };
  done = false;

  constructor(private readonly onDelta: (text: string) => void) {}

  feed(text: string): void {
    this.buf += text;
    let i: number;
    while ((i = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, i).replace(/\r$/, "");
      this.buf = this.buf.slice(i + 1);
      this.line(line);
    }
  }

  end(): ChatResult {
    if (this.buf.trim()) this.line(this.buf);
    this.buf = "";
    this.result.toolCalls = this.result.toolCalls.filter((t) => t && t.function.name);
    return this.result;
  }

  private line(line: string): void {
    if (!line.startsWith("data:")) return;
    const data = line.slice(5).trim();
    if (data === "[DONE]") {
      this.done = true;
      return;
    }
    let chunk: { choices?: { delta?: { content?: string | null; tool_calls?: { index?: number; id?: string; function?: { name?: string; arguments?: string } }[] }; finish_reason?: string | null }[]; error?: { message?: string } };
    try {
      chunk = JSON.parse(data);
    } catch {
      return;
    }
    if (chunk.error) throw new Error(`LiteLLM: ${chunk.error.message ?? "error"}`);
    const c = chunk.choices?.[0];
    if (!c) return;
    const d = c.delta ?? {};
    if (typeof d.content === "string" && d.content) {
      this.result.content += d.content;
      this.onDelta(d.content);
    }
    for (const t of d.tool_calls ?? []) {
      const idx = t.index ?? 0;
      const cur = (this.result.toolCalls[idx] ??= { id: "", type: "function", function: { name: "", arguments: "" } });
      if (t.id) cur.id = t.id;
      if (t.function?.name) cur.function.name += t.function.name;
      if (t.function?.arguments) cur.function.arguments += t.function.arguments;
    }
    if (c.finish_reason) this.result.finish = c.finish_reason;
  }
}

export interface AssistantStatus {
  available: boolean;
  reason: string; // why not, or what it uses
  model: string | null;
  modelFrom: "console.json" | "default" | "first listed" | null;
  endpoint: string | null; // the base URL, never the key
  keyFile: string;
  checkedAt: string;
}

export interface LiteLLMConfig {
  keyFile: string;
  configDir: string; // config/litellm.json says whether the stack is installed; console.json may name the model
  run: Runner; // for `sudo -n cat` of the key file
  fetch?: typeof fetch;
  now?: () => number;
  log?: (line: string) => void;
}

// The env file litellm:models writes: KEY=value lines.
export function parseKeyFile(text: string): Credentials | null {
  const kv = new Map<string, string>();
  for (const line of text.split("\n")) {
    const m = /^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (m) kv.set(m[1], m[2].replace(/^["']|["']$/g, ""));
  }
  const key = kv.get("LITELLM_API_KEY") ?? "";
  const baseUrl = (kv.get("LITELLM_BASE_URL") ?? "").replace(/\/+$/, "");
  if (!key || !/^https?:\/\/[^\s/]+/.test(baseUrl)) return null;
  return { key, baseUrl };
}

// console.json `assistantModel` (fields.json of the console module), if set.
export function configuredModel(configDir: string): string | null {
  try {
    const c = JSON.parse(readFileSync(join(configDir, "console.json"), "utf8")) as { assistantModel?: unknown };
    return typeof c.assistantModel === "string" && c.assistantModel.trim() ? c.assistantModel.trim() : null;
  } catch {
    return null;
  }
}

export function chooseModel(listed: string[], configured: string | null): { model: string | null; from: AssistantStatus["modelFrom"]; why?: string } {
  if (configured) {
    return listed.includes(configured)
      ? { model: configured, from: "console.json" }
      : { model: null, from: null, why: `console.json names model '${configured}', which LiteLLM does not offer the console's key (it offers: ${listed.join(", ") || "none"})` };
  }
  if (listed.includes("default")) return { model: "default", from: "default" };
  if (listed.length > 0) return { model: listed[0], from: "first listed" };
  return { model: null, from: null, why: "LiteLLM offers the console's key no model" };
}

const OK_TTL = 5 * 60_000;
const FAIL_TTL = 30_000;

export class LiteLLM {
  private creds: Credentials | null = null;
  private last: AssistantStatus | null = null;
  private lastAt = 0;
  private inflight: Promise<AssistantStatus> | null = null;

  constructor(private readonly cfg: LiteLLMConfig) {}

  private now(): number {
    return (this.cfg.now ?? Date.now)();
  }

  credentials(): Credentials | null {
    return this.creds;
  }

  model(): string | null {
    return this.last?.available ? this.last.model : null;
  }

  // One streamed completion with tools (ChatFn).
  readonly chat: ChatFn = async (req, onDelta, signal) => {
    const c = this.creds;
    if (!c) throw new Error("no LiteLLM key");
    const f = this.cfg.fetch ?? fetch;
    const timeout = AbortSignal.timeout(5 * 60_000);
    const r = await f(`${c.baseUrl}/chat/completions`, {
      method: "POST",
      headers: { Authorization: `Bearer ${c.key}`, "Content-Type": "application/json", Accept: "text/event-stream" },
      body: JSON.stringify({ model: req.model, messages: req.messages, tools: req.tools, tool_choice: "auto", stream: true }),
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    });
    if (!r.ok || !r.body) {
      const text = (await r.text().catch(() => "")).slice(0, 300);
      if (r.status === 401 || r.status === 403) void this.status(true);
      throw new Error(`LiteLLM answered HTTP ${r.status}${text ? `: ${text}` : ""}`);
    }
    const p = new StreamParser(onDelta);
    const dec = new TextDecoder();
    for await (const part of r.body) {
      p.feed(dec.decode(part, { stream: true }));
      if (p.done) break;
    }
    p.feed(dec.decode());
    return p.end();
  };

  // The status, re-checked after five minutes (half a minute while unavailable).
  status(force = false): Promise<AssistantStatus> {
    const ttl = this.last?.available ? OK_TTL : FAIL_TTL;
    if (!force && this.last && this.now() - this.lastAt < ttl) return Promise.resolve(this.last);
    if (!this.inflight) {
      this.inflight = this.check().then((s) => {
        if (this.last?.available !== s.available || this.last?.reason !== s.reason) this.cfg.log?.(`assistant: ${s.available ? `available (${s.model} via ${s.endpoint})` : `unavailable — ${s.reason}`}`);
        this.last = s;
        this.lastAt = this.now();
        this.inflight = null;
        return s;
      });
    }
    return this.inflight;
  }

  private async readKey(): Promise<{ creds: Credentials | null; why: string }> {
    const f = this.cfg.keyFile;
    let text: string | null = null;
    try {
      text = readFileSync(f, "utf8");
    } catch {
      // Root's 0600 file in root's 0700 /etc/secrets (so not even its absence
      // shows): through the unit's sudo, as the verbs use it.
      const r = await this.cfg.run("sudo", ["-n", "cat", f], 10_000);
      if (r.ran && r.rc === 0) text = r.stdout;
      else if (!(r.ran && /No such file/i.test(r.stderr))) {
        return { creds: null, why: `${f} could not be read (sudo -n cat: ${r.stderr.trim().split("\n").pop() || `exit ${r.rc}`})` };
      }
    }
    if (text === null) {
      const stack = existsSync(join(this.cfg.configDir, "litellm.json"));
      return {
        creds: null,
        why: stack
          ? `no LiteLLM key for the console (${f} is absent): \`module-manager update console\` wires litellm:models`
          : "the AI stack is not installed (no litellm module on this site)",
      };
    }
    const c = parseKeyFile(text);
    return c ? { creds: c, why: "" } : { creds: null, why: `${f} holds no LITELLM_API_KEY and LITELLM_BASE_URL` };
  }

  private async check(): Promise<AssistantStatus> {
    const at = new Date(this.now()).toISOString();
    const base: AssistantStatus = { available: false, reason: "", model: null, modelFrom: null, endpoint: null, keyFile: this.cfg.keyFile, checkedAt: at };
    const k = await this.readKey();
    this.creds = k.creds;
    if (!k.creds) return { ...base, reason: k.why };
    const endpoint = k.creds.baseUrl;
    const f = this.cfg.fetch ?? fetch;
    let listed: string[];
    try {
      const r = await f(`${endpoint}/models`, { headers: { Authorization: `Bearer ${k.creds.key}` }, signal: AbortSignal.timeout(8000) });
      if (r.status === 401 || r.status === 403) return { ...base, endpoint, reason: `LiteLLM refused the console's key (HTTP ${r.status}) at ${endpoint}` };
      if (!r.ok) return { ...base, endpoint, reason: `LiteLLM answered HTTP ${r.status} at ${endpoint}/models` };
      const body = (await r.json()) as { data?: { id?: unknown }[] };
      listed = (body.data ?? []).map((m) => m.id).filter((x): x is string => typeof x === "string");
    } catch (e) {
      return { ...base, endpoint, reason: `LiteLLM does not answer at ${endpoint} (${(e as Error).message}): is mgmt's reach to its port 4000 open?` };
    }
    const m = chooseModel(listed, configuredModel(this.cfg.configDir));
    if (!m.model) return { ...base, endpoint, reason: m.why ?? "no model" };
    return { ...base, available: true, endpoint, model: m.model, modelFrom: m.from, reason: `model ${m.model} (${m.from}) through LiteLLM at ${endpoint}` };
  }
}
