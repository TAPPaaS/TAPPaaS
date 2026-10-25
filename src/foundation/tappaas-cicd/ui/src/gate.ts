// gate.ts — proof that a request came through the Authentik gate (ADR-034 D2).
//
// The firewall's address alone proves nothing: a host on mgmt that takes it
// could send any X-Authentik-* header. With every request the gate's outpost
// sends X-Authentik-Jwt, the user's token from the route's proxy provider. With
// no signing key on the provider (identity:accessControl sets none) Authentik
// signs it HS256 with the provider's client secret, which only Authentik and
// this console hold. The console verifies it — signature, audience, issuer,
// expiry — and takes the user and groups from it, not from the plain headers.
//
// The key is the provider's, looked up by the route's external host through the
// Authentik API with the credentials the controllers use, and cached. Only the
// console's own routes (console.<domain>, status.<domain>) are looked up, so a
// token from another gated app does not open the console.

import { createHmac, timingSafeEqual } from "crypto";
import { readFileSync } from "fs";

export interface GateKey {
  clientId: string;
  secret: string;
  slug: string; // the application's slug: the issuer ends in /application/o/<slug>/
}

export interface GateClaims {
  user: string;
  groups: string[];
  name: string | null;
  email: string | null;
}

export type Verified = { ok: true; claims: GateClaims } | { ok: false; reason: string };

const LEEWAY_S = 60; // clock skew between the identity VM and the mothership

function b64json(part: string): Record<string, unknown> | null {
  try {
    const v: unknown = JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

// Verifies an HS256 token against the provider's key. `now` in seconds.
export function verifyGateToken(token: string | undefined, key: GateKey, now: number): Verified {
  if (!token) return { ok: false, reason: "no X-Authentik-Jwt: the request did not come through the identity gate" };
  const parts = token.split(".");
  if (parts.length !== 3) return { ok: false, reason: "X-Authentik-Jwt is not a JWT" };
  const head = b64json(parts[0]);
  const body = b64json(parts[1]);
  if (!head || !body) return { ok: false, reason: "X-Authentik-Jwt cannot be read" };
  // Never what the token says it is: only HS256, the provider's own algorithm.
  if (head.alg !== "HS256") return { ok: false, reason: `X-Authentik-Jwt is signed ${String(head.alg)}, not HS256` };
  const want = createHmac("sha256", key.secret).update(`${parts[0]}.${parts[1]}`).digest();
  const got = Buffer.from(parts[2], "base64url");
  if (got.length !== want.length || !timingSafeEqual(got, want)) return { ok: false, reason: "X-Authentik-Jwt has a wrong signature" };

  const aud = Array.isArray(body.aud) ? body.aud : [body.aud];
  if (!aud.includes(key.clientId)) return { ok: false, reason: "X-Authentik-Jwt is for another application" };
  if (typeof body.iss !== "string" || !body.iss.replace(/\/?$/, "/").endsWith(`/application/o/${key.slug}/`)) {
    return { ok: false, reason: "X-Authentik-Jwt has another issuer" };
  }
  if (typeof body.exp !== "number" || body.exp + LEEWAY_S < now) return { ok: false, reason: "X-Authentik-Jwt has expired" };
  if (typeof body.iat === "number" && body.iat - LEEWAY_S > now) return { ok: false, reason: "X-Authentik-Jwt is issued in the future" };

  const user = typeof body.preferred_username === "string" && body.preferred_username ? body.preferred_username : null;
  if (!user) return { ok: false, reason: "X-Authentik-Jwt names no user" };
  const groups = Array.isArray(body.groups) ? body.groups.filter((g): g is string => typeof g === "string") : [];
  const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
  return { ok: true, claims: { user, groups, name: str(body.name), email: str(body.email) } };
}

// ── the keys, from Authentik ──────────────────────────────────────────

export type KeyFetch = (host: string) => Promise<GateKey | null>;

// Only the console's own routes have a key here.
export const isConsoleHost = (host: string): boolean => /^(console|status)\.[^/:\s]+$/i.test(host);

const RETRY_MS = 30_000; // a miss or a failed fetch is retried at most this often per host

export class GateKeys {
  private keys = new Map<string, GateKey>();
  private tried = new Map<string, number>();
  private stale = new Set<string>();

  constructor(private readonly fetchKey: KeyFetch, private readonly log: (m: string) => void = () => {}, private readonly clock: () => number = Date.now) {}

  get(host: string): GateKey | null {
    return this.keys.get(host.toLowerCase()) ?? null;
  }

  // The key for `host` in the cache: fetched when it is missing or marked stale,
  // at most every RETRY_MS. A stale key stays in use until a new one arrives.
  async ensure(host: string): Promise<void> {
    const h = host.toLowerCase();
    if (!isConsoleHost(h) || (this.keys.has(h) && !this.stale.has(h))) return;
    const last = this.tried.get(h);
    if (last !== undefined && this.clock() - last < RETRY_MS) return;
    this.tried.set(h, this.clock());
    this.stale.delete(h);
    try {
      const k = await this.fetchKey(h);
      if (k) this.keys.set(h, k);
      else this.log(`gate: no proxy provider for https://${h} in Authentik`);
    } catch (e) {
      this.log(`gate: could not read the key for ${h} from Authentik: ${(e as Error).message}`);
    }
  }

  // A token the cached key refused: the secret may have changed, so the key is
  // fetched again (at most every RETRY_MS). It is kept meanwhile — a forged
  // token must not lock the real users out.
  forget(host: string): void {
    const h = host.toLowerCase();
    if (this.keys.has(h)) this.stale.add(h);
  }
}

// The provider behind https://<host>: its client id and secret (the oauth2 view
// of the provider carries the secret, the proxy view the external host).
export function authentikKeyFetch(credentialFile: string): KeyFetch {
  return async (host: string): Promise<GateKey | null> => {
    let url = "";
    let token = "";
    for (const line of readFileSync(credentialFile, "utf8").split("\n")) {
      const i = line.indexOf("=");
      if (i < 0) continue;
      const k = line.slice(0, i).trim();
      if (k === "url") url = line.slice(i + 1).trim().replace(/\/+$/, "");
      if (k === "token") token = line.slice(i + 1).trim();
    }
    if (!url || !token) throw new Error(`${credentialFile} has no url= and token=`);
    const get = async (path: string): Promise<Record<string, unknown>> => {
      const r = await fetch(`${url}/api/v3/${path}`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
      if (!r.ok) throw new Error(`GET ${path}: HTTP ${r.status}`);
      return (await r.json()) as Record<string, unknown>;
    };
    const proxies = ((await get("providers/proxy/?page_size=500")).results ?? []) as Record<string, unknown>[];
    const want = `https://${host}`;
    const p = proxies.find((x) => String(x.external_host ?? "").replace(/\/+$/, "").toLowerCase() === want);
    if (!p) return null;
    const o = await get(`providers/oauth2/${String(p.pk)}/`);
    const clientId = String(o.client_id ?? "");
    const secret = String(o.client_secret ?? "");
    const slug = String(o.assigned_application_slug ?? p.assigned_application_slug ?? "");
    if (!clientId || !secret || !slug) throw new Error(`provider ${String(p.name)} has no client id, secret or application`);
    return { clientId, secret, slug };
  };
}
