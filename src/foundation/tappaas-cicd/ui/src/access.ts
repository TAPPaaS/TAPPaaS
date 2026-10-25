// access.ts — who may talk to the console, and as whom (ADR-034 D2, D3, D10).
//
//   - The backend accepts connections only from the firewall (Caddy and the
//     Authentik gate run there) and from loopback. The firewall's address is not
//     proof on its own (a host on mgmt can take it): from it a request must
//     carry the gate's X-Authentik-Jwt, verified against the route's provider
//     (gate.ts), and the user and groups are the token's. One without the gate's
//     headers came through a route without the gate and is refused.
//   - The role comes from the Authentik groups (installer, admin, users); the
//     `status.<domain>` route caps it at read whatever the groups say.
//   - Before identity exists (D10) there is no gate. While config/identity.json is
//     absent and the setup token file exists, the console also accepts the mgmt
//     and admin-VPN networks — and every request from them must present the token.
//     Once identity.json exists the token is refused even if its file remains.
//
//   - Reads are open to every accepted caller; a loopback peer without the
//     gate's headers reads as `read`. A write (a job, P2) is never loopback's:
//     it needs the gate (Admin or Installer) or, while setup is open, the token
//     (mayWrite below), and the status route never writes.

import { existsSync, readFileSync } from "fs";
import { createHash, timingSafeEqual } from "crypto";
import { GateKeys, verifyGateToken } from "./gate";

export type Role = "installer" | "admin" | "read";

export interface AccessConfig {
  firewall: string[]; // addresses whose X-Authentik-* headers are believed
  allow: string[]; // further peers (loopback by default; a dev port-forward arrives as loopback)
  setupAllow: string[]; // networks accepted, with the token, before identity exists
  tokenFile: string;
  identityFile: string; // config/identity.json: identity is installed once it exists
  trustLocalHeaders: boolean; // dev only: believe X-Authentik-* from `allow` peers too
  gate?: GateKeys; // the routes' provider keys (gate.ts); without it the firewall is refused
  now?: () => number; // seconds; tests set it
}

export interface Me {
  user: string | null;
  name: string | null;
  email: string | null;
  groups: string[];
  role: Role;
  via: "gate" | "local" | "setup-token";
  route: "console" | "status";
}

// `forget`: the cached gate key for that host refused the token — fetch it again soon.
export type Decision = { ok: true; me: Me } | { ok: false; status: number; reason: string; forget?: string };

// ── addresses ─────────────────────────────────────────────────────────

export function normalizeAddr(a: string | undefined): string {
  if (!a) return "";
  return a.startsWith("::ffff:") ? a.slice(7) : a;
}

function ipv4ToInt(a: string): number | null {
  const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(a);
  if (!m) return null;
  const p = m.slice(1).map(Number);
  if (p.some((x) => x > 255)) return null;
  return ((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3];
}

// An address matches an entry that is the address itself or an IPv4 network a.b.c.d/n.
export function addrMatches(addr: string, entry: string): boolean {
  const a = normalizeAddr(addr);
  if (!entry.includes("/")) return a === normalizeAddr(entry);
  const [net, bitsS] = entry.split("/");
  const bits = Number(bitsS);
  const ai = ipv4ToInt(a);
  const ni = ipv4ToInt(net);
  if (ai === null || ni === null || !Number.isInteger(bits) || bits < 0 || bits > 32) return false;
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return ((ai & mask) >>> 0) === ((ni & mask) >>> 0);
}

const anyMatch = (addr: string, list: string[]): boolean => list.some((e) => addrMatches(addr, e));

// ── the setup token (D10) ─────────────────────────────────────────────

export interface SetupState {
  active: boolean; // the token is accepted now
  identityInstalled: boolean;
  tokenPresent: boolean;
}

export function setupState(cfg: AccessConfig): SetupState {
  const identityInstalled = existsSync(cfg.identityFile);
  const tokenPresent = existsSync(cfg.tokenFile) && readToken(cfg.tokenFile) !== "";
  return { active: tokenPresent && !identityInstalled, identityInstalled, tokenPresent };
}

function readToken(file: string): string {
  try {
    return readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

// Constant-time: compare digests, so neither the length nor a prefix leaks.
export function tokenMatches(presented: string | null, cfg: AccessConfig): boolean {
  if (!presented) return false;
  const want = readToken(cfg.tokenFile);
  if (!want) return false;
  const h = (s: string): NodeBuffer => Buffer.from(createHash("sha256").update(s).digest("hex"), "utf8");
  return timingSafeEqual(h(presented.trim()), h(want));
}

// The token as a request presents it: a bearer header, the setup cookie, or
// ?token= on the first page load (the server turns that into the cookie).
export const SETUP_COOKIE = "tappaas_setup";
export function presentedToken(headers: Record<string, string | string[] | undefined>, query: string | null): string | null {
  const auth = header(headers, "authorization");
  if (auth && /^Bearer\s+/i.test(auth)) return auth.replace(/^Bearer\s+/i, "").trim();
  const cookie = header(headers, "cookie") ?? "";
  for (const part of cookie.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === SETUP_COOKIE) {
      // A malformed escape is a wrong token, not an error: it gets a 401.
      try {
        return decodeURIComponent(v.join("="));
      } catch {
        return v.join("=");
      }
    }
  }
  return query;
}

// ── the role table (D3) ───────────────────────────────────────────────

// The groups the gate sends, by their TAPPaaS names (identity's bootstrap and
// update create them, identity/USERS.md): `installer` is a group of its own; the
// Admin is the `admin` role, which Authentik carries as a group named `admin`;
// `users` is the team group everyone is in. Compared without case.
export const ROLE_GROUPS: { group: string; role: Role }[] = [
  { group: "installer", role: "installer" },
  { group: "admin", role: "admin" },
  { group: "users", role: "read" },
];

export function roleOf(groups: string[]): Role | null {
  const g = new Set(groups.map((x) => x.toLowerCase()));
  return ROLE_GROUPS.find((r) => g.has(r.group))?.role ?? null;
}

export function routeOf(host: string | undefined): "console" | "status" {
  return /^status\./i.test(host ?? "") ? "status" : "console";
}

// The host the client asked for. Caddy rewrites Host to the upstream's own name
// (tappaas-cicd.mgmt.internal:9097) unless the route sets proxyPreserveHost,
// and carries the client's Host in X-Forwarded-Host — which any other peer
// could send too, so it is read only from a peer whose headers are believed
// (the firewall; loopback under --trust-local-headers). Host is the fallback.
export function routeHost(headers: Record<string, string | string[] | undefined>, believeForwarded: boolean): string | undefined {
  const fwd = believeForwarded ? header(headers, "x-forwarded-host") : undefined;
  return fwd && fwd.trim() ? fwd.split(",")[0].trim() : header(headers, "host");
}

function header(h: Record<string, string | string[] | undefined>, name: string): string | undefined {
  const v = h[name];
  return Array.isArray(v) ? v[0] : v;
}

// Authentik sends the groups pipe-separated.
export function splitGroups(v: string | undefined): string[] {
  return (v ?? "").split("|").map((s) => s.trim()).filter((s) => s.length > 0);
}

// ── the decisions ─────────────────────────────────────────────────────

// Whether a connection from `peer` is accepted at all (checked on connect).
export function peerAllowed(peer: string, cfg: AccessConfig, setup: SetupState): boolean {
  if (anyMatch(peer, cfg.firewall) || anyMatch(peer, cfg.allow)) return true;
  return setup.active && anyMatch(peer, cfg.setupAllow);
}

export function decide(
  peer: string,
  headers: Record<string, string | string[] | undefined>,
  queryToken: string | null,
  cfg: AccessConfig,
  setup: SetupState,
): Decision {
  const fromFirewall = anyMatch(peer, cfg.firewall);
  const local = anyMatch(peer, cfg.allow);
  const route = routeOf(routeHost(headers, fromFirewall || (local && cfg.trustLocalHeaders)));
  const cap = (r: Role): Role => (route === "status" ? "read" : r);

  if (fromFirewall || (local && cfg.trustLocalHeaders && header(headers, "x-authentik-username"))) {
    const hdrUser = header(headers, "x-authentik-username");
    const jwt = header(headers, "x-authentik-jwt");
    if (!hdrUser && !jwt) return { ok: false, status: 401, reason: "no X-Authentik-Username: this route is not behind the identity gate" };
    let user = hdrUser ?? "";
    let groups = splitGroups(header(headers, "x-authentik-groups"));
    let name = header(headers, "x-authentik-name") ?? null;
    let email = header(headers, "x-authentik-email") ?? null;
    if (fromFirewall) {
      // The headers say who; the token proves it. Only the token's word counts.
      const host = (routeHost(headers, true) ?? "").toLowerCase();
      const key = cfg.gate?.get(host) ?? null;
      if (!key) return { ok: false, status: 503, reason: `the identity gate's key for ${host || "this route"} is not known (Authentik unreachable, or no proxy provider for it): try again shortly` };
      const v = verifyGateToken(jwt, key, (cfg.now ?? (() => Date.now() / 1000))());
      if (!v.ok) return { ok: false, status: 401, reason: v.reason, forget: v.reason.includes("signature") ? host : undefined };
      if (hdrUser && hdrUser !== v.claims.user) return { ok: false, status: 401, reason: "X-Authentik-Username is not the token's user" };
      ({ user, groups, name, email } = v.claims);
    }
    const role = roleOf(groups);
    if (!role) return { ok: false, status: 403, reason: `${user} is in none of the groups installer, admin, users` };
    return { ok: true, me: { user, name, email, groups, role: cap(role), via: "gate", route } };
  }

  const token = presentedToken(headers, queryToken);
  if (token !== null) {
    // A token is only ever good before identity exists; afterwards it is a 401
    // even if the file is still there (T6).
    if (setup.active && tokenMatches(token, cfg)) {
      return { ok: true, me: { user: "setup", name: "Setup", email: null, groups: [], role: cap("installer"), via: "setup-token", route } };
    }
    if (!local) return { ok: false, status: 401, reason: setup.active ? "wrong setup token" : "the setup token is no longer accepted: identity is installed" };
  }

  if (local) {
    return { ok: true, me: { user: null, name: null, email: null, groups: [], role: "read", via: "local", route } };
  }
  if (setup.active && anyMatch(peer, cfg.setupAllow)) {
    return { ok: false, status: 401, reason: "setup token required (~/config/console-setup-token on tappaas-cicd)" };
  }
  return { ok: false, status: 403, reason: `connections from ${normalizeAddr(peer)} are not accepted` };
}

// ── writes (ADR-034 D3, D4) ───────────────────────────────────────────

export type WriteDecision = { ok: true } | { ok: false; status: number; reason: string };

// Whether `me` may start a write: the identity must come from the gate (Admin
// or Installer) or be the setup token while setup is open; loopback without the
// gate's headers reads only. The status route never writes. A destructive verb
// needs the Installer role (the setup token acts as Installer only while active).
export function mayWrite(me: Me, setup: SetupState, destructive: boolean): WriteDecision {
  if (me.route === "status") return { ok: false, status: 403, reason: "the status route is read-only" };
  if (me.via === "local") return { ok: false, status: 403, reason: "a write needs the identity gate (Installer or Admin) or the setup token; loopback reads only" };
  if (me.via === "setup-token" && !setup.active) return { ok: false, status: 401, reason: "the setup token is no longer accepted: identity is installed" };
  if (me.role === "read") return { ok: false, status: 403, reason: `${me.user ?? "this caller"} may read only (a member of Admin or Installer operates)` };
  if (destructive && me.role !== "installer") return { ok: false, status: 403, reason: "a destructive verb needs the Installer role" };
  return { ok: true };
}
