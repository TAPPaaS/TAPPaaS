// access.ts — who may talk to the console, and as whom (ADR-034 D2, D3, D10).
//
//   - The backend accepts connections only from the firewall (Caddy and the
//     Authentik gate run there) and from loopback. The `X-Authentik-*` headers
//     are believed only from the firewall: anything else on mgmt could forge them.
//   - From the firewall a request must carry X-Authentik-Username; one that does
//     not came through a route without the gate and is refused.
//   - The role comes from the Authentik groups (Installer, Admin, users); the
//     `status.<domain>` route caps it at read whatever the groups say.
//   - Before identity exists (D10) there is no gate. While config/identity.json is
//     absent and the setup token file exists, the console also accepts the mgmt
//     and admin-VPN networks — and every request from them must present the token.
//     Once identity.json exists the token is refused even if its file remains.
//
// P1 has no write endpoints; the role is reported (/api/v1/me) and enforced
// from P2 on.

import { existsSync, readFileSync } from "fs";
import { createHash, timingSafeEqual } from "crypto";

export type Role = "installer" | "admin" | "read";

export interface AccessConfig {
  firewall: string[]; // addresses whose X-Authentik-* headers are believed
  allow: string[]; // further peers (loopback by default; a dev port-forward arrives as loopback)
  setupAllow: string[]; // networks accepted, with the token, before identity exists
  tokenFile: string;
  identityFile: string; // config/identity.json: identity is installed once it exists
  trustLocalHeaders: boolean; // dev only: believe X-Authentik-* from `allow` peers too
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

export type Decision = { ok: true; me: Me } | { ok: false; status: number; reason: string };

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
    if (k === SETUP_COOKIE) return decodeURIComponent(v.join("="));
  }
  return query;
}

// ── the role table (D3) ───────────────────────────────────────────────

export function roleOf(groups: string[]): Role | null {
  const g = new Set(groups.map((x) => x.toLowerCase()));
  if (g.has("installer")) return "installer";
  if (g.has("admin")) return "admin";
  if (g.has("users")) return "read";
  return null;
}

export function routeOf(host: string | undefined): "console" | "status" {
  return /^status\./i.test(host ?? "") ? "status" : "console";
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
  const route = routeOf(header(headers, "host"));
  const cap = (r: Role): Role => (route === "status" ? "read" : r);
  const fromFirewall = anyMatch(peer, cfg.firewall);
  const local = anyMatch(peer, cfg.allow);

  if (fromFirewall || (local && cfg.trustLocalHeaders && header(headers, "x-authentik-username"))) {
    const user = header(headers, "x-authentik-username");
    if (!user) return { ok: false, status: 401, reason: "no X-Authentik-Username: this route is not behind the identity gate" };
    const groups = splitGroups(header(headers, "x-authentik-groups"));
    const role = roleOf(groups);
    if (!role) return { ok: false, status: 403, reason: `${user} is in none of Installer, Admin, users` };
    return {
      ok: true,
      me: {
        user,
        name: header(headers, "x-authentik-name") ?? null,
        email: header(headers, "x-authentik-email") ?? null,
        groups,
        role: cap(role),
        via: "gate",
        route,
      },
    };
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
    return { ok: false, status: 401, reason: "setup token required (printed by the install summary)" };
  }
  return { ok: false, status: 403, reason: `connections from ${normalizeAddr(peer)} are not accepted` };
}
