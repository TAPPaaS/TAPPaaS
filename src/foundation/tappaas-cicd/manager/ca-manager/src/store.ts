// store.ts — where ca-manager keeps what it knows (ADR-043 D3, D8).
//
//   config/certificates.json   the record: each CA and each certificate, with
//                              fingerprints and validity — never a key
//   config/site-ca.pem         the trust bundle every guest and node reads
//   <key dir>/ca/<id>.key|pem  each CA's key and certificate
//   <key dir>/certs/<n>.key|pem each issued certificate's key, and its chain
//
// The key dir is outside config/ and mode 700 (TAPPAAS_CA_DIR, default
// ~tappaas/.tappaas-ca): config/ is read widely, and its history is kept.

import { X509Certificate } from "crypto";
import { existsSync, readFileSync, statSync } from "fs";
import { join } from "path";
import { chmodGuarded, mkdirGuarded, renameGuarded, writeFileGuarded, writeJsonAtomic } from "../../../lib/ts/src/config-io";
import { CaDoc, bundleOrder, docProblems, emptyDoc } from "./ca";

export const RECORD = "certificates.json";
export const BUNDLE = "site-ca.pem";

export interface CertInfo {
  fingerprint: string;
  notBefore: string;
  notAfter: string;
  subject: string;
  names: string[];
  ca: boolean;
}

// What a PEM certificate says of itself, through Node's own parser.
export function certInfo(pem: string): CertInfo {
  const x = new X509Certificate(pem);
  const names = (x.subjectAltName ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.startsWith("DNS:"))
    .map((s) => s.slice(4));
  return {
    fingerprint: x.fingerprint256,
    notBefore: new Date(x.validFrom).toISOString(),
    notAfter: new Date(x.validTo).toISOString(),
    subject: x.subject.replace(/\n/g, ", "),
    names,
    ca: x.ca,
  };
}

export class Store {
  constructor(
    readonly configDir: string,
    readonly keyDir: string,
  ) {}

  get recordFile(): string {
    return join(this.configDir, RECORD);
  }
  get bundleFile(): string {
    return join(this.configDir, BUNDLE);
  }
  caKey(id: string): string {
    return join(this.keyDir, "ca", `${id}.key`);
  }
  caCert(id: string): string {
    return join(this.keyDir, "ca", `${id}.pem`);
  }
  certKey(name: string): string {
    return join(this.keyDir, "certs", `${name}.key`);
  }
  certChain(name: string): string {
    return join(this.keyDir, "certs", `${name}.pem`);
  }
  providerSecret(name: string): string {
    return join(this.keyDir, "providers", `${name}.env`);
  }

  load(): CaDoc {
    if (!existsSync(this.recordFile)) return emptyDoc();
    const raw: unknown = JSON.parse(readFileSync(this.recordFile, "utf8"));
    const problems = docProblems(raw);
    if (problems.length) throw new Error(`${this.recordFile}: ${problems.join("; ")}`);
    return raw as CaDoc;
  }

  save(doc: CaDoc): void {
    writeJsonAtomic(this.recordFile, doc);
  }

  // The key dir, and its two subdirectories, mode 700.
  ensureKeyDir(): void {
    for (const d of [this.keyDir, join(this.keyDir, "ca"), join(this.keyDir, "certs"), join(this.keyDir, "providers")]) {
      mkdirGuarded(d, { recursive: true });
      chmodGuarded(d, 0o700);
    }
  }

  // Certificates in the bundle on disk that no recorded CA is: a CA put there by
  // hand, which a rewrite would take away from every guest.
  foreignInBundle(doc: CaDoc): string[] {
    if (!existsSync(this.bundleFile)) return [];
    const ours = new Set(Object.values(doc.cas).map((c) => c.fingerprint));
    const pems = readFileSync(this.bundleFile, "utf8").match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) ?? [];
    return pems.map((p) => certInfo(p)).filter((c) => !ours.has(c.fingerprint)).map((c) => c.subject);
  }

  // The bundle from the CAs' own files, written only when it differs. A bundle
  // holding a CA ca-manager did not make is left as it is unless `replace`.
  writeBundle(doc: CaDoc, replace = false): boolean {
    const text = this.bundleText(doc);
    if (existsSync(this.bundleFile) && readFileSync(this.bundleFile, "utf8") === text) return false;
    const foreign = replace ? [] : this.foreignInBundle(doc);
    if (foreign.length) throw new Error(`${this.bundleFile} holds CAs ca-manager did not make (${foreign.join("; ")}): rewriting it would take them from every guest. Replace them first, or pass --replace-bundle`);
    const tmp = `${this.bundleFile}.tmp`;
    writeFileGuarded(tmp, text, "utf8");
    chmodGuarded(tmp, 0o644);
    renameGuarded(tmp, this.bundleFile);
    return true;
  }

  bundleText(doc: CaDoc): string {
    return bundleOrder(doc)
      .map((id) => readFileSync(this.caCert(id), "utf8").trim() + "\n")
      .join("");
  }

  // A key file that anyone but its owner may read is a finding.
  keyModeProblem(file: string): string | null {
    if (!existsSync(file)) return `${file} is missing`;
    return (statSync(file).mode & 0o077) === 0 ? null : `${file} is readable by others than its owner`;
  }
}
