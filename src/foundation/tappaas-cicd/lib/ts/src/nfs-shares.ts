// nfs-shares.ts — the NFS share model of ADR-029 v0.9, shared by storage-manager
// (which owns config/shares.json and changes it one share at a time) and
// module-manager validate (which checks consumers' mounts against it).
//
// A share is declared once, in config/shares.json `nfs.shares.<name>` — a map, so
// names are Site-unique by construction (D4, D18). A consumer names the share in
// `config."storage:nfs".mounts[]` (D3). The same rules are applied at install time
// by the storage module's bash (storage/lib/nfs-lib.sh); test-nfs-lib.sh and the
// unit tests here pin the same cases.
//
// Pure: configs arrive through a reader, so the tests need no tree.

export interface NfsFinding {
  severity: "error" | "warning";
  message: string;
}

export interface Share {
  server?: string;
  pool?: string;
  quota?: string;
  properties?: Record<string, string>;
  backup?: { enabled?: boolean; exclude?: string[] };
  owner?: { uid?: number; gid?: number };
  grants?: Record<string, string>;
  path?: string;
  version?: string;
  v3Ports?: { mountd?: number; nlockmgr?: number; statd?: number };
}

export interface SharesDoc {
  nfs?: { shares?: Record<string, Share> };
  [section: string]: unknown;
}

export type ConfigReader = (instance: string) => Record<string, unknown> | null;

export const NFS_COORDINATE = "storage:nfs";
export const NFS_ALIAS_DOMAIN = "mgmt.internal";
export const SHARES_INSTANCE = "shares"; // config/shares.json
export const NAME_RE = /^[a-z][a-z0-9-]*$/;
export const OWNER_MIN = 64000;
export const OWNER_MAX = 64999;
export const PROPERTIES = new Set(["recordsize", "compression", "atime"]);
const VERSIONS = new Set(["4.2", "4.1", "4.0", "3"]);
const SUBDIR_RE = /^[A-Za-z0-9._/-]+$/;
// Directories a share may never cover: the guest's own system.
const FORBIDDEN = /^\/(?:$|nix(?:\/|$)|etc(?:\/|$)|var$|boot(?:\/|$)|proc|sys|dev|run|usr(?:\/|$)|bin|sbin|lib)/;

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string => (typeof v === "string" ? v : "");

export type ShareRef = { kind: "named"; share: string } | { kind: "literal"; host: string; path: string };

// D2: a reference containing ':' is an unmodelled server's literal
// <ip-or-host>:/<path>; anything else is a share name.
export function parseShareRef(ref: string): ShareRef | string {
  const i = ref.indexOf(":");
  if (i >= 0) {
    const host = ref.slice(0, i);
    const path = ref.slice(i + 1);
    if (!host || !path.startsWith("/"))
      return `share '${ref}' is not <ip-or-host>:/<path> — a share is named, or a literal with an absolute path`;
    return { kind: "literal", host, path };
  }
  if (!NAME_RE.test(ref)) return `share name '${ref}' must match ${NAME_RE.source}`;
  return { kind: "named", share: ref };
}

export const shareAlias = (share: string): string => `nfs-${share}.${NFS_ALIAS_DOMAIN}`;

// D2a: only a server on the site's own or a private routed network is mounted.
export function isPublicIpv4(host: string): boolean {
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  if (a === 10 || a === 127) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT: the overlay
  if (a === 169 && b === 254) return false;
  return true;
}

export function sharesOf(doc: SharesDoc | Obj | null): Record<string, Share> {
  return obj(obj(obj(doc ?? {}).nfs).shares) as Record<string, Share>;
}

const managedOf = (server: Obj | null): boolean => str(server?.management || "managed") === "managed";

// One share's declaration (D4, D2a). `hasHook` says whether a managed server's
// module ships the NFS server hook (D19); a registered server needs none.
export function checkShare(
  name: string,
  share: Share,
  read: ConfigReader,
  hasHook: (instance: string) => boolean,
): NfsFinding[] {
  const out: NfsFinding[] = [];
  const err = (m: string): void => void out.push({ severity: "error", message: `share ${name}: ${m}` });
  const warn = (m: string): void => void out.push({ severity: "warning", message: `share ${name}: ${m}` });
  const s = obj(share);
  if (!NAME_RE.test(name)) err(`name must match ${NAME_RE.source}`);
  const server = str(s.server);
  const srv = server ? read(server) : null;
  if (!server) err("server is required");
  else if (!srv) err(`server ${server} is not a module instance (no config/${server}.json)`);
  const managed = managedOf(srv);
  if (srv && managed && !hasHook(server))
    err(`server ${server}'s module ships no NFS server hook — it cannot serve shares (ADR-029 D19)`);
  if (srv && str(srv.zone0) === "wan") err(`server ${server} is in the wan zone — NFS is never served across it (ADR-029 D2a)`);
  const grants = s.grants;
  if (grants !== undefined && (typeof grants !== "object" || grants === null || Array.isArray(grants)))
    err("grants must be a map of consumer to ro|rw");
  for (const [c, a] of Object.entries(obj(grants))) {
    if (a !== "ro" && a !== "rw") err(`grant for ${c} is ${String(a)} (ro|rw)`);
    if (!read(c)) warn(`grants ${c}, which is not deployed — it shares to nobody until ${c} is installed`);
  }
  if (!srv || managed) {
    if (!str(s.pool)) err("pool is required on a managed Host");
    if ("path" in s) err("path is for a registered, unmanaged server — a managed Host builds the dataset from pool");
    if (typeof obj(s.backup).enabled !== "boolean") err("backup.enabled must be stated, true or false (ADR-029 D9 — there is no default)");
    if ("owner" in s) {
      const o = obj(s.owner);
      if (![o.uid, o.gid].every((v) => typeof v === "number" && v >= OWNER_MIN && v <= OWNER_MAX))
        err(`owner must be {uid, gid} in ${OWNER_MIN}-${OWNER_MAX}`);
    }
    for (const k of Object.keys(obj(s.properties)))
      if (!PROPERTIES.has(k)) err(`property ${k} is not one TAPPaaS sets (recordsize, compression, atime)`);
  } else {
    if (!str(s.path).startsWith("/")) err("path (absolute) is required on a registered, unmanaged server");
    for (const k of ["pool", "quota", "owner", "properties", "backup"])
      if (k in s) err(`${k} is not allowed on a registered, unmanaged server — TAPPaaS does not provision it`);
    const v = str(s.version) || "4.2";
    if (!VERSIONS.has(v)) err(`version ${v} (4.2|4.1|4.0|3)`);
    const p = obj(s.v3Ports);
    if (v === "3" && !["mountd", "nlockmgr", "statd"].every((k) => typeof p[k] === "number"))
      err("NFSv3 needs v3Ports {mountd, nlockmgr, statd} pinned — dynamic ports cannot be firewalled per host");
  }
  return out;
}

// The whole file (D18): every share, and the owners unique across them.
export function checkShares(doc: SharesDoc | Obj | null, read: ConfigReader, hasHook: (i: string) => boolean): NfsFinding[] {
  const out: NfsFinding[] = [];
  const shares = sharesOf(doc);
  const owners = new Map<number, string>();
  for (const [name, share] of Object.entries(shares)) {
    out.push(...checkShare(name, share, read, hasHook));
    const uid = obj(obj(share).owner).uid;
    if (typeof uid === "number") {
      if (owners.has(uid)) out.push({ severity: "error", message: `share ${name}: owner ${uid} is also ${owners.get(uid)}'s — one owner per share (ADR-029 D5)` });
      owners.set(uid, name);
    }
  }
  return out;
}

// The lowest free owner uid across the Site (D5, Q2); null when the range is used up.
export function nextOwner(doc: SharesDoc | Obj | null): number | null {
  const used = new Set(Object.values(sharesOf(doc)).map((s) => obj(obj(s).owner).uid));
  for (let u = OWNER_MIN; u <= OWNER_MAX; u++) if (!used.has(u)) return u;
  return null;
}

const mountsOf = (cfg: Obj): Obj[] => arr(obj(obj(cfg.config)[NFS_COORDINATE]).mounts).map(obj);

// Does this consumer mount that share? (D6: a share or grant it mounts is not taken away.)
export function mountsShare(cfg: Obj | null, share: string): boolean {
  return !!cfg && mountsOf(cfg).some((m) => m.share === share);
}

// D3 / D11 / D15 / D5 layer 2 — one consumer's mounts: shape, and where the share is
// declared, the two-key check and the firewall path. An undeclared share is a
// pending mount — a warning, never an error.
export function checkMounts(name: string, cfg: Obj, read: ConfigReader): NfsFinding[] {
  const out: NfsFinding[] = [];
  const err = (message: string): void => void out.push({ severity: "error", message });
  const mounts = mountsOf(cfg);
  if (mounts.length === 0) return out;
  const wired = [...arr(cfg.dependsOn), ...arr(cfg.integratesWith)].map(str);
  if (!wired.includes(NFS_COORDINATE)) {
    err(`config."${NFS_COORDINATE}".mounts declared without ${NFS_COORDINATE} in dependsOn — nothing would mount them`);
    return out;
  }
  const rules = wired.includes("network:rules") || wired.includes("firewall:rules");
  const zone = str(cfg.zone0);
  const shares = sharesOf(read(SHARES_INSTANCE));
  const paths = new Set<string>();
  for (const m of mounts) {
    const path = str(m.path);
    const at = `mount ${path || "<no path>"}`;
    if (!path.startsWith("/")) err(`${at}: path must be absolute`);
    else if (FORBIDDEN.test(path)) err(`${at}: not a directory a share may cover`);
    if (paths.has(path)) err(`${at}: mounted twice`);
    paths.add(path);
    const access = m.access ?? "ro";
    if (access !== "ro" && access !== "rw") err(`${at}: access ${String(access)} (ro|rw)`);
    const subdir = str(m.subdir);
    if (subdir && (subdir.startsWith("/") || !SUBDIR_RE.test(subdir) || subdir.split("/").some((s) => s === ".." || s === ".")))
      err(`${at}: subdir '${subdir}' must be a relative path inside the share — no leading /, no . or .. (ADR-029 D15)`);
    if ("stopUnits" in m && !(Array.isArray(m.stopUnits) && m.stopUnits.every((u) => typeof u === "string")))
      err(`${at}: stopUnits must be a list of unit names`);
    const ref = parseShareRef(str(m.share));
    if (typeof ref === "string") {
      err(`${at}: ${ref}`);
      continue;
    }
    let crosses: boolean;
    if (ref.kind === "literal") {
      if (read(ref.host)) {
        err(`${at}: ${ref.host} is a module instance — name its share, a literal path would go around the grant (ADR-029 D2)`);
        continue;
      }
      if (isPublicIpv4(ref.host)) {
        err(`${at}: ${ref.host} is a public address — NFS with sec=sys is cleartext and trusts the client's UID; only a server on the site's own or a private routed network is mounted (ADR-029 D2a)`);
        continue;
      }
      crosses = true; // an unmodelled server's zone cannot be known
    } else {
      const share = shares[ref.share];
      if (!share) {
        out.push({ severity: "warning", message: `${at}: share ${ref.share} is not declared — pending, the directory stays local until it is (ADR-029 D11)` });
        continue;
      }
      const server = read(str(share.server)) ?? {};
      if (str(server.zone0) === "wan") {
        err(`${at}: share ${ref.share} is on ${str(share.server)}, in the wan zone — NFS is never mounted across it (ADR-029 D2a)`);
        continue;
      }
      const grant = obj(share.grants)[name];
      if (!grant) {
        err(`${at}: share ${ref.share} grants ${name} nothing — run: storage-manager nfs grant ${ref.share} ${name} ${String(access)}  (or remove the mount, ADR-029 D11)`);
        continue;
      }
      if (access === "rw" && grant === "ro") {
        err(`${at}: asks rw, but share ${ref.share} grants ${name} only ro`);
        continue;
      }
      crosses = str(server.zone0) !== zone;
    }
    if (crosses && !rules)
      err(`${at}: share ${str(m.share)} is reached through the firewall — ${name} must depend on network:rules, which derives the tcp/2049 rule from its mounts (ADR-029 D5)`);
  }
  return out;
}
