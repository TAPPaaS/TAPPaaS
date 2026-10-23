// ui.tsx — the small pieces every page uses: the router, links, badges, the
// status dot, the "Open in" list and the read-state line.

import { MouseEvent, ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useJumps } from "./api";
import { Envelope, Jump, Me } from "./types";

// Who is looking (GET /me), for what a page offers: the read role and the
// status route see no operate control (ADR-034 D2, D3).
export const MeContext = createContext<Me | null>(null);
export const useMe = (): Me | null => useContext(MeContext);
export const canOperate = (me: Me | null): boolean => me !== null && me.role !== "read" && me.route !== "status";

// ── a router of four pages ────────────────────────────────────────────
export function usePath(): string {
  const [path, setPath] = useState(window.location.pathname);
  useEffect(() => {
    const on = () => setPath(window.location.pathname);
    window.addEventListener("popstate", on);
    return () => window.removeEventListener("popstate", on);
  }, []);
  return path;
}

// The address's #fragment, followed as the path is (a link to a row of a page).
export function useHash(): string {
  const [hash, setHash] = useState(window.location.hash.slice(1));
  useEffect(() => {
    const on = () => setHash(window.location.hash.slice(1));
    window.addEventListener("popstate", on);
    window.addEventListener("hashchange", on);
    return () => {
      window.removeEventListener("popstate", on);
      window.removeEventListener("hashchange", on);
    };
  }, []);
  return hash;
}

export function navigate(to: string): void {
  if (to === window.location.pathname + window.location.search) return;
  window.history.pushState(null, "", to);
  window.dispatchEvent(new PopStateEvent("popstate"));
  window.scrollTo(0, 0);
}

// Replace the current address (a redirect: no history entry of its own).
export function replacePath(to: string): void {
  window.history.replaceState(null, "", to);
  window.dispatchEvent(new PopStateEvent("popstate"));
}

export function Link({ to, children, className }: { to: string; children: ReactNode; className?: string }) {
  const click = (e: MouseEvent<HTMLAnchorElement>) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    navigate(to);
  };
  return (
    <a href={to} onClick={click} className={className}>
      {children}
    </a>
  );
}

// ── status ────────────────────────────────────────────────────────────
export type Level = "fail" | "warn" | "pass" | "skip" | "unknown" | "info";

export function levelOf(s: string | null | undefined): Level {
  switch (s) {
    case "fail":
    case "failed":
    case "down":
    case "error":
      return "fail";
    case "warn":
    case "warning":
    case "drift":
    case "act":
      return "warn";
    case "pass":
    case "ok":
    case "up":
    case "running":
    case "in-sync":
    case "covered":
      return "pass";
    case "skip":
      return "skip";
    default:
      return "unknown";
  }
}

export function Dot({ level, title }: { level: Level; title?: string }) {
  return <span className={`dot dot-${level}`} title={title} aria-label={title ?? level} />;
}

export function Badge({ level, children, title }: { level: Level; children: ReactNode; title?: string }) {
  return (
    <span className={`badge badge-${level}`} title={title}>
      {children}
    </span>
  );
}

export function Tag({ level }: { level: string }) {
  const l = levelOf(level);
  return <span className={`tag tag-${l}`}>{level.toUpperCase()}</span>;
}

// ── "Open in …" ───────────────────────────────────────────────────────
export function OpenIn({ kind, id, sw, compact }: { kind: string; id: string | null; sw?: string; compact?: boolean }) {
  const list: Jump[] = useJumps(kind, id, sw);
  if (list.length === 0) return compact ? null : <span className="muted">no jump for this object</span>;
  return (
    <span className="jumps">
      {list.map((j) => (
        <a key={j.url + j.label} href={j.url} target="_blank" rel="noreferrer noopener" className="jump" title={j.url}>
          {j.label} ↗
        </a>
      ))}
    </span>
  );
}

// ── how old a read is, and whether it failed ───────────────────────────
export function since(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

export function when(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return `${d.toLocaleDateString([], { year: "numeric", month: "2-digit", day: "2-digit" })} ${d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
}

export function ReadState<T>({ env, failure, what }: { env: Envelope<T> | null; failure: string | null; what: string }) {
  if (failure) return <div className="readstate readstate-fail">{what}: {failure}</div>;
  if (!env) return <div className="readstate">reading {what}…</div>;
  if (env.data === null && env.refreshing) return <div className="readstate">reading {what} — the first read can take a minute…</div>;
  if (env.error) {
    return (
      <div className={`readstate ${env.data === null ? "readstate-fail" : "readstate-warn"}`}>
        {env.data === null ? `${what} could not be read` : `${what} from ${since(env.at)}; the last refresh failed`}: {env.error}
      </div>
    );
  }
  return null;
}

export function Section({ title, aside, children }: { title: ReactNode; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className="section">
      <header className="section-head">
        <h2>{title}</h2>
        {aside ? <span className="section-aside">{aside}</span> : null}
      </header>
      {children}
    </section>
  );
}

export function KV({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="kv">
      {rows.map(([k, v]) => (
        <div key={k} className="kv-row">
          <dt>{k}</dt>
          <dd>{v === null || v === undefined || v === "" ? <span className="muted">—</span> : v}</dd>
        </div>
      ))}
    </dl>
  );
}
