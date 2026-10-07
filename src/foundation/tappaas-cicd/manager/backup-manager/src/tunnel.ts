// tunnel.ts — the WireGuard tunnel under one backup-buddy pull (#796).
//
// One pull = one tunnel, SERVED by the site whose data is pulled (the `remote`
// peer) and DIALED by the site that pulls (the `pull` peer). Each tunnel is a
// /30: <net>.1 is the serving side (its PBS is reachable there on tcp/8007),
// <net>.2 the dialing side. The serving side picks the /30 — from the site's
// `buddy` zone (zones.json, default 10.255.2.0/24) unless --tunnel-net pins it —
// and the dialing side takes it from them, so both ends agree.
//
// This module is pure: allocation and validation over the config directory.
// The live work (OPNsense instance, peer, rules) is backup/lib/pbs-tunnel.sh.

import { existsSync, readdirSync, readFileSync } from "fs";
import { join } from "path";

export type TunnelRole = "serve" | "dial";

export interface Tunnel {
  role: TunnelRole;
  net: string; // a.b.c.d/30
  listenPort?: number; // serve: the UDP port we listen on
  endpoint?: string; // dial: their public address host:port
  peerKey?: string; // the other side's WireGuard public key
  mtu?: number;
}

export const DEFAULT_POOL = "10.255.2.0/24";
export const DEFAULT_LISTEN_PORT = 51830; // 51820 = satellite infra, 51821 = admin VPN

export function isTunnelRole(v: string): v is TunnelRole {
  return v === "serve" || v === "dial";
}

// ── CIDR arithmetic ────────────────────────────────────────────────────
export function parseCidr(s: string): { base: number; len: number } | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/.exec(s.trim());
  if (!m) return null;
  const o = m.slice(1, 5).map(Number);
  const len = Number(m[5]);
  if (o.some((x) => x > 255) || len > 32) return null;
  const ip = ((o[0] << 24) >>> 0) + (o[1] << 16) + (o[2] << 8) + o[3];
  const mask = len === 0 ? 0 : (0xffffffff << (32 - len)) >>> 0;
  return { base: (ip & mask) >>> 0, len };
}

export function intToIp(n: number): string {
  return [24, 16, 8, 0].map((s) => (n >>> s) & 255).join(".");
}

function range(c: { base: number; len: number }): [number, number] {
  return [c.base, c.base + 2 ** (32 - c.len) - 1];
}

export function overlaps(a: string, b: string): boolean {
  const ca = parseCidr(a);
  const cb = parseCidr(b);
  if (!ca || !cb) return false;
  const [a0, a1] = range(ca);
  const [b0, b1] = range(cb);
  return a0 <= b1 && b0 <= a1;
}

/** Why <net> is not a usable tunnel /30, or null when it is. */
export function slash30Error(net: string): string | null {
  const m = /^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$/.exec(net.trim());
  const c = parseCidr(net);
  if (!m || !c) return `'${net}' is not an IPv4 CIDR`;
  if (c.len !== 30) return `a buddy tunnel is a /30, not /${c.len} ('${net}')`;
  if (intToIp(c.base) !== m[1]) return `'${net}' is not on a /30 boundary (did you mean ${intToIp(c.base)}/30?)`;
  return null;
}

/** <net>.1 (serving side) and <net>.2 (dialing side). */
export function tunnelHosts(net: string): { serve: string; dial: string } {
  const c = parseCidr(net);
  if (!c) throw new Error(`not a CIDR: ${net}`);
  return { serve: intToIp(c.base + 1), dial: intToIp(c.base + 2) };
}

// ── what the site already uses ─────────────────────────────────────────
function readObj(file: string): Record<string, unknown> | null {
  try {
    const j = JSON.parse(readFileSync(file, "utf8")) as unknown;
    return j && typeof j === "object" && !Array.isArray(j) ? (j as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** The `buddy` zone's range — the pool serve tunnels are carved from. */
export function buddyPool(configDir: string): string {
  const z = readObj(join(configDir, "zones.json"));
  const b = z?.buddy as Record<string, unknown> | undefined;
  const ip = typeof b?.ip === "string" ? b.ip : "";
  return parseCidr(ip) ? ip : DEFAULT_POOL;
}

/** Every other zone's range: a tunnel /30 must not sit inside any of them. */
export function zoneNets(configDir: string): Array<{ zone: string; ip: string }> {
  const z = readObj(join(configDir, "zones.json")) ?? {};
  const out: Array<{ zone: string; ip: string }> = [];
  for (const [name, v] of Object.entries(z)) {
    if (name.startsWith("_") || name === "buddy" || !v || typeof v !== "object") continue;
    const ip = (v as Record<string, unknown>).ip;
    if (typeof ip === "string" && parseCidr(ip)) out.push({ zone: name, ip });
  }
  return out;
}

export function asTunnel(v: unknown): Tunnel | null {
  if (!v || typeof v !== "object") return null;
  const t = v as Record<string, unknown>;
  if (typeof t.role !== "string" || !isTunnelRole(t.role) || typeof t.net !== "string") return null;
  const out: Tunnel = { role: t.role, net: t.net };
  if (typeof t.listenPort === "number") out.listenPort = t.listenPort;
  if (typeof t.endpoint === "string" && t.endpoint !== "") out.endpoint = t.endpoint;
  if (typeof t.peerKey === "string" && t.peerKey !== "") out.peerKey = t.peerKey;
  if (typeof t.mtu === "number") out.mtu = t.mtu;
  return out;
}

export interface TunnelUse {
  file: string; // config basename, e.g. remote-anna.json
  tunnel: Tunnel;
}

/** The tunnels the peer configs in <configDir> declare (pull- and remote- files). */
export function tunnelsInUse(configDir: string): TunnelUse[] {
  if (!existsSync(configDir)) return [];
  const out: TunnelUse[] = [];
  for (const f of readdirSync(configDir).sort()) {
    if (!f.endsWith(".json") || !(f.startsWith("pull-") || f.startsWith("remote-"))) continue;
    const t = asTunnel(readObj(join(configDir, f))?.tunnel);
    if (t) out.push({ file: f, tunnel: t });
  }
  return out;
}

// ── allocation ─────────────────────────────────────────────────────────
/** The first /30 of <pool> overlapping none of <used>, or null when full. */
export function allocateNet(pool: string, used: string[]): string | null {
  const p = parseCidr(pool);
  if (!p || p.len > 30) return null;
  const [lo, hi] = range(p);
  for (let n = lo; n + 3 <= hi; n += 4) {
    const cand = `${intToIp(n)}/30`;
    if (!used.some((u) => overlaps(u, cand))) return cand;
  }
  return null;
}

/** The first listen port from <start> no serve tunnel holds. */
export function allocatePort(used: number[], start = DEFAULT_LISTEN_PORT): number {
  let p = start;
  while (used.includes(p)) p++;
  return p;
}

/** The next free /30 and listen port for a new serve tunnel (<exceptFile> = the one being rewritten). */
export function nextServe(configDir: string, exceptFile?: string): { net: string | null; port: number } {
  const uses = tunnelsInUse(configDir).filter((u) => u.file !== exceptFile);
  const net = allocateNet(buddyPool(configDir), [
    ...uses.map((u) => u.tunnel.net),
    ...zoneNets(configDir).map((z) => z.ip),
  ]);
  const port = allocatePort(uses.flatMap((u) => (u.tunnel.listenPort ? [u.tunnel.listenPort] : [])));
  return { net, port };
}

// ── validation (backup-manager validate) ───────────────────────────────
/** Errors a tunnel declaration would hit at onboarding, found offline. */
export function tunnelErrors(configDir: string): string[] {
  const errs: string[] = [];
  const uses = tunnelsInUse(configDir);
  const zones = zoneNets(configDir);
  for (const u of uses) {
    const t = u.tunnel;
    const what = `${u.file} tunnel`;
    const kind = u.file.startsWith("pull-") ? "pull" : "remote";
    if (kind === "pull" && t.role !== "dial") errs.push(`${what}: a pull dials its tunnel (role 'dial', not '${t.role}')`);
    if (kind === "remote" && t.role !== "serve") errs.push(`${what}: a remote serves its tunnel (role 'serve', not '${t.role}')`);
    const bad = slash30Error(t.net);
    if (bad) {
      errs.push(`${what}: ${bad}`);
      continue;
    }
    if (t.role === "serve" && !t.listenPort) errs.push(`${what}: serve needs a listenPort`);
    if (t.role === "dial" && !(t.endpoint && /:\d+$/.test(t.endpoint))) {
      errs.push(`${what}: dial needs an endpoint host:port (their public address)`);
    }
    if (t.role === "dial" && !t.peerKey) errs.push(`${what}: dial needs the serving side's peerKey`);
    for (const z of zones) {
      if (overlaps(t.net, z.ip)) errs.push(`${what}: ${t.net} overlaps zone '${z.zone}' (${z.ip})`);
    }
  }
  for (let i = 0; i < uses.length; i++) {
    for (let j = i + 1; j < uses.length; j++) {
      const a = uses[i];
      const b = uses[j];
      if (overlaps(a.tunnel.net, b.tunnel.net)) {
        errs.push(`tunnel ${a.tunnel.net} is used by both ${a.file} and ${b.file} — give one --tunnel-net`);
      }
      if (a.tunnel.listenPort && a.tunnel.listenPort === b.tunnel.listenPort) {
        errs.push(`listen port ${a.tunnel.listenPort} is used by both ${a.file} and ${b.file}`);
      }
    }
  }
  return errs;
}
