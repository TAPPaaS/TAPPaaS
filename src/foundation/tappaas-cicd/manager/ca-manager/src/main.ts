// ca-manager — the site's certificate authorities and the certificates they
// issue (ADR-043). Owns config/certificates.json and config/site-ca.pem; the
// keys are in its key dir, never in config/.
//
// One internal CA on every site (`init`), one CA per domain tree with no public
// certificates (`domain add`), and the certificates they sign (`cert issue`,
// `cert renew`). Every changing verb takes --check: it says what it would do and
// writes nothing.
//
// Exit codes: ok=0, error=1.

import { join } from "path";
import { CL, GN, YW, die, guarded, info, requireOperator, warn } from "../../../lib/ts/src/cli";
import { HelpSpec, checkArgs, renderHelp } from "../../../lib/ts/src/help";
import { defaultConfigDir, readJsonObject, simulating } from "../../../lib/ts/src/config-io";
import {
  CA_DAYS,
  CERT_DAYS,
  CaDoc,
  CertRecord,
  INTERNAL_ID,
  INTERNAL_NAME,
  RENEW_DAYS,
  certProblem,
  daysLeft,
  domainNeed,
  dueForRenewal,
  signerFor,
} from "./ca";
import { issue, makeCa } from "./openssl";
import { Store, certInfo } from "./store";
import { existsSync, readFileSync } from "fs";

const VERSION = "0.1.0";

export const HELP: HelpSpec = {
  name: "ca-manager",
  version: VERSION,
  tagline: "TAPPaaS site certificates — the internal CA, a CA per local domain tree, and what they issue (ADR-043)",
  verbs: [
    { usage: "status [--json]", effect: "read", options: [["--json", "status: the record as JSON, with days left."]] },
    { usage: "validate", note: "(the record against the key dir and the trust bundle)" },
    {
      usage: "init [--check]",
      options: [["--check", "Say what it would make; change nothing."]],
      details:
        "Makes the site's internal CA, which may sign names under `internal` and nothing else, and\n" +
        "writes the trust bundle config/site-ca.pem. Runs once, in the install; a second run changes\n" +
        "nothing.",
    },
    {
      usage: "domain add <domain> [--check]",
      options: [["--check", "Say what it would make; change nothing."]],
      details:
        "Makes a CA for <domain> and its subdomains, for a domain with no public certificates. A domain\n" +
        "an existing domain CA already covers needs none, and is told so.",
    },
    {
      usage: "cert issue <name> --dns <n>[,<n>…] [--check]",
      name: "cert issue",
      options: [
        ["--dns N", "The names, comma-separated (a wildcard is *.<domain>)."],
        ["--check", "Say which CA would sign it; change nothing."],
      ],
      details: "Signs a certificate for the names, by the one CA whose constraint covers them all, and keeps\nits key in the key dir. <name> is how ca-manager knows it.",
    },
    {
      usage: "cert renew [<name>] [--within <days>] [--force] [--check]",
      name: "cert renew",
      options: [
        ["--within D", `Renew what expires within D days (default ${RENEW_DAYS}).`],
        ["--force", "Renew now, whatever its expiry."],
        ["--check", "List what it would renew; change nothing."],
      ],
    },
  ],
  common: [["--json", "Machine-readable output (status)."]],
  notes: [
    "Keys are in TAPPAAS_CA_DIR (default /home/tappaas/.tappaas-ca), mode 700, never in config/.",
    "Every CA carries a name constraint: a CA's key, if stolen, can sign nothing outside its names.",
  ],
};

function opt(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}
function positional(args: string[], skip: number, valued: string[]): string[] {
  const out: string[] = [];
  for (let i = skip; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      if (valued.includes(args[i])) i++;
      continue;
    }
    out.push(args[i]);
  }
  return out;
}

function siteName(configDir: string): string {
  const site = readJsonObject(join(configDir, "site.json"));
  const n = site && typeof site.name === "string" ? site.name : "";
  return n || "site";
}

const CERT_NAME = /^[a-z0-9][a-z0-9.-]{0,120}$/;

function stamp(): string {
  return new Date().toISOString();
}

function now(): Date {
  const fixed = process.env.CA_MANAGER_NOW;
  return fixed ? new Date(fixed) : new Date();
}

// The CA made, recorded, and the bundle rewritten.
function createCa(store: Store, doc: CaDoc, id: string, scope: "internal" | "domain", permitted: string[], cn: string): void {
  store.ensureKeyDir();
  makeCa(store.caKey(id), store.caCert(id), cn, permitted, CA_DAYS);
  const ci = certInfo(readFileSync(store.caCert(id), "utf8"));
  doc.cas[id] = { scope, permitted, subject: ci.subject, fingerprint: ci.fingerprint, notBefore: ci.notBefore, notAfter: ci.notAfter, state: "active", created: stamp() };
  store.save(doc);
  store.writeBundle(doc);
}

function signCert(store: Store, doc: CaDoc, name: string, names: string[], ca: string): CertRecord {
  store.ensureKeyDir();
  const pem = issue(store.caKey(ca), store.caCert(ca), store.certKey(name), store.certChain(name), names, CERT_DAYS);
  const ci = certInfo(pem);
  const rec: CertRecord = { ca, names, fingerprint: ci.fingerprint, notBefore: ci.notBefore, notAfter: ci.notAfter, issued: stamp() };
  doc.certificates[name] = rec;
  store.save(doc);
  return rec;
}

function init(store: Store, check: boolean): number {
  const doc = store.load();
  if (doc.cas[INTERNAL_ID]) {
    info(`${GN}✓${CL} the internal CA exists (${doc.cas[INTERNAL_ID].subject})`);
    if (!check && store.writeBundle(doc)) info(`  wrote ${store.bundleFile}`);
    return 0;
  }
  const cn = `TAPPaaS ${siteName(store.configDir)} internal CA`;
  if (check || simulating()) {
    info(`would make ${cn}, for names under ${INTERNAL_NAME}, and write ${store.bundleFile}`);
    return 0;
  }
  createCa(store, doc, INTERNAL_ID, "internal", [INTERNAL_NAME], cn);
  info(`${GN}✓${CL} made ${cn}, for names under ${INTERNAL_NAME}`);
  info(`  its key: ${store.caKey(INTERNAL_ID)} — escrow it with the backup keys`);
  return 0;
}

function domainAdd(store: Store, domain: string, check: boolean): number {
  const doc = store.load();
  const need = domainNeed(doc, domain);
  if (need.kind === "refused") die(need.why);
  if (need.kind === "covered") {
    info(`${GN}✓${CL} ${domain} needs no CA of its own: ${need.by} covers it`);
    return 0;
  }
  const cn = `TAPPaaS ${domain} CA`;
  if (check || simulating()) {
    info(`would make ${cn}, for ${domain} and its subdomains`);
    return 0;
  }
  createCa(store, doc, need.id, "domain", [domain], cn);
  info(`${GN}✓${CL} made ${cn}, for ${domain} and its subdomains`);
  info(`  people using ${domain} import ${store.caCert(need.id)} into their browsers`);
  return 0;
}

function certIssue(store: Store, name: string, names: string[], check: boolean): number {
  if (!CERT_NAME.test(name)) die(`${name}: a certificate's name is lower-case letters, digits, dots and dashes`);
  const doc = store.load();
  if (doc.certificates[name]) die(`a certificate ${name} exists: renew it (cert renew ${name} --force), or pick another name`);
  const problem = certProblem(doc, names);
  if (problem) die(problem);
  const ca = signerFor(doc, names)!;
  if (check || simulating()) {
    info(`would sign ${name} (${names.join(", ")}) by ${ca}, for ${CERT_DAYS} days`);
    return 0;
  }
  const rec = signCert(store, doc, name, names, ca);
  info(`${GN}✓${CL} ${name}: ${names.join(", ")}, signed by ${ca}, until ${rec.notAfter.slice(0, 10)}`);
  return 0;
}

function certRenew(store: Store, only: string | undefined, within: number, force: boolean, check: boolean): number {
  const doc = store.load();
  if (only && !doc.certificates[only]) die(`no certificate ${only} (ca-manager status)`);
  const t = now();
  const due = Object.entries(doc.certificates).filter(([n, c]) => (!only || n === only) && (force || dueForRenewal(c, t, within)));
  if (due.length === 0) {
    info(`${GN}✓${CL} nothing to renew: no certificate expires within ${within} days`);
    return 0;
  }
  let failed = 0;
  for (const [n, c] of due) {
    const ca = signerFor(doc, c.names);
    if (!ca) {
      warn(`${n}: no active CA covers ${c.names.join(", ")} — not renewed`);
      failed++;
      continue;
    }
    if (check || simulating()) {
      info(`would renew ${n} (${daysLeft(c.notAfter, t)} days left) by ${ca}`);
      continue;
    }
    const rec = signCert(store, doc, n, c.names, ca);
    info(`${GN}✓${CL} renewed ${n}, until ${rec.notAfter.slice(0, 10)}`);
  }
  return failed ? 1 : 0;
}

function status(store: Store, json: boolean): number {
  const doc = store.load();
  const t = now();
  if (json) {
    const withDays = {
      ...doc,
      cas: Object.fromEntries(Object.entries(doc.cas).map(([k, v]) => [k, { ...v, daysLeft: daysLeft(v.notAfter, t) }])),
      certificates: Object.fromEntries(Object.entries(doc.certificates).map(([k, v]) => [k, { ...v, daysLeft: daysLeft(v.notAfter, t), due: dueForRenewal(v, t) }])),
    };
    process.stdout.write(JSON.stringify(withDays, null, 1) + "\n");
    return 0;
  }
  if (Object.keys(doc.cas).length === 0) {
    info(`${YW}no CA yet${CL}: ca-manager init`);
    return 0;
  }
  info("CAs:");
  for (const [id, ca] of Object.entries(doc.cas)) info(`  ${id.padEnd(28)} ${ca.state.padEnd(8)} ${ca.permitted.join(", ").padEnd(24)} until ${ca.notAfter.slice(0, 10)} (${daysLeft(ca.notAfter, t)} days)`);
  const certs = Object.entries(doc.certificates);
  info(certs.length ? "Certificates:" : "Certificates: none yet");
  for (const [n, c] of certs) {
    const left = daysLeft(c.notAfter, t);
    const mark = left < 0 ? `${YW}expired${CL}` : dueForRenewal(c, t) ? `${YW}due${CL}` : "ok";
    info(`  ${n.padEnd(28)} ${mark.padEnd(8)} ${c.names.join(", ")}  by ${c.ca}, until ${c.notAfter.slice(0, 10)} (${left} days)`);
  }
  return 0;
}

function validate(store: Store): number {
  let doc: CaDoc;
  try {
    doc = store.load();
  } catch (e) {
    die((e as Error).message);
  }
  const problems: string[] = [];
  for (const [id, ca] of Object.entries(doc.cas)) {
    const k = store.keyModeProblem(store.caKey(id));
    if (k) problems.push(`CA ${id}: ${k}`);
    if (!existsSync(store.caCert(id))) problems.push(`CA ${id}: ${store.caCert(id)} is missing`);
    else if (certInfo(readFileSync(store.caCert(id), "utf8")).fingerprint !== ca.fingerprint) problems.push(`CA ${id}: its certificate is not the one recorded`);
  }
  for (const [n, c] of Object.entries(doc.certificates)) {
    const k = store.keyModeProblem(store.certKey(n));
    if (k) problems.push(`certificate ${n}: ${k}`);
    if (!existsSync(store.certChain(n))) problems.push(`certificate ${n}: ${store.certChain(n)} is missing`);
    else if (certInfo(readFileSync(store.certChain(n), "utf8")).fingerprint !== c.fingerprint) problems.push(`certificate ${n}: its file is not the one recorded`);
  }
  if (Object.keys(doc.cas).length && !problems.length) {
    const want = store.bundleText(doc);
    const have = existsSync(store.bundleFile) ? readFileSync(store.bundleFile, "utf8") : "";
    if (have !== want) problems.push(`${store.bundleFile} does not hold exactly the recorded CAs: ca-manager init rewrites it`);
  }
  for (const p of problems) console.error(`\x1b[01;31m[Error]\x1b[0m ${p}`);
  if (problems.length) return 1;
  info(`${GN}✓${CL} ${store.recordFile} valid (${Object.keys(doc.cas).length} CA(s), ${Object.keys(doc.certificates).length} certificate(s))`);
  return 0;
}

export function run(argv: string[]): number {
  const args = argv;
  if (args.length === 0 || args[0] === "help" || ((args[0] === "--help" || args[0] === "-h") && !args.includes("--json"))) {
    info(renderHelp(HELP));
    return 0;
  }
  if (args[0] === "--version" || args[0] === "version") {
    info(`ca-manager ${VERSION}`);
    return 0;
  }
  const rc = checkArgs(HELP, args);
  if (rc !== undefined) return rc;
  const store = new Store(defaultConfigDir(), process.env.TAPPAAS_CA_DIR ?? "/home/tappaas/.tappaas-ca");
  const check = args.includes("--check");

  if (args[0] === "status") return status(store, args.includes("--json"));
  if (args[0] === "validate") return validate(store);
  requireOperator();
  if (args[0] === "init") return init(store, check);
  if (args[0] === "domain" && args[1] === "add") {
    const [domain] = positional(args, 2, []);
    if (!domain) die("domain add <domain>");
    return domainAdd(store, domain, check);
  }
  if (args[0] === "cert" && args[1] === "issue") {
    const [name] = positional(args, 2, ["--dns"]);
    const dns = opt(args, "--dns");
    if (!name || !dns) die("cert issue <name> --dns <n>[,<n>…]");
    return certIssue(store, name, dns.split(",").map((s) => s.trim()).filter(Boolean), check);
  }
  if (args[0] === "cert" && args[1] === "renew") {
    const [name] = positional(args, 2, ["--within"]);
    const w = opt(args, "--within");
    const within = w === undefined ? RENEW_DAYS : Number(w);
    if (!Number.isInteger(within) || within < 0) die("--within <days>: a whole number of days");
    return certRenew(store, name, within, args.includes("--force"), check);
  }
  die(`unknown verb '${args.slice(0, 2).join(" ")}' — see 'ca-manager --help'`);
}

if (require.main === module) {
  process.exit(guarded(() => run(process.argv.slice(2))));
}
