// assistant.tsx — the Assistant drawer (ADR-034 D7, spike §5.9, mockup 5): on
// every page, knowing what is in view. It exists only when the backend says
// the assistant is available (GET /assistant/status: LiteLLM answers with the
// console's key); otherwise neither the drawer nor its nav entry is drawn.

import { ReactNode, createContext, useContext } from "react";
import { AssistantStatus } from "./types";

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

export function AssistantDrawer({ status, focus, site, onClose }: { status: AssistantStatus; focus: Focus; site: string; onClose: () => void }) {
  return (
    <aside className="drawer" aria-label="Assistant">
      <header className="drawer-head">
        <div>
          <div className="drawer-title">✦ Assistant</div>
          <div className="muted small">context: {focusLabel(focus)} · site {site}</div>
          <div className="muted small">LiteLLM · {status.model ?? "?"}{status.modelFrom === "console.json" ? " (console.json)" : " (site default)"}</div>
        </div>
        <button className="btn-x" onClick={onClose} aria-label="close the assistant">×</button>
      </header>
      <div className="drawer-body" />
      <footer className="drawer-foot muted small">Reads freely (list, show, drift, validate, logs). Changes only through a Run you click.</footer>
    </aside>
  );
}
