// serves.ts — resolution of a zone's `environment` link (ADR-014 D2), and the
// rendering of the EFFECTIVE zones document the planes actually consume.
//
// ── One link, one direction (#865) ────────────────────────────────────
// A zone names its environment; nothing points the other way. A Service zone
// (or the Management zone, for the mgmt environment) names the environment
// whose zone it IS; a Client, IoT, Guest or DMZ zone names the environment it
// serves. An environment's zone is the Service/Management zone naming it —
// exactly one per environment.
//
// ── The problem (#424) ────────────────────────────────────────────────
// A client zone reaches its services, and an IoT zone is reached by them.
// Writing that as a LITERAL service-zone name does not survive install: `init`
// renames `srv` -> `<defaultEnvironment>`, and every literal reference is
// stranded (on the reference system: iotCams.pinhole-allowed-from still named
// `srvHome` long after it went Inactive). A consumer zone names the
// ENVIRONMENT instead, and the edge is derived from that environment's CURRENT
// zone on every render — so a rename can never strand it.
//
// ── Authored vs. effective (decision D-C4) ────────────────────────────
// Derived edges are NEVER written back into zones.json. If they were, the 3-way
// merge would see them as operator edits and pin them, so clearing an `environment`
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
// THE RULE: the link only ever modifies the consumer zone that DECLARES it.
//
//   Client/Guest zone Z names environment E (service zone S):
//     the CLIENT consumes the service  ->  Z.access-to += S
//   IoT zone Z names environment E (service zone S):
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
//     the link handles.
//
// A DMZ zone may name the environment it fronts; that derives no edge.
//
// Side benefit: R2 becomes structural rather than conditional — the IoT branch
// touches only `pinhole-allowed-from`, so an isolated zone can never gain an
// inbound `access-to` by any path.

import { existsSync, readdirSync } from "fs";
import { dirname, join } from "path";
import { CONSUMER_TYPES, ENVIRONMENT_TYPES, OWNER_TYPES, ZonesDoc } from "./types";

export { CONSUMER_TYPES, ENVIRONMENT_TYPES, OWNER_TYPES };
import { isDocKey, loadZones } from "./zones";
import { writeJsonAtomic } from "../../../lib/ts/src/config-io";

// ── F2 (phased enforcement) ───────────────────────────────────────────
// Under the ADR-014 D5 lattice a client reaching its service is an UPWARD edge,
// so the strictly-correct derivation is the pinhole alone. Deriving the
// zone-wide `access-to` as well is what preserves TODAY's reachability — and
// this branch's governing invariant is that it re-cuts no firewall rule.
//
// The consequence is deliberate and expected: an environment-linked client zone
// trips I1 as a WARNING (two edges on the reference system). Those warnings are
// the worklist for the deferred conversion issue. When per-module pinholes
// replace the zone-wide reach, flip this to false and the warnings disappear.
export const SERVES_DERIVES_ZONE_WIDE_CLIENT_ACCESS = true;


export interface ServesEdge {
  zone: string; // the consumer zone
  environment: string; // the environment it names
  serviceZone: string; // that environment's zone
  // What was added, for the reconcile/report line.
  added: string[];
}

export interface ResolveResult {
  edges: ServesEdge[];
  // Hard problems: an environment that does not exist, an environment named by
  // no Service zone or by two, or `environment` on a zone type that may not
  // carry it. Reported by validate; fatal to reconcile.
  errors: string[];
}

// The environment a zone names, or undefined.
export function zoneEnvironment(z: { environment?: unknown } | undefined): string | undefined {
  const v = z?.environment;
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

// The zones that are `env`'s own zone: Service or Management zones naming it.
// One on a well-formed site; the caller reports none or several.
export function ownZonesOf(doc: ZonesDoc, env: string): string[] {
  const out: string[] = [];
  for (const [name, z] of doc.zones) {
    if (OWNER_TYPES.has(String(z.type ?? "")) && zoneEnvironment(z) === env) out.push(name);
  }
  return out;
}

// The environment's zone, when exactly one zone is its own.
export function environmentZoneIn(doc: ZonesDoc, env: string): string | undefined {
  const own = ownZonesOf(doc, env);
  return own.length === 1 ? own[0] : undefined;
}

// The environment's zone, read from the zones.json beside configDir (a site
// config root). undefined when zones.json is absent or no single zone is its own.
export function environmentZone(configDir: string, env: string): string | undefined {
  const f = join(configDir, "zones.json");
  if (!existsSync(f)) return undefined;
  try {
    return environmentZoneIn(loadZones(f), env);
  } catch {
    return undefined;
  }
}

// Does <configDir>/environments/ exist at all? Without it (a pre-ADR-007
// system, or a test zones file in a temp dir) environment names cannot be
// checked against files, and are not.
export function hasEnvironments(configDir: string): boolean {
  return existsSync(join(configDir, "environments"));
}

// The environments on this system (file names under environments/), sorted.
export function environmentNames(configDir: string): string[] {
  const dir = join(configDir, "environments");
  if (!existsSync(dir)) return [];
  try {
    return readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)).sort();
  } catch {
    return [];
  }
}

// Whether environment `env` exists (its file is present).
export function environmentExists(configDir: string, env: string): boolean {
  return existsSync(join(configDir, "environments", `${env}.json`));
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

// The link problems of `doc` that do not depend on the derivation: a zone type
// that may not carry `environment`, an environment that does not exist, two
// zones that are one environment's own. Shared by resolve and validate. `bad`
// holds the zones whose own link is broken, which resolve then skips.
export function linkErrors(doc: ZonesDoc, configDir: string): { errors: string[]; bad: Set<string> } {
  const errors: string[] = [];
  const bad = new Set<string>();
  const checkFiles = hasEnvironments(configDir);
  const owners = new Map<string, string[]>();
  for (const [name, z] of doc.zones) {
    const env = zoneEnvironment(z);
    if (z.environment !== undefined && env === undefined) {
      errors.push(`zone '${name}' has environment ${JSON.stringify(z.environment)} — one environment name`);
      bad.add(name);
      continue;
    }
    if (env === undefined) continue;
    const type = typeof z.type === "string" ? z.type : "";
    if (!ENVIRONMENT_TYPES.has(type)) {
      errors.push(
        `zone '${name}' is type ${type || "(unset)"} and must not name an environment ` +
          `(only Service, Management, Client, IoT, Guest and DMZ zones do). ` +
          `Clear it with \`network-manager bind ${name} --unbind\`.`,
      );
      bad.add(name);
      continue;
    }
    if (checkFiles && !environmentExists(configDir, env)) {
      errors.push(
        `zone '${name}' names environment '${env}', which does not exist ` +
          `(no ${join(configDir, "environments", `${env}.json`)}). Create the environment, or re-bind the zone.`,
      );
      bad.add(name);
      continue;
    }
    if (OWNER_TYPES.has(type)) owners.set(env, [...(owners.get(env) ?? []), name]);
  }
  for (const [env, zs] of owners) {
    if (zs.length > 1) {
      errors.push(
        `environment '${env}' is named by ${zs.length} Service/Management zones (${zs.join(", ")}) — ` +
          `an environment has one zone of its own; unbind all but one`,
      );
    }
  }
  return { errors, bad };
}

// Every environment on the system that no Service/Management zone names.
export function environmentsWithoutZone(doc: ZonesDoc, configDir: string): string[] {
  return environmentNames(configDir).filter((e) => ownZonesOf(doc, e).length === 0);
}

// Resolve every consumer link in `doc` INTO the mutable raw document `out`
// (which the caller has already deep-copied from the authored doc). Pure apart
// from checking the environment files under configDir.
export function resolveServes(
  doc: ZonesDoc,
  out: Record<string, unknown>,
  configDir: string,
): ResolveResult {
  const edges: ServesEdge[] = [];
  const { errors, bad } = linkErrors(doc, configDir);

  for (const [name, z] of doc.zones) {
    const env = zoneEnvironment(z);
    const type = typeof z.type === "string" ? z.type : "";
    if (env === undefined || !CONSUMER_TYPES.has(type) || bad.has(name)) continue;

    const own = ownZonesOf(doc, env);
    if (own.length === 0) {
      errors.push(
        `zone '${name}' serves environment '${env}', which no Service zone names ` +
          `(bind its zone: \`network-manager bind <zone> --environment ${env}\`).`,
      );
      continue;
    }
    if (own.length > 1) continue; // reported by linkErrors
    const svc = own[0];
    if (type === "DMZ") continue; // records the link; derives no edge

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

    edges.push({ zone: name, environment: env, serviceZone: svc, added });
  }

  return { edges, errors };
}

export interface EffectiveDoc {
  raw: Record<string, unknown>;
  edges: ServesEdge[];
  errors: string[];
}

// Render the effective document: a deep-ish copy of the authored raw doc with
// every consumer link resolved into it. Doc blocks are carried through.
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

// Load the authored zones.json, render its effective form, and write it beside
// the source. Best-effort by contract: it returns the errors rather than
// throwing, so a zone add cannot fail merely because an environment file is
// missing. `reconcile` and `validate` are what turn those errors fatal.
//
// The config root is taken from the zones file's own directory, so a temp/test
// zones.json renders against whatever environments/ sits next to it.
export function refreshEffective(zonesFile: string): EffectiveDoc {
  const configDir = dirname(zonesFile);
  const doc = loadZones(zonesFile);
  const eff = renderEffective(doc, configDir);
  writeJsonAtomic(effectiveFileFor(zonesFile), eff.raw);
  return eff;
}

// ── One-time migration back-fill (ADR-014 D2) ─────────────────────────
// Convert a LITERAL service-zone reference into an `environment` link, for
// every Client/IoT/Guest zone whose literal names a zone that is some
// environment's own zone. The literal is then dropped, because the render
// re-derives exactly the same edge.
//
// THE INVARIANT THIS MUST HOLD: the AUTHORED document changes, the EFFECTIVE
// document does not. That is what makes the migration safe to run on a live
// system — the firewall sees the same graph before and after.
//
// Runs inside `merge`: merge is already the rename-aware step and runs on every
// update-tappaas. Idempotent — a converged install re-runs it as a no-op.
//
// A literal that names a zone no environment owns (e.g. a retired `srvHome`)
// is deliberately left alone: it is not a link, it is stale, and pruning it is
// `retire`'s job, not the merge's.

export interface BackfillChange {
  zone: string;
  environment: string;
  serviceZone: string;
  droppedFrom: string; // the field the literal was removed from
}

export interface BackfillResult {
  changes: BackfillChange[];
}

function dropRef(z: Record<string, unknown>, f: string, v: string): boolean {
  if (!Array.isArray(z[f])) return false;
  const cur = z[f] as unknown[];
  const next = cur.filter((x) => x !== v);
  if (next.length === cur.length) return false;
  z[f] = next;
  return true;
}

// Back-fill `environment` in the raw document `raw` (mutated in place). The
// service zones are read from `raw` itself: a Service/Management zone naming an
// environment is that environment's zone.
export function backfillServes(raw: Record<string, unknown>, configDir: string): BackfillResult {
  const changes: BackfillChange[] = [];
  const known = new Set(environmentNames(configDir));
  const envByZone = new Map<string, string>();
  for (const [name, v] of Object.entries(raw)) {
    if (isDocKey(name) || v === null || typeof v !== "object" || Array.isArray(v)) continue;
    const z = v as Record<string, unknown>;
    const env = zoneEnvironment(z);
    if (env !== undefined && known.has(env) && OWNER_TYPES.has(String(z["type"] ?? ""))) {
      envByZone.set(name, env);
    }
  }
  if (envByZone.size === 0) return { changes };
  const zoneByEnv = new Map<string, string>();
  for (const [zone, env] of envByZone) if (!zoneByEnv.has(env)) zoneByEnv.set(env, zone);

  for (const [name, v] of Object.entries(raw)) {
    if (isDocKey(name) || v === null || typeof v !== "object" || Array.isArray(v)) continue;
    const z = v as Record<string, unknown>;
    const type = typeof z["type"] === "string" ? (z["type"] as string) : "";
    if (!["Client", "IoT", "Guest"].includes(type)) continue;

    // The field whose literal encodes the link, per the role asymmetry above.
    const field = type === "IoT" ? "pinhole-allowed-from" : "access-to";
    const refs = Array.isArray(z[field]) ? (z[field] as unknown[]) : [];

    const already = zoneEnvironment(z);
    // A zone the operator already bound: still prune the now-derived literal so
    // a re-run converges, but do not re-point the link.
    const targetEnv = already ?? (() => {
      for (const r of refs) {
        if (typeof r === "string" && envByZone.has(r)) return envByZone.get(r) as string;
      }
      return undefined;
    })();
    if (targetEnv === undefined) continue;

    const svc = zoneByEnv.get(targetEnv);
    if (svc === undefined) continue;

    if (already === undefined) z["environment"] = targetEnv;

    // Drop ONLY the local literal the render now derives. The service zone's own
    // entries are authored state that no link reproduces (see header) —
    // pruning them here would silently narrow the graph.
    const dropped = dropRef(z, field, svc);

    if (already === undefined || dropped) {
      changes.push({ zone: name, environment: targetEnv, serviceZone: svc, droppedFrom: field });
    }
  }
  return { changes };
}

