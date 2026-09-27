// security.ts — what is running on this installation and which of it needs a
// fix (ADR-011 v0.3). Two verbs and a gate:
//
//   scan security    inventory every target, match it against the CVE source of
//                    its layer, write ~/config/sbom/{site.cdx.json,cve-status.json}
//   report security  print cve-status.json
//   cve-status gate  (validate) WARN on a failed scan, an ACT, or a stale scan
//
// One scanner per layer (ADR-011 §4):
//
//   nix       a NixOS closure — the store-path list, with the CPE vendor taken
//             from the estate's own nixpkgs (meta.identifiers.cpeParts) — grype
//   debian    /etc/os-release, /etc/debian_version, dpkg status — trivy rootfs
//   image     a running container, by its registry digest — trivy image
//   opnsense  pkg audit (VuXML) + `pkg upgrade -nU` for what the channel offers
//
// Targets are derived, never configured: the mothership, every managed module
// with a VM or container (the module that provides network:rules is the
// OPNsense firewall), the containers running inside them, and the site's nodes.
//
// Everything a target sends back is read-only output of commands it already
// has; nothing is installed on a guest. The two rules the dry run forced:
//
//   COVERAGE  a scan that saw nothing is a FAILURE, never "0 vulnerabilities"
//   ACTION    the verdict is "fix available and not applied", not a CVE count
//
// All I/O goes through SecurityIO so the tests run offline.

import { spawnSync } from "child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, statfsSync, writeFileSync } from "fs";
import { hostname, tmpdir } from "os";
import { join } from "path";
import { RemoteResult, mgmtDomain, operatorHome, sshIdentity } from "../../../lib/ts/src/cluster";
import { isManaged, loadConfigModules, readModuleJson, siteNodeHostnames } from "./config";
import { guestTarget } from "./checks";
import { CheckResult, CheckRow, CheckStatus, ClusterClient } from "./types";

export const SBOM_DIRNAME = "sbom";
export const STATUS_FILE = "cve-status.json";
export const PREVIOUS_FILE = "cve-status.previous.json";
export const SITE_CDX_FILE = "site.cdx.json";

// ── the result model ───────────────────────────────────────────────────
// unknown: a target that could not be probed, so its system is not known
export type Layer = "nix" | "debian" | "image" | "opnsense" | "unknown";
// act      a Critical/High finding with a fix published (OPNsense: any
//          vulnerable package the channel has an update for)
// act-low  fixable findings, none Critical/High
// watch    nothing fixable — waiting on upstream
// triage   Nix: matched by CPE, no fix-state; a person decides (VEX, §8)
// failed   coverage failed — NOT clean
export type Verdict = "act" | "act-low" | "watch" | "triage" | "failed";

export interface Finding {
  id: string;
  severity: string; // Critical | High | Medium | Low | Unknown
  pkg: string;
  installed: string;
  fixed: string; // "" when no fix is published
  purl: string;
}

export interface TargetStatus {
  id: string; // stable key across scans: "node:tappaas1", "identity", "image:identity/authentik-server"
  name: string;
  layer: Layer;
  host: string;
  runsOn?: string[]; // images: the module/container that runs it
  ref?: string; // images: the digest scanned
  coverage: "ok" | "fail";
  note: string; // why coverage failed, or what to know about this target
  seen: number; // packages inventoried
  findings: number; // unique vulnerability ids after VEX
  critical: number;
  high: number;
  fixable: number | null; // null: the layer has no fix-state (nix)
  critHighFixable: number | null;
  suppressed: number; // findings a committed VEX statement decided
  verdict: Verdict;
  act: Finding[]; // what ACT refers to
  critHighKeys: string[]; // "<id> <pkg>" of every Critical/High finding — the diff base
  new: string[]; // critHighKeys not present in the previous scan
}

export interface ScanStatus {
  schema: 1;
  generated: string;
  sweep: { endTime: string; ok: boolean | null } | null;
  scanners: Record<string, string>;
  notes: string[];
  targets: TargetStatus[];
}

// ── inventory: CycloneDX components ────────────────────────────────────
export interface Component {
  type: "library" | "application";
  name: string;
  version: string;
  purl: string;
  cpe?: string;
  properties?: { name: string; value: string }[];
}

// A split output rides after the version: glibc-2.42-84-getent is glibc 2.42-84.
const NIX_OUTPUTS = new Set(["bin", "lib", "dev", "out", "man", "doc", "info", "debug", "static", "data", "dist", "py"]);

// `<hash>-<pname>-<version>[-<output>]` → [pname, version]; null for a path with
// no version (etc, generated units, firmware) — no CVE database can match those.
// The version starts at the first dash-separated segment that begins with a
// digit, the split nixpkgs' own builtins.parseDrvName makes.
export function parseStorePath(path: string): [string, string] | null {
  const base = path.replace(/\/+$/, "").split("/").pop() ?? "";
  const m = /^[0-9a-z]{32}-(.+)$/.exec(base);
  if (!m) return null;
  let parts = m[1].split("-");
  if (parts.length > 1 && NIX_OUTPUTS.has(parts[parts.length - 1])) parts = parts.slice(0, -1);
  for (let i = 1; i < parts.length; i++) {
    if (!/^\d/.test(parts[i])) continue;
    let ver = parts.slice(i);
    while (ver.length > 1 && !/^\d/.test(ver[ver.length - 1])) ver = ver.slice(0, -1);
    return [parts.slice(0, i).join("-"), ver.join("-")];
  }
  return null;
}

// The runtime closure as components, without CPEs (enrichCpes adds them).
// dbus-1, gtk-3.0: an API-level directory, not a release — a bare-integer
// version is dropped when the same package also has a dotted one.
export function nixComponents(paths: string[]): { components: Component[]; dropped: number } {
  const seen = new Set<string>();
  let comps: Component[] = [];
  let dropped = 0;
  for (const p of paths) {
    if (!p.trim()) continue;
    const pv = parseStorePath(p.trim());
    if (!pv) {
      dropped++;
      continue;
    }
    const key = `${pv[0]}@${pv[1]}`;
    if (seen.has(key)) continue;
    seen.add(key);
    comps.push({ type: "library", name: pv[0], version: pv[1], purl: `pkg:nix/${pv[0]}@${pv[1]}` });
  }
  const dotted = new Set(comps.filter((c) => c.version.includes(".")).map((c) => c.name));
  const before = comps.length;
  comps = comps.filter((c) => !(/^\d+$/.test(c.version) && dotted.has(c.name)));
  dropped += before - comps.length;
  return { components: comps, dropped };
}

export interface CpeParts {
  vendor: string | null;
  product: string | null;
}

// The CPE vendor decides whether NVD matches at all (sbomnix's glibc:glibc
// finds nothing; NVD says gnu:glibc). nixpkgs declares it for the packages that
// matter; where it does not, vendor = product, and the component says which.
export function applyCpes(comps: Component[], parts: Record<string, CpeParts | null> | null): number {
  let fromMeta = 0;
  for (const c of comps) {
    const p = parts?.[c.name] ?? null;
    const vendor = p?.vendor ?? null;
    const product = p?.product ?? c.name;
    if (vendor) fromMeta++;
    c.cpe = `cpe:2.3:a:${vendor ?? c.name}:${vendor ? product : c.name}:${c.version}:*:*:*:*:*:*:*`;
    c.properties = [{ name: "tappaas:cpe-source", value: vendor ? "nixpkgs-meta" : "naive" }];
  }
  return fromMeta;
}

// ── the probe every Linux target runs (read-only, commands it already has) ─
// One script, three transports: ssh to a guest, `pct exec` for a container,
// `sh -s` on the mothership itself. @@end proves the output is complete.
export const LINUX_PROBE = [
  'S=""; [ "$(id -u)" = 0 ] || S="sudo -n"',
  "if [ -e /run/current-system ]; then echo '@@nixos'; nix-store -q --requisites /run/current-system",
  "elif [ -f /etc/debian_version ]; then echo '@@os-release'; cat /etc/os-release; echo '@@debian_version'; cat /etc/debian_version; echo '@@dpkg'; cat /var/lib/dpkg/status",
  "else echo '@@other'; fi",
  "for rt in podman docker; do command -v $rt >/dev/null 2>&1 || continue",
  "  $S $rt ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | while IFS='|' read -r n i; do",
  "    d=$($S $rt image inspect --format '{{join .RepoDigests \",\"}}' \"$i\" 2>/dev/null)",
  '    echo "@@container $rt|$n|$i|$d"',
  "  done",
  "done",
  "echo '@@end'",
].join("\n");

export const OPNSENSE_PROBE = [
  "echo '@@pkgs'; pkg query '%n %v'",
  "echo '@@audit'; pkg audit 2>&1",
  // -n: dry run, -U: no catalogue update — what the channel offers, from the
  // catalogue OPNsense itself last fetched. Changes nothing on the firewall.
  "echo '@@upgrades'; pkg upgrade -nU 2>&1",
  "echo '@@vulnxml'; stat -f %m /var/db/pkg/vuln.xml 2>/dev/null",
  "echo '@@version'; opnsense-version 2>/dev/null",
  "echo '@@end'",
].join("\n");

export interface Container {
  runtime: string;
  name: string;
  image: string;
  digests: string[];
}

export interface LinuxProbe {
  os: "nixos" | "debian" | "other";
  paths: string[];
  osRelease: string;
  debianVersion: string;
  dpkg: string;
  containers: Container[];
  complete: boolean;
}

export function parseLinuxProbe(out: string): LinuxProbe {
  const r: LinuxProbe = { os: "other", paths: [], osRelease: "", debianVersion: "", dpkg: "", containers: [], complete: false };
  let section = "";
  const buf: Record<string, string[]> = { "os-release": [], debian_version: [], dpkg: [] };
  for (const line of out.split("\n")) {
    if (line.startsWith("@@")) {
      const tag = line.slice(2);
      if (tag === "nixos") r.os = "nixos";
      if (tag === "os-release") r.os = "debian";
      if (tag === "end") r.complete = true;
      if (tag.startsWith("container ")) {
        const [runtime, name, image, digests] = tag.slice("container ".length).split("|");
        r.containers.push({
          runtime: runtime ?? "",
          name: name ?? "",
          image: image ?? "",
          digests: (digests ?? "").split(",").map((d) => d.trim()).filter((d) => d.includes("@sha256:")),
        });
      }
      section = tag;
      continue;
    }
    if (section === "nixos") {
      if (line.startsWith("/nix/store/")) r.paths.push(line.trim());
    } else if (section in buf) buf[section].push(line);
  }
  r.osRelease = buf["os-release"].join("\n");
  r.debianVersion = buf.debian_version.join("\n").trim();
  r.dpkg = buf.dpkg.join("\n");
  return r;
}

export interface OpnsenseProbe {
  pkgs: { name: string; version: string }[];
  audit: { pkg: string; cves: string[] }[];
  auditRan: boolean;
  upgrades: Set<string>;
  vulnXmlAgeDays: number | null;
  version: string;
  complete: boolean;
}

export function parseOpnsenseProbe(out: string, now: number): OpnsenseProbe {
  const r: OpnsenseProbe = { pkgs: [], audit: [], auditRan: false, upgrades: new Set(), vulnXmlAgeDays: null, version: "", complete: false };
  let section = "";
  for (const raw of out.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (line.startsWith("@@")) {
      section = line.slice(2);
      if (section === "end") r.complete = true;
      continue;
    }
    if (section === "pkgs") {
      const [name, version] = line.trim().split(/\s+/);
      if (name && version) r.pkgs.push({ name, version });
    } else if (section === "audit") {
      const v = /^(\S+) is vulnerable:/.exec(line);
      if (v) r.audit.push({ pkg: v[1], cves: [] });
      const c = /^\s+CVE:\s+(CVE-\d+-\d+)/.exec(line);
      if (c && r.audit.length > 0) r.audit[r.audit.length - 1].cves.push(c[1]);
      // with nothing to report it still prints "0 problem(s) …"; no such line
      // at all means it did not run
      if (/problem\(s\)|is vulnerable:/.test(line)) r.auditRan = true;
    } else if (section === "upgrades") {
      const u = /^\s+(\S+):\s+(\S+)\s+->\s+(\S+)/.exec(line);
      if (u) r.upgrades.add(u[1]);
    } else if (section === "vulnxml") {
      const t = Number(line.trim());
      if (t > 0) r.vulnXmlAgeDays = Math.floor((now / 1000 - t) / 86400);
    } else if (section === "version") {
      if (line.trim()) r.version = line.trim();
    }
  }
  return r;
}

// "unbound-1.25.1_1" → "unbound"; FreeBSD package names may contain dashes.
export function pkgNameOf(nameVer: string): string {
  const i = nameVer.lastIndexOf("-");
  return i > 0 ? nameVer.slice(0, i) : nameVer;
}

// ── scanner output → findings ──────────────────────────────────────────
interface GrypeMatch {
  vulnerability?: { id?: string; severity?: string; fix?: { versions?: string[]; state?: string } };
  artifact?: { name?: string; version?: string; purl?: string };
}

export function grypeFindings(json: string): Finding[] {
  const doc = JSON.parse(json) as { matches?: GrypeMatch[] };
  return (doc.matches ?? []).map((m) => ({
    id: m.vulnerability?.id ?? "",
    severity: normSeverity(m.vulnerability?.severity ?? ""),
    pkg: m.artifact?.name ?? "",
    installed: m.artifact?.version ?? "",
    // grype's nix matches are by CPE and carry no fix-state: never "fixable".
    fixed: "",
    purl: m.artifact?.purl ?? "",
  }));
}

interface TrivyDoc {
  Metadata?: { OS?: { Family?: string; Name?: string } };
  Results?: {
    Packages?: { Name?: string; Version?: string; Release?: string; PkgIdentifier?: { PURL?: string } }[];
    Vulnerabilities?: {
      VulnerabilityID?: string;
      Severity?: string;
      PkgName?: string;
      InstalledVersion?: string;
      FixedVersion?: string;
      PkgIdentifier?: { PURL?: string };
    }[];
  }[];
}

export function trivyParse(json: string): { family: string; osName: string; components: Component[]; findings: Finding[] } {
  const doc = JSON.parse(json) as TrivyDoc;
  const components: Component[] = [];
  const findings: Finding[] = [];
  for (const res of doc.Results ?? []) {
    for (const p of res.Packages ?? []) {
      const version = p.Release ? `${p.Version ?? ""}-${p.Release}` : (p.Version ?? "");
      components.push({ type: "library", name: p.Name ?? "", version, purl: p.PkgIdentifier?.PURL ?? "" });
    }
    for (const v of res.Vulnerabilities ?? []) {
      findings.push({
        id: v.VulnerabilityID ?? "",
        severity: normSeverity(v.Severity ?? ""),
        pkg: v.PkgName ?? "",
        installed: v.InstalledVersion ?? "",
        fixed: v.FixedVersion ?? "",
        purl: v.PkgIdentifier?.PURL ?? "",
      });
    }
  }
  return { family: doc.Metadata?.OS?.Family ?? "", osName: doc.Metadata?.OS?.Name ?? "", components, findings };
}

function normSeverity(s: string): string {
  const l = s.toLowerCase();
  if (l === "critical") return "Critical";
  if (l === "high") return "High";
  if (l === "medium") return "Medium";
  if (l === "low" || l === "negligible") return "Low";
  return "Unknown";
}

// ── VEX: triage decisions committed next to the module (ADR-011 §8) ─────
export interface VexStatement {
  id: string;
  state: string;
  refs: string[]; // purls; empty = every package
  source: string;
}

const VEX_SUPPRESS = new Set(["not_affected", "false_positive", "resolved", "resolved_with_pedigree"]);

export function parseVex(json: string, source: string): VexStatement[] {
  const doc = JSON.parse(json) as { vulnerabilities?: { id?: string; analysis?: { state?: string }; affects?: { ref?: string }[] }[] };
  const out: VexStatement[] = [];
  for (const v of doc.vulnerabilities ?? []) {
    if (!v.id || !v.analysis?.state) continue;
    out.push({ id: v.id, state: v.analysis.state, refs: (v.affects ?? []).map((a) => a.ref ?? "").filter(Boolean), source });
  }
  return out;
}

// pkg:deb/debian/libc6@2.41-12?arch=amd64 → { base: "pkg:deb/debian/libc6", version: "2.41-12" }
function splitPurl(p: string): { base: string; version: string } {
  const clean = p.split("?")[0].split("#")[0];
  const at = clean.lastIndexOf("@");
  return at > clean.indexOf("/") ? { base: clean.slice(0, at), version: clean.slice(at + 1) } : { base: clean, version: "" };
}

// A statement with a versioned ref stops applying when the version changes —
// the decision was about THAT build, and the next one is looked at again.
export function vexSuppresses(f: Finding, vex: VexStatement[]): boolean {
  const fp = splitPurl(f.purl);
  return vex.some((s) => {
    if (s.id !== f.id || !VEX_SUPPRESS.has(s.state)) return false;
    if (s.refs.length === 0) return true;
    return s.refs.some((r) => {
      const rp = splitPurl(r);
      return rp.base === fp.base && (rp.version === "" || rp.version === fp.version);
    });
  });
}

// ── coverage + verdict (ADR-011 §6, §7) ────────────────────────────────
export function nixCoverage(comps: Component[]): string {
  if (comps.length < 50) return `only ${comps.length} package(s) inventoried`;
  if (!comps.some((c) => c.name === "glibc")) return "glibc not in the inventory";
  return "";
}

export function osCoverage(family: string, seen: number): string {
  if (!family) return "the scanner detected no operating system";
  if (seen === 0) return "the scanner saw no packages";
  return "";
}

// Fold a target's findings into its status: VEX first, then the counts over
// unique ids, then the verdict.
export function summarize(
  base: Pick<TargetStatus, "id" | "name" | "layer" | "host" | "runsOn" | "ref">,
  seen: number,
  coverageFail: string,
  all: Finding[],
  vex: VexStatement[],
  hasFixState: boolean,
  note = "",
): TargetStatus {
  const kept = all.filter((f) => f.id && !vexSuppresses(f, vex));
  const suppressed = new Set(all.filter((f) => f.id && vexSuppresses(f, vex)).map((f) => f.id)).size;
  const ids = (fs: Finding[]): number => new Set(fs.map((f) => f.id)).size;
  const ch = kept.filter((f) => f.severity === "Critical" || f.severity === "High");
  const fixable = kept.filter((f) => f.fixed !== "");
  const chFix = ch.filter((f) => f.fixed !== "");
  const status: TargetStatus = {
    ...base,
    coverage: coverageFail ? "fail" : "ok",
    note: coverageFail || note,
    seen,
    findings: ids(kept),
    critical: ids(kept.filter((f) => f.severity === "Critical")),
    high: ids(kept.filter((f) => f.severity === "High")),
    fixable: hasFixState ? ids(fixable) : null,
    critHighFixable: hasFixState ? ids(chFix) : null,
    suppressed,
    verdict: "watch",
    act: [],
    critHighKeys: [...new Set(ch.map((f) => `${f.id} ${f.pkg}`))].sort(),
    new: [],
  };
  if (coverageFail) status.verdict = "failed";
  else if (!hasFixState) status.verdict = "triage";
  else if (chFix.length > 0) {
    status.verdict = "act";
    status.act = dedupe(chFix);
  } else if (fixable.length > 0) status.verdict = "act-low";
  return status;
}

// OPNsense: VuXML carries no severity; a vulnerable package the channel has an
// update for is the thing to act on.
export function summarizeOpnsense(
  base: Pick<TargetStatus, "id" | "name" | "layer" | "host">,
  p: OpnsenseProbe | null,
  vex: VexStatement[],
): TargetStatus {
  if (!p || !p.complete || p.pkgs.length === 0 || !p.auditRan) {
    const why = !p ? "the firewall could not be reached" : p.pkgs.length === 0 ? "pkg listed no packages" : "pkg audit did not run";
    return summarize(base, p?.pkgs.length ?? 0, why, [], vex, true);
  }
  const findings: Finding[] = [];
  for (const a of p.audit) {
    const name = pkgNameOf(a.pkg);
    const fixed = p.upgrades.has(name) ? "channel update" : "";
    const installed = a.pkg.slice(name.length + 1);
    for (const id of a.cves.length ? a.cves : [`VuXML:${a.pkg}`]) {
      findings.push({ id, severity: "Unknown", pkg: name, installed, fixed, purl: `pkg:generic/opnsense/${name}@${installed}` });
    }
  }
  const age = p.vulnXmlAgeDays;
  const note = `${p.version || "OPNsense"}; VuXML ${age === null ? "age unknown" : `${age} day(s) old`}`;
  const s = summarize(base, p.pkgs.length, "", findings, vex, true, note);
  const fixable = findings.filter((f) => f.fixed !== "" && !vexSuppresses(f, vex));
  if (fixable.length > 0) {
    s.verdict = "act";
    s.act = dedupe(fixable);
  }
  return s;
}

function dedupe(fs: Finding[]): Finding[] {
  const m = new Map<string, Finding>();
  for (const f of fs) if (!m.has(`${f.id} ${f.pkg}`)) m.set(`${f.id} ${f.pkg}`, f);
  const rank = (s: string): number => ["Critical", "High", "Medium", "Low", "Unknown"].indexOf(s);
  return [...m.values()].sort((a, b) => rank(a.severity) - rank(b.severity) || a.id.localeCompare(b.id));
}

// ── what changed since the previous scan ───────────────────────────────
export interface ScanDiff {
  newAct: { target: string; findings: Finding[] }[];
  newlyFailed: TargetStatus[];
}

export function diffScans(cur: ScanStatus, prev: ScanStatus | null): ScanDiff {
  const prevById = new Map((prev?.targets ?? []).map((t) => [t.id, t]));
  const out: ScanDiff = { newAct: [], newlyFailed: [] };
  for (const t of cur.targets) {
    const p = prevById.get(t.id);
    const before = new Set(p?.critHighKeys ?? []);
    t.new = t.critHighKeys.filter((k) => !before.has(k));
    if (t.verdict === "failed" && p?.verdict !== "failed") out.newlyFailed.push(t);
    const actBefore = new Set((p?.act ?? []).map((f) => `${f.id} ${f.pkg}`));
    const fresh = t.act.filter((f) => !actBefore.has(`${f.id} ${f.pkg}`));
    if (fresh.length > 0) out.newAct.push({ target: t.id, findings: fresh });
  }
  return out;
}

// ── I/O boundary ───────────────────────────────────────────────────────
export interface SecurityIO {
  now(): number;
  // Run the probe on a target; null when it could not be reached.
  probeLocal(script: string): RemoteResult;
  probeGuest(host: string, script: string): RemoteResult;
  probeLxc(node: string, vmid: number, script: string): RemoteResult;
  probeNode(node: string, script: string): RemoteResult;
  probeFirewall(script: string): RemoteResult;
  // pname → nixpkgs meta.identifiers.cpeParts (null: eval failed as a whole)
  nixCpeParts(names: string[]): Record<string, CpeParts | null> | null;
  dbUpdate(): string[]; // notes; empty when both databases are current
  grype(sbomFile: string): RemoteResult;
  trivyRootfs(dir: string): RemoteResult;
  trivyImage(ref: string): RemoteResult;
  versions(): Record<string, string>;
  diskSpace(path: string): { free: number; total: number };
  cachesPresent(): boolean;
  hostname(): string;
}

const SSH_OPTS = ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "IdentitiesOnly=yes"];
const MIN = 60_000;

function exec(cmd: string, args: string[], input?: string, timeout = 10 * MIN, env?: Record<string, string | undefined>): RemoteResult {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 512 * 1024 * 1024, input, timeout, env });
  if (r.error) return { rc: -1, stdout: "", stderr: r.error.message, ran: false };
  return { rc: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "", ran: true };
}

export class CliSecurityIO implements SecurityIO {
  private readonly home = operatorHome() ?? process.env.HOME ?? "/home/tappaas";
  now(): number {
    return Date.now();
  }
  probeLocal(script: string): RemoteResult {
    return exec("sh", ["-s"], script, 5 * MIN);
  }
  probeGuest(host: string, script: string): RemoteResult {
    return exec("ssh", [...SSH_OPTS, "-i", sshIdentity(), `tappaas@${host}`, "sh -s"], script, 5 * MIN);
  }
  probeLxc(node: string, vmid: number, script: string): RemoteResult {
    return exec("ssh", [...SSH_OPTS, "-i", sshIdentity(), `root@${node}.${mgmtDomain()}`, `pct exec ${vmid} -- sh -s`], script, 5 * MIN);
  }
  probeNode(node: string, script: string): RemoteResult {
    return exec("ssh", [...SSH_OPTS, "-i", sshIdentity(), `root@${node}.${mgmtDomain()}`, "sh -s"], script, 5 * MIN);
  }
  // The firewall authorizes its own key, not the general cicd one.
  probeFirewall(script: string): RemoteResult {
    const fwKey = join(this.home, ".ssh", "tappaas-fw");
    const key = existsSync(fwKey) ? fwKey : sshIdentity();
    return exec("ssh", [...SSH_OPTS, "-i", key, `root@firewall.${mgmtDomain()}`, "sh -s"], script, 5 * MIN);
  }
  nixCpeParts(names: string[]): Record<string, CpeParts | null> | null {
    const dir = mkdtempSync(join(tmpdir(), "tappaas-cpe-"));
    try {
      const f = join(dir, "names.json");
      writeFileSync(f, JSON.stringify(names));
      // The mothership's own nixpkgs IS the estate pin (ADR-028 D1): the vendor
      // it declares holds for every guest built from the same pin.
      const np = process.env.TAPPAAS_NIXPKGS ? `import ${process.env.TAPPAAS_NIXPKGS}` : "import <nixpkgs>";
      const expr =
        `let pkgs = ${np} {}; names = builtins.fromJSON (builtins.readFile ${f}); ` +
        "look = n: let r = builtins.tryEval (let p = pkgs.${n} or null; in " +
        "if p == null then null else (p.meta.identifiers.cpeParts or null)); in " +
        "if r.success then (if r.value == null then null else { vendor = r.value.vendor or null; product = r.value.product or null; }) else null; " +
        "in builtins.listToAttrs (map (n: { name = n; value = look n; }) names)";
      const r = exec("nix-instantiate", ["--eval", "--strict", "--json", "-E", expr], undefined, 5 * MIN);
      if (r.rc !== 0) return null;
      return JSON.parse(r.stdout) as Record<string, CpeParts | null>;
    } catch {
      return null;
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  dbUpdate(): string[] {
    const notes: string[] = [];
    const g = exec("grype", ["db", "update"], undefined, 20 * MIN);
    if (g.rc !== 0) notes.push(`grype database update failed: ${lastLine(g.stderr || g.stdout)}`);
    const t = exec("trivy", ["image", "--download-db-only", "--quiet"], undefined, 20 * MIN);
    if (t.rc !== 0) notes.push(`trivy database update failed: ${lastLine(t.stderr || t.stdout)}`);
    return notes;
  }
  grype(sbomFile: string): RemoteResult {
    return exec("grype", [`sbom:${sbomFile}`, "-o", "json", "-q"], undefined, 15 * MIN, { ...process.env, GRYPE_DB_AUTO_UPDATE: "false" });
  }
  trivyRootfs(dir: string): RemoteResult {
    return exec("trivy", ["rootfs", "--skip-db-update", "--quiet", "--scanners", "vuln", "--list-all-pkgs", "--format", "json", dir], undefined, 15 * MIN);
  }
  trivyImage(ref: string): RemoteResult {
    return exec("trivy", ["image", "--skip-db-update", "--quiet", "--scanners", "vuln", "--list-all-pkgs", "--format", "json", ref], undefined, 30 * MIN);
  }
  versions(): Record<string, string> {
    const v = (cmd: string, args: string[]): string =>
      /Version:\s+(\S+)/.exec(exec(cmd, args, undefined, MIN).stdout)?.[1] ?? "unavailable";
    return { grype: v("grype", ["version"]), trivy: v("trivy", ["--version"]) };
  }
  diskSpace(path: string): { free: number; total: number } {
    const s = statfsSync(path);
    return { free: s.bavail * s.bsize, total: s.blocks * s.bsize };
  }
  cachesPresent(): boolean {
    return existsSync(join(this.home, ".cache", "grype")) && existsSync(join(this.home, ".cache", "trivy"));
  }
  hostname(): string {
    return hostname();
  }
}

function lastLine(s: string): string {
  const lines = s.trim().split("\n").filter((l) => l.trim());
  return (lines[lines.length - 1] ?? "").trim().slice(0, 200);
}

// ── the scan ───────────────────────────────────────────────────────────
// The scanner databases take ~6 GB (measured on hrossen 2026-09-27: grype 3.0,
// trivy 1.4 + its Java DB 1.5, pulled by the first image with jars in it,
// ADR-011 §5). The first download is refused when it would take the root disk
// over the disk-threshold gate's 80% — on hrossen it took a 32 GB root to 91%,
// and a scan that fails the health gate it reports into helps no one.
export const DB_SPACE_BYTES = 6.5 * 1024 ** 3;
export const DISK_CEILING = 0.8;

export function dbSpaceProblem(free: number, total: number): string {
  if (total <= 0) return "";
  const after = (total - free + DB_SPACE_BYTES) / total;
  if (after < DISK_CEILING) return "";
  return `the scanner databases (~${(DB_SPACE_BYTES / 1024 ** 3).toFixed(1)} GiB) would take the root disk to ` +
    `${Math.round(after * 100)}%, over the ${DISK_CEILING * 100}% disk gate — grow the mothership's disk first`;
}

interface Planned {
  id: string;
  name: string;
  layer: "linux" | "opnsense";
  host: string;
  probe: () => RemoteResult;
}

export interface ScanOpts {
  configDir: string;
  defaultNode: string;
  repoDir: string;
  log?: (msg: string) => void;
}

export function planTargets(configDir: string, defaultNode: string, client: ClusterClient, io: SecurityIO): Planned[] {
  const out: Planned[] = [];
  const self = io.hostname();
  for (const m of loadConfigModules(configDir, defaultNode).filter(isManaged)) {
    const raw = readModuleJson(join(configDir, `${m.module}.json`)) ?? {};
    const vmname = typeof raw.vmname === "string" && raw.vmname ? raw.vmname : m.module;
    const provides = Array.isArray(raw.provides) ? (raw.provides as unknown[]) : [];
    if (provides.includes("rules")) {
      out.push({ id: m.module, name: `${m.module} (firewall)`, layer: "opnsense", host: `firewall.${mgmtDomain()}`, probe: () => io.probeFirewall(OPNSENSE_PROBE) });
      continue;
    }
    if (vmname === self) {
      out.push({ id: m.module, name: `${m.module} (mothership)`, layer: "linux", host: self, probe: () => io.probeLocal(LINUX_PROBE) });
      continue;
    }
    if (raw.kind === "lxc") {
      const node = client.actualNode(m.node, m.vmid) || m.node;
      out.push({ id: m.module, name: m.module, layer: "linux", host: `${node}:ct${m.vmid}`, probe: () => io.probeLxc(node, m.vmid, LINUX_PROBE) });
      continue;
    }
    const target = guestTarget(configDir, m.module) ?? `${vmname}.mgmt.internal`;
    out.push({ id: m.module, name: m.module, layer: "linux", host: target, probe: () => io.probeGuest(target, LINUX_PROBE) });
  }
  for (const n of siteNodeHostnames(configDir)) {
    out.push({ id: `node:${n}`, name: `${n} (node)`, layer: "linux", host: `${n}.${mgmtDomain()}`, probe: () => io.probeNode(n, LINUX_PROBE) });
  }
  return out;
}

export function loadVex(repoDir: string): VexStatement[] {
  const out: VexStatement[] = [];
  const walk = (d: string, depth: number): void => {
    if (depth > 6 || !existsSync(d)) return;
    for (const e of readdirSync(d)) {
      if (e.startsWith(".") || e === "node_modules" || e === "dist" || e === "result") continue;
      const p = join(d, e);
      let st;
      try {
        st = statSync(p);
      } catch {
        continue;
      }
      if (st.isDirectory()) walk(p, depth + 1);
      else if (e.endsWith("-vex.json")) {
        try {
          out.push(...parseVex(readFileSync(p, "utf8"), p.slice(repoDir.length + 1)));
        } catch {
          // an unreadable VEX file decides nothing; the finding stays reported
        }
      }
    }
  };
  walk(join(repoDir, "src"), 0);
  return out;
}

interface CdxTarget {
  status: TargetStatus;
  version: string;
  components: Component[];
}

export function runScan(opts: ScanOpts, client: ClusterClient, io: SecurityIO): { status: ScanStatus; cdx: Record<string, unknown> } {
  const log = opts.log ?? ((): void => undefined);
  const vex = loadVex(opts.repoDir);
  const notes: string[] = [];
  const plan = planTargets(opts.configDir, opts.defaultNode, client, io);
  const results: CdxTarget[] = [];

  // The databases first: a scan against a database that is not there fails
  // every target, which coverage then reports — nothing is silently clean.
  let dbOk = true;
  const disk = io.diskSpace(opts.configDir);
  const space = io.cachesPresent() ? "" : dbSpaceProblem(disk.free, disk.total);
  if (space) {
    dbOk = false;
    notes.push(space);
  } else {
    log("updating the scanner databases");
    notes.push(...io.dbUpdate());
  }

  const tmp = mkdtempSync(join(tmpdir(), "tappaas-scan-"));
  try {
    // 1. probe every target
    type Probed = { t: Planned; linux?: LinuxProbe; opn?: OpnsenseProbe | null; err?: string };
    const probed: Probed[] = [];
    for (const t of plan) {
      log(`probing ${t.name} (${t.host})`);
      const r = t.probe();
      if (t.layer === "opnsense") {
        probed.push({ t, opn: r.rc === 0 && r.ran ? parseOpnsenseProbe(r.stdout, io.now()) : null });
        continue;
      }
      if (!r.ran || r.rc !== 0) {
        probed.push({ t, err: `unreachable: ${lastLine(r.stderr) || `exit ${r.rc}`}` });
        continue;
      }
      const lp = parseLinuxProbe(r.stdout);
      probed.push({ t, linux: lp, err: lp.complete ? undefined : "the probe's output was cut short" });
    }

    // 2. one nixpkgs evaluation for every Nix package name on the site
    const nixComps = new Map<string, { components: Component[]; dropped: number }>();
    for (const p of probed) if (p.linux?.os === "nixos") nixComps.set(p.t.id, nixComponents(p.linux.paths));
    const names = [...new Set([...nixComps.values()].flatMap((c) => c.components.map((x) => x.name)))];
    const parts = names.length > 0 ? io.nixCpeParts(names) : {};
    if (parts === null) notes.push("nixpkgs CPE metadata unavailable — every Nix vendor guessed from the package name");
    for (const c of nixComps.values()) applyCpes(c.components, parts);

    // 3. scan each target with its layer's scanner
    const failed = (t: Planned, layer: Layer, why: string, seen = 0): CdxTarget => ({
      status: summarize({ id: t.id, name: t.name, layer, host: t.host }, seen, why, [], vex, layer !== "nix"),
      version: "",
      components: [],
    });
    for (const p of probed) {
      const t = p.t;
      if (t.layer === "opnsense") {
        const s = summarizeOpnsense({ id: t.id, name: t.name, layer: "opnsense", host: t.host }, p.opn ?? null, vex);
        results.push({
          status: s,
          version: p.opn?.version ?? "",
          components: (p.opn?.pkgs ?? []).map((k) => ({ type: "library", name: k.name, version: k.version, purl: `pkg:generic/opnsense/${k.name}@${k.version}` })),
        });
        continue;
      }
      if (!p.linux) {
        results.push(failed(t, "unknown", p.err ?? "unreachable"));
        continue;
      }
      const lp = p.linux;
      if (lp.os === "nixos") {
        const nc = nixComps.get(t.id)!;
        if (p.err || !dbOk) {
          results.push({ ...failed(t, "nix", p.err ?? "no scanner database — see the scan's notes", nc.components.length), components: nc.components });
        } else {
          log(`matching ${t.name}: ${nc.components.length} Nix packages`);
          const f = join(tmp, `${safe(t.id)}.cdx.json`);
          writeFileSync(f, JSON.stringify(cdxDoc(nc.components)));
          let cov = nixCoverage(nc.components);
          let findings: Finding[] = [];
          if (!cov) {
            const g = io.grype(f);
            if (!g.ran || g.rc !== 0) cov = `grype failed: ${lastLine(g.stderr) || `exit ${g.rc}`}`;
            else {
              try {
                findings = grypeFindings(g.stdout);
              } catch {
                cov = "grype output not parseable";
              }
            }
          }
          results.push({
            status: summarize({ id: t.id, name: t.name, layer: "nix", host: t.host }, nc.components.length, cov, findings, vex, false,
              `${nc.dropped} unversioned store paths not inventoried`),
            version: "",
            components: nc.components,
          });
        }
      } else if (lp.os === "debian") {
        if (p.err || !dbOk) results.push(failed(t, "debian", p.err ?? "no scanner database — see the scan's notes"));
        else {
          log(`matching ${t.name}: Debian packages`);
          const root = join(tmp, safe(t.id));
          mkdirSync(join(root, "etc"), { recursive: true });
          mkdirSync(join(root, "var", "lib", "dpkg"), { recursive: true });
          writeFileSync(join(root, "etc", "os-release"), lp.osRelease + "\n");
          if (lp.debianVersion) writeFileSync(join(root, "etc", "debian_version"), lp.debianVersion + "\n");
          writeFileSync(join(root, "var", "lib", "dpkg", "status"), lp.dpkg + "\n");
          results.push(trivyTarget({ id: t.id, name: t.name, layer: "debian", host: t.host }, io.trivyRootfs(root), vex));
        }
      } else {
        results.push(failed(t, "unknown", p.err ?? "not NixOS or Debian — no scanner for this system"));
      }

      // the images running inside it, by digest — one target per image, however
      // many containers run it (authentik's server and worker are one image)
      for (const g of groupByImage(lp.containers)) {
        const c = g[0];
        const names = g.map((x) => x.name);
        const id = `image:${t.id}/${c.name}`;
        const base = { id, name: `${names.join(", ")} (${t.id})`, layer: "image" as Layer, host: t.host, runsOn: names.map((n) => `${t.id}/${n}`), ref: c.digests[0] ?? c.image };
        if (c.digests.length === 0) {
          results.push({ status: summarize(base, 0, "the image has no registry digest (built locally?) — cannot be scanned as running", [], vex, true), version: "", components: [] });
        } else if (!dbOk) {
          results.push({ status: summarize(base, 0, "no scanner database — see the scan's notes", [], vex, true), version: "", components: [] });
        } else {
          log(`matching ${base.name}: ${c.digests[0]}`);
          const r = trivyTarget(base, io.trivyImage(c.digests[0]), vex);
          r.version = c.image;
          results.push(r);
        }
      }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }

  const sweep = readSweep(opts.configDir);
  const status: ScanStatus = {
    schema: 1,
    generated: new Date(io.now()).toISOString(),
    sweep,
    scanners: io.versions(),
    notes,
    targets: results.map((r) => r.status),
  };
  return { status, cdx: siteCdx(results, status, siteName(opts.configDir)) };
}

export function groupByImage(cs: Container[]): Container[][] {
  const m = new Map<string, Container[]>();
  for (const c of cs) {
    const key = c.digests[0] ?? `local:${c.image}`;
    m.set(key, [...(m.get(key) ?? []), c]);
  }
  return [...m.values()];
}

function trivyTarget(base: Pick<TargetStatus, "id" | "name" | "layer" | "host" | "runsOn" | "ref">, r: RemoteResult, vex: VexStatement[]): CdxTarget {
  if (!r.ran || r.rc !== 0) {
    return { status: summarize(base, 0, `trivy failed: ${lastLine(r.stderr) || `exit ${r.rc}`}`, [], vex, true), version: "", components: [] };
  }
  try {
    const t = trivyParse(r.stdout);
    return {
      status: summarize(base, t.components.length, osCoverage(t.family, t.components.length), t.findings, vex, true, t.osName ? `${t.family} ${t.osName}` : ""),
      version: t.osName,
      components: t.components,
    };
  } catch {
    return { status: summarize(base, 0, "trivy output not parseable", [], vex, true), version: "", components: [] };
  }
}

function safe(id: string): string {
  return id.replace(/[^A-Za-z0-9_.-]/g, "_");
}

function readSweep(configDir: string): ScanStatus["sweep"] {
  const r = readModuleJson(join(configDir, "last-update-result.json"));
  if (!r) return null;
  return { endTime: typeof r.end_time === "string" ? r.end_time : "", ok: typeof r.ok === "boolean" ? r.ok : null };
}

function siteName(configDir: string): string {
  const s = readModuleJson(join(configDir, "site.json"));
  return typeof s?.name === "string" && s.name ? s.name : "site";
}

function uuid(): string {
  const h = (n: number): string => Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
  return `${h(8)}-${h(4)}-4${h(3)}-${"89ab"[Math.floor(Math.random() * 4)]}${h(3)}-${h(12)}`;
}

function cdxDoc(components: Component[]): Record<string, unknown> {
  return { bomFormat: "CycloneDX", specVersion: "1.4", serialNumber: `urn:uuid:${uuid()}`, version: 1, components };
}

// One CycloneDX document for the installation: each target is a component
// (an operating system or a container) with its packages nested beneath it.
export function siteCdx(results: CdxTarget[], status: ScanStatus, site: string): Record<string, unknown> {
  return {
    bomFormat: "CycloneDX",
    specVersion: "1.4",
    serialNumber: `urn:uuid:${uuid()}`,
    version: 1,
    metadata: {
      timestamp: status.generated,
      tools: [{ vendor: "TAPPaaS", name: "health-manager scan security" }, ...Object.entries(status.scanners).map(([name, version]) => ({ name, version }))],
      component: { type: "application", name: `tappaas-site-${site}`, "bom-ref": `site:${site}` },
      properties: status.sweep ? [{ name: "tappaas:sweep-end", value: status.sweep.endTime }] : [],
    },
    components: results.map((r) => ({
      type: r.status.layer === "image" ? "container" : "operating-system",
      "bom-ref": r.status.id,
      name: r.status.name,
      ...(r.version ? { version: r.version } : {}),
      properties: [
        { name: "tappaas:layer", value: r.status.layer },
        { name: "tappaas:host", value: r.status.host },
        { name: "tappaas:coverage", value: r.status.coverage },
        ...(r.status.ref ? [{ name: "tappaas:image-ref", value: r.status.ref }] : []),
      ],
      components: r.components,
    })),
  };
}

// ── persistence ────────────────────────────────────────────────────────
export function sbomDir(configDir: string): string {
  return join(configDir, SBOM_DIRNAME);
}

export function readStatus(path: string): ScanStatus | null {
  if (!existsSync(path)) return null;
  try {
    const s = JSON.parse(readFileSync(path, "utf8")) as ScanStatus;
    return s && Array.isArray(s.targets) ? s : null;
  } catch {
    return null;
  }
}

// The previous scan becomes cve-status.previous.json; both files are replaced
// atomically, so a reader never sees half a scan.
export function writeScan(configDir: string, status: ScanStatus, cdx: Record<string, unknown>): ScanDiff {
  const dir = sbomDir(configDir);
  mkdirSync(dir, { recursive: true });
  const cur = join(dir, STATUS_FILE);
  const prev = readStatus(cur);
  const diff = diffScans(status, prev);
  if (existsSync(cur)) renameSync(cur, join(dir, PREVIOUS_FILE));
  for (const [file, doc] of [[SITE_CDX_FILE, cdx], [STATUS_FILE, status]] as const) {
    writeFileSync(join(dir, `${file}.tmp`), JSON.stringify(doc, null, 1) + "\n");
    renameSync(join(dir, `${file}.tmp`), join(dir, file));
  }
  return diff;
}

// --if-new-sweep: the sweep unit runs hourly and mostly does nothing; only a
// sweep that wrote a result is worth a scan.
export function sweepIsNewer(configDir: string): boolean {
  const result = join(configDir, "last-update-result.json");
  const status = join(sbomDir(configDir), STATUS_FILE);
  if (!existsSync(result)) return false;
  if (!existsSync(status)) return true;
  return statSync(result).mtimeMs > statSync(status).mtimeMs;
}

// ── presentation ───────────────────────────────────────────────────────
const VERDICT_TEXT: Record<Verdict, string> = {
  act: "ACT",
  "act-low": "act (low/medium only)",
  watch: "watch — waiting on upstream",
  triage: "triage (Nix: no fix-state)",
  failed: "SCAN FAILED — not clean",
};

export function verdictLine(t: TargetStatus): string {
  if (t.verdict === "failed") return `${VERDICT_TEXT.failed}: ${t.note}`;
  if (t.verdict === "act") {
    return t.layer === "opnsense"
      ? `ACT: ${new Set(t.act.map((f) => f.pkg)).size} vulnerable package(s) have a channel update`
      : `ACT: ${t.critHighFixable} critical/high fixable`;
  }
  return VERDICT_TEXT[t.verdict];
}

const ORDER: Verdict[] = ["act", "failed", "act-low", "triage", "watch"];

export function renderReport(s: ScanStatus, all: boolean, now: number): string[] {
  const out: string[] = [];
  const age = Math.floor((now - Date.parse(s.generated)) / 3_600_000);
  out.push(`Security scan of ${s.generated} (${age < 48 ? `${age} h` : `${Math.floor(age / 24)} days`} ago)` +
    (s.sweep ? ` — after the sweep that ended ${s.sweep.endTime || "?"}${s.sweep.ok === false ? " (failed)" : ""}` : ""));
  out.push(`scanners: ${Object.entries(s.scanners).map(([k, v]) => `${k} ${v}`).join(", ")}`);
  for (const n of s.notes) out.push(`note: ${n}`);
  out.push("");
  const rows = [...s.targets].sort((a, b) => ORDER.indexOf(a.verdict) - ORDER.indexOf(b.verdict) || a.id.localeCompare(b.id));
  const pad = (x: string | number, n: number): string => String(x).padEnd(n);
  out.push(`${pad("TARGET", 30)}${pad("LAYER", 9)}${pad("PKGS", 6)}${pad("CVES", 6)}${pad("CRIT", 5)}${pad("HIGH", 5)}${pad("FIX C/H", 8)}${pad("NEW", 5)}VERDICT`);
  for (const t of rows) {
    out.push(
      `${pad(t.name.slice(0, 29), 30)}${pad(t.layer, 9)}${pad(t.seen, 6)}${pad(t.findings, 6)}${pad(t.critical, 5)}${pad(t.high, 5)}` +
        `${pad(t.critHighFixable ?? "-", 8)}${pad(t.new.length, 5)}${verdictLine(t)}`,
    );
  }
  const acts = rows.filter((t) => t.act.length > 0);
  for (const t of acts) {
    out.push("", `${t.name} — ${t.act.length} to act on${t.ref ? ` (${t.ref})` : ""}:`);
    const list = all ? t.act : t.act.slice(0, 10);
    for (const f of list) out.push(`  ${pad(f.severity, 9)}${pad(f.id, 20)}${pad(f.pkg, 24)}${f.installed} → ${f.fixed}`);
    if (list.length < t.act.length) out.push(`  … ${t.act.length - list.length} more (--all)`);
  }
  const vexed = rows.reduce((a, t) => a + t.suppressed, 0);
  if (vexed > 0) out.push("", `${vexed} finding(s) decided by committed VEX statements and not listed.`);
  return out;
}

// ── the validate gate: WARN, never FAIL (ADR-011 §9) ───────────────────
// A CVE published upstream must not be able to fail a sweep or a test run;
// the gate makes the scan visible, the mail and the report make it actionable.
export const STALE_DAYS = 8;

export function checkCveStatus(configDir: string, now: number): CheckResult {
  const s = readStatus(join(sbomDir(configDir), STATUS_FILE));
  if (!s) return { name: "cve-status", status: "skip", detail: "no security scan yet — health-manager scan security" };
  const rows: CheckRow[] = [];
  for (const t of s.targets) {
    if (t.verdict === "failed" || t.verdict === "act") rows.push({ status: "warn", text: `${t.name.padEnd(30)}${verdictLine(t)}` });
  }
  const days = Math.floor((now - Date.parse(s.generated)) / 86_400_000);
  const count = (v: Verdict): number => s.targets.filter((t) => t.verdict === v).length;
  const detail =
    `${s.targets.length} target(s): ${count("act")} act, ${count("failed")} failed, ${count("triage")} triage, ` +
    `${count("watch") + count("act-low")} watch — scanned ${days} day(s) ago; health-manager report security`;
  let status: CheckStatus = rows.length > 0 ? "warn" : "pass";
  if (days > STALE_DAYS) {
    status = "warn";
    rows.push({ status: "warn", text: `the last scan is ${days} days old (no sweep since, or the scan unit failed)` });
  }
  return { name: "cve-status", status, detail, rows };
}

// ── the notice (ADR-007e site notification target) ─────────────────────
export function noticeBody(s: ScanStatus, d: ScanDiff): string {
  const out: string[] = [];
  for (const t of d.newlyFailed) out.push(`SCAN FAILED  ${t.name}: ${t.note}`);
  for (const a of d.newAct) {
    const t = s.targets.find((x) => x.id === a.target)!;
    out.push(`NEW TO ACT   ${t.name}${t.ref ? ` (${t.ref})` : ""}: ${a.findings.length} finding(s) with a fix published`);
    for (const f of a.findings.slice(0, 10)) out.push(`    ${f.severity.padEnd(9)}${f.id.padEnd(20)}${f.pkg} ${f.installed} → ${f.fixed}`);
    if (a.findings.length > 10) out.push(`    … ${a.findings.length - 10} more`);
  }
  out.push("", "The whole report:", ...renderReport(s, false, Date.parse(s.generated)).map((l) => `  ${l}`));
  out.push("", "Look at:", "  health-manager report security", "  ~/config/sbom/cve-status.json   ~/config/sbom/site.cdx.json");
  return out.join("\n");
}

export function notify(s: ScanStatus, d: ScanDiff, bin: string): { sent: boolean; message: string } {
  if (d.newAct.length === 0 && d.newlyFailed.length === 0) return { sent: false, message: "nothing new to act on — no notice" };
  const parts: string[] = [];
  if (d.newAct.length) parts.push(`${d.newAct.length} target(s) with new fixable CVEs`);
  if (d.newlyFailed.length) parts.push(`${d.newlyFailed.length} scan(s) failed`);
  const r = exec(bin, ["--what", "security notice", "--subject", `security: ${parts.join(", ")}`], noticeBody(s, d), MIN);
  return { sent: r.rc === 0, message: lastLine(r.stdout || r.stderr) };
}
