// nfs.ts — the pvehost:nfs declarations, checked across modules (ADR-029, #766).
//
// Two declarations meet in one check: a server's own `nfs.exports[]` (a cluster
// node builds them, a registered, unmanaged server describes them) and a
// consumer's `config."pvehost:nfs".mounts[]`. The service scripts refuse a bad
// pair at install time (pvehost/lib/nfs-lib.sh); this is the same set of rules
// reported by `module-manager validate`, so it is caught before anything runs.
// Keep the two in step: test-nfs-lib.sh and test/unit/nfs.test.ts pin the same
// cases.
//
// Pure: configs arrive through `readConfig`, so the unit tests need no tree.

export interface NfsFinding {
  severity: "error" | "warning";
  message: string;
}

export type ConfigReader = (instance: string) => Record<string, unknown> | null;

export const NFS_COORDINATE = "pvehost:nfs";
const NAME_RE = /^[a-z][a-z0-9-]*$/;
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

export interface ShareRef {
  kind: "named" | "literal";
  host: string;
  rest: string; // export name (named) or absolute path (literal)
}

// ADR-029 D2: no leading slash after the colon → a named share on a module
// instance; a leading slash → an unmodelled server's literal path.
export function parseShareRef(ref: string): ShareRef | string {
  const i = ref.indexOf(":");
  if (i < 0) return `share '${ref}' is not <host>:<name> or <host>:/<path>`;
  const host = ref.slice(0, i);
  const rest = ref.slice(i + 1);
  if (!host || !rest) return `share '${ref}' has an empty host or name`;
  if (rest.startsWith("/")) return { kind: "literal", host, rest };
  if (!NAME_RE.test(rest)) return `share name '${rest}' must match ${NAME_RE.source}`;
  return { kind: "named", host, rest };
}

// ADR-029 D2a: an NFS server is reached on our own VLANs or a private routed
// network, never across someone else's — sec=sys is cleartext and trusts the
// client's claimed UID. Only a literal IP can be judged offline; a name is
// resolved, and judged, by the service at install time.
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

// ADR-029 D4 / D2a — one server's nfs.exports[].
export function checkExports(name: string, cfg: Obj): NfsFinding[] {
  const out: NfsFinding[] = [];
  const err = (message: string): void => void out.push({ severity: "error", message });
  const exports = arr(obj(cfg.nfs).exports);
  const managed = str(cfg.management || "managed") === "managed";
  const seen = new Set<string>();
  for (const raw of exports) {
    const e = obj(raw);
    const n = str(e.name) || "<unnamed>";
    if (!NAME_RE.test(str(e.name))) err(`nfs export ${n}: name must match ${NAME_RE.source}`);
    if (seen.has(n)) err(`nfs export ${n}: declared twice on ${name}`);
    seen.add(n);
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

// ADR-029 D3 / D11 / D5 layer 2 — one consumer's mounts against the servers they
// name: shape, the two-key check, and the firewall path.
export function checkMounts(name: string, cfg: Obj, read: ConfigReader): NfsFinding[] {
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
    const ref = parseShareRef(str(m.share));
    if (typeof ref === "string") {
      err(`${at}: ${ref}`);
      continue;
    }
    const server = read(ref.host);
    let crosses: boolean;
    if (ref.kind === "literal") {
      if (server) {
        err(`${at}: ${ref.host} is a module instance — name its share (${ref.host}:<name>), a path would go around the grant`);
        continue;
      }
      if (isPublicIpv4(ref.host)) {
        err(`${at}: ${ref.host} is a public address — NFS with sec=sys is cleartext and trusts the client's UID; only a server on the site's own or a private routed network is mounted (ADR-029 D2a)`);
        continue;
      }
      crosses = true; // an unmodelled server's zone cannot be known
    } else {
      if (!server) {
        err(`${at}: ${ref.host} is not a module instance (no config/${ref.host}.json) — for an unmodelled server write ${ref.host}:/<path>`);
        continue;
      }
      if (str(server.zone0) === "wan") {
        err(`${at}: ${ref.host} sits in the wan zone — NFS is never mounted across it (ADR-029 D2a)`);
        continue;
      }
      const exp = arr(obj(server.nfs).exports).map(obj).find((e) => e.name === ref.rest);
      if (!exp) {
        err(`${at}: ${ref.host} declares no export '${ref.rest}' — add it to config/${ref.host}.json nfs.exports[] (a consumer never creates an export, ADR-029 D11)`);
        continue;
      }
      const grant = arr(exp.grants).map(obj).find((g) => g.consumer === name);
      if (!grant) {
        err(`${at}: ${ref.host}:${ref.rest} grants ${name} nothing — add {"consumer": "${name}", "access": "${String(access)}"} to its grants`);
        continue;
      }
      if (access === "rw" && (grant.access ?? "ro") === "ro") {
        err(`${at}: asks rw, but ${ref.host}:${ref.rest} grants ${name} only ro`);
        continue;
      }
      crosses = str(server.zone0) !== zone;
    }
    if (crosses && !rules)
      err(`${at}: ${str(m.share)} is reached through the firewall — ${name} must depend on network:rules, which derives the tcp/2049 rule from its mounts (ADR-029 D5)`);
  }
  return out;
}

// A grant whose consumer is not deployed shares to nobody yet. Worth saying — it
// may be a typo — but not an error: the consumer may simply come later.
export function unusedGrants(cfg: Obj, read: ConfigReader): NfsFinding[] {
  const out: NfsFinding[] = [];
  for (const e of arr(obj(cfg.nfs).exports).map(obj))
    for (const g of arr(e.grants).map(obj)) {
      const c = str(g.consumer);
      if (c && !read(c))
        out.push({ severity: "warning", message: `nfs export ${str(e.name)}: grants ${c}, which is not deployed — it shares to nobody until ${c} is installed` });
    }
  return out;
}
