// ── split-horizon target resolution (ADR-021 D5) ──────────────────────
//
// THE single place that answers "what address does a published name resolve to
// on the inside?". Before this existed the rule was transcribed into three
// writers — network:proxy's update-service.sh, acme-setup.sh, and
// environment-manager's clients.ts — which each derived it from a different
// zone and disagreed on a live site (#577). Every writer now calls
// `network-manager split-horizon-target <domain>` instead of re-deriving it.
//
// The rule itself is ADR-021 D2 and is deliberately trivial: the answer is the
// DMZ zone's gateway, for every caller, always. Authorization is not encoded in
// the address — Caddy's access list and the Authentik identity gate decide who
// may use a service, and the firewall's caddy-reach rule (D3) decides who can
// reach Caddy at all.
//
// The resolver also owns the R3 question — is this name published? — so that
// too is answered once. A name with no public DNS record cannot get an ACME
// certificate, so there is nothing for Caddy to serve and no split-horizon
// record to write. That is a supported configuration, not an error, and it must
// be reported as its own state rather than as a failed lookup.

import { spawnSync } from "child_process";
import type { Zone, ZonesDoc } from "./types";

export const DMZ_ZONE = "dmz";

export type SplitHorizonTarget =
  | { status: "ok"; ip: string; zone: string }
  // The name resolves nowhere public: no cert, no Caddy handler, no record.
  | { status: "unpublished"; domain: string; reason: string }
  // The site cannot express a split-horizon answer at all.
  | { status: "error"; reason: string };

// First host address of a CIDR — the zone's gateway, where OPNsense (and
// therefore os-caddy) listens. Mirrors zone_manager.py's `gateway_ip`.
export function gatewayIpOf(cidr: string | undefined): string | undefined {
  if (!cidr) return undefined;
  const [addr, bits] = cidr.split("/");
  if (!addr || !bits) return undefined;
  const octets = addr.split(".").map((o) => Number(o));
  if (octets.length !== 4 || octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)) {
    return undefined;
  }
  const prefix = Number(bits);
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) return undefined;
  const asInt = ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>> 0;
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  const network = (asInt & mask) >>> 0;
  const gw = (network + 1) >>> 0;
  return [(gw >>> 24) & 255, (gw >>> 16) & 255, (gw >>> 8) & 255, gw & 255].join(".");
}

// The pure core (ADR-021 Testing: "the resolver as a pure function"). Whether
// the name is published is an INPUT here, so the decision is testable without
// touching the network; the CLI supplies it from a public DNS lookup.
export function resolveSplitHorizonTarget(
  doc: ZonesDoc,
  domain: string,
  published: boolean,
): SplitHorizonTarget {
  if (!published) {
    return {
      status: "unpublished",
      domain,
      reason:
        `no public DNS record for '${domain}' — ACME cannot issue for a name ` +
        `that does not resolve publicly, so there is no certificate and nothing ` +
        `for Caddy to serve`,
    };
  }
  const dmz: Zone | undefined = doc.zones.get(DMZ_ZONE);
  if (!dmz) {
    return {
      status: "error",
      reason:
        `no '${DMZ_ZONE}' zone in zones.json — the split-horizon answer is the ` +
        `DMZ gateway (ADR-021 D2), so a site without one cannot publish a name ` +
        `internally at all`,
    };
  }
  const ip = gatewayIpOf(dmz.ip);
  if (!ip) {
    return {
      status: "error",
      reason: `zone '${DMZ_ZONE}' has no usable 'ip' (got ${JSON.stringify(dmz.ip)})`,
    };
  }
  return { status: "ok", ip, zone: DMZ_ZONE };
}

// ── the I/O half, kept separate so the rule above stays pure ──────────
// Deliberately asks a PUBLIC resolver, never the site's Unbound: Unbound holds
// the split-horizon override itself, so asking it whether a name is published
// would answer "yes" for every name we already wrote a record for — the test
// would confirm its own past output.
export const PUBLIC_RESOLVERS = ["1.1.1.1", "9.9.9.9"];

// Synchronous form, for the CLI. `run()` is sync by design (every other verb
// is), so rather than make the whole entry point async for one DNS lookup we
// re-enter node for it. Same resolver, same servers, same answer — just
// blocking. A non-zero exit (including a crash or a timeout kill) reads as
// "not publicly resolvable", which is the safe direction: it degrades to
// UNPUBLISHED and skips publishing rather than writing a record for a name
// that cannot hold a certificate.
export function isPubliclyResolvableSync(
  domain: string,
  timeoutMs = 5000,
  servers: string[] = PUBLIC_RESOLVERS,
): boolean {
  const script =
    "const {Resolver}=require('dns');" +
    `const r=new Resolver({timeout:${timeoutMs},tries:1});` +
    `r.setServers(${JSON.stringify(servers)});` +
    `r.resolve4(${JSON.stringify(domain)},(e,a)=>{` +
    "process.exit(!e&&Array.isArray(a)&&a.length>0?0:1)});";
  const r = spawnSync(process.execPath, ["-e", script], { stdio: "pipe" });
  return r.status === 0;
}
