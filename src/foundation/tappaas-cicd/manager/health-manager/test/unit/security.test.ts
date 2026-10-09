// security.test.ts — the CVE scan and its report (ADR-011 v0.3).
//
// The rules the dry run on hrossen forced, each pinned here: a scan that saw
// nothing is a FAILURE, never "0 vulnerabilities" (trivy without
// /etc/debian_version said exactly that); the verdict is "fix available and not
// applied", not a count; the Nix vendor comes from nixpkgs, because a guessed
// one (glibc:glibc) matches nothing; and the validate gate only ever WARNs.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, utimesSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { RemoteResult } from "../../../../lib/ts/src/cluster";
import {
  CpeParts, DB_SPACE_BYTES, dbSpaceProblem, Finding, LINUX_PROBE, OPNSENSE_PROBE, PREVIOUS_FILE, STATUS_FILE, ScanStatus, SecurityIO,
  TargetStatus, applyCpes, checkCveStatus, fit, groupByImage, diffScans, nixComponents, parseLinuxProbe, parseOpnsenseProbe,
  loadVex, parseStorePath, parseVex, scanComponentList, scanImageRefs, readStatus, registeredModuleDirs, renderReport, runScan, sbomDir, summarize, summarizeOpnsense, sweepIsNewer,
  vexFor, vexSuppresses, writeScan, isBuildOnly, pickSeverities, aptModules, moduleOf,
} from "../../src/security";
import { run } from "../../src/main";
import { FakeClusterClient } from "./fake-client";

let passed = 0;
let failed = 0;
function check(cond: boolean, name: string): void {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}`); }
}

const ok = (stdout: string): RemoteResult => ({ rc: 0, stdout, stderr: "", ran: true });
const down: RemoteResult = { rc: 255, stdout: "", stderr: "ssh: connect to host x port 22: No route to host", ran: true };
const H = (n: number): string => n.toString(36).padStart(32, "a").slice(-32);

// A NixOS closure big enough to pass coverage, with glibc in it.
function nixProbe(extra: string[] = [], containers: string[] = []): string {
  const paths = [`/nix/store/${H(1)}-glibc-2.42-84`, `/nix/store/${H(2)}-glibc-2.42-84-getent`, `/nix/store/${H(3)}-openssl-3.6.4`,
    `/nix/store/${H(4)}-etc`, `/nix/store/${H(5)}-dbus-1`, `/nix/store/${H(6)}-dbus-1.16.2`];
  for (let i = 0; i < 60; i++) paths.push(`/nix/store/${H(100 + i)}-lib${i}-1.${i}.0`);
  return ["@@nixos", ...paths, ...extra, ...containers.map((c) => `@@container ${c}`), "@@end"].join("\n");
}

const debProbe = ["@@os-release", 'ID=debian', 'VERSION_ID="13"', "@@debian_version", "13.7", "@@dpkg",
  "Package: libc6", "Status: install ok installed", "Version: 2.41-12", "", "@@end"].join("\n");

const fwProbe = (upgrade: boolean): string => ["@@pkgs", "unbound 1.25.1_1", "openssl 3.0.21,1", "beep 1.0_2", "@@audit",
  "unbound-1.25.1_1 is vulnerable:", "  Unbound -- multiple vulnerabilities", "  CVE: CVE-2026-77860", "  CVE: CVE-2026-85501",
  "  WWW: https://vuxml.FreeBSD.org/x.html", "", "1 problem(s) in 1 installed package(s) found.", "@@upgrades",
  ...(upgrade ? ["The following 1 package(s) will be affected:", "\tunbound: 1.25.1_1 -> 1.25.2"] : ["Your packages are up to date."]),
  "@@vulnxml", String(Math.floor(Date.parse("2026-09-26T00:00:00Z") / 1000)), "@@version", "OPNsense 26.1.11_10 (amd64)", "@@end"].join("\n");

function grypeJson(ms: Array<[string, string, string, string]>): string {
  return JSON.stringify({ matches: ms.map(([id, sev, name, ver]) => ({
    vulnerability: { id, severity: sev }, artifact: { name, version: ver, purl: `pkg:nix/${name}@${ver}` } })) });
}

function trivyJson(family: string, pkgs: number, vulns: Array<[string, string, string, string]>): string {
  return JSON.stringify({
    Metadata: family ? { OS: { Family: family, Name: "13.7" } } : {},
    Results: [{
      Packages: Array.from({ length: pkgs }, (_, i) => ({ Name: `p${i}`, Version: "1.0", PkgIdentifier: { PURL: `pkg:deb/debian/p${i}@1.0` } })),
      Vulnerabilities: vulns.map(([id, sev, pkg, fixed]) => ({ VulnerabilityID: id, Severity: sev, PkgName: pkg, InstalledVersion: "1.0",
        FixedVersion: fixed, PkgIdentifier: { PURL: `pkg:deb/debian/${pkg}@1.0?arch=amd64` } })),
    }],
  });
}

class FakeIO implements SecurityIO {
  local = ok(nixProbe());
  guests = new Map<string, RemoteResult>();
  lxc = new Map<string, RemoteResult>(); // `${node}/${vmid}`
  nodes = new Map<string, RemoteResult>();
  firewall = ok(fwProbe(false));
  cpe: Record<string, CpeParts | null> | null = { glibc: { vendor: "gnu", product: "glibc" }, openssl: { vendor: "openssl", product: "openssl" } };
  grypeOut = ok(grypeJson([["CVE-2026-5450", "Critical", "glibc", "2.42-84"]]));
  rootfs = ok(trivyJson("debian", 813, [["CVE-2026-1", "HIGH", "libc6", ""]]));
  images = new Map<string, RemoteResult>();
  free = 100 * 1024 ** 3;
  total = 200 * 1024 ** 3;
  caches = true;
  probes: string[] = [];
  grypeInputs: string[] = [];
  now(): number { return Date.parse("2026-09-27T12:00:00Z"); }
  probeLocal(s: string): RemoteResult { this.probes.push(`local:${s === LINUX_PROBE}`); return this.local; }
  probeGuest(h: string, s: string): RemoteResult { this.probes.push(`guest:${h}:${s === LINUX_PROBE}`); return this.guests.get(h) ?? down; }
  probeLxc(n: string, v: number): RemoteResult { this.probes.push(`lxc:${n}/${v}`); return this.lxc.get(`${n}/${v}`) ?? down; }
  probeNode(n: string): RemoteResult { this.probes.push(`node:${n}`); return this.nodes.get(n) ?? down; }
  probeFirewall(s: string): RemoteResult { this.probes.push(`fw:${s === OPNSENSE_PROBE}`); return this.firewall; }
  severities: Record<string, string> | null = {};
  cveSeverities(): Record<string, string> | null { return this.severities; }
  nixCpeParts(): Record<string, CpeParts | null> | null { return this.cpe; }
  dbUpdate(): string[] { return []; }
  grype(f: string): RemoteResult { this.grypeInputs.push(readFileSync(f, "utf8")); return this.grypeOut; }
  trivyRootfs(): RemoteResult { return this.rootfs; }
  trivyImage(ref: string): RemoteResult { return this.images.get(ref) ?? { rc: 1, stdout: "", stderr: "FATAL image not found", ran: true }; }
  versions(): Record<string, string> { return { grype: "0.112.0", trivy: "0.72.0" }; }
  diskSpace(): { free: number; total: number } { return { free: this.free, total: this.total }; }
  cachesPresent(): boolean { return this.caches; }
  hostname(): string { return "tappaas-cicd"; }
}

function site(): string {
  const dir = mkdtempSync(join(tmpdir(), "hm-sec-"));
  const w = (n: string, o: unknown): void => writeFileSync(join(dir, `${n}.json`), JSON.stringify(o));
  w("site", { name: "rossen", hardware: { nodes: [{ name: "tappaas1" }] } });
  w("tappaas-cicd", { vmname: "tappaas-cicd", vmid: 130, node: "tappaas1", zone0: "mgmt", status: "Production" });
  w("identity", { vmname: "identity", vmid: 140, node: "tappaas1", zone0: "mgmt", status: "Development" });
  w("network", { vmname: "network", vmid: 110, node: "tappaas1", zone0: "mgmt", provides: ["proxy", "rules"] });
  w("vllm-amd", { vmname: "vllm-amd", vmid: 312, node: "tappaas2", kind: "lxc", zone0: "rossen" });
  w("coturn", { vmname: "coturn", vmid: 341, node: "tappaas1", zone0: "dmz" });
  w("old", { vmname: "old", vmid: 999, node: "tappaas1", status: "archived" });
  return dir;
}

const repo = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "hm-sec-repo-"));
  mkdirSync(join(dir, "src", "apps", "identity"), { recursive: true });
  return dir;
};

// ── store paths ──────────────────────────────────────────────────────
console.log("parseStorePath / nixComponents");
{
  const p = (s: string): string => JSON.stringify(parseStorePath(`/nix/store/${H(9)}-${s}`));
  check(p("glibc-2.42-84") === '["glibc","2.42-84"]', "glibc-2.42-84 → glibc 2.42-84");
  check(p("glibc-2.42-84-getent") === '["glibc","2.42-84"]', "a split output after the version is not part of it");
  check(p("util-linux-2.42.3-swap") === '["util-linux","2.42.3"]', "util-linux-2.42.3-swap → util-linux 2.42.3");
  check(p("openssl-3.6.4-bin") === '["openssl","3.6.4"]', "a known output suffix is dropped");
  check(p("etc") === "null" && p("unit-foo.service") === "null", "an unversioned path has no identity");
  const c = nixComponents(parseLinuxProbe(nixProbe()).paths);
  check(c.components.filter((x) => x.name === "glibc").length === 1, "glibc and glibc-getent are one component");
  check(!c.components.some((x) => x.name === "dbus" && x.version === "1"), "dbus-1 (an API directory) is dropped next to dbus-1.16.2");
  check(c.dropped === 2, `unversioned and API-directory paths are counted (${c.dropped})`);
}

// ── CPE vendor from nixpkgs ──────────────────────────────────────────
console.log("applyCpes");
{
  const c = nixComponents([`/nix/store/${H(1)}-glibc-2.42-84`, `/nix/store/${H(2)}-libmicrohttpd-1.0.2`]).components;
  const n = applyCpes(c, { glibc: { vendor: "gnu", product: "glibc" }, libmicrohttpd: { vendor: null, product: "libmicrohttpd" } });
  check(c[0].cpe === "cpe:2.3:a:gnu:glibc:2.42-84:*:*:*:*:*:*:*", "nixpkgs' vendor: gnu:glibc, which NVD matches");
  check(c[1].cpe?.startsWith("cpe:2.3:a:libmicrohttpd:libmicrohttpd:") === true, "no vendor in nixpkgs → vendor = product");
  check(c[0].properties?.[0].value === "nixpkgs-meta" && c[1].properties?.[0].value === "naive", "each component says where its vendor came from");
  check(n === 1, "one of two from nixpkgs meta");
  const d = nixComponents([`/nix/store/${H(1)}-glibc-2.42-84`]).components;
  applyCpes(d, null);
  check(d[0].properties?.[0].value === "naive", "a failed nixpkgs evaluation degrades to naive, it does not drop the component");
  // The ffmpeg Jellyfin runs: nixpkgs declares only product jellyfin-ffmpeg, which NVD never lists.
  const j = nixComponents([`/nix/store/${H(3)}-jellyfin-ffmpeg-7.1.4-3-bin`, `/nix/store/${H(4)}-ffmpeg-8.1.2-lib`,
    `/nix/store/${H(5)}-ffmpeg-headless-8.1.2-lib`]).components;
  check(j[0].name === "jellyfin-ffmpeg" && j[0].version === "7.1.4-3", "jellyfin-ffmpeg-7.1.4-3-bin → jellyfin-ffmpeg 7.1.4-3");
  applyCpes(j, { "jellyfin-ffmpeg": { vendor: null, product: "jellyfin-ffmpeg" }, ffmpeg: { vendor: null, product: "ffmpeg" } });
  check(j[0].cpe === "cpe:2.3:a:ffmpeg:ffmpeg:7.1.4:*:*:*:*:*:*:*", "a fork is matched as upstream ffmpeg at the release it carries");
  check(j[0].purl === "pkg:nix/jellyfin-ffmpeg@7.1.4-3" && j[0].properties?.[0].value === "fork", "the fork keeps its own purl for findings and VEX");
  check(j[1].cpe === "cpe:2.3:a:ffmpeg:ffmpeg:8.1.2:*:*:*:*:*:*:*", "plain ffmpeg is unchanged");
  check(j[2].cpe === "cpe:2.3:a:ffmpeg:ffmpeg:8.1.2:*:*:*:*:*:*:*", "a build variant (ffmpeg-headless) is ffmpeg at its own version");
}

// ── probes ───────────────────────────────────────────────────────────
console.log("parseLinuxProbe / parseOpnsenseProbe");
{
  const lp = parseLinuxProbe(nixProbe([], ["podman|authentik-server|ghcr.io/goauthentik/server:2025.2.1|ghcr.io/goauthentik/server@sha256:53ab,ghcr.io/goauthentik/server@sha256:dc07"]));
  check(lp.os === "nixos" && lp.complete && lp.paths.length === 66, "NixOS closure read, @@end seen");
  check(lp.containers.length === 1 && lp.containers[0].digests[0] === "ghcr.io/goauthentik/server@sha256:53ab", "a running container and its registry digests");
  const two = parseLinuxProbe(nixProbe([], ["podman|authentik-server|a:1|a@sha256:1", "podman|authentik-worker|a:1|a@sha256:1", "podman|redis|r:7|r@sha256:2"]));
  check(groupByImage(two.containers).map((g) => g.length).join(",") === "2,1", "two containers on one image are one image to scan");
  // The same containers, listed in the other order and with the digests swapped:
  // the target must come out identical, or every finding reads as new and the
  // owner gets a security notice every morning.
  const a = parseLinuxProbe(nixProbe([], ["podman|authentik-server|a:1|a@sha256:2,a@sha256:1", "podman|authentik-worker|a:1|a@sha256:1,a@sha256:2"]));
  const b = parseLinuxProbe(nixProbe([], ["podman|authentik-worker|a:1|a@sha256:2,a@sha256:1", "podman|authentik-server|a:1|a@sha256:1,a@sha256:2"]));
  const first = (p: typeof a): string => groupByImage(p.containers).map((g) => `${g.map((c) => c.name).join("+")}@${g[0].digests[0]}`).join(" ");
  check(first(a) === first(b) && first(a) === "authentik-server+authentik-worker@a@sha256:1",
    `an image's target is the same whatever order podman lists its containers and digests in (${first(a)} / ${first(b)})`);
  const cut = parseLinuxProbe(nixProbe().replace("@@end", ""));
  check(!cut.complete, "output without @@end is known to be cut short");
  const deb = parseLinuxProbe(debProbe);
  check(deb.os === "debian" && deb.debianVersion === "13.7" && deb.dpkg.includes("Package: libc6"), "Debian: os-release, debian_version, dpkg status");
  const fw = parseOpnsenseProbe(fwProbe(true), Date.parse("2026-09-27T12:00:00Z"));
  check(fw.pkgs.length === 3 && fw.audit[0].pkg === "unbound-1.25.1_1" && fw.audit[0].cves.length === 2, "pkg audit: vulnerable package and its CVEs");
  check(fw.upgrades.has("unbound") && fw.auditRan && fw.vulnXmlAgeDays === 1, "the channel's upgrade, audit ran, VuXML age");
}

// ── coverage + verdicts ──────────────────────────────────────────────
console.log("summarize: coverage and verdicts");
{
  const base = { id: "t", name: "t", layer: "debian" as const, host: "h" };
  const f = (id: string, severity: string, fixed: string, pkg = "p"): Finding => ({ id, severity, pkg, installed: "1", fixed, purl: `pkg:deb/debian/${pkg}@1` });
  const failedEmpty = summarize(base, 0, "the scanner detected no operating system", [], [], true);
  check(failedEmpty.verdict === "failed" && failedEmpty.coverage === "fail", "0 packages seen → SCAN FAILED, never clean (the 4b case)");
  check(summarize(base, 9, "", [f("A", "Critical", "2"), f("B", "Low", "")], [], true).verdict === "act", "Critical with a fix → act");
  check(summarize(base, 9, "", [f("A", "Medium", "2")], [], true).verdict === "act-low", "only Medium fixable → act-low");
  check(summarize(base, 9, "", [f("A", "Critical", "")], [], true).verdict === "watch", "Critical without a fix → watch (upstream)");
  const nix = summarize({ ...base, layer: "nix" }, 400, "", [f("A", "Critical", "")], [], false);
  check(nix.verdict === "triage" && nix.fixable === null, "Nix → triage, fix-state unknown (null, not 0)");
  const dup = summarize(base, 9, "", [f("A", "High", "2", "x"), f("A", "High", "2", "y")], [], true);
  check(dup.findings === 1 && dup.high === 1 && dup.critHighKeys.length === 2, "counts are unique CVE ids; keys keep the package");
}

console.log("summarizeOpnsense");
{
  const base = { id: "network", name: "network (firewall)", layer: "opnsense" as const, host: "fw" };
  const now = Date.parse("2026-09-27T12:00:00Z");
  const withUpd = summarizeOpnsense(base, parseOpnsenseProbe(fwProbe(true), now), []);
  check(withUpd.verdict === "act" && withUpd.act.length === 2, "a vulnerable package the channel updates → act");
  const noUpd = summarizeOpnsense(base, parseOpnsenseProbe(fwProbe(false), now), []);
  check(noUpd.verdict === "watch" && noUpd.findings === 2, "no update on the channel → watch, CVEs still counted");
  check(summarizeOpnsense(base, null, []).verdict === "failed", "an unreachable firewall is a failed scan");
  const noAudit = parseOpnsenseProbe(fwProbe(false).replace(/@@audit[\s\S]*@@upgrades/, "@@audit\n@@upgrades"), now);
  check(summarizeOpnsense(base, noAudit, []).verdict === "failed", "pkg audit that printed nothing did not run → failed");
  check(noUpd.critical === 0 && noUpd.high === 0 && noUpd.note.includes("severity unknown"), "no severity looked up: Unknown, and the note says so");
  const sev = summarizeOpnsense(base, parseOpnsenseProbe(fwProbe(false), now), [], { "CVE-2026-77860": "Critical", "CVE-2026-85501": "High" });
  check(sev.critical === 1 && sev.high === 1 && sev.critHighKeys.join(",") === "CVE-2026-77860 unbound,CVE-2026-85501 unbound",
    "VuXML has no severity: the CVE database's counts the firewall's critical/high (it showed 0 of 42)");
  const picked = pickSeverities([
    { id: "CVE-1", provider: "ubuntu", severity: "medium" }, { id: "CVE-1", provider: "nvd", severity: "high" }, { id: "CVE-1", provider: "alpine", severity: "critical" },
    { id: "cve-2", provider: "debian", severity: "negligible" }, { id: "CVE-2", provider: "rhel", severity: "low" }, { id: "CVE-3", provider: "x", severity: "unknown" }]);
  check(picked["CVE-1"] === "High" && picked["CVE-2"] === "Low" && !("CVE-3" in picked), "NVD's severity first, else the highest; ids case-folded; unknown is no severity");
}

console.log("build-only packages, modules");
{
  check(["linux-libc-dev", "proxmox-headers-7.0.14-23-pve", "gcc-14", "cpp-14-x86-64-linux-gnu", "libssl-dev", "binutils-common"].every(isBuildOnly),
    "kernel headers, compilers and -dev packages are build-only");
  check(!["libssl3t64", "linux-image-amd64", "proxmox-kernel-7.0", "gcc-14-base", "libgcc-s1", "sudo"].some(isBuildOnly), "…what runs is not (gcc-14-base is a runtime package)");
  check(moduleOf("node:tappaas2") === "cluster" && moduleOf("image:identity/authentik-server") === "identity" && moduleOf("coturn") === "coturn",
    "a node is an instance of cluster; an image of its module");
  const dir = mkdtempSync(join(tmpdir(), "hm-apt-"));
  writeFileSync(join(dir, "backup.json"), JSON.stringify({ imageType: "apt", node: "tappaas3" }));
  writeFileSync(join(dir, "coturn.json"), JSON.stringify({ vmid: 341, node: "tappaas1" }));
  check(JSON.stringify(aptModules(dir, "tappaas1")) === '{"tappaas3":["backup"]}', "a module installed as packages (imageType apt) is found on its node, with no vmid");
}

// ── VEX ──────────────────────────────────────────────────────────────
console.log("VEX");
{
  const vex = parseVex(JSON.stringify({ vulnerabilities: [
    { id: "CVE-1", analysis: { state: "not_affected" }, affects: [{ ref: "pkg:nix/glibc@2.42-84" }] },
    { id: "CVE-2", analysis: { state: "false_positive" }, affects: [{ ref: "pkg:nix/tar" }] },
    { id: "CVE-3", analysis: { state: "in_triage" } },
    { id: "CVE-4", analysis: { state: "resolved" } },
  ] }), "x-vex.json");
  const f = (id: string, purl: string): Finding => ({ id, severity: "High", pkg: "p", installed: "", fixed: "", purl });
  check(vexSuppresses(f("CVE-1", "pkg:nix/glibc@2.42-84"), vex), "a versioned statement decides that version");
  check(!vexSuppresses(f("CVE-1", "pkg:nix/glibc@2.43"), vex), "…and not the next one, which is looked at again");
  check(vexSuppresses(f("CVE-2", "pkg:nix/tar@0.4.45"), vex), "an unversioned ref covers every version");
  check(!vexSuppresses(f("CVE-3", "pkg:nix/x@1"), vex), "in_triage decides nothing");
  check(vexSuppresses(f("CVE-4", "pkg:deb/debian/x@1?arch=amd64"), vex), "no affects = every package; qualifiers ignored");
  const s = summarize({ id: "t", name: "t", layer: "nix", host: "h" }, 100, "", [f("CVE-1", "pkg:nix/glibc@2.42-84"), f("CVE-9", "pkg:nix/a@1")], vex, false);
  check(s.findings === 1 && s.suppressed === 1, "suppressed findings are counted, not listed");
}

// ── VEX from every registered repository ─────────────────────────────
console.log("loadVex");
{
  const cfg = mkdtempSync(join(tmpdir(), "hm-vex-cfg-"));
  const mkRepo = (name: string, module: string, rel: string): string => {
    const root = mkdtempSync(join(tmpdir(), `hm-vex-${name}-`));
    mkdirSync(join(root, rel), { recursive: true });
    writeFileSync(join(root, "src", "module-catalog.json"), JSON.stringify({ modules: [{ name: module, moduleJson: `${rel}/${module}.json` }] }));
    return root;
  };
  const vexDoc = (id: string): string => JSON.stringify({ vulnerabilities: [{ id, analysis: { state: "not_affected" } }] });
  const tappaas = mkRepo("tappaas", "templates", "src/foundation/templates");
  const community = mkRepo("community", "gitea", "src/someone/dev/gitea");
  writeFileSync(join(tappaas, "src/foundation/templates/templates-vex.json"), vexDoc("CVE-A"));
  writeFileSync(join(community, "src/someone/dev/gitea/gitea-vex.json"), vexDoc("CVE-B"));
  writeFileSync(join(community, "src/stray-vex.json"), vexDoc("CVE-STRAY"));
  writeFileSync(join(community, "src/someone/dev/gitea/broken-vex.json"), "{not json");
  writeFileSync(join(cfg, "site.json"), JSON.stringify({ repositories: [
    { name: "TAPPaaS", path: tappaas, catalog: "src/module-catalog.json" },
    { name: "Community", path: community } ] }));
  const v = loadVex(cfg, "/nonexistent");
  const ids = v.statements.map((s) => s.id).sort().join(",");
  check(ids === "CVE-A,CVE-B", `a VEX file in a Community module counts as much as one in TAPPaaS (${ids})`);
  check(!ids.includes("STRAY"), "a VEX file outside every registered module is not read");
  check(v.unreadable.length === 1 && v.unreadable[0].endsWith("broken-vex.json"), "an unparseable VEX file is reported, not silently skipped");
  check(registeredModuleDirs(join(cfg, "none"), tappaas).length === 1, "no registered repositories → the tree the scan ships in");
  const by = Object.fromEntries(v.statements.map((s) => [s.id, s.module]));
  check(by["CVE-A"] === "" && by["CVE-B"] === "gitea", "templates-vex.json is everyone's; <module>-vex.json is that module's");
  const at = (t: string): string => vexFor(v.statements, t).map((s) => s.id).sort().join(",");
  check(at("gitea") === "CVE-A,CVE-B" && at("image:gitea/server") === "CVE-A,CVE-B", "a module's target and its images get the base and its own");
  check(at("forgejo") === "CVE-A", "…another module only the base: a decision about gitea's use of a package is not forgejo's");
  check(vexFor([{ id: "C", state: "not_affected", refs: [], source: "s", module: "cluster" }], "node:tappaas1").length === 1, "a Proxmox node is the cluster module's");
}

// ── the whole scan, offline ──────────────────────────────────────────
console.log("runScan");
{
  const dir = site();
  const io = new FakeIO();
  io.guests.set("identity.mgmt.internal", ok(nixProbe([], ["podman|authentik-server|ghcr.io/goauthentik/server:2025.2.1|ghcr.io/goauthentik/server@sha256:dc07",
    "podman|authentik-worker|ghcr.io/goauthentik/server:2025.2.1|ghcr.io/goauthentik/server@sha256:dc07"])));
  io.images.set("ghcr.io/goauthentik/server@sha256:dc07", ok(trivyJson("debian", 425, [["CVE-2025-1", "CRITICAL", "libxml2", "2.9.14"], ["CVE-2025-2", "LOW", "tar", ""]])));
  io.lxc.set("tappaas3/312", ok(debProbe));
  io.nodes.set("tappaas1", ok(debProbe));
  io.rootfs = ok(trivyJson("debian", 813, [["CVE-2026-1", "HIGH", "libc6", ""], ["CVE-2026-1", "HIGH", "linux-libc-dev", ""], ["CVE-2026-7", "HIGH", "linux-libc-dev", ""]]));
  io.severities = { "CVE-2026-77860": "Critical" };
  writeFileSync(join(dir, "backup.json"), JSON.stringify({ imageType: "apt", node: "tappaas1" }));
  const client = new FakeClusterClient();
  client.actualNodes.set("tappaas2/312", "tappaas3"); // HA moved the container
  const { status, cdx } = runScan({ configDir: dir, defaultNode: "tappaas1", repoDir: repo() }, client, io);
  const t = (id: string): TargetStatus | undefined => status.targets.find((x) => x.id === id);
  check(io.probes.includes("local:true"), "the mothership probes itself locally");
  check(io.probes.includes("lxc:tappaas3/312"), "a container is probed through pct on the node it RUNS on");
  check(io.probes.includes("fw:true") && !io.probes.some((p) => p.startsWith("guest:network")), "the rules provider is scanned as OPNsense");
  check(!t("old"), "an archived module is not a target");
  check(t("tappaas-cicd")?.verdict === "triage" && t("identity")?.verdict === "triage", "Nix closures land in triage");
  check(io.grypeInputs[0].includes("cpe:2.3:a:gnu:glibc:2.42-84"), "grype gets the nixpkgs vendor for glibc");
  const img = t("image:identity/authentik-server");
  check(img?.verdict === "act" && img.critHighFixable === 1 && img.ref === "ghcr.io/goauthentik/server@sha256:dc07", "the running image, by digest: act");
  check(img?.runsOn?.length === 2 && !t("image:identity/authentik-worker"), "server and worker: one image target naming both");
  check(t("vllm-amd")?.layer === "debian" && t("node:tappaas1")?.verdict === "watch", "Debian container and node scanned by trivy");
  const n1 = t("node:tappaas1");
  check(n1?.high === 1 && n1.buildOnly === 1 && n1.note.includes("1 CVE(s) only in build-only packages"),
    "a CVE only in kernel headers is not counted, but said; one also in a running package still counts");
  check(n1?.module === "cluster" && n1.apt?.join(",") === "backup" && n1.note.includes("Proxmox packages (kernel, QEMU, backup) not matched"),
    "a node is cluster's, carries the apt-installed backup, and says what no feed covers");
  check(t("image:identity/authentik-server")?.module === "identity" && t("network")?.critical === 1, "an image is its module's; the firewall's severity is looked up");
  const c = t("coturn");
  check(c?.verdict === "failed" && c.note.startsWith("unreachable"), "an unreachable guest is SCAN FAILED with the reason");
  const comps = (cdx.components as Array<Record<string, unknown>>);
  const idc = comps.find((x) => x["bom-ref"] === "image:identity/authentik-server");
  check(cdx.bomFormat === "CycloneDX" && cdx.specVersion === "1.4" && idc?.type === "container" && (idc.components as unknown[]).length === 425,
    "one CycloneDX document: each target a component, its packages nested");
  check(comps.find((x) => x["bom-ref"] === "tappaas-cicd")?.type === "operating-system", "a closure is an operating-system component");

  // the rules around it
  const io2 = new FakeIO();
  io2.caches = false;
  io2.free = 9 * 1024 ** 3; // hrossen: 32 GB root, 9 GB free
  io2.total = 32 * 1024 ** 3;
  const r2 = runScan({ configDir: dir, defaultNode: "tappaas1", repoDir: repo() }, client, io2).status;
  check(r2.notes.some((n) => n.includes("over the 80% disk gate")) && r2.targets.filter((x) => x.layer !== "opnsense").every((x) => x.verdict === "failed"),
    "databases that would take the root disk over 80% → nothing is scanned, and nothing reads clean");
  check(dbSpaceProblem(20 * 1024 ** 3, 32 * 1024 ** 3) === "" && dbSpaceProblem(9 * DB_SPACE_BYTES, 10 * DB_SPACE_BYTES) === "",
    "room enough → no objection");
  const io3 = new FakeIO();
  io3.local = ok(nixProbe().split("\n").filter((l) => !l.includes("glibc")).join("\n"));
  check(runScan({ configDir: dir, defaultNode: "tappaas1", repoDir: repo() }, client, io3).status.targets.find((x) => x.id === "tappaas-cicd")?.verdict === "failed",
    "a closure without glibc fails coverage");
  const io4 = new FakeIO();
  io4.nodes.set("tappaas1", ok(debProbe));
  io4.rootfs = ok(trivyJson("", 0, []));
  check(runScan({ configDir: dir, defaultNode: "tappaas1", repoDir: repo() }, client, io4).status.targets.find((x) => x.id === "node:tappaas1")?.verdict === "failed",
    "trivy detecting no OS (no /etc/debian_version) is SCAN FAILED, not 0 vulnerabilities");
}

// ── persistence, diff, the gate, the report ──────────────────────────
console.log("writeScan / diffScans / checkCveStatus / report");
{
  const dir = site();
  const now = Date.parse("2026-09-27T12:00:00Z");
  const mk = (targets: Partial<TargetStatus>[], generated = "2026-09-27T12:00:00.000Z"): ScanStatus => ({
    schema: 1, generated, sweep: null, scanners: {}, notes: [],
    targets: targets.map((x) => ({ id: "x", name: "x", layer: "debian", host: "h", coverage: "ok", note: "", seen: 1, findings: 0, critical: 0, high: 0,
      fixable: 0, critHighFixable: 0, suppressed: 0, verdict: "watch", act: [], critHighKeys: [], new: [], ...x })),
  });
  const actF: Finding = { id: "CVE-1", severity: "Critical", pkg: "p", installed: "1", fixed: "2", purl: "" };
  const first = mk([{ id: "a", verdict: "act", act: [actF], critHighKeys: ["CVE-1 p"], critHighFixable: 1 }, { id: "b" }]);
  const d1 = writeScan(dir, first, { bomFormat: "CycloneDX" });
  check(d1.newAct.length === 1 && first.targets[0].new.length === 1, "first scan: everything to act on is new");
  check(existsSync(join(sbomDir(dir), STATUS_FILE)) && existsSync(join(sbomDir(dir), "site.cdx.json")), "status and CycloneDX written under config/sbom");
  const second = mk([{ id: "a", verdict: "act", act: [actF], critHighKeys: ["CVE-1 p"], critHighFixable: 1 }, { id: "b", verdict: "failed", coverage: "fail", note: "unreachable" }]);
  const d2 = writeScan(dir, second, {});
  check(d2.newAct.length === 0 && d2.newlyFailed.length === 1, "second scan: the same ACT is not new; a new failure is");
  check(readStatus(join(sbomDir(dir), PREVIOUS_FILE))?.targets[1].verdict === "watch", "the previous scan is kept");
  check(diffScans(second, second).newlyFailed.length === 0, "a target that stays failed is not re-announced");

  const g = checkCveStatus(dir, now);
  check(g.status === "warn" && (g.rows ?? []).length === 2, "gate: an ACT and a failed scan are WARN rows");
  const clean = site();
  writeScan(clean, mk([{ id: "a", verdict: "triage", fixable: null }]), {});
  check(checkCveStatus(clean, now).status === "pass", "gate: nothing to act on → pass");
  check(checkCveStatus(clean, now + 20 * 86_400_000).status === "warn", "gate: a scan older than 8 days → warn");
  check(checkCveStatus(site(), now).status === "skip", "gate: no scan yet → skip");
  check(![g, checkCveStatus(clean, now + 99 * 86_400_000)].some((x) => x.status === "fail"), "gate: never FAIL");

  check(fit("authentik-server, authentik-worker (identity)", 30).length === 30 && fit("authentik-server, authentik-worker (identity)", 30).endsWith("… "),
    "a long target name is cut and still leaves a space before the verdict");
  check(fit("coturn", 30) === "coturn".padEnd(30), "a short name is padded, not cut");
  const lines = renderReport(second, false, now);
  check(lines.some((l) => l.includes("ACT: 1 critical/high fixable")) && lines.some((l) => l.includes("SCAN FAILED — not clean: unreachable")),
    "report: verdicts spelled out");
  check(lines.findIndex((l) => l.includes("ACT:")) < lines.findIndex((l) => l.includes("SCAN FAILED")), "report: ACT first, then failures");

  // --if-new-sweep
  const sw = site();
  check(!sweepIsNewer(sw), "no sweep result → no scan");
  writeFileSync(join(sw, "last-update-result.json"), '{"ok":true}');
  check(sweepIsNewer(sw), "a sweep result and no scan → scan");
  writeScan(sw, mk([{ id: "a" }]), {});
  utimesSync(join(sw, "last-update-result.json"), new Date(now - 3_600_000), new Date(now - 3_600_000));
  utimesSync(join(sbomDir(sw), STATUS_FILE), new Date(now), new Date(now));
  check(!sweepIsNewer(sw), "the scan is newer than the sweep → nothing to do");

  // the verbs
  const client = new FakeClusterClient();
  check(run(["report", "security", "--config-dir", site()], client) === 1, "report security without a scan → exit 1");
  check(run(["report", "security", "--config-dir", dir], client) === 0, "report security → exit 0");
  check(run(["scan", "security", "--if-new-sweep", "--config-dir", site()], client) === 0, "scan --if-new-sweep with no new sweep → exit 0, nothing run");
  check(run(["scan", "security", "--bogus", "--config-dir", site()], client) !== 0, "an option the verb does not take is refused");
}

// ── scan nix-list: a package list matched as if it ran (#788) ──
{
  const io = new FakeIO();
  const r = scanComponentList([{ name: "glibc", version: "2.42-84" }, { name: "glibc", version: "2.42-84" }, { name: "zlib", version: "" }], io);
  check(r.error === "" && r.findings.length === 1 && r.findings[0].id === "CVE-2026-5450", "a listed package is matched like a scanned one");
  const io2v = new FakeIO();
  io2v.grypeOut = ok(grypeJson([["CVE-2026-84782", "High", "openssl", "3.6.4"], ["CVE-2026-84782", "High", "openssl", "3.6.5"]]));
  const two = scanComponentList([{ name: "openssl", version: "3.6.4" }, { name: "openssl", version: "3.6.5" }], io2v);
  check(two.findings.map((f) => f.installed).sort().join(",") === "3.6.4,3.6.5", "one CVE in two versions of a package stays a finding for each (a list holds many targets)");
  const sbom = JSON.parse(io.grypeInputs[0]);
  check(sbom.components.length === 1, "duplicates and versionless entries are not sent to the matcher");
  check(String(sbom.components[0].cpe).startsWith("cpe:2.3:a:gnu:glibc:2.42-84"), "…with the CPE vendor from nixpkgs");
  io.grypeOut = { rc: 1, stdout: "", stderr: "db missing", ran: true };
  check(scanComponentList([{ name: "glibc", version: "2.42-84" }], io).error.startsWith("grype failed"), "a failed matcher is an error, not zero findings");
  check(scanComponentList([], new FakeIO()).error !== "", "an empty list is an error, not a clean result");
}

// ── scan images: by registry reference, nothing running (#788) ──
{
  const io = new FakeIO();
  io.images.set("ex/app:1", ok(trivyJson("debian", 100, [["CVE-2026-9", "CRITICAL", "libc6", "2.36-9+deb12u5"]])));
  const r = scanImageRefs(["ex/app:1", "ex/app:1", "ex/gone:2"], io);
  check(Object.keys(r).length === 2, "each reference is scanned once");
  check(r["ex/app:1"].findings.length === 1 && r["ex/app:1"].error === "", "an image's findings come back by reference");
  check(r["ex/gone:2"].error.startsWith("trivy failed"), "an image trivy cannot fetch is an error, not zero findings");
}

// ── VEX in the preview's verbs: the scan's rule, suppressed kept apart (#788) ──
{
  const io = new FakeIO();
  const vex = parseVex(JSON.stringify({ vulnerabilities: [{ id: "CVE-2026-5450", analysis: { state: "not_affected" }, affects: [{ ref: "pkg:nix/glibc@2.42-84" }] }] }), "t");
  const r = scanComponentList([{ name: "glibc", version: "2.42-84" }], io, vex);
  check(r.findings.length === 0 && r.suppressed.length === 1 && r.suppressed[0].id === "CVE-2026-5450", "a VEX statement suppresses a listed package's finding, and it is returned as suppressed");
  const io2 = new FakeIO();
  io2.grypeOut = ok(grypeJson([["CVE-2026-5450", "Critical", "glibc", "2.42-100"]]));
  const r2 = scanComponentList([{ name: "glibc", version: "2.42-100" }], io2, vex);
  check(r2.findings.length === 1 && r2.suppressed.length === 0, "…a versioned statement stops applying at another version");
  const io3 = new FakeIO();
  io3.images.set("ex/app:1", ok(trivyJson("debian", 100, [["CVE-2026-9", "CRITICAL", "libc6", "2.36-9+deb12u5"]])));
  const v3 = parseVex(JSON.stringify({ vulnerabilities: [{ id: "CVE-2026-9", analysis: { state: "false_positive" } }] }), "t");
  check(scanImageRefs(["ex/app:1"], io3, v3)["ex/app:1"].suppressed.length === 1, "…and in an image, the same rule");
  const v4 = [...parseVex(JSON.stringify({ vulnerabilities: [{ id: "CVE-2026-5450", analysis: { state: "not_affected" } }] }), "a", "nextcloud"),
    ...parseVex(JSON.stringify({ vulnerabilities: [{ id: "CVE-2026-5450", analysis: { state: "false_positive" } }] }), "b", "immich")];
  const r4 = scanComponentList([{ name: "glibc", version: "2.42-84" }], new FakeIO(), v4);
  check(r4.suppressed[0]?.vexModules?.join(",") === "immich,nextcloud", "a list mixes modules: a suppressed finding names whose statements decided it");
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
