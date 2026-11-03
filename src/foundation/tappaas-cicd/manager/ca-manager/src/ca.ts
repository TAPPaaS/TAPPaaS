// ca.ts — the rules of ADR-043, with no I/O: which CA may sign a name, when a
// domain needs a CA of its own, and when a certificate is due for renewal.
//
// The site has one internal CA (it may sign `internal` and nothing else) and a
// domain CA per domain tree that has no public certificates (D1). A CA's
// permitted names cover their subdomains, as the name constraint in its
// certificate does (D2), so `test.my-org.tld` never needs a CA of its own when
// `my-org.tld` has one; `other-org.tld` does.

export type Scope = "internal" | "domain";
export type CaState = "active" | "retiring";

export interface CaRecord {
  scope: Scope;
  permitted: string[]; // what the name constraint allows (D2)
  subject: string;
  fingerprint: string; // SHA-256 of the certificate
  notBefore: string;
  notAfter: string;
  state: CaState;
  created: string;
}

export interface CertRecord {
  ca: string; // the id of the CA that signed it
  names: string[];
  fingerprint: string;
  notBefore: string;
  notAfter: string;
  issued: string;
  // A certificate the firewall serves (a domain CA's wildcard): its name in the
  // trust store and the refid Caddy binds (D7).
  trust?: string;
  refid?: string;
  // Where it was put on a guest (D5), so a renewal puts it there again.
  deliveries?: Delivery[];
}

export interface Delivery {
  host: string; // reached as tappaas@<host>, the key written as root through sudo
  dir: string; // <dir>/<as>.pem (the certificate, then its CA) and <dir>/<as>.key
  as: string;
  group: string; // the key is mode 0640, root:<group>
  reload: string[]; // the units reloaded after a change
}

const HOST = /^[a-z0-9][a-z0-9.-]{0,252}$/;
const UNIT = /^[A-Za-z0-9@._-]+$/;
// A delivery's fields, refused when one could leave the guest's directory or be
// read as a shell word.
export function deliveryProblem(d: Delivery): string | null {
  if (!HOST.test(d.host)) return `${d.host}: not a host name`;
  if (!/^\/[A-Za-z0-9._/-]+$/.test(d.dir) || d.dir.includes("..")) return `${d.dir}: an absolute directory, letters, digits, . _ - and /`;
  if (!/^[a-z0-9][a-z0-9._-]{0,60}$/.test(d.as)) return `${d.as}: a file name, letters, digits, . _ -`;
  if (!/^[a-z_][a-z0-9_-]{0,31}$/.test(d.group)) return `${d.group}: a group name`;
  const bad = d.reload.find((u) => !UNIT.test(u));
  return bad ? `${bad}: not a unit name` : null;
}

// The script the guest runs as root (`sudo sh -s`) to take a certificate in. The
// chain and key travel inside it, on ssh's stdin, never in an argument. Each file
// is replaced atomically, and the units are reloaded only when something changed.
export function deliveryScript(d: Delivery, chain: string, key: string): string {
  const pem = `${d.dir}/${d.as}.pem`;
  const kf = `${d.dir}/${d.as}.key`;
  const end = (t: string): string => (t.endsWith("\n") ? t : `${t}\n`);
  return [
    "set -eu",
    "umask 077",
    `getent group ${d.group} >/dev/null || { echo "no group ${d.group} here" >&2; exit 3; }`,
    `install -d -m 0750 -o root -g ${d.group} ${d.dir}`,
    `cat > ${pem}.new <<'TAPPAAS_CHAIN'`,
    end(chain) + "TAPPAAS_CHAIN",
    `cat > ${kf}.new <<'TAPPAAS_KEY'`,
    end(key) + "TAPPAAS_KEY",
    `chown root:${d.group} ${pem}.new ${kf}.new`,
    `chmod 0644 ${pem}.new`,
    `chmod 0640 ${kf}.new`,
    "changed=0",
    `cmp -s ${pem}.new ${pem} 2>/dev/null && cmp -s ${kf}.new ${kf} 2>/dev/null || changed=1`,
    `mv -f ${pem}.new ${pem}`,
    `mv -f ${kf}.new ${kf}`,
    ...(d.reload.length ? [`[ "$changed" = 1 ] && systemctl try-reload-or-restart ${d.reload.join(" ")}`] : []),
    `[ "$changed" = 1 ] && echo changed || echo unchanged`,
    "",
  ].join("\n");
}

// The wildcard of an environment: its record's name, and the names it holds.
export function wildcardName(env: string): string {
  return `wildcard-${env}`;
}
export function wildcardNames(domain: string): string[] {
  return [`*.${domain}`, domain];
}

export interface CaDoc {
  version: 1;
  cas: Record<string, CaRecord>;
  certificates: Record<string, CertRecord>;
  // DNS providers (D6): what ACME's DNS-01 uses. The secret is in the key dir,
  // never here: only the names of its fields.
  providers?: Record<string, ProviderRecord>;
}

export interface ProviderRecord {
  type: string; // os-acme-client's provider: cloudflare, hetzner, dns_desec, …
  domains: string[]; // the domains it serves, each with its subdomains; none: any
  keys: string[]; // the names of its credential's fields (dns_cf_token, …)
  added: string;
}

// The provider for a domain: the one whose domains cover it, else the one that
// serves any domain. Null when neither exists.
export function providerFor(doc: CaDoc, domain: string): string | null {
  const ps = Object.entries(doc.providers ?? {});
  const named = ps.find(([, p]) => p.domains.some((d) => within(domain, d)));
  if (named) return named[0];
  const any = ps.find(([, p]) => p.domains.length === 0);
  return any ? any[0] : null;
}

// A provider's credential: KEY=VALUE lines, each key acme.sh's dns_<provider>_<field>.
export function parseCredential(text: string): { fields: Record<string, string> } | { error: string } {
  const fields: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.replace(/#.*$/, "").trim();
    if (!line) continue;
    const i = line.indexOf("=");
    if (i <= 0) return { error: `not KEY=VALUE: ${line.slice(0, 20)}…` };
    const k = line.slice(0, i).trim();
    const v = line.slice(i + 1).trim();
    if (k === "provider") continue; // the legacy file's first line
    if (!/^dns_[a-z0-9_]+$/i.test(k)) return { error: `${k}: the fields are named dns_… (acme.sh's names, e.g. dns_cf_token)` };
    if (!v) return { error: `${k}: no value` };
    fields[k] = v;
  }
  if (Object.keys(fields).length === 0) return { error: "no dns_… field on stdin" };
  return { fields };
}

// The refid acme-manager setup prints for the issued certificate.
export function refidFromSetup(output: string): string | null {
  const m = [...output.matchAll(/^\s+refid:\s+(\S+)/gm)];
  return m.length ? m[m.length - 1][1] : null;
}

export const INTERNAL_ID = "internal";
export const INTERNAL_NAME = "internal";
export const CA_DAYS = 3650; // D1: 10 years
export const CERT_DAYS = 365; // D9: Apple refuses more than 825
export const RENEW_DAYS = 60; // D9: renewed this long before expiry

export function emptyDoc(): CaDoc {
  return { version: 1, cas: {}, certificates: {} };
}

// A DNS name as a certificate carries it: lower case, labels of letters, digits
// and inner dashes, and at most one leading `*.` for a wildcard.
const LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
export function nameProblem(name: string): string | null {
  const n = name.startsWith("*.") ? name.slice(2) : name;
  if (n !== n.toLowerCase()) return `${name}: write it in lower case`;
  if (n.length === 0 || n.length > 253) return `${name}: not a DNS name`;
  if (!n.split(".").every((l) => LABEL.test(l))) return `${name}: not a DNS name`;
  return null;
}

// `name` is `tree` or lies under it. A wildcard is judged by what it stands under.
export function within(name: string, tree: string): boolean {
  const n = name.startsWith("*.") ? name.slice(2) : name;
  return n === tree || n.endsWith(`.${tree}`);
}

export function domainCaId(domain: string): string {
  return `domain-${domain}`;
}

// The active CA whose permitted names cover every one of `names`, or null.
export function signerFor(doc: CaDoc, names: string[]): string | null {
  for (const [id, ca] of Object.entries(doc.cas)) {
    if (ca.state !== "active") continue;
    if (names.every((n) => ca.permitted.some((p) => within(n, p)))) return id;
  }
  return null;
}

// What a new domain needs (D1's rule). `covered`: an active domain CA's tree
// already holds it, so it needs nothing. `new`: it gets a CA of its own.
export type DomainNeed = { kind: "covered"; by: string } | { kind: "new"; id: string } | { kind: "refused"; why: string };

export function domainNeed(doc: CaDoc, domain: string): DomainNeed {
  const problem = nameProblem(domain);
  if (problem) return { kind: "refused", why: problem };
  if (domain.startsWith("*.")) return { kind: "refused", why: `${domain}: a domain, not a wildcard` };
  if (within(domain, INTERNAL_NAME)) return { kind: "refused", why: `${domain}: names under internal belong to the internal CA` };
  if (!domain.includes(".")) return { kind: "refused", why: `${domain}: a domain CA needs a domain of two labels or more` };
  for (const [id, ca] of Object.entries(doc.cas)) {
    if (ca.scope === "domain" && ca.state === "active" && ca.permitted.some((p) => within(domain, p))) return { kind: "covered", by: id };
  }
  return { kind: "new", id: domainCaId(domain) };
}

// A certificate's names, refused when one is malformed or when the signer it
// would get is not the CA its kind belongs to: no CA signs a mix of internal
// and domain names, since no name constraint allows both.
export function certProblem(doc: CaDoc, names: string[]): string | null {
  if (names.length === 0) return "a certificate needs at least one name";
  for (const n of names) {
    const p = nameProblem(n);
    if (p) return p;
  }
  if (!signerFor(doc, names)) {
    const internal = names.filter((n) => within(n, INTERNAL_NAME));
    if (internal.length && internal.length < names.length) return "internal and domain names go in separate certificates";
    if (internal.length) return "no internal CA yet: ca-manager init";
    return `no domain CA covers ${names.join(", ")}: ca-manager domain add <domain>`;
  }
  return null;
}

// Days from `now` to `notAfter`, rounded down.
export function daysLeft(notAfter: string, now: Date): number {
  return Math.floor((Date.parse(notAfter) - now.getTime()) / 86_400_000);
}

export function dueForRenewal(cert: CertRecord, now: Date, within = RENEW_DAYS): boolean {
  return daysLeft(cert.notAfter, now) <= within;
}

// The name constraint as openssl's -addext takes it.
export function constraintExt(permitted: string[]): string {
  return `nameConstraints=critical,${permitted.map((p) => `permitted;DNS:${p}`).join(",")}`;
}

// The trust bundle (D8): every CA the site trusts, active and retiring, in id order.
export function bundleOrder(doc: CaDoc): string[] {
  return Object.keys(doc.cas).sort((a, b) => (a === INTERNAL_ID ? -1 : b === INTERNAL_ID ? 1 : a.localeCompare(b)));
}

// The document read back from disk: anything else is refused, not repaired.
export function docProblems(raw: unknown): string[] {
  const out: string[] = [];
  const d = raw as Partial<CaDoc> | null;
  if (!d || typeof d !== "object") return ["not a JSON object"];
  if (d.version !== 1) out.push("version is not 1");
  if (!d.cas || typeof d.cas !== "object") out.push("cas is missing");
  if (!d.certificates || typeof d.certificates !== "object") out.push("certificates is missing");
  for (const [id, ca] of Object.entries(d.cas ?? {})) {
    if (ca.scope !== "internal" && ca.scope !== "domain") out.push(`CA ${id}: scope is internal or domain`);
    if (!Array.isArray(ca.permitted) || ca.permitted.length === 0) out.push(`CA ${id}: no permitted names`);
    if (ca.state !== "active" && ca.state !== "retiring") out.push(`CA ${id}: state is active or retiring`);
  }
  for (const [name, c] of Object.entries(d.certificates ?? {})) {
    if (!d.cas?.[c.ca]) out.push(`certificate ${name}: its CA ${c.ca} is not recorded`);
    else if (!c.names.every((n) => d.cas![c.ca].permitted.some((p) => within(n, p)))) out.push(`certificate ${name}: a name outside its CA's constraint`);
  }
  return out;
}
