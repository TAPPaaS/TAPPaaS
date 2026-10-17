// api.ts — reading /api/v1. One hook, useRead(path), re-reading every minute
// (the backend caches and refreshes on its own timers; the browser only asks
// for the latest answer), and an explicit refresh that asks the backend to
// re-run its reads now.

import { useCallback, useEffect, useRef, useState } from "react";
import { Envelope, Jump } from "./types";

export class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export async function get<T>(path: string): Promise<Envelope<T>> {
  const r = await fetch(`/api/v1/${path}`, { credentials: "same-origin", headers: { Accept: "application/json" } });
  const body = (await r.json().catch(() => ({}))) as Partial<Envelope<T>> & { error?: string };
  if (!r.ok) throw new ApiError(r.status, body.error ?? `HTTP ${r.status}`);
  return { data: null, at: null, ageSeconds: null, refreshing: false, error: null, ...body } as Envelope<T>;
}

export interface Read<T> {
  env: Envelope<T> | null;
  failure: string | null; // the request itself failed (not the read behind it)
  loading: boolean;
  reload: () => void;
}

const POLL_MS = 60_000;
const listeners = new Set<() => void>();

// Every open read re-reads (after a refresh, say).
export function reloadAll(): void {
  for (const l of listeners) l();
}

export function useRead<T>(path: string | null, pollMs: number = POLL_MS): Read<T> {
  const [env, setEnv] = useState<Envelope<T> | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const seq = useRef(0);

  const load = useCallback(() => {
    if (!path) return;
    const n = ++seq.current;
    setLoading(true);
    get<T>(path)
      .then((e) => {
        if (n !== seq.current) return;
        setEnv(e);
        setFailure(null);
        // A read still loading for the first time: ask again soon.
        if (e.data === null && e.refreshing) setTimeout(() => n === seq.current && load(), 3000);
      })
      .catch((e: Error) => n === seq.current && setFailure(e.message))
      .finally(() => n === seq.current && setLoading(false));
  }, [path]);

  useEffect(() => {
    setEnv(null);
    load();
    const t = setInterval(load, pollMs);
    listeners.add(load);
    return () => {
      clearInterval(t);
      listeners.delete(load);
      seq.current++;
    };
  }, [load, pollMs]);

  return { env, failure, loading, reload: load };
}

export async function refreshAll(): Promise<void> {
  await fetch("/api/v1/refresh?what=all", { method: "POST", credentials: "same-origin" });
  // The backend answers at once and refreshes behind it; read again shortly.
  setTimeout(reloadAll, 2500);
  setTimeout(reloadAll, 15000);
  setTimeout(reloadAll, 45000);
}

// Jumps are per object and change rarely: one request per object per page load.
const jumpCache = new Map<string, Promise<Jump[]>>();
export function jumps(kind: string, id: string, sw?: string): Promise<Jump[]> {
  const key = `${kind}/${encodeURIComponent(id)}${sw ? `?switch=${encodeURIComponent(sw)}` : ""}`;
  let p = jumpCache.get(key);
  if (!p) {
    p = get<Jump[]>(`jumps/${key}`).then((e) => e.data ?? []).catch(() => []);
    jumpCache.set(key, p);
  }
  return p;
}

export function useJumps(kind: string, id: string | null, sw?: string): Jump[] {
  const [list, setList] = useState<Jump[]>([]);
  useEffect(() => {
    let live = true;
    setList([]);
    if (id) void jumps(kind, id, sw).then((j) => live && setList(j));
    return () => {
      live = false;
    };
  }, [kind, id, sw]);
  return list;
}
