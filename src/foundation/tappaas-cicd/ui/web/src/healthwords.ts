// healthwords.ts — the words and links the Health page, its panel, the
// Overview's health strip and the Security page's Threats share: the condition
// types, the filters as an address, a condition's hits and hold as the operator
// reads them, and what an acknowledgement does to it.

import type { HealthHits, HealthRoot } from "./types";

// The types health speaks in, in the filter's order: what fails, what drifts or
// runs out, what waits on the operator, what could be attacked and what is.
export const CONDITION_TYPES = ["operational", "drift", "capacity", "performance", "backup", "upkeep", "vulnerability", "threat", "impact"];

export interface HealthFilters {
  type: string; // "" is all
  class: string;
  environment: string;
}

export const NO_HEALTH_FILTERS: HealthFilters = { type: "", class: "", environment: "" };

// A query string as pairs, without the DOM (the unit tests run this in node).
function params(search: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const part of search.replace(/^\?/, "").split("&")) {
    if (!part) continue;
    const at = part.indexOf("=");
    const dec = (x: string): string => {
      try {
        return decodeURIComponent(x.replace(/\+/g, " "));
      } catch {
        return x;
      }
    };
    out.set(dec(at < 0 ? part : part.slice(0, at)), dec(at < 0 ? "" : part.slice(at + 1)));
  }
  return out;
}

const query = (pairs: [string, string][]): string => pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");

/** The filters an address carries: /health?type=threat&class=vm&environment=prod. */
export function filtersOf(search: string): HealthFilters {
  const q = params(search);
  return { type: q.get("type") ?? "", class: q.get("class") ?? "", environment: q.get("environment") ?? "" };
}

export const filtering = (f: HealthFilters): boolean => !!(f.type || f.class || f.environment);

/** The Health page's address for a selection under filters. */
export function healthPath(select: string | null, f: HealthFilters): string {
  const pairs: [string, string][] = [];
  if (f.type) pairs.push(["type", f.type]);
  if (f.class) pairs.push(["class", f.class]);
  if (f.environment) pairs.push(["environment", f.environment]);
  if (select) pairs.push(["select", select]);
  const s = query(pairs);
  return `/health${s ? `?${s}` : ""}`;
}

/** The filters' query for a read (health/counts). */
export function filterQuery(f: HealthFilters): string {
  return query([["type", f.type], ["class", f.class], ["environment", f.environment]]);
}

/** A root cause under the filters: a root in that type, of that class, in that
 *  environment (its own or one of what it impacts). The server's rootMatches. */
export function rootMatches(r: HealthRoot, f: HealthFilters): boolean {
  const types = r.types ?? (r.type ? [r.type] : []);
  return (!f.type || types.includes(f.type)) && (!f.class || r.class === f.class) && (!f.environment || r.environment === f.environment || r.environments.includes(f.environment));
}

/** How long ago, in the words a row has room for: 5 min, 2 h, 3 d. */
export function ago(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "";
  const m = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000));
  return m < 60 ? `${m} min` : m < 48 * 60 ? `${Math.round(m / 60)} h` : `${Math.round(m / 1440)} d`;
}

/** "7 hits" — the count alone, for a column. */
export const hitsCount = (h: HealthHits): string => (h.count === 1 ? "1 hit" : `${h.count} hits`);

/** The hold as a column: "until acknowledged", "5 h left", "over". */
export function holdText(heldUntil: string | undefined, now = Date.now()): string {
  if (!heldUntil) return "";
  if (heldUntil === "ack") return "until acknowledged";
  const left = Date.parse(heldUntil) - now;
  if (Number.isNaN(left)) return "";
  return left <= 0 ? "over" : `${ago(new Date(now - left).toISOString(), now)} left`;
}

/** What acknowledging a condition does, from the rule that holds it: a hit held
 *  until acknowledged ends at the next assessment; any other keeps its status
 *  and stops counting. */
export function ackEffect(c: { heldUntil?: string; heldBy?: string; type: string }): string {
  if (c.heldUntil === "ack") {
    return `This ${c.type} is held until someone acknowledges it${c.heldBy ? ` (${c.heldBy})` : ""}: the acknowledgement ends it at the next assessment, and a new hit opens it again. Say what was checked.`;
  }
  if (c.heldUntil) {
    return `This ${c.type} is held from its last hit${c.heldBy ? ` (${c.heldBy})` : ""} and ends by itself; the acknowledgement keeps its status but stops counting it for validate, mails and the Overview until then.`;
  }
  return "The condition keeps its status but stops counting for validate, mails and the Overview. On a root cause it covers the symptoms too.";
}
