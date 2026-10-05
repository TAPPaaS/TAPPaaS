// nfs.ts — the pvehost:nfs declarations, checked across modules (ADR-029 v0.8).
//
// Two declarations meet in one check: a server's own `nfs.exports[]` (a cluster
// node builds them, a registered, unmanaged server describes them) and a
// consumer's `config."pvehost:nfs".mounts[]`. A mount names a SHARE, never a
// server: share names are unique across the Site, and the share is found by
// looking through every deployed instance. The service scripts apply the same
// rules at install time (pvehost/lib/nfs-lib.sh); this reports them from
// `module-manager validate`, before anything runs. Keep the two in step:
// test-nfs-lib.sh and test/unit/nfs.test.ts pin the same cases.
//
// Pure: configs arrive through a lister and a reader, so the tests need no tree.

export interface NfsFinding {
  severity: "error" | "warning";
  message: string;
}

export type ConfigReader = (instance: string) => Record<string, unknown> | null;
export type InstanceLister = () => string[];

export const NFS_COORDINATE = "pvehost:nfs";
export const NFS_ALIAS_DOMAIN = "mgmt.internal";
const NAME_RE = /^[a-z][a-z0-9-]*$/;
const SUBDIR_RE = /^[A-Za-z0-9._/-]+$/;
const OWNER_MIN = 64000;
const OWNER_MAX = 64999;
const PROPERTIES = new Set(["recordsize", "compression", "atime"]);
const VERSIONS = new Set(["4.2", "4.1", "4.0", "3"]);
// Directories a share may never cover: the guest's own system.
const FORBIDDEN = /^\/(?:$|nix(?:\/|$)|etc(?:\/|$)|var$|boot(?:\/|$)|proc|sys|dev|run|usr(?:\/|$)|bin|sbin|lib)/;

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string => (typeof v === "string" ? v : "");

export type ShareRef =
  | { kind: "named"; share: string }
  | { kind: "literal"; host: string; path: string };

// ADR-029 D2 (v0.8): a reference containing ':' is an unmodelled server's literal
// <ip-or-host>:/<path>; anything else is a Site-unique share name.
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

// ADR-029 D2a: an NFS server is reached on our own VLANs or a private routed
// network, never across someone else's. Only a literal IP can be judged offline.
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

const deps = (c: Obj): string[] => [...arr(c.dependsOn), ...arr(c.integratesWith)].map(str);
const exportsOf = (c: Obj): Obj[] => arr(obj(c.nfs).exports).map(obj);

// Every instance declaring an export of that name, sorted. One is the server;
// none is a pending share; more is an error (names are Site-unique, D2).
export function shareServers(share: string, list: InstanceLister, read: ConfigReader): string[] {
  return list()
    .filter((i) => exportsOf(read(i) ?? {}).some((e) => e.name === share))
    .sort();
}

// ADR-029 D4 / D2a — one server's nfs.exports[], and (v0.8) that each name is
// declared by no other instance.
export function checkExports(name: string, cfg: Obj, list?: InstanceLister, read?: ConfigReader): NfsFinding[] {
  const out: NfsFinding[] = [];
  const err = (message: string): void => void out.push({ severity: "error", message });
  const managed = str(cfg.management || "managed") === "managed";
  const seen = new Set<string>();
  for (const e of exportsOf(cfg)) {
    const n = str(e.name) || "<unnamed>";
    if (!NAME_RE.test(str(e.name))) err(`nfs export ${n}: name must match ${NAME_RE.source}`);
    if (seen.has(n)) err(`nfs export ${n}: declared twice on ${name}`);
    seen.add(n);
    if (list && read) {
      const others = shareServers(n, list, read).filter((i) => i !== name);
      if (others.length) err(`nfs export ${n}: also declared by ${others.join(", ")} — share names are unique across the Site (ADR-029 D2)`);
    }
    const consumers = new Set<string>();
    for (const g of arr(e.grants).map(obj)) {
      const c = str(g.consumer);
      if (!c) err(`nfs export ${n}: a grant has no consumer`);
      else if (consumers.has(c)) err(`nfs export ${n}: ${c} is granted twice`);
      consumers.add(c);
      const a = g.access ?? "ro";
      if (a !== "ro" && a !== "rw") err(`nfs export ${n}: grant for ${c} has access ${String(a)} (ro|rw)`);
    }
    if (managed) {
      if (!str(e.pool)) err(`nfs export ${n}: pool is required on a managed Host`);
      if ("path" in e) err(`nfs export ${n}: path is for a registered, unmanaged server — a managed Host builds the dataset from pool`);
      if (typeof obj(e.backup).enabled !== "boolean")
        err(`nfs export ${n}: backup.enabled must be stated, true or false (ADR-029 D9 — there is no default)`);
      if ("owner" in e) {
        const o = obj(e.owner);
        const ok = [o.uid, o.gid].every((v) => typeof v === "number" && v >= OWNER_MIN && v <= OWNER_MAX);
        if (!ok) err(`nfs export ${n}: owner must be {uid, gid} in ${OWNER_MIN}-${OWNER_MAX}`);
      }
      for (const k of Object.keys(obj(e.properties)))
        if (!PROPERTIES.has(k)) err(`nfs export ${n}: property ${k} is not one TAPPaaS sets (recordsize, compression, atime)`);
    } else {
      if (!str(e.path).startsWith("/")) err(`nfs export ${n}: path (absolute) is required on a registered, unmanaged server`);
      for (const k of ["pool", "quota", "owner", "properties", "backup"])
        if (k in e) err(`nfs export ${n}: ${k} is not allowed on a registered, unmanaged server — TAPPaaS does not provision it`);
      const v = str(e.version) || "4.2";
      if (!VERSIONS.has(v)) err(`nfs export ${n}: version ${v} (4.2|4.1|4.0|3)`);
      const p = obj(e.v3Ports);
      if (v === "3" && !["mountd", "nlockmgr", "statd"].every((k) => typeof p[k] === "number"))
        err(`nfs export ${n}: NFSv3 needs v3Ports {mountd, nlockmgr, statd} pinned — dynamic ports cannot be firewalled per host`);
    }
  }
  return out;
}

// ADR-029 D3 / D11 / D15 / D5 layer 2 (v0.8) — one consumer's mounts: shape, and
// where the share exists, the two-key check and the firewall path. A share no
// server declares is a pending mount — reported as a warning, never refused.
export function checkMounts(name: string, cfg: Obj, list: InstanceLister, read: ConfigReader): NfsFinding[] {
  const out: NfsFinding[] = [];
  const err = (message: string): void => void out.push({ severity: "error", message });
  const mounts = arr(obj(obj(cfg.config)[NFS_COORDINATE]).mounts).map(obj);
  if (mounts.length === 0) return out;
  const wired = deps(cfg);
  if (!wired.includes(NFS_COORDINATE)) {
    err(`config."${NFS_COORDINATE}".mounts declared without ${NFS_COORDINATE} in dependsOn — nothing would mount them`);
    return out;
  }
  const rules = wired.includes("network:rules") || wired.includes("firewall:rules");
  const zone = str(cfg.zone0);
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
      const servers = shareServers(ref.share, list, read);
      if (servers.length === 0) {
        out.push({ severity: "warning", message: `${at}: share ${ref.share} is not declared on any server — pending, the directory stays local until it is (ADR-029 D11)` });
        continue;
      }
      if (servers.length > 1) {
        err(`${at}: share ${ref.share} is declared by ${servers.join(", ")} — share names are unique across the Site`);
        continue;
      }
      const server = read(servers[0]) ?? {};
      if (str(server.zone0) === "wan") {
        err(`${at}: share ${ref.share} is on ${servers[0]}, in the wan zone — NFS is never mounted across it (ADR-029 D2a)`);
        continue;
      }
      const exp = exportsOf(server).find((e) => e.name === ref.share) ?? {};
      const grant = arr(exp.grants).map(obj).find((g) => g.consumer === name);
      if (!grant) {
        err(`${at}: share ${ref.share} (on ${servers[0]}) grants ${name} nothing — add {"consumer": "${name}", "access": "${String(access)}"} to its grants in config/${servers[0]}.json, or remove the mount (ADR-029 D11)`);
        continue;
      }
      if (access === "rw" && (grant.access ?? "ro") === "ro") {
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

// A grant whose consumer is not deployed shares to nobody yet. Worth saying — it
// may be a typo — but not an error: the consumer may simply come later.
export function unusedGrants(cfg: Obj, read: ConfigReader): NfsFinding[] {
  const out: NfsFinding[] = [];
  for (const e of exportsOf(cfg))
    for (const g of arr(e.grants).map(obj)) {
      const c = str(g.consumer);
      if (c && !read(c))
        out.push({ severity: "warning", message: `nfs export ${str(e.name)}: grants ${c}, which is not deployed — it shares to nobody until ${c} is installed` });
    }
  return out;
}
