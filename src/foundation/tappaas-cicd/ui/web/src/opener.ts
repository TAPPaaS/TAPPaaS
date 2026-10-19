// opener.ts — a wizard the assistant opened (open_console, consoletargets.ts):
// the drawer routes to the wizard's page and leaves a request here; the
// button that opens that wizard on the page takes it, opens its dialog with
// the values filled in, and clears it. A request nobody takes within a minute
// (the page did not offer the wizard: a read-only role) is dropped.

import { useEffect, useState } from "react";
import { TargetValues } from "./consoletargets";

export interface OpenRequest {
  wizard: string;
  arg: string | null;
  values: TargetValues;
  n: number;
  at: number;
}

let pending: OpenRequest | null = null;
let seq = 0;
const subs = new Set<() => void>();
const TTL = 60_000;

export function requestOpen(wizard: string, arg: string | null, values: TargetValues): void {
  pending = { wizard, arg, values, n: ++seq, at: Date.now() };
  subs.forEach((f) => f());
}

function matching(wizard: string, arg?: string | null): OpenRequest | null {
  const p = pending;
  if (!p || Date.now() - p.at > TTL || p.wizard !== wizard) return null;
  return arg === undefined || p.arg === arg ? p : null;
}

// The request for this wizard (and object), until it is claimed.
export function useOpenRequest(wizard: string, arg?: string | null): OpenRequest | null {
  const [, tick] = useState(0);
  useEffect(() => {
    const f = () => tick((x) => x + 1);
    subs.add(f);
    return () => {
      subs.delete(f);
    };
  }, []);
  return matching(wizard, arg);
}

// Take a request: true for the first taker only (two buttons for one wizard
// may be on a page).
function claim(n: number): boolean {
  if (!pending || pending.n !== n) return false;
  pending = null;
  return true;
}

// A dialog the assistant opens: open(values) once per request that matches,
// when `ready` (the page has what the dialog needs).
export function useOpenedBy(wizard: string, arg: string | null | undefined, open: (values: TargetValues) => void, ready = true): void {
  const request = useOpenRequest(wizard, arg);
  useEffect(() => {
    if (request && ready && claim(request.n)) open(request.values);
  }, [request?.n, ready]);
}
