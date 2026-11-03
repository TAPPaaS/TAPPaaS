// ca.test.ts — ADR-043's rules, offline: which CA may sign a name, when a domain
// needs a CA of its own (D1), and when a certificate is due (D9).

import {
  CaDoc,
  CaRecord,
  certProblem,
  constraintExt,
  daysLeft,
  docProblems,
  domainNeed,
  dueForRenewal,
  emptyDoc,
  nameProblem,
  parseCredential,
  providerFor,
  refidFromSetup,
  signerFor,
  within,
} from "../../src/ca";

let passed = 0;
let failed = 0;
function check(cond: boolean, msg: string): void {
  if (cond) {
    passed++;
    console.log(`  ok: ${msg}`);
  } else {
    failed++;
    console.log(`  FAIL: ${msg}`);
  }
}

const ca = (scope: "internal" | "domain", permitted: string[], state: "active" | "retiring" = "active"): CaRecord => ({
  scope, permitted, state, subject: "x", fingerprint: "f", notBefore: "2026-01-01T00:00:00Z", notAfter: "2036-01-01T00:00:00Z", created: "2026-01-01T00:00:00Z",
});
const doc: CaDoc = { version: 1, cas: { internal: ca("internal", ["internal"]), "domain-my-org.tld": ca("domain", ["my-org.tld"]) }, certificates: {} };

// ── names ──
check(nameProblem("logging.mgmt.internal") === null, "a plain name is a name");
check(nameProblem("*.my-org.tld") === null, "…and a wildcard");
check(nameProblem("Logging.mgmt.internal") !== null, "upper case is refused");
check(nameProblem("a..b") !== null && nameProblem("-a.b") !== null && nameProblem("*.*.a") !== null, "malformed names are refused");
check(within("x.test.my-org.tld", "my-org.tld") && within("*.test.my-org.tld", "my-org.tld") && within("my-org.tld", "my-org.tld"), "a tree holds its subdomains, wildcards and itself");
check(!within("evilmy-org.tld", "my-org.tld") && !within("my-org.tld.evil", "my-org.tld"), "…not a name that only ends with the same letters");

// ── D1: when a domain needs a CA ──
check(domainNeed(emptyDoc(), "my-org.tld").kind === "new", "the first domain gets a CA");
const sub = domainNeed(doc, "test.my-org.tld");
check(sub.kind === "covered" && sub.by === "domain-my-org.tld", "a subdomain environment needs none: its tree's CA covers it");
const other = domainNeed(doc, "other-org.tld");
check(other.kind === "new" && other.id === "domain-other-org.tld", "an unrelated domain gets a CA of its own");
check(domainNeed(doc, "lab2.internal").kind === "refused", "a name under internal is the internal CA's, never a domain CA's");
check(domainNeed(doc, "tld").kind === "refused", "a single label is refused");
check(domainNeed(doc, "*.x.tld").kind === "refused", "a wildcard is not a domain");
const retired: CaDoc = { ...doc, cas: { ...doc.cas, "domain-my-org.tld": ca("domain", ["my-org.tld"], "retiring") } };
check(domainNeed(retired, "test.my-org.tld").kind === "new", "a retiring CA covers nothing new");

// ── who signs ──
check(signerFor(doc, ["logging.mgmt.internal"]) === "internal", "an internal name: the internal CA");
check(signerFor(doc, ["*.my-org.tld", "*.test.my-org.tld"]) === "domain-my-org.tld", "names of one tree: its CA");
check(signerFor(doc, ["x.hrossen.dk"]) === null, "a name no CA covers: no signer");
check(certProblem(doc, ["a.mgmt.internal", "a.my-org.tld"]) === "internal and domain names go in separate certificates", "a mix of internal and domain names is refused");
check((certProblem(doc, ["x.other.tld"]) ?? "").includes("domain add"), "an uncovered name says how to cover it");
check((certProblem(emptyDoc(), ["a.mgmt.internal"]) ?? "").includes("ca-manager init"), "an internal name before init says to init");
check(certProblem(doc, []) !== null, "a certificate needs a name");

// ── D9 ──
const t = new Date("2026-11-03T00:00:00Z");
const cert = (notAfter: string) => ({ ca: "internal", names: ["a.internal"], fingerprint: "f", notBefore: "2026-01-01T00:00:00Z", notAfter, issued: "" });
check(daysLeft("2026-12-03T00:00:00Z", t) === 30, "days left");
check(dueForRenewal(cert("2026-12-31T00:00:00Z"), t) && !dueForRenewal(cert("2027-06-01T00:00:00Z"), t), "due 60 days before expiry, not before");
check(dueForRenewal(cert("2026-10-01T00:00:00Z"), t), "an expired certificate is due");

// ── D2: the extension, and the record read back ──
check(constraintExt(["my-org.tld"]) === "nameConstraints=critical,permitted;DNS:my-org.tld", "the name constraint is critical and permits the tree");
check(docProblems(doc).length === 0, "a good record has no problems");
check(docProblems({ version: 1, cas: {}, certificates: { x: cert("2027-01-01T00:00:00Z") } }).some((p) => p.includes("not recorded")), "a certificate of an unknown CA is a problem");
check(docProblems({ ...doc, certificates: { x: { ...cert("2027-01-01T00:00:00Z"), names: ["a.other.tld"] } } }).some((p) => p.includes("outside")), "a recorded name outside its CA's constraint is a problem");
check(docProblems(null).length > 0 && docProblems({ version: 2, cas: {}, certificates: {} }).length > 0, "a broken record is refused");

// ── D6: DNS providers ──
const pd: CaDoc = { ...doc, providers: {
  cf: { type: "cloudflare", domains: ["my-org.tld"], keys: ["dns_cf_token"], added: "" },
  any: { type: "hetzner", domains: [], keys: ["dns_hetzner_token"], added: "" },
} };
check(providerFor(pd, "test.my-org.tld") === "cf", "a domain's provider covers its subdomains");
check(providerFor(pd, "other.tld") === "any", "…and a provider for any domain takes the rest");
check(providerFor({ ...doc, providers: {} }, "x.tld") === null, "…none: no provider");
const pc = parseCredential("provider=cloudflare\ndns_cf_token=abc # the token\n\ndns_cf_account_id = 42\n");
check("fields" in pc && pc.fields.dns_cf_token === "abc" && pc.fields.dns_cf_account_id === "42", "the legacy file's lines are a credential, comments and its provider line dropped");
check("error" in parseCredential("token=abc\n") && "error" in parseCredential("dns_cf_token=\n") && "error" in parseCredential(""), "a field not named dns_…, an empty value, or nothing at all is refused");
check(refidFromSetup("signed\n  status: 200\n  refid: 6ae9abc\n") === "6ae9abc" && refidFromSetup("nothing") === null, "the refid acme-manager setup prints");

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
