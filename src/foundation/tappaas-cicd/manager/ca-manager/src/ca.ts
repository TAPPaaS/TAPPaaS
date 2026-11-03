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
