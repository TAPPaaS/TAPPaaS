// peers.ts — CRUD for the OFF-SITE PEER relationships (ADR-012 §1.4).
//
// A peer is a relationship between this site's PBS and someone else's. It is
// not a module capability: nothing declares `dependsOn: backup:remote`, and the
// dependency resolver never touches these. They are set up once by an operator,
// which is why they live here — the manager owns configuration — rather than in
// the module's service wiring.
//
// Three kinds — the three relationships another PBS can have with ours:
//
//   pull      pull-<name>.json     WE pull a copy of THEIR PBS into pull/<name>
//                                  (we hold a read-only login on them; we own
//                                  the schedule and the retention of our copy)
//   remote    remote-<name>.json   THEY pull OUR backups — the off-site copy of
//                                  our data lives with them. We grant a
//                                  read-only login and nothing else; we hold no
//                                  credential on them, so their copy cannot be
//                                  reached, let alone erased, from here (§1.4.1)
//   receive   receive-<name>.json  THEY push their backups into receive/<name>
//                                  on our PBS — we are their off-site, for a
//                                  system with no PBS of its own. We issue them
//                                  a write-no-delete login and own the retention
//
// `pull` and `remote` are the same movement from opposite ends: if A keeps a
// copy of B, A adds a `pull` peer for B and B adds a `remote` peer for A.
//
// There is deliberately NO kind for "we send our backups to an external PBS".
// A site with no local datastore configures that as PLACEMENT — `placementState:
// external` + `pbsUrl` on the backup module — not as a peer relationship. And a
// TAPPaaS PBS never pushes to another PBS at all; every inter-PBS copy is a
// pull, which is what makes the compromise isolation structural (§1.4.1).
//
// This module writes the CONFIG. The credential belongs to neither side's JSON
// (§2.5, prompt-not-store), so onboarding — which must prompt, and must talk to
// a live PBS — is delegated to the module's own scripts, exactly as `restore`
// delegates to restore.sh. Nothing here reimplements a PBS call.

import { existsSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";

export type PeerKind = "pull" | "remote" | "receive";

// The on-disk prefix and the script directory for each kind. The config
// prefixes are the historical ones (`remote-`, `external-`, `push-`) and are
// what listPeers already reads; the kind names are what an operator says.
const KINDS: Record<PeerKind, { prefix: string; dir: string; template: string }> = {
  pull: { prefix: "pull-", dir: "pull", template: "pull.json" },
  remote: { prefix: "remote-", dir: "remote", template: "remote.json" },
  receive: { prefix: "receive-", dir: "receive", template: "receive.json" },
};

export function isPeerKind(v: string): v is PeerKind {
  return v === "pull" || v === "remote" || v === "receive";
}

export function normalizeKind(v: string): PeerKind | null {
  const s = v.toLowerCase();
  return isPeerKind(s) ? s : null;
}

export function peerConfigPath(configDir: string, kind: PeerKind, name: string): string {
  return join(configDir, `${KINDS[kind].prefix}${name}.json`);
}

/** The module's onboarding/offboarding script for a kind, under backup/scripts/. */
export function peerScript(moduleDir: string, kind: PeerKind, action: "onboard" | "offboard"): string {
  return join(moduleDir, "scripts", KINDS[kind].dir, `${action}.sh`);
}

export interface PeerSpec {
  name: string;
  host?: string; // pull: the far PBS we pull from
  store?: string; // pull: its datastore
  namespace?: string; // pull/receive: where the data lands on our datastore
  //                     remote: what they may read ("" = the root namespace)
  remoteNamespace?: string; // pull: which namespace to pull FROM
  schedule?: string; // pull: when to pull
  groupFilter?: string; // pull: replicate only part of the source
  authId?: string; // remote: the login they pull with
  propagate?: boolean; // remote: let the grant reach child namespaces (default no)
  // Where the peer physically is (#609) — the evidence its copy is off-site.
  physicalLocation?: { country: string; city?: string; facility?: string };
  retention?: Record<string, number>;
}

// Build the config document for a peer. Deliberately mirrors the shipped
// templates (scripts/<kind>/<kind>.json) field for field — the onboarding
// scripts read these names, and a doc this manager writes must be one they
// already understand.
export function buildPeerConfig(
  kind: PeerKind,
  spec: PeerSpec,
  siteName?: string,
): Record<string, unknown> {
  const ns = spec.namespace ?? defaultNamespace(kind, spec.name, siteName);
  const place = spec.physicalLocation ? { physicalLocation: spec.physicalLocation } : {};
  if (kind === "pull") {
    return {
      name: spec.name,
      type: "tappaas",
      remoteHost: spec.host ?? "",
      remoteStore: spec.store ?? "tappaas_backup",
      remoteNamespace: spec.remoteNamespace ?? "",
      namespace: ns,
      pullSchedule: spec.schedule ?? "04:00",
      removeVanished: false, // never let a compromised source erase our copy
      encryptionRequired: true,
      readAuthId: "", // prompted at onboarding, never stored
      groupFilter: spec.groupFilter ?? "",
      retention: spec.retention ?? { keepLast: 4, keepDaily: 14, keepWeekly: 8, keepMonthly: 12 },
      ...place,
    };
  }
  if (kind === "receive") {
    return {
      name: spec.name,
      type: "receive",
      namespace: ns,
      encryptionRequired: true,
      retention: spec.retention ?? { keepDaily: 7, keepWeekly: 4, keepMonthly: 3 },
      ...place,
    };
  }
  // remote: they pull OUR backups. No namespace is created on our datastore —
  // this is a read grant on data we already hold. `namespace` therefore means
  // WHAT THEY MAY READ, and empty is the root: our VM backups.
  return {
    name: spec.name,
    type: "remote",
    authId: spec.authId ?? "",
    namespace: spec.namespace ?? "",
    // Off by default and deliberately so: a propagating grant on the root
    // namespace also exposes fs/ (our config and secrets capture) and every
    // other peer's data.
    propagate: spec.propagate ?? false,
    ...place,
  };
}

// For pull and receive the namespace is on OUR datastore and is named after the
// PEER. For push it is on THEIRS and is named after US — the remote created it
// by adding a receive peer for this site, so defaulting it to the peer's name
// would write into a namespace they never authorised.
// Namespaces on OUR datastore, named after the peer whose data they hold.
// `remote` creates none — it grants read access to data we already have.
function defaultNamespace(kind: PeerKind, name: string, _siteName?: string): string {
  if (kind === "pull") return `pull/${name}`;
  if (kind === "receive") return `receive/${name}`;
  return "";
}

/** This site's name — used in messages, not in namespace naming. */
export function siteName(configDir: string): string | undefined {
  try {
    const raw = JSON.parse(readFileSync(join(configDir, "site.json"), "utf8")) as Record<string, unknown>;
    return typeof raw.name === "string" && raw.name !== "" ? raw.name : undefined;
  } catch {
    return undefined;
  }
}

/** Write a peer config atomically. Refuses to clobber an existing one. */
export function writePeerConfig(
  configDir: string,
  kind: PeerKind,
  spec: PeerSpec,
  force = false,
): string {
  const site = siteName(configDir);
  const f = peerConfigPath(configDir, kind, spec.name);
  if (existsSync(f) && !force) {
    throw new Error(`peer '${spec.name}' already exists (${f}) — pass --force to overwrite`);
  }
  const tmp = `${f}.tmp`;
  writeFileSync(tmp, JSON.stringify(buildPeerConfig(kind, spec, site), null, 2) + "\n", "utf8");
  renameSync(tmp, f);
  return f;
}

/**
 * Every kind a name exists as. A single peer name legitimately holds more than
 * one relationship — a backup buddy is commonly BOTH a pull (we take a copy of
 * theirs) and a receive (they push into ours) — so "find the peer called X" has
 * no single answer and callers must say which relationship they mean.
 */
export function findPeers(configDir: string, name: string): Array<{ kind: PeerKind; file: string }> {
  const out: Array<{ kind: PeerKind; file: string }> = [];
  for (const kind of Object.keys(KINDS) as PeerKind[]) {
    const f = peerConfigPath(configDir, kind, name);
    if (existsSync(f)) out.push({ kind, file: f });
  }
  return out;
}

/** One specific relationship, or null. */
export function findPeer(
  configDir: string,
  kind: PeerKind,
  name: string,
): { kind: PeerKind; file: string } | null {
  const f = peerConfigPath(configDir, kind, name);
  return existsSync(f) ? { kind, file: f } : null;
}

export function removePeerConfig(
  configDir: string,
  kind: PeerKind,
  name: string,
): { kind: PeerKind; file: string } {
  const hit = findPeer(configDir, kind, name);
  if (!hit) throw new Error(`no ${kind} peer named '${name}' in ${configDir}`);
  unlinkSync(hit.file);
  return hit;
}

/** Read a peer config back (for show / validation). */
export function readPeerConfig(
  configDir: string,
  kind: PeerKind,
  name: string,
): Record<string, unknown> | null {
  const hit = findPeer(configDir, kind, name);
  if (!hit) return null;
  try {
    return JSON.parse(readFileSync(hit.file, "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/** Peer config basenames present in configDir (used by tests and `peer list`). */
export function peerFiles(configDir: string): string[] {
  if (!existsSync(configDir)) return [];
  const prefixes = Object.values(KINDS).map((k) => k.prefix);
  return readdirSync(configDir)
    .filter((f) => f.endsWith(".json") && prefixes.some((p) => f.startsWith(p)))
    .sort();
}
