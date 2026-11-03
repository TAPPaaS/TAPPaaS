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
import { defaultConfigDir, readJsonObject, simulating, writeJsonAtomic } from "../../../lib/ts/src/config-io";
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
  parseCredential,
  providerFor,
  refidFromSetup,
  wildcardName,
  wildcardNames,
} from "./ca";
import { issue, makeCa } from "./openssl";
import { Store, certInfo } from "./store";
import { EnvDomain, buildCaReport } from "./cmdbreport";
import { printOrSend, reportChange } from "../../../lib/ts/src/cmdb-reporter";
import { readdirSync } from "fs";
import { chmodSync, existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "fs";
import { hostname } from "os";
import { spawnSync } from "child_process";

const VERSION = "0.1.0";

export const HELP: HelpSpec = {
  name: "ca-manager",
  version: VERSION,
  tagline: "TAPPaaS site certificates — the internal CA, a CA per local domain tree, and what they issue (ADR-043)",
  verbs: [
    { usage: "status [--json]", effect: "read", options: [["--json", "status: the record as JSON, with days left."]] },
    { usage: "validate", note: "(the record against the key dir and the trust bundle)" },
    {
      usage: "report [--json] [--discover]",
      name: "report (to the CMDB, ADR-040)",
      effect: "read",
      options: [
        ["--json", "report: print it instead of sending it."],
        ["--discover", "report: accepted for the CMDB's sweep (ADR-040 D15); the report is already its full depth."],
      ],
      details: "Sends each CA as a certificate-authority CI (ADR-043 D11): on this mothership, serving the\nenvironments in its tree, with what it issued. Never a key.",
    },
    {
      usage: "init [--replace-bundle] [--no-rebuild] [--check]",
      options: [
        ["--replace-bundle", "Rewrite config/site-ca.pem even when it holds CAs ca-manager did not make."],
        ["--no-rebuild", "Leave the mothership's own trust to its next rebuild (the install and the update rebuild anyway)."],
        ["--check", "Say what it would make; change nothing."],
      ],
      details:
        "Makes the site's internal CA, which may sign names under `internal` and nothing else, and\n" +
        "writes the trust bundle config/site-ca.pem. Runs once, in the install; a second run changes\n" +
        "nothing.",
    },
    {
      usage: "domain add <domain> [--no-rebuild] [--check]",
      options: [
        ["--no-rebuild", "Leave the mothership's own trust to its next rebuild."],
        ["--check", "Say what it would make; change nothing."],
      ],
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
      usage: "wildcard <environment> --domain <domain> [--no-rebuild] [--check]",
      options: [
        ["--domain D", "The environment's primary domain."],
        ["--no-rebuild", "Leave the mothership's own trust to its next rebuild."],
        ["--check", "Say what it would make and import; change nothing."],
      ],
      details:
        "For an environment in dnsMode local: its domain's CA (made when no CA covers the domain yet), a\n" +
        "wildcard for *.<domain> and <domain> signed by it, both imported into the firewall's trust store\n" +
        "(the CA without its key), and the wildcard's refid written to config/cert-refids.json for Caddy.\n" +
        "Run again, it renews a wildcard that is due and re-imports it in place: the refid stays.\n" +
        "When the environment had another certificate, every route on it moves to the new one,\n" +
        "Caddy is reloaded, and the old one leaves the firewall once nothing serves it.",
    },
    {
      usage: "provider add <name> --type <t> [--domain <d>[,<d>…]] [--check]",
      name: "provider add",
      options: [
        ["--type T", "os-acme-client's provider: cloudflare, hetzner, desec, … or its dns_ key."],
        ["--domain D", "The domains it serves, each with its subdomains; none: any domain."],
        ["--check", "Check the credential's shape; change nothing."],
      ],
      details:
        "A DNS provider for ACME's DNS-01 (ADR-043 D6). Its credential comes on stdin as KEY=VALUE\n" +
        "lines named as acme.sh names them (dns_cf_token=…), never in an argument, and is kept in the\n" +
        "key dir; config/certificates.json records only its fields' names. Adding a name again replaces it.",
    },
    { usage: "provider list [--json]", name: "provider list", effect: "read", options: [["--json", "provider list: as JSON."]] },
    { usage: "provider for <domain>", name: "provider for", effect: "read", note: "(the provider a domain's ACME certificate uses; exit 1 when none)" },
    { usage: "provider remove <name>", name: "provider remove" },
    {
      usage: "acme <environment> --domain <domain> [--staging] [--dns-sleep <s>] [--check]",
      options: [
        ["--domain D", "The environment's primary domain."],
        ["--staging", "Let's Encrypt's staging CA (testing)."],
        ["--dns-sleep S", "Seconds for the TXT record to spread before validation (default 150)."],
        ["--check", "Say which provider it would use; change nothing."],
      ],
      details:
        "For an environment in dnsMode wildcard: a Let's Encrypt wildcard for *.<domain> and <domain>,\n" +
        "through os-acme-client on the firewall, with the domain's provider. Its refid goes to\n" +
        "config/cert-refids.json; routes on an older certificate move to it. The firewall renews it.",
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

// The environments and their primary domains, for which a domain CA serves.
function envDomains(configDir: string): EnvDomain[] {
  const dir = join(configDir, "environments");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => {
      const e = readJsonObject(join(dir, f));
      const d = e && typeof e.domains === "object" && e.domains ? (e.domains as Record<string, unknown>).primary : undefined;
      return { name: f.replace(/\.json$/, ""), domain: typeof d === "string" ? d : "" };
    })
    .filter((e) => e.domain);
}

function caReport(store: Store) {
  return buildCaReport(store.load(), hostname().split(".")[0], envDomains(store.configDir));
}

// A change is in the CMDB as it is made (ADR-040 D4); delivery never fails the verb.
function reportMade(store: Store, verb: string): void {
  const s = reportChange(caReport(store), verb);
  if (s.error) warn(`cmdb: change not recorded: ${s.error}`);
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
function createCa(store: Store, doc: CaDoc, id: string, scope: "internal" | "domain", permitted: string[], cn: string, replace = false): boolean {
  // Refuse before anything is made: a CA that could not join the bundle would
  // be recorded and trusted by nothing.
  const foreign = replace ? [] : store.foreignInBundle(doc);
  if (foreign.length) die(`${store.bundleFile} holds CAs ca-manager did not make (${foreign.join("; ")}): rewriting it would take them from every guest. Replace them first, or pass --replace-bundle to init`);
  store.ensureKeyDir();
  makeCa(store.caKey(id), store.caCert(id), cn, permitted, CA_DAYS);
  const ci = certInfo(readFileSync(store.caCert(id), "utf8"));
  doc.cas[id] = { scope, permitted, subject: ci.subject, fingerprint: ci.fingerprint, notBefore: ci.notBefore, notAfter: ci.notAfter, state: "active", created: stamp() };
  store.save(doc);
  return store.writeBundle(doc, replace);
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

function init(store: Store, check: boolean, replace: boolean, rebuild: boolean): number {
  const doc = store.load();
  if (doc.cas[INTERNAL_ID]) {
    info(`${GN}✓${CL} the internal CA exists (${doc.cas[INTERNAL_ID].subject})`);
    if (!check && !simulating()) {
      try {
        if (store.writeBundle(doc, replace)) {
          info(`  wrote ${store.bundleFile}`);
          if (rebuild) refreshOwnTrust();
        }
      } catch (e) {
        die((e as Error).message);
      }
    }
    return 0;
  }
  const cn = `TAPPaaS ${siteName(store.configDir)} internal CA`;
  if (check || simulating()) {
    info(`would make ${cn}, for names under ${INTERNAL_NAME}, and write ${store.bundleFile}`);
    return 0;
  }
  const changed = createCa(store, doc, INTERNAL_ID, "internal", [INTERNAL_NAME], cn, replace);
  info(`${GN}✓${CL} made ${cn}, for names under ${INTERNAL_NAME}`);
  info(`  its key: ${store.caKey(INTERNAL_ID)} — escrow it with the backup keys`);
  if (changed && rebuild) refreshOwnTrust();
  return 0;
}

function domainAdd(store: Store, domain: string, check: boolean, rebuild: boolean): number {
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
  const changed = createCa(store, doc, need.id, "domain", [domain], cn);
  info(`${GN}✓${CL} made ${cn}, for ${domain} and its subdomains`);
  info(`  people using ${domain} import ${store.caCert(need.id)} into their browsers`);
  if (changed && rebuild) refreshOwnTrust();
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

const FIREWALL = process.env.OPNSENSE_HOST ?? "firewall.mgmt.internal";

// The mothership's own trust follows the bundle only when it rebuilds (D8): its
// checks and the modules' tests call the site's names with it. So a bundle that
// changed is followed by its rebuild, which renders tappaas-site.nix first.
// polkit lets the operator start the unit; nothing here needs root.
function refreshOwnTrust(): void {
  const cmd = process.env.CA_MANAGER_REBUILD ?? "systemctl";
  const unit = `tappaas-rebuild@${hostname().split(".")[0]}.service`;
  info(`  the site's CAs changed: rebuilding this mothership so its own trust follows (${unit})…`);
  const r = spawnSync(cmd, ["start", "--wait", unit], { encoding: "utf8" });
  if (r.status === 0) info(`${GN}✓${CL} this mothership trusts the site's CAs`);
  else warn(`the mothership was not rebuilt (${(r.stderr ?? "").trim() || r.error?.message || `exit ${r.status}`}): until it is, its calls to the new CA's names fail — systemctl start --wait ${unit}`);
}

function caddyReload(): void {
  const reload = spawnSync("ssh", ["-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", `root@${FIREWALL}`, "configctl caddy reload"], { encoding: "utf8" });
  if (reload.status !== 0) warn(`Caddy was not reloaded (${(reload.stderr ?? "").trim() || `exit ${reload.status}`}): it serves the old certificate until it is`);
}

// trust-manager <verb> …: the refid it prints last, and whether it changed the store.
function trustManager(args: string[], input?: string): { refid: string; changed: boolean } {
  // The firewall's API certificate is self-signed, as every other caller of its API
  // assumes (acme-manager, caddy-manager): until it comes from the internal CA.
  const r = spawnSync("trust-manager", ["--no-ssl-verify", ...args], { encoding: "utf8", ...(input !== undefined ? { input } : {}) });
  if (r.error) throw new Error(`trust-manager: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`trust-manager ${args[0]}: ${(r.stderr ?? "").trim().split("\n").slice(-1)[0] || `exit ${r.status}`}`);
  const refid = (r.stdout ?? "").trim().split("\n").slice(-1)[0] ?? "";
  if (!/^[0-9a-f]{8,}$/.test(refid)) throw new Error(`trust-manager ${args[0]}: no refid in its answer`);
  return { refid, changed: /^(imported|updated):/m.test(r.stderr ?? "") };
}

// The certificate on the firewall, with the CA that signed it (D7): returns its
// refid. Caddy caches what it serves, so a certificate replaced in place is
// followed by a reload of Caddy.
function pushToFirewall(store: Store, doc: CaDoc, name: string): string {
  const rec = doc.certificates[name];
  const trust = rec.trust ?? `TAPPaaS: ${name}`;
  trustManager(["ca-ensure", "--name", `TAPPaaS: ${rec.ca}`, "--pem-file", store.caCert(rec.ca)]);
  const r = trustManager(["cert-ensure", "--name", trust, "--pem-file", store.certChain(name), "--key-stdin"], readFileSync(store.certKey(name), "utf8"));
  if (r.changed && rec.refid === r.refid) caddyReload();
  rec.trust = trust;
  rec.refid = r.refid;
  store.save(doc);
  return r.refid;
}

function moveOff(old: string, refid: string): void {
  const rb = spawnSync("caddy-manager", ["--no-ssl-verify", "rebind-certificate", "--from", old, "--to", refid], { encoding: "utf8" });
  if (rb.status !== 0) {
    warn(`the routes on ${old} were not moved to ${refid} (${(rb.stderr ?? "").trim().split("\n").slice(-1)[0] || `exit ${rb.status}`}): caddy-manager rebind-certificate --from ${old} --to ${refid}`);
    return;
  }
  const moved = (rb.stdout ?? "").split("\n").filter((l) => l.startsWith("moved: ")).map((l) => l.slice(7));
  if (moved.length) info(`${GN}✓${CL} moved ${moved.length} route(s) onto it: ${moved.join(", ")}`);
  caddyReload();
  const rt = spawnSync("trust-manager", ["--no-ssl-verify", "cert-retire", "--refid", old], { encoding: "utf8" });
  if (rt.status !== 0) warn(`the old certificate ${old} stays on the firewall: ${(rt.stderr ?? "").trim().split("\n").slice(-1)[0] || `exit ${rt.status}`}`);
  else for (const l of (rt.stdout ?? "").split("\n").filter((x) => x.startsWith("removed: "))) info(`  ${l}`);
}

function recordRefid(store: Store, env: string, refid: string): void {
  const file = join(store.configDir, "cert-refids.json");
  const cur = readJsonObject(file) ?? {};
  if (cur[env] === refid) return;
  writeJsonAtomic(file, { ...cur, [env]: refid });
}

function wildcard(store: Store, env: string, domain: string, check: boolean, rebuild: boolean): number {
  if (!CERT_NAME.test(env)) die(`${env}: not an environment name`);
  const doc = store.load();
  const need = domainNeed(doc, domain);
  if (need.kind === "refused") die(need.why);
  const name = wildcardName(env);
  const names = wildcardNames(domain);
  const have = doc.certificates[name];
  const reissue = !have || have.names.join(",") !== names.join(",");
  const renew = !reissue && dueForRenewal(have, now());
  if (check || simulating()) {
    if (need.kind === "new") info(`would make TAPPaaS ${domain} CA, for ${domain} and its subdomains`);
    info(reissue ? `would sign ${name} (${names.join(", ")})` : renew ? `would renew ${name}` : `${name} is current`);
    info(`would import the CA and ${name} into the firewall's trust store and record the refid for ${env}`);
    return 0;
  }
  let bundleChanged = false;
  if (need.kind === "new") {
    bundleChanged = createCa(store, doc, need.id, "domain", [domain], `TAPPaaS ${domain} CA`);
    info(`${GN}✓${CL} made TAPPaaS ${domain} CA — people using ${domain} import ${store.caCert(need.id)}`);
  }
  // The mothership trusts the new CA before anything calls a name it signs.
  if (bundleChanged && rebuild) refreshOwnTrust();
  const ca = signerFor(doc, names);
  if (!ca) die(`no active CA covers ${names.join(", ")}`);
  if (reissue || renew) {
    const keep = have ? { trust: have.trust, refid: have.refid } : {};
    const rec = signCert(store, doc, name, names, ca);
    Object.assign(rec, keep);
    store.save(doc);
    info(`${GN}✓${CL} ${reissue ? "signed" : "renewed"} ${name}: ${names.join(", ")}, until ${rec.notAfter.slice(0, 10)}`);
  }
  let refid: string;
  try {
    refid = pushToFirewall(store, doc, name);
  } catch (e) {
    die(`${name} could not be put on the firewall: ${(e as Error).message}`);
  }
  const before = readJsonObject(join(store.configDir, "cert-refids.json"))?.[env];
  recordRefid(store, env, refid);
  info(`${GN}✓${CL} ${name} on the firewall, refid ${refid}, recorded for ${env}`);
  // The environment had another certificate (ACME's, or one made by hand): every
  // route on it moves together, Caddy drops its cached copy, and the old one
  // leaves the firewall once nothing serves it.
  if (typeof before === "string" && before && before !== refid) moveOff(before, refid);
  return 0;
}

const PROVIDER_NAME = /^[a-z0-9][a-z0-9-]{0,40}$/;

function providerAdd(store: Store, name: string, type: string, domains: string[], check: boolean): number {
  if (!PROVIDER_NAME.test(name)) die(`${name}: a provider's name is lower-case letters, digits and dashes`);
  if (!/^[a-z0-9_]+$/i.test(type)) die(`--type ${type}: a provider name or dns_ key`);
  for (const d of domains) {
    const p = domainNeed(emptyDocFor(), d);
    if (p.kind === "refused") die(p.why);
  }
  const cred = parseCredential(readFileSync(0, "utf8"));
  if ("error" in cred) die(`provider add: ${cred.error}`);
  const keys = Object.keys(cred.fields).sort();
  if (check || simulating()) {
    info(`would record ${name} (${type}${domains.length ? `, for ${domains.join(", ")}` : ", for any domain"}) with ${keys.join(", ")}`);
    return 0;
  }
  const doc = store.load();
  store.ensureKeyDir();
  const file = store.providerSecret(name);
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, keys.map((k) => `${k}=${cred.fields[k]}`).join("\n") + "\n", "utf8");
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
  doc.providers = { ...(doc.providers ?? {}), [name]: { type, domains, keys, added: stamp() } };
  store.save(doc);
  info(`${GN}✓${CL} provider ${name} (${type}) for ${domains.length ? domains.join(", ") : "any domain"}: ${keys.join(", ")}`);
  return 0;
}

function emptyDocFor(): CaDoc {
  return { version: 1, cas: {}, certificates: {} };
}

function providerList(store: Store, json: boolean): number {
  const ps = store.load().providers ?? {};
  if (json) {
    process.stdout.write(JSON.stringify(ps, null, 1) + "\n");
    return 0;
  }
  if (!Object.keys(ps).length) info("no DNS provider yet: ca-manager provider add <name> --type <t> < credential");
  for (const [n, p] of Object.entries(ps)) info(`  ${n.padEnd(16)} ${p.type.padEnd(12)} ${p.domains.length ? p.domains.join(", ") : "any domain"}  (${p.keys.join(", ")})`);
  return 0;
}

function providerRemove(store: Store, name: string): number {
  const doc = store.load();
  if (!doc.providers?.[name]) die(`no provider ${name} (ca-manager provider list)`);
  delete doc.providers[name];
  store.save(doc);
  if (existsSync(store.providerSecret(name))) unlinkSync(store.providerSecret(name));
  info(`${GN}✓${CL} removed provider ${name} — the firewall keeps its copy in os-acme-client until it is removed there`);
  return 0;
}

function siteEmail(configDir: string): string {
  const site = readJsonObject(join(configDir, "site.json"));
  return site && typeof site.email === "string" ? site.email : "";
}

function acme(store: Store, env: string, domain: string, staging: boolean, dnsSleep: number, check: boolean): number {
  if (!CERT_NAME.test(env)) die(`${env}: not an environment name`);
  const doc = store.load();
  const name = providerFor(doc, domain);
  if (!name) die(`no DNS provider for ${domain}: ca-manager provider add <name> --type <t> --domain ${domain} < credential`);
  const p = doc.providers![name];
  const email = siteEmail(store.configDir);
  if (!email || email.startsWith("CHANGE")) die("site.json .email is not set: Let's Encrypt needs a contact");
  if (check || simulating()) {
    info(`would get *.${domain} from Let's Encrypt${staging ? " (staging)" : ""} through ${name} (${p.type}), and record its refid for ${env}`);
    return 0;
  }
  const secret = readFileSync(store.providerSecret(name), "utf8");
  // acme.sh's DNS hooks are put in place by os-acme-client's own setup (#327).
  spawnSync("ssh", ["-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", `root@${FIREWALL}`, "sh /usr/local/opnsense/scripts/OPNsense/AcmeClient/setup.sh"], { encoding: "utf8" });
  const args = ["--firewall", FIREWALL, "--no-ssl-verify", "setup", "--domain", domain, "--email", email, "--provider", p.type,
    "--dns-sleep", String(dnsSleep), "--timeout", String(dnsSleep + 180), "--provider-fields-stdin",
    ...(staging ? ["--staging", "--account-name", "letsencrypt-staging"] : [])];
  info(`getting *.${domain} from Let's Encrypt${staging ? " (staging)" : ""} through ${name} — a few minutes`);
  const r = spawnSync("acme-manager", args, { encoding: "utf8", input: secret, env: { ...process.env, PYTHONUNBUFFERED: "1" } });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  if (r.status !== 0) {
    process.stderr.write(out.split("\n").slice(-15).join("\n") + "\n");
    die(`acme-manager setup failed for ${domain} (exit ${r.status})`);
  }
  const refid = refidFromSetup(out);
  if (!refid) die("acme-manager reported success but printed no refid");
  const before = readJsonObject(join(store.configDir, "cert-refids.json"))?.[env];
  recordRefid(store, env, refid);
  info(`${GN}✓${CL} *.${domain} issued, refid ${refid}, recorded for ${env}`);
  if (typeof before === "string" && before && before !== refid) moveOff(before, refid);
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
    const keep = { trust: c.trust, refid: c.refid };
    const rec = Object.assign(signCert(store, doc, n, c.names, ca), keep);
    store.save(doc);
    info(`${GN}✓${CL} renewed ${n}, until ${rec.notAfter.slice(0, 10)}`);
    if (rec.trust) {
      try {
        pushToFirewall(store, doc, n);
        info(`  …and replaced on the firewall (refid ${rec.refid})`);
      } catch (e) {
        warn(`${n} was renewed but not put on the firewall: ${(e as Error).message}`);
        failed++;
      }
    }
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
  if (args[0] === "report") return printOrSend(caReport(store), args.includes("--json"));
  requireOperator();
  const changed = (rc: number, verb: string): number => {
    if (rc === 0 && !check && !simulating()) reportMade(store, verb);
    return rc;
  };
  if (args[0] === "init") return changed(init(store, check, args.includes("--replace-bundle"), !args.includes("--no-rebuild")), "init");
  if (args[0] === "domain" && args[1] === "add") {
    const [domain] = positional(args, 2, []);
    if (!domain) die("domain add <domain>");
    return changed(domainAdd(store, domain, check, !args.includes("--no-rebuild")), "domain add");
  }
  if (args[0] === "cert" && args[1] === "issue") {
    const [name] = positional(args, 2, ["--dns"]);
    const dns = opt(args, "--dns");
    if (!name || !dns) die("cert issue <name> --dns <n>[,<n>…]");
    return changed(certIssue(store, name, dns.split(",").map((s) => s.trim()).filter(Boolean), check), "cert issue");
  }
  if (args[0] === "wildcard") {
    const [env] = positional(args, 1, ["--domain"]);
    const domain = opt(args, "--domain");
    if (!env || !domain) die("wildcard <environment> --domain <domain>");
    return changed(wildcard(store, env, domain, check, !args.includes("--no-rebuild")), "wildcard");
  }
  if (args[0] === "provider" && args[1] === "list") return providerList(store, args.includes("--json"));
  if (args[0] === "provider" && args[1] === "for") {
    const [domain] = positional(args, 2, []);
    if (!domain) die("provider for <domain>");
    const n = providerFor(store.load(), domain);
    if (!n) return 1;
    info(n);
    return 0;
  }
  if (args[0] === "provider" && args[1] === "add") {
    const [name] = positional(args, 2, ["--type", "--domain"]);
    const type = opt(args, "--type");
    if (!name || !type) die("provider add <name> --type <t> [--domain <d>,…] < credential");
    return changed(providerAdd(store, name, type, (opt(args, "--domain") ?? "").split(",").map((s) => s.trim()).filter(Boolean), check), "provider add");
  }
  if (args[0] === "provider" && args[1] === "remove") {
    const [name] = positional(args, 2, []);
    if (!name) die("provider remove <name>");
    return changed(providerRemove(store, name), "provider remove");
  }
  if (args[0] === "acme") {
    const [env] = positional(args, 1, ["--domain", "--dns-sleep"]);
    const domain = opt(args, "--domain");
    if (!env || !domain) die("acme <environment> --domain <domain>");
    const ds = opt(args, "--dns-sleep");
    const sleep = ds === undefined ? 150 : Number(ds);
    if (!Number.isInteger(sleep) || sleep < 0) die("--dns-sleep <seconds>");
    return changed(acme(store, env, domain, args.includes("--staging"), sleep, check), "acme");
  }
  if (args[0] === "cert" && args[1] === "renew") {
    const [name] = positional(args, 2, ["--within"]);
    const w = opt(args, "--within");
    const within = w === undefined ? RENEW_DAYS : Number(w);
    if (!Number.isInteger(within) || within < 0) die("--within <days>: a whole number of days");
    return changed(certRenew(store, name, within, args.includes("--force"), check), "cert renew");
  }
  die(`unknown verb '${args.slice(0, 2).join(" ")}' — see 'ca-manager --help'`);
}

if (require.main === module) {
  process.exit(guarded(() => run(process.argv.slice(2))));
}
