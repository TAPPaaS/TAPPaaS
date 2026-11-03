// cmdbreport.test.ts — what ca-manager reports to the CMDB (ADR-043 D11).

import { CaDoc } from "../../src/ca";
import { buildCaReport } from "../../src/cmdbreport";

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

const ca = (scope: "internal" | "domain", permitted: string[], fp: string) => ({
  scope, permitted, state: "active" as const, subject: "x", fingerprint: fp, notBefore: "2026-11-03T00:00:00Z", notAfter: "2036-11-01T00:00:00Z", created: "",
});
const doc: CaDoc = {
  version: 1,
  cas: { internal: ca("internal", ["internal"], "AA"), "domain-lab9.org": ca("domain", ["lab9.org"], "BB") },
  certificates: {
    "wildcard-mgmt": { ca: "domain-lab9.org", names: ["*.lab9.org", "lab9.org"], fingerprint: "CC", notBefore: "", notAfter: "2027-11-03T00:00:00Z", issued: "", refid: "abc123" },
    logging: { ca: "internal", names: ["logging.mgmt.internal"], fingerprint: "DD", notBefore: "", notAfter: "2027-11-03T00:00:00Z", issued: "" },
  },
};
const r = buildCaReport(doc, "tappaas-cicd", [{ name: "mgmt", domain: "lab9.org" }, { name: "test", domain: "test.lab9.org" }, { name: "other", domain: "other.org" }]).report();

const cas = (r.objects ?? []).filter((o) => o.class === "certificate-authority");
check(cas.length === 2, "each CA is a CI");
const dom = cas.find((o) => o.name === "domain-lab9.org")!;
check(dom.ref === "certificate-authority:domain-lab9.org/BB", "its fingerprint is in its ref: a replaced CA is another CI");
check(JSON.stringify(dom.attributes?.onNode) === '{"class":"vm","name":"tappaas-cicd"}', "it runs on the mothership");
check((dom.attributes?.certificates as { refid?: string }[])[0].refid === "abc123", "what it issued rides on it, with the refid the firewall serves");
const serves = (r.relations ?? []).filter((x) => x.type === "serves").map((x) => (x.to as { name: string }).name).sort();
check(JSON.stringify(serves) === '["mgmt","test"]', "a domain CA serves the environments in its tree, a subdomain's included");
check(!(r.relations ?? []).some((x) => x.from === "certificate-authority:internal/AA"), "the internal CA serves no environment");
check(!JSON.stringify(r).includes("PRIVATE"), "no key in the report");

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
