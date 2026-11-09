// assistant.tsx — the Assistant drawer (ADR-034 D7, spike §5.9, mockup 5): on
// every page, knowing what is in view. It exists only when the backend says
// the assistant is available (GET /assistant/status: LiteLLM answers with the
// console's key); otherwise neither the drawer nor its nav entry is drawn.
//
// A question is POSTed to /assistant/chat and its answer read as it streams:
// the reads the assistant made, its text, and its proposals. A proposal is a
// card that runs as a wizard's step does (flows.tsx): Run, in one job with the
// verb's dry run first, or for a plan to read, Preview and a Run that applies
// that preview — with the card's conversation and turn on the job, so Activity
// shows it came via the assistant. The assistant runs nothing itself. When it
// opens a page or a wizard (open_console, a `navigate` event), the drawer
// routes the console there and the wizard opens filled in (opener.ts); the
// drawer stays open, with a line saying what was opened.

import { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { get } from "./api";
import { confirmMatches, proposalFlow } from "./argv";
import { TargetValues, resolveTarget } from "./consoletargets";
import { requestOpen } from "./opener";
import { useJobRun } from "./run";
import { Command, JobOutput, JobStatusLine, quote } from "./jobs";
import { AssistantStatus, Me } from "./types";
import { FindingList, Link, TypedConfirm, canOperate, navigate, useMe } from "./ui";
import { refusalLines, runFailure } from "./wizards";
import { Focus, focusLabel, focusLabelOf, focusOf } from "./focus";

export type { Focus };
export { focusLabel, focusLabelOf, focusOf };


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
  object?: string;
  objectLabel?: string;
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

// ── a proposed job: through the job model, as a wizard's step runs it ──

// How a card runs follows from how its verb previews (argv.ts proposalFlow):
// a read: Run; no dry run, or one that only says yes or no: Run, one job with
// its dry run first, a refusal shown here with Try again; a plan or a
// destructive dry run: Preview to read, and Run applies that preview. Unlike a
// wizard's step nothing starts by itself: a card runs on the operator's click.
function ProposalCard({ p, conversation, me }: { p: Proposal; conversation: string; me: Me | null }) {
  const preview = useJobRun();
  const run = useJobRun();
  const [confirm, setConfirm] = useState("");
  const [dismissed, setDismissed] = useState(false);
  const flow = proposalFlow(p);
  const direct = flow === "read" || flow === "act";
  const pj = preview.job;
  const aj = run.job;
  const error = run.error ?? preview.error;
  const may = canOperate(me);
  const from = { conversation, proposal: p.id };
  const previewDone = pj !== null && pj.state === "done";
  const refusedByDryRun = previewDone && p.preview === "dry-run-flag" && pj!.exit !== 0;
  const pending = previewDone && p.preview === "apply-flag" && pj!.exit === 2; // changes to apply, not a failure
  const object = pj?.object ?? p.object ?? "";
  const label = pj?.objectLabel ?? p.objectLabel ?? object;
  const typed = !p.destructive || confirmMatches(confirm, object, label);
  const failed = run.finished && !run.ok;
  const spent = run.id !== null && !failed; // under way, or done with
  const ready = direct || (previewDone && !refusedByDryRun);
  const canRun = may && !spent && !failed && ready && typed && !run.live;

  if (dismissed) return <div className="card-proposal card-dismissed muted small">Proposal dismissed: <code className="mono">{quote(p.argv)}</code></div>;

  const doPreview = () => {
    run.retry();
    return preview.preview(p.argv, from);
  };
  const doRun = async () => {
    const named = p.destructive ? confirm : undefined;
    if (flow === "read") await run.read(p.argv, from);
    else if (flow === "act") await run.apply(p.argv, named, from);
    else if (preview.id) await run.applyPreview(preview.id, named);
  };

  return (
    <div className={`card-proposal${p.destructive ? " card-destructive" : ""}`}>
      <div className="card-proposal-head">
        <b>{p.read ? "Proposed read" : "Proposed change"}</b>
        <span className="muted small">{p.read ? "changes nothing" : p.preview === "none" ? "no dry run" : direct ? "dry run first" : "previewed first"}{p.destructive ? " · destructive" : ""}</span>
      </div>
      {p.rationale ? <p className="small">{p.rationale}</p> : null}
      <Command argv={p.argv} />
      <p className="muted small">
        {may
          ? `Runs as ${me?.user ?? "you"} through the job runner; ${p.read ? "a read" : direct ? "one button" : "preview first"}, recorded in Activity.`
          : "Read only here (no sign-in through the gate): an installer runs it."}
      </p>
      {p.destructive && ready && !spent && may ? <TypedConfirm object={object} label={label} value={confirm} set={setConfirm} /> : null}
      <div className="actions">
        {!direct ? (
          <button className="btn" disabled={!may || spent || preview.live} onClick={() => void doPreview()}>
            {preview.id ? "Preview again" : "Preview"}
          </button>
        ) : null}
        <button className={`btn ${p.destructive ? "btn-danger" : "btn-primary"}`} disabled={!canRun} onClick={() => void doRun()} title={ready ? "" : "Preview first"}>
          {run.state === "starting" ? "Starting…" : "Run"}
        </button>
        <button className="btn" disabled={run.id !== null} onClick={() => setDismissed(true)}>
          Dismiss
        </button>
      </div>
      {error ? <p className="readstate readstate-fail">{error}</p> : null}
      {pj ? (
        <div className="jobview">
          <JobStatusLine job={pj} label="preview" {...(pending ? { level: "pass", state: "changes pending" } : {})} />
          {pj.refused ? <p className="readstate readstate-fail">{pj.refused}</p> : null}
          <JobOutput job={pj} fold={run.id ? "tail" : "open"} />
        </div>
      ) : null}
      {refusedByDryRun ? <p className="readstate readstate-warn">The dry run refuses this change (exit {pj!.exit}): nothing to run.</p> : null}
      {aj ? (
        <div className="jobview">
          <JobStatusLine job={aj} label={p.read ? "result" : "run"} />
          {failed ? (
            <>
              <p className="readstate readstate-fail">{run.inApply ? `It did not finish: ${runFailure(aj)}` : `Nothing was applied: ${runFailure(aj)}`}.</p>
              {aj.previewPhase?.stopped ? <FindingList items={refusalLines(aj.output).map((text) => ({ text }))} /> : null}
            </>
          ) : null}
          <JobOutput job={aj} fold={failed ? "tail" : "open"} tail={8} />
          {failed ? (
            <div className="actions">
              <button className="btn btn-primary" onClick={run.retry}>Try again</button>
            </div>
          ) : null}
          {run.ok ? <p className="muted small">Recorded in <Link to="/activity">Activity</Link> with this output.</p> : null}
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
            {wizard && !operator ? <span className="muted"> · its form needs an installer signed in</span> : wizard ? <span className="muted"> · nothing changes until you apply it there</span> : null}
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
    void send(q, focusOf(window.location.pathname, window.location.search));
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
          <div className="muted small">context: {focusLabelOf(focus.page === "health" ? focusOf(window.location.pathname, window.location.search) : focus)} · site {site}</div>
          <div className="muted small">LiteLLM · {status.model ?? "?"}{status.modelFrom === "console.json" ? " (console.json)" : " (site default)"}</div>
        </div>
        <button className="btn btn-small" disabled={busy} onClick={() => { setConversation(null); setTurns([]); }} title="Start a new conversation">New</button>
        <button className="btn-x" onClick={onClose} aria-label="close the assistant">×</button>
      </header>
      <div className="drawer-body" ref={body}>
        {turns.length === 0 ? (
          <div className="muted small">
            <p>Ask about the site, a module, a zone, a finding. The assistant reads the console's own records — the health gates, the modules, the topology, backups, Activity, a host's logs when the logging module is installed, and the managers' help — opens the console's wizard for a change, filled in, or proposes it as a card you run.</p>
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
      <footer className="drawer-foot muted small">Reads freely (list, show, drift, validate, logs); opens a wizard filled in. Changes only through a Run you click.</footer>
    </aside>
  );
}
