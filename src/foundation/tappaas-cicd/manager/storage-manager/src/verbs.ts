// verbs.ts — what each storage-manager verb does to config/shares.json (ADR-029 v0.9
// D17), as pure functions over the document: a verb either returns the new document
// or a refusal. Writing, validating and converging are main.ts's; this is what the
// unit tests pin.

import {
  NAME_RE,
  OWNER_MAX,
  OWNER_MIN,
  PROPERTIES,
  Share,
  SharesDoc,
  nextOwner,
  sharesOf,
} from "../../../lib/ts/src/nfs-shares";

export type Result = { doc: SharesDoc; summary: string } | { refused: string };

const clone = (d: SharesDoc): SharesDoc => JSON.parse(JSON.stringify(d ?? {}));

function withShares(doc: SharesDoc, fn: (shares: Record<string, Share>) => void): SharesDoc {
  const d = clone(doc);
  d.nfs = d.nfs ?? {};
  d.nfs.shares = d.nfs.shares ?? {};
  fn(d.nfs.shares);
  return d;
}

export interface AddSpec {
  server: string;
  pool?: string;
  quota?: string;
  backup?: boolean;
  backupExclude?: string[];
  properties?: Record<string, string>;
  path?: string;
  version?: string;
  v3Ports?: { mountd: number; nlockmgr: number; statd: number };
}

// share add — a new declaration. A managed share gets its owner allocated here (D5):
// the owner is part of the declaration from the start, so no server ever writes back.
export function addShare(doc: SharesDoc, name: string, spec: AddSpec, managed: boolean): Result {
  if (!NAME_RE.test(name)) return { refused: `share name '${name}' must match ${NAME_RE.source}` };
  if (sharesOf(doc)[name]) return { refused: `share ${name} is already declared (on ${sharesOf(doc)[name].server}) — share names are unique across the Site` };
  const share: Share = { server: spec.server };
  if (managed) {
    if (spec.path) return { refused: `--path is for a registered, unmanaged server; ${spec.server} is managed — give --pool` };
    if (!spec.pool) return { refused: `--pool is required: ${spec.server} is a managed Host and builds the dataset` };
    if (spec.backup === undefined) return { refused: "--backup true|false is required — whether this share is backed up is a decision, not a default (ADR-029 D9)" };
    share.pool = spec.pool;
    if (spec.quota) share.quota = spec.quota;
    if (spec.properties && Object.keys(spec.properties).length) share.properties = spec.properties;
    share.backup = { enabled: spec.backup, ...(spec.backupExclude?.length ? { exclude: spec.backupExclude } : {}) };
    const uid = nextOwner(doc);
    if (uid === null) return { refused: `the owner range ${OWNER_MIN}-${OWNER_MAX} is used up` };
    share.owner = { uid, gid: uid };
  } else {
    if (spec.pool || spec.quota || spec.backup !== undefined || spec.properties)
      return { refused: `${spec.server} is a registered, unmanaged server — TAPPaaS builds nothing there: give --path (and --version), not --pool/--quota/--backup/--prop` };
    if (!spec.path) return { refused: `--path is required for a registered, unmanaged server` };
    share.path = spec.path;
    if (spec.version) share.version = spec.version;
    if (spec.v3Ports) share.v3Ports = spec.v3Ports;
  }
  share.grants = {};
  return {
    doc: withShares(doc, (s) => void (s[name] = share)),
    summary: `share ${name} declared on ${spec.server}${share.owner ? ` (owner ${share.owner.uid}:${share.owner.gid})` : ""}`,
  };
}

// share modify — within each field's D7 class. Accepted: quota, backup.enabled,
// backup.exclude, properties.<k>. Refused: what is a data migration or immutable.
export function modifyShare(doc: SharesDoc, name: string, sets: Array<[string, string]>): Result {
  const cur = sharesOf(doc)[name];
  if (!cur) return { refused: `share ${name} is not declared` };
  for (const [k] of sets) {
    if (k === "server" || k === "pool")
      return { refused: `${k} is a data migration, not a change in place (ADR-029 D7): send the dataset to its new place, then redeclare — a 'share move' verb comes later` };
    if (k === "name") return { refused: "a share is renamed by declaring a new one and moving the data — every consumer names it" };
    if (k === "owner" || k.startsWith("owner.")) return { refused: "owner is immutable once allocated — changing it needs a recursive chown of the dataset" };
    if (k === "grants" || k.startsWith("grants.")) return { refused: "grants change with 'nfs grant' / 'nfs revoke'" };
    if (k === "path" || k === "version" || k === "v3Ports") {
      if (cur.pool) return { refused: `${k} is for a registered, unmanaged server's share` };
      continue;
    }
    if (!["quota", "backup.enabled", "backup.exclude"].includes(k) && !k.startsWith("properties."))
      return { refused: `${k} is not a field 'share modify' changes (quota, backup.enabled, backup.exclude, properties.<k>)` };
    if (cur.path && !cur.pool) return { refused: `${name} is on a registered, unmanaged server — TAPPaaS provisions nothing there to change` };
  }
  const changed: string[] = [];
  const out = withShares(doc, (shares) => {
    const s = shares[name];
    for (const [k, v] of sets) {
      if (k === "quota") s.quota = v;
      else if (k === "backup.enabled") s.backup = { ...(s.backup ?? {}), enabled: v === "true" };
      else if (k === "backup.exclude") s.backup = { ...(s.backup ?? {}), exclude: v ? v.split(",") : [] };
      else if (k.startsWith("properties.")) s.properties = { ...(s.properties ?? {}), [k.slice("properties.".length)]: v };
      else if (k === "path") s.path = v;
      else if (k === "version") s.version = v;
      changed.push(`${k}=${v}`);
    }
  });
  for (const [k, v] of sets) {
    if (k === "backup.enabled" && v !== "true" && v !== "false") return { refused: "backup.enabled is true or false" };
    if (k.startsWith("properties.") && !PROPERTIES.has(k.slice("properties.".length)))
      return { refused: `${k.slice("properties.".length)} is not a property TAPPaaS sets (recordsize, compression, atime)` };
  }
  return { doc: out, summary: `share ${name}: ${changed.join(", ")}` };
}

// grant / revoke — one consumer at a time. Revoking from a consumer that still mounts
// the share is refused (D6): remove the mount first.
export function grant(doc: SharesDoc, name: string, consumer: string, access: string): Result {
  if (!sharesOf(doc)[name]) return { refused: `share ${name} is not declared — declare it first ('nfs share add')` };
  if (access !== "ro" && access !== "rw") return { refused: `access is ro or rw, not '${access}'` };
  return {
    doc: withShares(doc, (s) => void (s[name].grants = { ...(s[name].grants ?? {}), [consumer]: access })),
    summary: `share ${name}: ${consumer} may mount it ${access}`,
  };
}

export function revoke(doc: SharesDoc, name: string, consumer: string, mounts: boolean): Result {
  const cur = sharesOf(doc)[name];
  if (!cur) return { refused: `share ${name} is not declared` };
  if (!(consumer in (cur.grants ?? {}))) return { refused: `share ${name} grants ${consumer} nothing` };
  if (mounts) return { refused: `${consumer} still mounts ${name} — remove the mount from its config first (ADR-029 D6)` };
  return {
    doc: withShares(doc, (s) => {
      const g = { ...(s[name].grants ?? {}) };
      delete g[consumer];
      s[name].grants = g;
    }),
    summary: `share ${name}: ${consumer}'s grant revoked`,
  };
}

// share delete — the declaration goes; the data stays (D6). Refused while any
// deployed consumer mounts the share.
export function deleteShare(doc: SharesDoc, name: string, mountedBy: string[]): Result {
  if (!sharesOf(doc)[name]) return { refused: `share ${name} is not declared` };
  if (mountedBy.length)
    return { refused: `share ${name} is mounted by ${mountedBy.join(", ")} — remove those mounts first (ADR-029 D6)` };
  return {
    doc: withShares(doc, (s) => void delete s[name]),
    summary: `share ${name} deleted — unshared and its data kept; 'nfs share purge ${name} --server ${sharesOf(doc)[name].server}' destroys it`,
  };
}
