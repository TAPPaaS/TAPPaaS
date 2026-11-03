// cmdbreport.ts — what ca-manager reports to the CMDB (ADR-043 D11): each CA as
// a certificate-authority CI, on the mothership that holds its key, and a domain
// CA serving every environment whose domain lies in its tree. What a CA issued
// rides on it as an attribute. Never a key, nor anything derived from one but
// the certificate's public fingerprint.

import { CmdbBatch } from "../../../lib/ts/src/cmdb-reporter";
import { CaDoc, within } from "./ca";

export const SOURCE = "ca-manager";

export interface EnvDomain {
  name: string;
  domain: string;
}

export function buildCaReport(doc: CaDoc, mothership: string, envs: EnvDomain[]): CmdbBatch {
  const b = new CmdbBatch(SOURCE);
  for (const [id, ca] of Object.entries(doc.cas)) {
    const issued = Object.entries(doc.certificates)
      .filter(([, c]) => c.ca === id)
      .map(([name, c]) => ({ name, names: c.names, notAfter: c.notAfter, ...(c.refid ? { refid: c.refid } : {}) }));
    const ref = b.put("certificate-authority", id, {
      fingerprint: ca.fingerprint,
      scope: ca.scope,
      permitted: ca.permitted,
      notBefore: ca.notBefore,
      notAfter: ca.notAfter,
      state: ca.state,
      escrowed: "",
      certificates: issued,
      onNode: { class: "vm", name: mothership },
      desired: { file: "certificates.json", key: `cas.${id}` },
    }, `certificate-authority:${id}/${ca.fingerprint}`);
    if (ca.scope !== "domain") continue;
    for (const e of envs) {
      if (ca.permitted.some((p) => within(e.domain, p))) b.relate("serves", ref, { class: "environment", name: e.name });
    }
  }
  return b;
}
