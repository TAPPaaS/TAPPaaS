// assistant.tsx — the Assistant drawer (ADR-034 D7, spike §5.9, mockup 5): on
// every page, knowing what is in view. It exists only when the backend says
// the assistant is available (GET /assistant/status: LiteLLM answers with the
// console's key); otherwise neither the drawer nor its nav entry is drawn.
//
// A question is POSTed to /assistant/chat and its answer read as it streams:
// the reads the assistant made, its text, and its proposals. A proposal is a
// card: Preview runs the verb's own dry run and Run applies that preview — the
// P2 job flow, with the card's conversation and turn on the job, so Activity
// shows it came via the assistant. The assistant runs nothing itself. When it
// opens a page or a wizard (open_console, a `navigate` event), the drawer
// routes the console there and the wizard opens filled in (opener.ts); the
// drawer stays open, with a line saying what was opened.

import { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { applyJob, get, previewJob, readJob, useJob } from "./api";
import { TargetValues, resolveTarget } from "./consoletargets";
import { requestOpen } from "./opener";
import { Command, Output, jobResult } from "./jobs";
import { AssistantStatus, Me } from "./types";
import { Tag, canOperate, navigate, useMe } from "./ui";

// What is in view, sent with every question.
export interface Focus {
  page: string; // overview, physical, modules, module, activity, …
  kind?: string; // the object in view: module, node, zone, finding, …
  name?: string;
  detail?: string; // e.g. the finding's text
}

export function focusOf(path: string): Focus {
  const seg = path.split("/").filter((s) => s.length > 0).map((s) => decodeURIComponent(s));
  if (seg.length === 0) return { page: "overview" };
  if (seg[0] === "modules" && seg[1]) return { page: "module", kind: "module", name: seg[1] };
  return { page: seg[0] };
}

export function focusLabel(f: Focus): string {
  if (f.kind && f.name) return `${f.kind} ${f.name}`;
  return `page ${f.page}`;
}

export interface AssistantApi {
  available: boolean;
  open: boolean;
  setOpen: (open: boolean) => void;
  // Open the drawer and ask, about an object other than the page's if given.
  ask: (question: string, focus?: Focus) => void;
}

export const AssistantContext = createContext<AssistantApi>({ available: false, open: false, setOpen: () => undefined, ask: () => undefined });
export const useAssistant = (): AssistantApi => useContext(AssistantContext);

// "Ask about this" — drawn only when the assistant is available.
export function AskAbout({ question, focus, children }: { question: string; focus: Focus; children?: ReactNode }) {
  const a = useAssistant();
  if (!a.available) return null;
  return (
    <button className="btn btn-small btn-ask" title="Ask the assistant about this" onClick={() => a.ask(question, focus)}>
      {children ?? "✦ Ask about this"}
    </button>
  );
}

// ── the conversation, as the backend streams it ───────────────────────

interface Step {
  tool: string;
  ok: boolean;
  summary: string;
  refused?: boolean;
}

export interface Proposal {
  id: string;
  turn: number;
  argv: string[];
  rationale: string;
  verb: string;
  read: boolean;
  destructive: boolean;
  preview: string;
}

// A page or wizard the assistant opened (open_console).
interface Opened {
  target: string;
  values: TargetValues;
  path: string;
  title: string;
  url: string | null;
}

interface Turn {
  n: number;
  question: string;
  focus: Focus | null;
  steps: Step[];
  answer: string;
  proposals: Proposal[];
  opened?: Opened[]; // absent in a conversation saved before open_console
  error: string | null;
  pending?: boolean;
}

type ChatEvent =
  | { type: "conversation"; id: string; turn: number; model: string }
  | { type: "step"; step: Step }
  | { type: "delta"; text: string }
  | { type: "proposal"; proposal: Proposal; conversation: string }
  | ({ type: "navigate" } & Opened)
  | { type: "done"; turn: Turn }
  | { type: "error"; message: string };

// Follow a navigate event: leave the wizard's request (its button on the page
// takes it), then route there. The catalog is the backend's (consoletargets.ts).
function follow(o: Opened): void {
  const r = resolveTarget(o.target, o.values);
  if (r.ok && r.wizard) requestOpen(r.wizard, r.arg, r.values);
  navigate(r.ok ? r.path : o.path);
}

async function streamChat(body: unknown, onEvent: (e: ChatEvent) => void, signal: AbortSignal): Promise<void> {
  const r = await fetch("/api/v1/assistant/chat", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "text/event-stream" },
    body: JSON.stringify(body),
    signal,
  });
  if (!r.ok || !r.body) {
    const j = (await r.json().catch(() => ({}))) as { error?: string };
    throw new Error(j.error ?? `HTTP ${r.status}`);
  }
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i: number;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const data = block.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).join("\n");
      if (data) onEvent(JSON.parse(data) as ChatEvent);
    }
  }
}

// ── a proposed job: Preview and Run through the job model ─────────────

function ProposalCard({ p, conversation, me }: { p: Proposal; conversation: string; me: Me | null }) {
  const [preview, setPreview] = useState<string | null>(null);
  const [applied, setApplied] = useState<string | null>(null);
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [dismissed, setDismissed] = useState(false);
  const pj = useJob(preview);
  const aj = useJob(applied);
  const may = canOperate(me);
  const from = { conversation, proposal: p.id };
  const previewDone = pj !== null && pj.state === "done";
  const refusedByDryRun = previewDone && p.preview === "dry-run-flag" && pj!.exit !== 0;
  const object = pj?.object ?? "";
  const label = pj?.objectLabel ?? object;
  const canRun = may && !applied && (p.read ? !preview : previewDone && !refusedByDryRun && (!p.destructive || (confirm !== "" && (confirm === object || confirm === label))));

  if (dismissed) return <div className="card-proposal card-dismissed muted small">Proposal dismissed: <code className="mono">{p.argv.join(" ")}</code></div>;

  const doPreview = async () => {
    setError(null);
    const r = await previewJob(p.argv, from);
    if (!r.data) return setError(r.error);
    if (r.error) setError(r.error);
    setPreview(r.data.id);
  };
  const doRun = async () => {
    setError(null);
    if (p.read) {
      const r = await readJob(p.argv, from);
      if (!r.data) return setError(r.error);
      return setPreview(r.data.id);
    }
    if (!preview) return;
    const r = await applyJob(preview, p.destructive ? confirm : undefined);
    if (!r.data || r.status >= 400) return setError(r.error ?? `HTTP ${r.status}`);
    setApplied(r.data.id);
  };

  return (
    <div className={`card-proposal${p.destructive ? " card-destructive" : ""}`}>
      <div className="card-proposal-head">
        <b>{p.read ? "Proposed read" : "Proposed change"}</b>
        <span className="muted small">{p.read ? "changes nothing" : p.preview === "none" ? "no dry run" : "previewed first"}{p.destructive ? " · destructive" : ""}</span>
      </div>
      {p.rationale ? <p className="small">{p.rationale}</p> : null}
      <Command argv={p.argv} />
      <p className="muted small">
        {may
          ? `Runs as ${me?.user ?? "you"} through the job runner; ${p.read ? "a read" : "preview first"}, recorded in Activity.`
          : "Read only here (no sign-in through the gate): an installer runs it."}
      </p>
      <div className="actions">
        {!p.read ? (
          <button className="btn" disabled={!may || applied !== null} onClick={() => void doPreview()}>
            {preview ? "Preview again" : "Preview"}
          </button>
        ) : null}
        <button className={`btn ${p.destructive ? "btn-danger" : "btn-primary"}`} disabled={!canRun} onClick={() => void doRun()} title={p.read || previewDone ? "" : "Preview first"}>
          Run
        </button>
        <button className="btn" disabled={applied !== null} onClick={() => setDismissed(true)}>
          Dismiss
        </button>
      </div>
      {error ? <p className="readstate readstate-fail">{error}</p> : null}
      {pj ? (
        <div className="jobview">
          <p className="small">
            <Tag level={pj.state === "refused" ? "fail" : pj.state !== "done" ? "skip" : pj.exit === 0 ? "pass" : "warn"} /> {p.read ? "result" : "preview"}: {jobResult(pj)}
            <span className="muted"> · job {pj.id}</span>
          </p>
          {pj.refused ? <p className="readstate readstate-fail">{pj.refused}</p> : null}
          <Output text={pj.output} live={pj.state === "running" || pj.state === "queued"} />
        </div>
      ) : null}
      {refusedByDryRun ? <p className="readstate readstate-warn">The dry run refuses this change (exit {pj!.exit}): nothing to run.</p> : null}
      {p.destructive && previewDone && !applied && may ? (
        <label className="form-row confirm">
          <span>Type <b className="mono">{object}</b> to confirm{label !== object ? <> — <span className="mono">{label}</span></> : null}</span>
          <input type="text" autoComplete="off" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        </label>
      ) : null}
      {aj ? (
        <div className="jobview">
          <p className="small">
            <Tag level={aj.state === "refused" ? "fail" : aj.state !== "done" ? "skip" : aj.exit === 0 ? "pass" : "warn"} /> run: {jobResult(aj)}
            <span className="muted"> · job {aj.id}</span>
          </p>
          <Output text={aj.output} live={aj.state === "running" || aj.state === "queued"} />
        </div>
      ) : null}
    </div>
  );
}

// ── the drawer ────────────────────────────────────────────────────────

function TurnView({ t, conversation, me }: { t: Turn; conversation: string; me: Me | null }) {
  const reads = t.steps.filter((s) => !s.refused && s.tool !== "propose_job" && s.tool !== "open_console");
  const operator = canOperate(me);
  const refused = t.steps.filter((s) => s.refused);
  return (
    <div className="turn">
      <div className="turn-who">{me?.user ?? "you"}</div>
      <div className="turn-q">{t.question}</div>
      <div className="turn-who">
        assistant{reads.length ? ` · read: ${reads.map((s) => s.summary).join(", ")}` : ""}
      </div>
      {refused.length ? <p className="readstate readstate-warn small">Refused: {refused.map((s) => s.tool).join(", ")} — the assistant has no such tool; it never runs a change.</p> : null}
      {(t.opened ?? []).map((o, i) => {
        const vals = Object.entries(o.values).map(([k, v]) => `${k} ${Array.isArray(v) ? v.join(", ") : String(v)}`);
        const wizard = !o.target.startsWith("/");
        return (
          <p key={i} className="turn-opened small">
            ↗ Opened <a href={o.path} onClick={(e) => { e.preventDefault(); follow(o); }}>{o.title}</a>
            {vals.length ? <span className="muted"> · filled in: {vals.join(", ")}</span> : null}
            {wizard && !operator ? <span className="muted"> · its form needs an installer signed in</span> : wizard ? <span className="muted"> · nothing changes until you preview and apply it there</span> : null}
          </p>
        );
      })}
      <div className="turn-a">{t.answer || (t.pending ? "…" : "")}</div>
      {t.error ? <p className="readstate readstate-fail small">{t.error}</p> : null}
      {t.proposals.map((p) => (
        <ProposalCard key={p.id} p={p} conversation={conversation} me={me} />
      ))}
    </div>
  );
}

export function AssistantDrawer({ status, focus, site, asked, open, onClose }: { status: AssistantStatus; focus: Focus; site: string; asked: { question: string; focus: Focus; n: number } | null; open: boolean; onClose: () => void }) {
  const me = useMe();
  const [conversation, setConversation] = useState<string | null>(null);
  const [turns, setTurns] = useState<Turn[]>([]);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [earlier, setEarlier] = useState<{ id: string; title: string; updated: string }[]>([]);
  const abort = useRef<AbortController | null>(null);
  const body = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    body.current?.scrollTo({ top: body.current.scrollHeight });
  }, [turns]);

  useEffect(() => {
    if (!open) return;
    void get<{ id: string; title: string; updated: string }[]>("assistant/conversations").then((e) => setEarlier(e.data ?? [])).catch(() => undefined);
  }, [open, conversation]);

  const patchLast = (f: (t: Turn) => Turn) => setTurns((ts) => (ts.length ? [...ts.slice(0, -1), f(ts[ts.length - 1])] : ts));

  const send = async (question: string, about: Focus) => {
    if (!question.trim() || busy) return;
    setBusy(true);
    setTurns((ts) => [...ts, { n: ts.length + 1, question, focus: about, steps: [], answer: "", proposals: [], error: null, pending: true }]);
    const ac = new AbortController();
    abort.current = ac;
    let conv = conversation;
    try {
      await streamChat({ conversation: conv ?? undefined, message: question, focus: about }, (e) => {
        if (e.type === "conversation") {
          conv = e.id;
          setConversation(e.id);
        } else if (e.type === "step") patchLast((t) => ({ ...t, steps: [...t.steps, e.step] }));
        else if (e.type === "delta") patchLast((t) => ({ ...t, answer: t.answer + e.text }));
        else if (e.type === "proposal") patchLast((t) => ({ ...t, proposals: [...t.proposals, e.proposal] }));
        else if (e.type === "navigate") {
          const { type: _t, ...o } = e;
          patchLast((t) => ({ ...t, opened: [...(t.opened ?? []), o] }));
          follow(o);
        }
        else if (e.type === "done") patchLast(() => ({ ...e.turn, pending: false }));
        else if (e.type === "error") patchLast((t) => ({ ...t, error: e.message, pending: false }));
      }, ac.signal);
    } catch (err) {
      if (!ac.signal.aborted) patchLast((t) => ({ ...t, error: (err as Error).message }));
    } finally {
      patchLast((t) => ({ ...t, pending: false }));
      setBusy(false);
      abort.current = null;
    }
  };

  // "Ask about this" from a page.
  useEffect(() => {
    if (asked) void send(asked.question, asked.focus);
  }, [asked?.n]);

  const submit = (e: { preventDefault(): void }) => {
    e.preventDefault();
    const q = text;
    setText("");
    void send(q, focus);
  };

  const load = async (id: string) => {
    const e = await get<{ id: string; turns: Turn[] }>(`assistant/conversations/${encodeURIComponent(id)}`).catch(() => null);
    if (!e?.data) return;
    setConversation(e.data.id);
    setTurns(e.data.turns);
  };

  return (
    <aside className="drawer" aria-label="Assistant" hidden={!open}>
      <header className="drawer-head">
        <div>
          <div className="drawer-title">✦ Assistant</div>
          <div className="muted small">context: {focusLabel(focus)} · site {site}</div>
          <div className="muted small">LiteLLM · {status.model ?? "?"}{status.modelFrom === "console.json" ? " (console.json)" : " (site default)"}</div>
        </div>
        <button className="btn btn-small" disabled={busy} onClick={() => { setConversation(null); setTurns([]); }} title="Start a new conversation">New</button>
        <button className="btn-x" onClick={onClose} aria-label="close the assistant">×</button>
      </header>
      <div className="drawer-body" ref={body}>
        {turns.length === 0 ? (
          <div className="muted small">
            <p>Ask about the site, a module, a zone, a finding. The assistant reads the console's own records — the health gates, the modules, the topology, backups, Activity, a host's logs when the logging module is installed, and the managers' help — opens the console's wizard for a change, filled in, or proposes it as a card you preview and run.</p>
            {earlier.length ? (
              <>
                <p>Earlier conversations:</p>
                <ul className="earlier">
                  {earlier.slice(0, 8).map((c) => (
                    <li key={c.id}>
                      <a href="#" onClick={(ev) => { ev.preventDefault(); void load(c.id); }}>{c.title || c.id}</a> <span className="muted">{c.updated.slice(0, 16).replace("T", " ")}</span>
                    </li>
                  ))}
                </ul>
              </>
            ) : null}
          </div>
        ) : null}
        {turns.map((t) => (
          <TurnView key={t.n} t={t} conversation={conversation ?? ""} me={me} />
        ))}
      </div>
      <form className="drawer-ask" onSubmit={submit}>
        <textarea
          rows={2}
          value={text}
          placeholder="Ask about the site, a module, a zone, a finding…"
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) submit(e);
          }}
        />
        {busy ? (
          <button type="button" className="btn" onClick={() => abort.current?.abort()}>Stop</button>
        ) : (
          <button type="submit" className="btn btn-primary" disabled={!text.trim()}>Ask</button>
        )}
      </form>
      <footer className="drawer-foot muted small">Reads freely (list, show, drift, validate, logs); opens a wizard filled in. Changes only through a Preview and Run you click.</footer>
    </aside>
  );
}
