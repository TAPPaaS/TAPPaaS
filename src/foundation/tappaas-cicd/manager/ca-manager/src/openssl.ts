// openssl.ts — the one place ca-manager runs openssl (ADR-043 D1, D2, D9).
// Keys are EC P-256: every client in O2's test takes them. A file is written
// next to its target and renamed over it, so a renewal never leaves a key and a
// certificate that do not belong together.

import { existsSync, readFileSync } from "fs";
import { dirname, join } from "path";
import { chmodGuarded, mkdirGuarded, renameGuarded, rmGuarded, writeFileGuarded } from "../../../lib/ts/src/config-io";
import { spawnGuarded } from "../../../lib/ts/src/exec";
import { constraintExt } from "./ca";

function openssl(args: string[]): string {
  const r = spawnGuarded("openssl", args, { encoding: "utf8" });
  if (r.error) throw new Error(`openssl: ${r.error.message}`);
  if (r.status !== 0) {
    const last = (r.stderr ?? "").trim().split("\n").slice(-1)[0] || `exit ${r.status}`;
    throw new Error(`openssl ${args[0]}: ${last}`);
  }
  return r.stdout ?? "";
}

function serial(): string {
  return `0x${openssl(["rand", "-hex", "16"]).trim()}`;
}

// A scratch dir beside `file`, removed after `fn`.
function beside<T>(file: string, fn: (dir: string) => T): T {
  const dir = join(dirname(file), `.tmp-${process.pid}-${Date.now()}`);
  mkdirGuarded(dir);
  chmodGuarded(dir, 0o700);
  try {
    return fn(dir);
  } finally {
    rmGuarded(dir, { recursive: true, force: true });
  }
}

function newKey(path: string): void {
  openssl(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", path]);
  chmodGuarded(path, 0o600);
}

// A self-signed root: a CA, allowed to sign certificates only, for the names
// `permitted` and their subdomains.
export function makeCa(keyFile: string, certFile: string, cn: string, permitted: string[], days: number): void {
  if (existsSync(keyFile) || existsSync(certFile)) throw new Error(`${keyFile} or ${certFile} exists: a CA is never overwritten`);
  beside(keyFile, (dir) => {
    const key = join(dir, "key");
    const cert = join(dir, "cert");
    newKey(key);
    openssl([
      "req", "-x509", "-new", "-key", key, "-out", cert, "-days", String(days), "-set_serial", serial(),
      "-subj", `/O=TAPPaaS/CN=${cn}`,
      "-addext", "basicConstraints=critical,CA:TRUE",
      "-addext", "keyUsage=critical,keyCertSign,cRLSign",
      "-addext", "subjectKeyIdentifier=hash",
      "-addext", constraintExt(permitted),
    ]);
    renameGuarded(key, keyFile);
    renameGuarded(cert, certFile);
  });
}

// A server (and client) certificate for `names`, signed by the CA, written as
// its key and its chain (the certificate, then the CA's).
export function issue(caKey: string, caCert: string, keyFile: string, chainFile: string, names: string[], days: number): string {
  return beside(keyFile, (dir) => {
    const key = join(dir, "key");
    const csr = join(dir, "csr");
    const ext = join(dir, "ext");
    const cert = join(dir, "cert");
    newKey(key);
    openssl(["req", "-new", "-key", key, "-out", csr, "-subj", `/CN=${names[0]}`]);
    writeFileGuarded(
      ext,
      [
        `subjectAltName=${names.map((n) => `DNS:${n}`).join(",")}`,
        "basicConstraints=critical,CA:FALSE",
        "keyUsage=critical,digitalSignature",
        "extendedKeyUsage=serverAuth,clientAuth",
        "authorityKeyIdentifier=keyid",
        "",
      ].join("\n"),
      "utf8",
    );
    openssl(["x509", "-req", "-in", csr, "-CA", caCert, "-CAkey", caKey, "-set_serial", serial(), "-days", String(days), "-extfile", ext, "-out", cert]);
    // The CA's constraint is the last word: a name it does not permit fails here.
    openssl(["verify", "-CAfile", caCert, cert]);
    const chain = join(dir, "chain");
    const pem = readFileSync(cert, "utf8");
    writeFileGuarded(chain, pem.trim() + "\n" + readFileSync(caCert, "utf8").trim() + "\n", "utf8");
    chmodGuarded(chain, 0o644);
    renameGuarded(key, keyFile);
    renameGuarded(chain, chainFile);
    return pem;
  });
}
