// serves.ts — resolution of the ADR-014 D2 `serves` link, and the rendering of
// the EFFECTIVE zones document the planes actually consume.
//
// ── The problem (#424) ────────────────────────────────────────────────
// A client zone reaches its services, and an IoT zone is reached by them.
// Writing that as a LITERAL service-zone name does not survive install: `init`
// renames `srv` -> `<defaultEnvironment>`, and every literal reference is
// stranded (on the reference system: iotCams.pinhole-allowed-from still named
// `srvHome` long after it went Inactive). `serves` names the ENVIRONMENT
// instead, and the edge is derived from that environment's CURRENT zone on
// every render — so a rename can never strand it.
//
// ── Authored vs. effective (decision D-C4) ────────────────────────────
// Derived edges are NEVER written back into zones.json. If they were, the 3-way
// merge would see them as operator edits and pin them, so clearing a `serves`
// link would leave its derived edges behind forever. zones.json stays purely
// AUTHORED; this module renders `zones.effective.json` beside it, and the
// consumers (zone-manager, rules_manager, the Caddy access lists) read that.
// It is generated, never hand-edited, and regenerated on every zones.json write.
//
// ── Direction depends on the zone's role; the edge is always LOCAL ────
// ADR-014 D2 describes the client direction and leaves IoT implicit, and its
// prose ("...and add this zone to that service zone's pinhole-allowed-from")
// implies a SYMMETRIC pair. That is wrong, and running it against the reference
// system proved it: a symmetric derivation invented edges the authored document
// never had — `<env>.access-to += iot` (a brand-new zone-wide pass rule) and
// `<env>.pinhole-allowed-from += home`. Under F2 this branch must re-cut no
// firewall rule, so the derivation has to reproduce the literal it replaces,
// not a canonical pair.
//
// THE RULE: `serves` only ever modifies the zone that DECLARES it.
//
//   Client/Guest zone Z serves environment E (service zone S):
//     the CLIENT consumes the service  ->  Z.access-to += S
//   IoT zone Z serves environment E (service zone S):
//     the SERVICE drives the devices   ->  Z.pinhole-allowed-from += S
//
// Each reproduces exactly the literal the shipped template wired by hand
// (home.access-to: [srvHome]; iotLocal/iotCams.pinhole-allowed-from: [srvHome]),
// so the back-fill is authored-only and the effective graph is byte-identical.
//
// Two edges are deliberately NOT derived:
//   - S.pinhole-allowed-from += Z (client side). Not needed while the client
//     reaches S zone-wide; it is precisely what the deferred F2 conversion adds
//     when that zone-wide edge becomes per-module pinholes. Deriving it now
//     would pre-empt a decision this branch defers.
//   - S.access-to += Z (non-isolated IoT). The service->IoT zone-wide edge is
//     AUTHORED on the service zone and is already rename-safe: the renamed thing
//     is the service zone's own KEY, while the IoT names it lists are stable.
//     #424 is about references TO the renamed zone, which is the direction
//     `serves` handles.
//
// Side benefit: R2 becomes structural rather than conditional — the IoT branch
// touches only `pinhole-allowed-from`, so an isolated zone can never gain an
// inbound `access-to` by any path.

import { existsSync, readdirSync, readFileSync } from "fs";
import { dirname, join } from "path";
import { Zone, ZonesDoc } from "./types";
import { isDocKey, loadZones } from "./zones";
import { writeJsonAtomic } from "../../../lib/ts/src/config-io";

// ── F2 (phased enforcement) ───────────────────────────────────────────
// Under the ADR-014 D5 lattice a client reaching its service is an UPWARD edge,
// so the strictly-correct derivation is the pinhole alone. Deriving the
// zone-wide `access-to` as well is what preserves TODAY's reachability — and
// this branch's governing invariant is that it re-cuts no firewall rule.
//
// The consequence is deliberate and expected: a `serves`-linked client zone
// trips I1 as a WARNING (two edges on the reference system). Those warnings are
// the worklist for the deferred conversion issue. When per-module pinholes
// replace the zone-wide reach, flip this to false and the warnings disappear.
export const SERVES_DERIVES_ZONE_WIDE_CLIENT_ACCESS = true;

// Zone types that may carry `serves`. A Service/Management/Overlay/WAN zone
// naming an environment is a configuration mistake, not a link.
const SERVES_ALLOWED_TYPES: ReadonlySet<string> = new Set(["Client", "IoT", "Guest"]);

export interface ServesEdge {
  zone: string; // the zone carrying `serves`
  environment: string; // the environment it names
  serviceZone: string; // that environment's network.zone
  // What was added, for the reconcile/report line.
  added: string[];
}

export interface ResolveResult {
  edges: ServesEdge[];
  // Hard problems: an unknown environment, an environment with no zone, a
  // service zone missing from zones.json, or `serves` on a zone type that may
  // not carry it. Reported by validate; fatal to reconcile.
  errors: string[];
}

// Read <configDir>/environments/<env>.json and return its .network.zone.
// Returns undefined when the file is absent/unreadable or names no zone; the
// caller turns that into a specific error message.
export function environmentZone(configDir: string, env: string): string | undefined {
  const f = join(configDir, "environments", `${env}.json`);
  if (!existsSync(f)) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(f, "utf8"));
  } catch {
    return undefined;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
  const net = (parsed as Record<string, unknown>)["network"];
  if (net === null || typeof net !== "object" || Array.isArray(net)) return undefined;
  const zone = (net as Record<string, unknown>)["zone"];
  return typeof zone === "string" && zone.length > 0 ? zone : undefined;
}

// Does <configDir>/environments/ exist at all? A pre-ADR-007 system has none;
// `serves` cannot resolve there, and that is not an error unless a zone
// actually carries the field.
export function hasEnvironments(configDir: string): boolean {
  return existsSync(join(configDir, "environments"));
}

// Append `v` to the array field `f` of raw zone `z`, creating it if absent and
// never duplicating. Returns true when it actually changed something.
function addRef(z: Record<string, unknown>, f: string, v: string): boolean {
  const cur = Array.isArray(z[f]) ? (z[f] as unknown[]).slice() : [];
  if (cur.includes(v)) return false;
  cur.push(v);
  z[f] = cur;
  return true;
}

// Resolve every `serves` link in `doc` INTO the mutable raw document `out`
// (which the caller has already deep-copied from the authored doc). Pure apart
// from reading the environment files under configDir.
export function resolveServes(
  doc: ZonesDoc,
  out: Record<string, unknown>,
  configDir: string,
): ResolveResult {
  const edges: ServesEdge[] = [];
  const errors: string[] = [];

  for (const [name, z] of doc.zones) {
    const serves = z.serves;
    if (typeof serves !== "string" || serves.length === 0) continue;

    const type = typeof z.type === "string" ? z.type : "";
    if (!SERVES_ALLOWED_TYPES.has(type)) {
      errors.push(
        `zone '${name}' is type ${type || "(unset)"} and must not carry 'serves' ` +
          `(only Client, IoT and Guest zones consume an environment). ` +
          `Clear it with \`network-manager bind ${name} --unbind\`.`,
      );
      continue;
    }

    const svc = environmentZone(configDir, serves);
    if (svc === undefined) {
      errors.push(
        `zone '${name}' serves environment '${serves}', which has no readable ` +
          `${join(configDir, "environments", `${serves}.json`)} with a '.network.zone'. ` +
          `Create the environment, or re-bind the zone.`,
      );
      continue;
    }
    if (!doc.zones.has(svc)) {
      errors.push(
        `zone '${name}' serves environment '${serves}', whose network.zone '${svc}' ` +
          `is not defined in zones.json.`,
      );
      continue;
    }

    const self = out[name] as Record<string, unknown> | undefined;
    if (!self) continue;

    // The edge is always LOCAL to the declaring zone — see the header.
    const added: string[] = [];
    if (type === "IoT") {
      // The environment's modules drive the devices: record who may pinhole in.
      // Never touches access-to, so R2 holds structurally, isolated or not.
      if (addRef(self, "pinhole-allowed-from", svc)) {
        added.push(`${name}.pinhole-allowed-from += ${svc}`);
      }
    } else if (SERVES_DERIVES_ZONE_WIDE_CLIENT_ACCESS) {
      // Client / Guest: the client consumes the service, zone-wide (F2).
      if (addRef(self, "access-to", svc)) added.push(`${name}.access-to += ${svc}`);
    }

    edges.push({ zone: name, environment: serves, serviceZone: svc, added });
  }

  return { edges, errors };
}

export interface EffectiveDoc {
  raw: Record<string, unknown>;
  edges: ServesEdge[];
  errors: string[];
}

// Render the effective document: a deep-ish copy of the authored raw doc with
// every `serves` link resolved into it. Doc blocks are carried through.
export function renderEffective(doc: ZonesDoc, configDir: string): EffectiveDoc {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(doc.raw)) {
    if (isDocKey(k) || v === null || typeof v !== "object" || Array.isArray(v)) {
      out[k] = v;
      continue;
    }
    const copy: Record<string, unknown> = {};
    for (const [f, fv] of Object.entries(v as Record<string, unknown>)) {
      copy[f] = Array.isArray(fv) ? [...fv] : fv;
    }
    out[k] = copy;
  }
  const r = resolveServes(doc, out, configDir);
  return { raw: out, edges: r.edges, errors: r.errors };
}

// The effective file's path: beside the zones.json it is derived from, so a
// temp//test zones file renders its own effective copy and never touches the
// live one.
export function effectiveFileFor(zonesFile: string): string {
  return join(dirname(zonesFile), "zones.effective.json");
}

// A zone's `serves` value, or undefined.
export function zoneServes(z: Zone | undefined): string | undefined {
  return typeof z?.serves === "string" && z.serves.length > 0 ? z.serves : undefined;
}

// Load the authored zones.json, render its effective form, and write it beside
// the source. Best-effort by contract: it returns the errors rather than
// throwing, so a zone add cannot fail merely because an environment file is
// missing. `reconcile` and `validate` are what turn those errors fatal.
//
// The config root is taken from the zones file's own directory, so a temp/test
// zones.json renders against whatever environments/ sits next to it (usually
// none — which correctly yields no derived edges).
export function refreshEffective(zonesFile: string): EffectiveDoc {
  const configDir = dirname(zonesFile);
  const doc = loadZones(zonesFile);
  const eff = renderEffective(doc, configDir);
  writeJsonAtomic(effectiveFileFor(zonesFile), eff.raw);
  return eff;
}

// ── One-time migration back-fill (ADR-014 D2) ─────────────────────────
// Convert a LITERAL service-zone reference into a symbolic `serves` link, for
// every Client/IoT/Guest zone whose literal names a zone that is some
// environment's `network.zone`. The literal is then dropped, because the render
// re-derives exactly the same edge.
//
// THE INVARIANT THIS MUST HOLD: the AUTHORED document changes, the EFFECTIVE
// document does not. That is what makes the migration safe to run on a live
// system — the firewall sees the same graph before and after.
//
// Runs inside `merge` (resolving ADR-014's open question about where it goes):
// merge is already the rename-aware step, it runs on every update-tappaas, and
// it holds the environment context. Idempotent — a converged install re-runs it
// as a no-op.
//
// A literal that names a NON-environment zone (e.g. a retired `srvHome`) is
// deliberately left alone: it is not a `serves` link, it is stale, and pruning
// it is `retire`'s job, not the merge's.

export interface BackfillChange {
  zone: string;
  environment: string;
  serviceZone: string;
  droppedFrom: string; // the field the literal was removed from
}

export interface BackfillResult {
  changes: BackfillChange[];
}

// environment name -> its network.zone, for every environment on this system.
export function environmentZoneMap(configDir: string): Map<string, string> {
  const m = new Map<string, string>();
  const dir = join(configDir, "environments");
  if (!existsSync(dir)) return m;
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return m;
  }
  for (const f of entries.sort()) {
    if (!f.endsWith(".json")) continue;
    const env = f.slice(0, -5);
    const z = environmentZone(configDir, env);
    if (z !== undefined) m.set(env, z);
  }
  return m;
}

function dropRef(z: Record<string, unknown>, f: string, v: string): boolean {
  if (!Array.isArray(z[f])) return false;
  const cur = z[f] as unknown[];
  const next = cur.filter((x) => x !== v);
  if (next.length === cur.length) return false;
  z[f] = next;
  return true;
}

// Back-fill `serves` in the raw document `raw` (mutated in place).
export function backfillServes(raw: Record<string, unknown>, configDir: string): BackfillResult {
  const changes: BackfillChange[] = [];
  const envByZone = new Map<string, string>();
  for (const [env, zone] of environmentZoneMap(configDir)) {
    // First environment wins if two share a service zone — deterministic
    // because environmentZoneMap iterates the directory sorted.
    if (!envByZone.has(zone)) envByZone.set(zone, env);
  }
  if (envByZone.size === 0) return { changes };

  for (const [name, v] of Object.entries(raw)) {
    if (isDocKey(name) || v === null || typeof v !== "object" || Array.isArray(v)) continue;
    const z = v as Record<string, unknown>;
    const type = typeof z["type"] === "string" ? (z["type"] as string) : "";
    if (!SERVES_ALLOWED_TYPES.has(type)) continue;

    // The field whose literal encodes the link, per the role asymmetry above.
    const field = type === "IoT" ? "pinhole-allowed-from" : "access-to";
    const refs = Array.isArray(z[field]) ? (z[field] as unknown[]) : [];

    const already = typeof z["serves"] === "string" && (z["serves"] as string).length > 0;
    // A zone the operator already bound: still prune the now-derived literal so
    // a re-run converges, but do not re-point the link.
    const targetEnv = already
      ? (z["serves"] as string)
      : (() => {
          for (const r of refs) {
            if (typeof r === "string" && envByZone.has(r)) return envByZone.get(r) as string;
          }
          return undefined;
        })();
    if (targetEnv === undefined) continue;

    const svc = environmentZone(configDir, targetEnv);
    if (svc === undefined) continue;

    if (!already) z["serves"] = targetEnv;

    // Drop ONLY the local literal the render now derives. The service zone's own
    // entries are authored state that no `serves` link reproduces (see header) —
    // pruning them here would silently narrow the graph.
    const dropped = dropRef(z, field, svc);

    if (!already || dropped) {
      changes.push({ zone: name, environment: targetEnv, serviceZone: svc, droppedFrom: field });
    }
  }
  return { changes };
}

export { SERVES_ALLOWED_TYPES };
