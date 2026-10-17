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
import { moduleOfLocation, moduleSourceOf } from "../../../lib/ts/src/instance";
import { isManaged, loadConfigModules, readModuleJson, siteNodeHostnames } from "./config";
import { guestTarget } from "./checks";
import { CheckResult, CheckRow, CheckStatus, CheckSubject, ClusterClient } from "./types";

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
  vexModules?: string[]; // a list scan's suppressed finding: whose statements decided it ("" = templates, every module)
  triage?: { module: string; state: string; risk: string }[]; // a list scan's kept finding: analysed, still counted (exploitable)
  unversioned?: boolean; // matched on a CVE record with no version range: every version "matches" — check first
}

export interface TargetStatus {
  id: string; // stable key across scans: "node:tappaas1", "identity", "image:identity/authentik-server"
  name: string;
  module?: string; // the module it is an instance of: a node is pvehost's, an image its module's
  apt?: string[]; // modules installed on this host as packages (imageType apt), e.g. backup
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
  buildOnly?: number; // CVE ids found only in build-only packages (headers, compilers) — not counted
  verdict: Verdict;
  act: Finding[]; // what ACT refers to
  critHighKeys: string[]; // "<id> <pkg>" of every Critical/High finding — the diff base
  critHighRisk?: string[]; // ids of those an `exploitable` statement analysed (RISK), still counted
  riskLevel?: string; // the worst risk-here among them
  critHighVex?: string[]; // Critical/High ids a VEX statement decided — not counted
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
// A fork or build variant packaged under its own name is matched as upstream
// at the release it carries: jellyfin-ffmpeg 7.1.4-3 is ffmpeg 7.1.4 plus
// Jellyfin's patch set, ffmpeg-headless a smaller build of the same source, and
// NVD lists their CVEs only under ffmpeg:ffmpeg. grype compares the CPE's
// version, so the component keeps its own name, version and purl (VEX refs).
const NIX_FORKS: Record<string, { vendor: string; product: string; version?: (v: string) => string }> = {
  "jellyfin-ffmpeg": { vendor: "ffmpeg", product: "ffmpeg", version: (v) => v.replace(/-\d+$/, "") },
  "ffmpeg-headless": { vendor: "ffmpeg", product: "ffmpeg" },
  "ffmpeg-full": { vendor: "ffmpeg", product: "ffmpeg" },
};

export function applyCpes(comps: Component[], parts: Record<string, CpeParts | null> | null): number {
  let fromMeta = 0;
  for (const c of comps) {
    const fork = NIX_FORKS[c.name];
    if (fork) {
      c.cpe = `cpe:2.3:a:${fork.vendor}:${fork.product}:${fork.version?.(c.version) ?? c.version}:*:*:*:*:*:*:*`;
      c.properties = [{ name: "tappaas:cpe-source", value: "fork" }];
      continue;
    }
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
// ── native libraries Python packages bundle (#811) ─────────────────────
// trivy reads an image's OS packages and its Python packages, but not the
// shared libraries a wheel ships inside it: PyAV's FFmpeg, soundfile's
// libsndfile, Pillow's codecs, cryptography's OpenSSL, numpy's OpenBLAS — and
// Python's own expat. They are loaded in the application process, so their CVEs
// are the application's. This asks the container's own Python for the versions
// those packages report (exact, unlike a soname), fed to it on stdin: nothing is
// installed. One JSON line; a container without Python prints nothing.
// Only what is really bundled counts: a library the process loads from a file
// the distro's package manager owns (a distro python3-cryptography on the
// system libcrypto) is the OS scan's, with the distro's backported fixes, and
// matching it again by upstream version would flag fixed CVEs.
export const BUNDLED_PY = "import json, os, sys, glob\nout = []\ndef add(product, version, via):\n    if version:\n        out.append({\"product\": product, \"version\": str(version).strip(), \"via\": via})\ndef tryit(f):\n    try:\n        f()\n    except Exception:\n        pass\ndef _expat():\n    import pyexpat\n    add(\"expat\", pyexpat.EXPAT_VERSION.replace(\"expat_\", \"\"), \"python\")\ndef _av():\n    import av\n    add(\"ffmpeg\", getattr(av, \"ffmpeg_version_info\", \"\"), \"av\")\ndef _sf():\n    import soundfile\n    add(\"libsndfile\", soundfile.__libsndfile_version__, \"soundfile\")\ndef _pil():\n    from PIL import features\n    # libjpeg_turbo, not jpg: \"jpg\" is the libjpeg API level (6.2/8.0).\n    for feat, prod in ((\"libjpeg_turbo\", \"libjpeg-turbo\"), (\"zlib\", \"zlib\"), (\"libtiff\", \"libtiff\"),\n                       (\"webp\", \"libwebp\"), (\"freetype2\", \"freetype\"), (\"littlecms2\", \"lcms2\")):\n        try:\n            v = features.version(feat)\n            # zlib-ng reports a zlib-compatible number: not zlib's own release.\n            if v and not (prod == \"zlib\" and \"ng\" in str(v)):\n                add(prod, v, \"Pillow\")\n        except Exception:\n            pass\ndef _crypto():\n    from cryptography.hazmat.backends.openssl.backend import backend\n    v = backend.openssl_version_text().split()\n    if v and v[0] == \"OpenSSL\":\n        add(\"openssl\", v[1], \"cryptography\")\ndef _numpy():\n    import numpy\n    cfg = getattr(numpy.__config__, \"CONFIG\", {})\n    b = cfg.get(\"Build Dependencies\", {}).get(\"blas\", {})\n    if \"openblas\" in str(b.get(\"name\", \"\")).lower():\n        add(\"openblas\", b.get(\"version\", \"\"), \"numpy\")\nfor f in (_expat, _av, _sf, _pil, _crypto, _numpy):\n    tryit(f)\n# Bundled or the system's? A distro's Python package links the distro's shared\n# library (python3-cryptography -> libcrypto.so.3 in /usr/lib), which the OS-package\n# scan already reports, with the distro's backported fixes; matching it again by\n# upstream version double-counts and flags fixed CVEs. A product counts as bundled\n# when its library is mapped from inside a Python package directory, or is not\n# mapped at all (linked statically into the extension). Mapped only from a system\n# path: dropped here.\nLIBNAME = {\"expat\": \"libexpat\", \"openssl\": \"libcrypto\", \"libsndfile\": \"libsndfile\", \"ffmpeg\": \"libavcodec\",\n           \"libjpeg-turbo\": \"libjpeg\", \"zlib\": \"libz\", \"libtiff\": \"libtiff\", \"libwebp\": \"libwebp\",\n           \"freetype\": \"libfreetype\", \"lcms2\": \"liblcms2\", \"openblas\": \"openblas\"}\nmaps = []\ntry:\n    maps = sorted({l.split()[-1] for l in open(\"/proc/self/maps\") if \"/\" in l.split()[-1]})\nexcept Exception:\n    pass\n# Files the distro's package manager owns: those the OS-package scan reports.\n_owned = None\ndef distro_owned(path):\n    global _owned\n    if _owned is None:\n        _owned = set()\n        for lst in glob.glob(\"/var/lib/dpkg/info/*.list\"):\n            try:\n                _owned.update(l.strip() for l in open(lst, errors=\"ignore\"))\n            except Exception:\n                pass\n        try:\n            for l in open(\"/lib/apk/db/installed\", errors=\"ignore\"):\n                if l.startswith(\"F:\"):\n                    d = l[2:].strip()\n                elif l.startswith(\"R:\"):\n                    _owned.add(\"/\" + d + \"/\" + l[2:].strip())\n        except Exception:\n            pass\n    real = os.path.realpath(path)\n    return path in _owned or real in _owned or (\"/usr\" + path) in _owned or real.replace(\"/usr\", \"\", 1) in _owned\ndef origin(product):\n    name = LIBNAME.get(product)\n    if not name:\n        return \"bundled\"\n    hits = [m for m in maps if os.path.basename(m).startswith(name)]\n    if any((\"-packages/\" in m) for m in hits):\n        return \"bundled\"\n    # mapped from a distro package: the OS scan covers it; built into the image\n    # some other way (e.g. /usr/local from source): nobody else sees it\n    return \"system\" if hits and all(distro_owned(m) for m in hits) else \"bundled\"\nout = [b for b in out if origin(b[\"product\"]) == \"bundled\"]\n# Native libraries wheels vendor (<pkg>.libs / <pkg>/.libs), whatever reads them:\n# counted, so a scan can say how much it could not attribute.\nlibs = set()\nfor p in sys.path:\n    if p and os.path.isdir(p):\n        for d in glob.glob(os.path.join(p, \"*.libs\")) + glob.glob(os.path.join(p, \"*\", \".libs\")):\n            for f in os.listdir(d):\n                if \".so\" in f:\n                    libs.add(f)\nprint(json.dumps({\"bundled\": out, \"vendoredLibs\": sorted(libs)}))\n";

export interface Bundled {
  product: string;
  version: string;
  via: string; // the Python package that carries it ("python" for the interpreter's own)
}

// product → CPE vendor:product, as NVD records them
export const BUNDLED_CPE: Record<string, string> = {
  ffmpeg: "ffmpeg:ffmpeg",
  libsndfile: "libsndfile_project:libsndfile",
  expat: "libexpat_project:libexpat",
  "libjpeg-turbo": "libjpeg-turbo:libjpeg-turbo",
  zlib: "zlib:zlib",
  libtiff: "libtiff:libtiff",
  libwebp: "webmproject:libwebp",
  freetype: "freetype:freetype",
  lcms2: "littlecms:little_cms_color_engine",
  openssl: "openssl:openssl",
  openblas: "openblas_project:openblas",
};

// The components to match, one per product+version: by CPE, as grype matches
// the Nix layer. The name says where it lives, so a finding reads "ffmpeg (in av)".
export function bundledComponents(list: Bundled[]): Component[] {
  const seen = new Set<string>();
  const out: Component[] = [];
  for (const b of list) {
    const vp = BUNDLED_CPE[b.product];
    if (!vp || !b.version || !/^\d/.test(b.version)) continue;
    const k = `${b.product}@${b.version}`;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push({
      type: "library",
      name: `${b.product} (in ${b.via})`,
      version: b.version,
      purl: `pkg:generic/${b.product}@${b.version}`,
      cpe: `cpe:2.3:a:${vp}:${b.version}:*:*:*:*:*:*:*`,
      properties: [{ name: "tappaas:bundled-in", value: b.via }],
    });
  }
  return out;
}

// base64 of an ASCII script, so the probe can pass it through `sh` unquoted
// (this build has no Node typings, hence no Buffer).
export function base64Ascii(text: string): string {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  for (let i = 0; i < text.length; i += 3) {
    const n = (text.charCodeAt(i) << 16) | ((text.charCodeAt(i + 1) || 0) << 8) | (text.charCodeAt(i + 2) || 0);
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63]
      + (i + 1 < text.length ? A[(n >> 6) & 63] : "=") + (i + 2 < text.length ? A[n & 63] : "=");
  }
  return out;
}

const BUNDLED_B64 = base64Ascii(BUNDLED_PY);

export const LINUX_PROBE = [
  'S=""; [ "$(id -u)" = 0 ] || S="sudo -n"',
  "if [ -e /run/current-system ]; then echo '@@nixos'; nix-store -q --requisites /run/current-system",
  "elif [ -f /etc/debian_version ]; then echo '@@os-release'; cat /etc/os-release; echo '@@debian_version'; cat /etc/debian_version; echo '@@dpkg'; cat /var/lib/dpkg/status",
  "else echo '@@other'; fi",
  "for rt in podman docker; do command -v $rt >/dev/null 2>&1 || continue",
  "  $S $rt ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | while IFS='|' read -r n i; do",
  "    d=$($S $rt image inspect --format '{{join .RepoDigests \",\"}}' \"$i\" 2>/dev/null)",
  '    echo "@@container $rt|$n|$i|$d"',
  // stdin of exec is the decoded script, not the loop's `ps` pipe
  `    echo '@@bundled'; echo ${BUNDLED_B64} | base64 -d | timeout 60 $S $rt exec -i "$n" sh -c 'if command -v python3 >/dev/null 2>&1; then exec python3 -; elif command -v python >/dev/null 2>&1; then exec python -; fi' 2>/dev/null; echo`,
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
  bundled?: Bundled[];
  vendoredLibs?: number; // native libraries found in wheels' .libs directories
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
          // Sorted: an image can carry several (its index and its platform
          // manifest), and the runtime does not promise their order — the first
          // one names the image's target, so it must be the same every night.
          digests: (digests ?? "").split(",").map((d) => d.trim()).filter((d) => d.includes("@sha256:")).sort(),
        });
      }
      section = tag;
      continue;
    }
    if (section === "nixos") {
      if (line.startsWith("/nix/store/")) r.paths.push(line.trim());
    } else if (section === "bundled") {
      const c = r.containers[r.containers.length - 1];
      if (c && line.trim().startsWith("{")) {
        try {
          const d = JSON.parse(line) as { bundled?: Bundled[]; vendoredLibs?: string[] };
          c.bundled = (d.bundled ?? []).filter((b) => b && b.product && b.version);
          c.vendoredLibs = (d.vendoredLibs ?? []).length;
        } catch {
          /* a garbled line: the image is still scanned by trivy */
        }
      }
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
  matchDetails?: { found?: { versionConstraint?: string } }[];
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
    // "none (unknown)": the CVE record names the product but no affected versions
    // (ImageMagick's 2014 SUN coder bug matches 7.1.2) — a likely false positive.
    ...(unversionedMatch(m) ? { unversioned: true } : {}),
  }));
}

function unversionedMatch(m: GrypeMatch): boolean {
  const cs = (m.matchDetails ?? []).map((d) => d.found?.versionConstraint ?? "");
  return cs.length > 0 && cs.every((c) => /^none\b/.test(c.trim()));
}

interface TrivyDoc {
  Metadata?: { OS?: { Family?: string; Name?: string } };
  Results?: {
    // A package's purl is `Identifier` (trivy >= 0.50); a vulnerability's, `PkgIdentifier`.
    Packages?: { Name?: string; Version?: string; Release?: string; Identifier?: { PURL?: string }; PkgIdentifier?: { PURL?: string } }[];
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
      components.push({ type: "library", name: p.Name ?? "", version, purl: p.Identifier?.PURL ?? p.PkgIdentifier?.PURL ?? "" });
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

// ── build-only packages ────────────────────────────────────────────────
// Kernel headers, compilers and -dev packages are on a host to BUILD something
// (a DKMS driver: r8127 on hrossen's tappaas1/2), never run by a service. The
// kernel's CVEs match linux-libc-dev and the headers by source package — 55 of
// tappaas1's critical/high were those. Counted apart, not as running code; the
// library a -dev package belongs to is its own package and still counts.
const BUILD_ONLY = /^(linux-libc-dev|(linux|proxmox|pve)-headers(-.*)?|(cpp|gcc|g\+\+)(-\d+)?(-x86-64-linux-gnu)?|binutils(-.*)?|build-essential|dpkg-dev|libc6-dev|.+-dev)$/;
export function isBuildOnly(pkg: string): boolean {
  return BUILD_ONLY.test(pkg);
}

// ── VEX: triage decisions committed next to the module (ADR-011 §8) ─────
export interface VexStatement {
  id: string;
  state: string;
  refs: string[]; // purls; empty = every package
  source: string;
  module: string; // whose targets it decides: "" = every target (templates, the estate-wide base)
  risk?: string; // exploitable/in_triage: the risk HERE, from ratings[] (source TAPPaaS) — low|medium|high|critical
}

const VEX_SUPPRESS = new Set(["not_affected", "false_positive", "resolved", "resolved_with_pedigree"]);

// An analysed finding that stays counted (exploitable) carries the risk it has in
// THIS deployment as a CycloneDX rating whose source is TAPPaaS — not the CVE's
// own severity: a critical libxml2 flaw reachable only by an admin is low here.
export function parseVex(json: string, source: string, module = ""): VexStatement[] {
  type Doc = { vulnerabilities?: { id?: string; analysis?: { state?: string }; affects?: { ref?: string }[];
    ratings?: { source?: { name?: string }; severity?: string }[] }[] };
  const doc = JSON.parse(json) as Doc;
  const out: VexStatement[] = [];
  for (const v of doc.vulnerabilities ?? []) {
    if (!v.id || !v.analysis?.state) continue;
    const s: VexStatement = { id: v.id, state: v.analysis.state, refs: (v.affects ?? []).map((a) => a.ref ?? "").filter(Boolean), source, module };
    const r = (v.ratings ?? []).find((x) => x.source?.name === "TAPPaaS" && x.severity);
    if (r?.severity) s.risk = r.severity.toLowerCase();
    out.push(s);
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
  return vexDeciders(f, vex).length > 0;
}

// The statements that decide a finding.
function vexDeciders(f: Finding, vex: VexStatement[]): VexStatement[] {
  return vexMatching(f, vex).filter((s) => VEX_SUPPRESS.has(s.state));
}

// The analysed-but-counted ones: exploitable or in_triage, with the risk here.
function vexTriage(f: Finding, vex: VexStatement[]): VexStatement[] {
  return vexMatching(f, vex).filter((s) => !VEX_SUPPRESS.has(s.state));
}

function vexMatching(f: Finding, vex: VexStatement[]): VexStatement[] {
  const fp = splitPurl(f.purl);
  return vex.filter((s) => {
    if (s.id !== f.id) return false;
    if (s.refs.length === 0) return true;
    return s.refs.some((r) => {
      const rp = splitPurl(r);
      return rp.base === fp.base && (rp.version === "" || rp.version === fp.version);
    });
  });
}

// ── nixpkgs patches: a fix nixpkgs backported ──────────────────────────
// A package's `patches` naming a CVE (libssh2's CVE-2026-55199.patch) is that fix,
// applied: the finding is resolved for the version nixpkgs builds — no person needs
// to triage it. Version-exact, like a versioned VEX ref: a module on another version
// of the package is looked at as it is. Measured on hrossen 2026-10-09: libssh2's
// nine findings and one of perl's were patched all along.
export const PATCH_SOURCE = "nixpkgs patches";

// The CVE ids a patch file's COMMIT MESSAGES name — `git log -p` / format-patch
// output, as nixpkgs keeps a release branch (glibc's 2.42-master.patch:
// "memalign: reinstate alignment overflow check (CVE-2026-0861)"). Only the
// message, between a commit header and its first diff: a CVE id in the code or a
// test the diff touches is not a fix this patch makes.
export function cvesInPatchMessages(text: string): string[] {
  const out = new Set<string>();
  let inMsg = false;
  for (const line of text.split("\n")) {
    if (/^(commit [0-9a-f]{7,}|From [0-9a-f]{40} )/.test(line)) inMsg = true;
    else if (/^(diff --git |---$|Index: )/.test(line)) inMsg = false;
    else if (inMsg) for (const c of line.match(/CVE-\d{4}-\d{4,}/gi) ?? []) out.add(c.toUpperCase());
  }
  return [...out].sort();
}
export function patchVex(p: Record<string, { version: string; patches: string[]; messageCves?: string[] } | null> | null): VexStatement[] {
  const out: VexStatement[] = [];
  for (const [name, v] of Object.entries(p ?? {})) {
    if (!v || !v.version) continue;
    const ids = new Set([...v.patches.flatMap((x) => (x.match(/CVE-\d{4}-\d{4,}/gi) ?? []).map((c) => c.toUpperCase())),
      ...(v.messageCves ?? [])]);
    for (const id of ids) out.push({ id, state: "resolved", refs: [`pkg:nix/${name}@${v.version}`], source: PATCH_SOURCE, module: "" });
  }
  return out;
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
  // What the release preview's platform rows show: RISK (analysed, still counted)
  // and VEX (decided), for Critical/High — the scan's own split of NOW.
  const isCH = (f: Finding): boolean => f.severity === "Critical" || f.severity === "High";
  const tri = ch.flatMap((f) => vexTriage(f, vex).map((v) => ({ id: f.id, risk: v.risk ?? "" })));
  if (tri.length > 0) {
    status.critHighRisk = [...new Set(tri.map((x) => x.id))].sort();
    const rank = ["critical", "high", "medium", "low"];
    const lv = tri.map((x) => x.risk).filter((r) => rank.includes(r)).sort((a, b) => rank.indexOf(a) - rank.indexOf(b));
    status.riskLevel = lv[0] ?? "unrated";
  }
  const chVex = new Set(all.filter((f) => f.id && isCH(f) && vexSuppresses(f, vex)).map((f) => f.id));
  if (chVex.size > 0) status.critHighVex = [...chVex].sort();
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
// VuXML carries no severity: every firewall finding was "Unknown", so the firewall
// counted 0 critical/high while it had 42 (hrossen, 2026-10-09: unbound, openssl,
// strongswan). A CVE id's severity comes from the scanner's own database (NVD
// first); a VuXML entry without a CVE id stays Unknown.
export function summarizeOpnsense(
  base: Pick<TargetStatus, "id" | "name" | "layer" | "host">,
  p: OpnsenseProbe | null,
  vex: VexStatement[],
  severity: Record<string, string> | null = null,
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
      findings.push({ id, severity: severity?.[id] ?? "Unknown", pkg: name, installed, fixed, purl: `pkg:generic/opnsense/${name}@${installed}` });
    }
  }
  const age = p.vulnXmlAgeDays;
  const note = `${p.version || "OPNsense"}; VuXML ${age === null ? "age unknown" : `${age} day(s) old`}` +
    (severity === null ? "; severity unknown (CVE database lookup failed)" : "; severity from the CVE database (NVD first)");
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
  // CVE id → Critical|High|Medium|Low from the local CVE database (null: lookup failed)
  cveSeverities(ids: string[]): Record<string, string> | null;
  // pname → nixpkgs meta.identifiers.cpeParts (null: eval failed as a whole)
  nixCpeParts(names: string[]): Record<string, CpeParts | null> | null;
  // pname → the version nixpkgs builds and the names of its patches (null: eval failed)
  nixPatches(names: string[]): Record<string, { version: string; patches: string[]; messageCves?: string[] } | null> | null;
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
  cveSeverities(ids: string[]): Record<string, string> | null {
    const out: Record<string, string> = {};
    for (let i = 0; i < ids.length; i += 200) {
      const r = exec("grype", ["db", "search", "vuln", ...ids.slice(i, i + 200), "-o", "json", "-q"], undefined, 5 * MIN,
        { ...process.env, GRYPE_DB_AUTO_UPDATE: "false" });
      if (r.rc !== 0) return null;
      try {
        Object.assign(out, pickSeverities(JSON.parse(r.stdout) as { id?: string; provider?: string; severity?: string }[]));
      } catch {
        return null;
      }
    }
    return out;
  }
  nixPatches(names: string[]): Record<string, { version: string; patches: string[]; messageCves?: string[] } | null> | null {
    const dir = mkdtempSync(join(tmpdir(), "tappaas-patches-"));
    try {
      const f = join(dir, "names.json");
      writeFileSync(f, JSON.stringify(names));
      const np = process.env.TAPPAAS_NIXPKGS ? `import ${process.env.TAPPAAS_NIXPKGS}` : "import <nixpkgs>";
      const expr =
        `let pkgs = ${np} {}; names = builtins.fromJSON (builtins.readFile ${f}); ` +
        "pname = x: if builtins.isAttrs x then (x.name or \"\") else baseNameOf (toString x); " +
        "ppath = x: if builtins.isAttrs x then \"\" else toString x; " +
        "look = n: let r = builtins.tryEval (let p = pkgs.${n} or null; in " +
        "if p == null || !(builtins.isAttrs p) then null else { " +
        // the version as the store path names it — glibc is 2.42-100 there, .version says 2.42
        "version = let v = (builtins.parseDrvName (p.name or \"\")).version; in if v != \"\" then v else (p.version or \"\"); " +
        "patches = map pname (p.patches or []); " +
        "paths = builtins.filter (x: x != \"\") (map ppath (p.patches or [])); }); in " +
        "if r.success then (builtins.deepSeq r.value r.value) else null; " +
        "in builtins.listToAttrs (map (n: { name = n; value = look n; }) names)";
      const r = exec("nix-instantiate", ["--eval", "--strict", "--json", "-E", expr], undefined, 10 * MIN);
      if (r.rc !== 0) return null;
      const raw = JSON.parse(r.stdout) as Record<string, { version: string; patches: string[]; paths?: string[] } | null>;
      const out: Record<string, { version: string; patches: string[]; messageCves?: string[] } | null> = {};
      for (const [n, v] of Object.entries(raw)) {
        if (!v) {
          out[n] = null;
          continue;
        }
        // A patch nixpkgs keeps as a file (glibc's 2.42-master.patch: its release
        // branch's commits) names in its commit messages the CVEs it fixes.
        const cves = new Set<string>();
        for (const p of v.paths ?? []) {
          try {
            for (const c of cvesInPatchMessages(readFileSync(p, "utf8"))) cves.add(c);
          } catch {
            // unreadable: its name still counts
          }
        }
        out[n] = { version: v.version, patches: v.patches, ...(cves.size > 0 ? { messageCves: [...cves].sort() } : {}) };
      }
      return out;
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

// One severity per CVE id: NVD's when it has one, else the highest any provider
// gives — distro feeds rate a CVE for their own build, NVD for the software.
export function pickSeverities(rows: { id?: string; provider?: string; severity?: string }[]): Record<string, string> {
  const rank = ["critical", "high", "medium", "low"];
  const nvd: Record<string, string> = {};
  const best: Record<string, string> = {};
  for (const r of rows) {
    const id = (r.id ?? "").toUpperCase();
    const s = (r.severity ?? "").toLowerCase();
    if (!id || !rank.includes(s)) continue;
    if (r.provider === "nvd") nvd[id] = s;
    if (!best[id] || rank.indexOf(s) < rank.indexOf(best[id])) best[id] = s;
  }
  const out: Record<string, string> = {};
  for (const id of Object.keys(best)) out[id] = normSeverity(nvd[id] ?? best[id]);
  return out;
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
  repoDir: string; // the tree this scan ships in — VEX source only when site.json registers no repository
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

// instance → module, from each deployed config's moduleSource (ADR-026 D6.3).
export function instanceModules(configDir: string): Record<string, string> {
  const out: Record<string, string> = {};
  let files: string[] = [];
  try {
    files = readdirSync(configDir).filter((f) => f.endsWith(".json"));
  } catch {
    return out;
  }
  for (const f of files) {
    const src = moduleSourceOf(readModuleJson(join(configDir, f)));
    if (src) out[f.slice(0, -".json".length)] = moduleOfLocation(src);
  }
  return out;
}

// node → the modules installed on it as packages (module json imageType "apt").
// They have no vmid, so loadConfigModules does not list them.
export function aptModules(configDir: string, defaultNode: string): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  let files: string[] = [];
  try {
    files = readdirSync(configDir).filter((f) => f.endsWith(".json")).sort();
  } catch {
    return out;
  }
  for (const f of files) {
    const raw = readModuleJson(join(configDir, f));
    if (!raw || raw.imageType !== "apt") continue;
    const node = typeof raw.node === "string" && raw.node ? raw.node : defaultNode;
    (out[node] ??= []).push(f.slice(0, -".json".length));
  }
  return out;
}

// The module directories of every REGISTERED repository: site.json
// .repositories, and in each its module catalogue — the same walk the field
// schema composes from (compose-fields.ts). A VEX file in a Community module is
// as binding as one in TAPPaaS; a stray file outside any registered module is
// not a decision anyone made about a deployed module, and is not read.
export function registeredModuleDirs(configDir: string, fallbackRepo: string): string[] {
  const readJson = (f: string): unknown => {
    try {
      return JSON.parse(readFileSync(f, "utf8"));
    } catch {
      return null;
    }
  };
  const dirsOf = (root: string, catalogRel: string): string[] => {
    const out: string[] = [];
    const collect = (node: unknown): void => {
      if (Array.isArray(node)) node.forEach(collect);
      else if (node && typeof node === "object") {
        const o = node as Record<string, unknown>;
        if (typeof o.moduleJson === "string" && o.moduleJson.includes("/")) {
          out.push(join(root, o.moduleJson.slice(0, o.moduleJson.lastIndexOf("/"))));
        }
        Object.values(o).forEach(collect);
      }
    };
    collect(readJson(join(root, catalogRel)));
    return out;
  };
  const site = readJson(join(configDir, "site.json")) as { repositories?: Array<Record<string, unknown>> } | null;
  const dirs: string[] = [];
  for (const r of site?.repositories ?? []) {
    const path = typeof r.path === "string" ? r.path : "";
    const cat = typeof r.catalog === "string" ? r.catalog : "src/module-catalog.json";
    if (path) dirs.push(...dirsOf(path, cat));
  }
  // A bare checkout with no site.json repositories: the tree the scan ships in.
  if (dirs.length === 0) dirs.push(...dirsOf(fallbackRepo, "src/module-catalog.json"));
  return [...new Set(dirs)].sort();
}

// A module's decisions are about how THAT module uses a package — libtiff not
// reachable in one module can be in another — so <module>-vex.json decides for
// that module's targets only; templates-vex.json, the estate-wide base (§8), for
// every target. A Proxmox node is the pvehost module's.
// A target names an INSTANCE (deconz-test: deconz in the `test` environment); its
// module is its config's moduleSource (ADR-026 D6.3) — never the instance name,
// or an instance outside the default environment loses its module's VEX.
export function moduleOf(target: string, instances: Record<string, string> = {}): string {
  if (target.startsWith("node:")) return "pvehost";
  const instance = target.replace(/^image:/, "").split("/")[0];
  return instances[instance] ?? instance;
}
export function vexFor(vex: VexStatement[], target: string, instances: Record<string, string> = {}): VexStatement[] {
  const module = moduleOf(target, instances);
  return vex.filter((s) => s.module === "" || s.module === module);
}

// Every <module>-vex.json in a registered module's directory (ADR-011 §8).
export function loadVex(configDir: string, fallbackRepo: string): { statements: VexStatement[]; files: string[]; unreadable: string[] } {
  const statements: VexStatement[] = [];
  const files: string[] = [];
  const unreadable: string[] = [];
  for (const dir of registeredModuleDirs(configDir, fallbackRepo)) {
    let entries: string[] = [];
    try {
      entries = readdirSync(dir);
    } catch {
      continue;
    }
    for (const e of entries.filter((x) => x.endsWith("-vex.json")).sort()) {
      const p = join(dir, e);
      try {
        const module = e.slice(0, -"-vex.json".length);
        statements.push(...parseVex(readFileSync(p, "utf8"), p, module === "templates" ? "" : module));
        files.push(p);
      } catch {
        // decides nothing — its findings stay reported — and the scan says so
        unreadable.push(p);
      }
    }
  }
  return { statements, files, unreadable };
}

interface CdxTarget {
  status: TargetStatus;
  version: string;
  components: Component[];
}

export function runScan(opts: ScanOpts, client: ClusterClient, io: SecurityIO): { status: ScanStatus; cdx: Record<string, unknown> } {
  const log = opts.log ?? ((): void => undefined);
  const inst = instanceModules(opts.configDir);
  const v = loadVex(opts.configDir, opts.repoDir);
  const vex = v.statements;
  const notes: string[] = [];
  if (v.files.length > 0) notes.push(`VEX: ${vex.length} statement(s) from ${v.files.length} file(s)`);
  for (const f of v.unreadable) notes.push(`VEX file not readable, ignored: ${f}`);
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
    // …and the CVE fixes nixpkgs backported into them: resolved, for every target.
    const patched = names.length > 0 ? patchVex(io.nixPatches(names)) : [];
    if (patched.length > 0) {
      vex.push(...patched);
      notes.push(`nixpkgs patches: ${patched.length} CVE fix(es) in ${new Set(patched.map((s) => s.refs[0])).size} package(s) count as resolved`);
    }

    // 3. scan each target with its layer's scanner
    const failed = (t: Planned, layer: Layer, why: string, seen = 0): CdxTarget => ({
      status: summarize({ id: t.id, name: t.name, layer, host: t.host }, seen, why, [], vexFor(vex, t.id, inst), layer !== "nix"),
      version: "",
      components: [],
    });
    for (const p of probed) {
      const t = p.t;
      const tv = vexFor(vex, t.id, inst);
      if (t.layer === "opnsense") {
        const ids = [...new Set((p.opn?.audit ?? []).flatMap((a) => a.cves))];
        const sev = ids.length > 0 && dbOk ? io.cveSeverities(ids) : ids.length > 0 ? null : {};
        const s = summarizeOpnsense({ id: t.id, name: t.name, layer: "opnsense", host: t.host }, p.opn ?? null, tv, sev);
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
            status: summarize({ id: t.id, name: t.name, layer: "nix", host: t.host }, nc.components.length, cov, findings, tv, false,
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
          results.push(trivyTarget({ id: t.id, name: t.name, layer: "debian", host: t.host }, io.trivyRootfs(root), tv));
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
          results.push({ status: summarize(base, 0, "the image has no registry digest (built locally?) — cannot be scanned as running", [], tv, true), version: "", components: [] });
        } else if (!dbOk) {
          results.push({ status: summarize(base, 0, "no scanner database — see the scan's notes", [], tv, true), version: "", components: [] });
        } else {
          log(`matching ${base.name}: ${c.digests[0]}`);
          const r = trivyTarget(base, io.trivyImage(c.digests[0]), tv, matchBundled(c, io, tmp));
          r.version = c.image;
          results.push(r);
        }
      }
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }

  // Which module each target is an instance of, and what is installed on a node
  // as packages: backup's Proxmox Backup Server is apt on its node, no VM.
  const apt = aptModules(opts.configDir, opts.defaultNode);
  for (const r of results) {
    r.status.module = moduleOf(r.status.id, inst);
    if (!r.status.id.startsWith("node:")) continue;
    const on = apt[r.status.id.slice(5)];
    if (on) r.status.apt = on;
    // Proxmox's own packages — its kernel, QEMU, PVE, and the backup server —
    // are in no feed trivy reads: matched by nothing, so say so.
    if (r.status.coverage === "ok") {
      r.status.note = [r.status.note, `Proxmox packages (kernel, QEMU${on ? `, ${on.join(", ")}` : ""}) not matched: no CVE feed`].filter(Boolean).join("; ");
    }
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

// The bundled libraries of one container, matched by CPE (#811). null when it
// reported none. A grype failure is said in the note, not hidden: the image's
// own scan still stands.
export function matchBundled(c: Container, io: SecurityIO, tmp: string): BundledMatch | null {
  const comps = bundledComponents(c.bundled ?? []);
  const unattributed = c.vendoredLibs ?? 0;
  if (comps.length === 0) {
    return unattributed > 0
      ? { components: [], findings: [], note: `${unattributed} native librar${unattributed === 1 ? "y" : "ies"} bundled in Python wheels not identified` }
      : null;
  }
  const f = join(tmp, `bundled-${safe(c.name)}-${comps.length}.cdx.json`);
  writeFileSync(f, JSON.stringify(cdxDoc(comps)));
  const g = io.grype(f);
  const list = comps.map((x) => `${x.name.replace(/ \(in .*\)$/, "")} ${x.version}`).join(", ");
  if (!g.ran || g.rc !== 0) {
    return { components: comps, findings: [], note: `bundled libraries not matched (grype: ${lastLine(g.stderr) || `exit ${g.rc}`}): ${list}` };
  }
  let findings: Finding[] = [];
  try {
    findings = grypeFindings(g.stdout);
  } catch {
    return { components: comps, findings: [], note: `bundled libraries not matched (grype output not parseable): ${list}` };
  }
  return { components: comps, findings, note: `bundled in Python packages: ${list}` };
}

// One group per image, its containers sorted by name, the groups by their first
// name. A group's first container names its target (image:<module>/<container>),
// and `podman ps` lists containers in no fixed order: unsorted, authentik's
// server and worker swapped places between nights, the target got a new id, and
// every one of its findings read as new — a security notice each morning.
// ── a package list, matched as if it ran (#788) ──────────────────────
// The release train's preview asks what the NEXT nixpkgs pin would bring. Its
// packages come from evaluating the guests against that pin — nothing runs it
// yet, so there is no store path to probe, only names and versions. Same CPE
// rule and matcher as a scan; the CPE vendor comes from the pin being previewed
// (the caller points TAPPAAS_NIXPKGS at it), not from the one installed.
// VEX applies as in a scan (vexSuppresses): what a statement decides comes back
// as `suppressed`, not dropped, so the preview counts it per module (#788).
export interface ListScan { findings: Finding[]; suppressed: Finding[]; error: string }
// The list mixes modules, so a suppressed finding names whose statements decided it
// (vexModules) and the caller applies vexFor's rule per module.
function splitVex(fs: Finding[], vex: VexStatement[]): { findings: Finding[]; suppressed: Finding[] } {
  const findings: Finding[] = [];
  const suppressed: Finding[] = [];
  for (const f of fs) {
    const by = vexDeciders(f, vex);
    // Analyses travel with the finding either way: one module's "not affected"
    // (vllm-amd: pip's bundled urllib3) leaves the finding another module's, and
    // that module's own "exploitable" (identity) must still read as RISK there.
    const tri = vexTriage(f, vex);
    const t = tri.length > 0 ? { triage: tri.map((s) => ({ module: s.module, state: s.state, risk: s.risk ?? "" })) } : {};
    if (by.length > 0) suppressed.push({ ...f, ...t, vexModules: [...new Set(by.map((s) => s.module))].sort() });
    else findings.push({ ...f, ...t });
  }
  return { findings, suppressed };
}

export function scanComponentList(list: { name: string; version: string }[], io: SecurityIO, vex: VexStatement[] = []): ListScan {
  const seen = new Set<string>();
  const comps: Component[] = [];
  for (const c of list) {
    if (!c || !c.name || !c.version) continue;
    const k = `${c.name}@${c.version}`;
    if (seen.has(k)) continue;
    seen.add(k);
    comps.push({ type: "library", name: c.name, version: c.version, purl: `pkg:nix/${c.name}@${c.version}` });
  }
  if (comps.length === 0) return { findings: [], suppressed: [], error: "no packages to match" };
  const names = [...new Set(comps.map((c) => c.name))];
  applyCpes(comps, io.nixCpeParts(names));
  vex = [...vex, ...patchVex(io.nixPatches(names))];
  const dir = mkdtempSync(join(tmpdir(), "tappaas-preview-"));
  try {
    const f = join(dir, "list.cdx.json");
    writeFileSync(f, JSON.stringify(cdxDoc(comps)));
    const g = io.grype(f);
    if (!g.ran || g.rc !== 0) return { findings: [], suppressed: [], error: `grype failed: ${lastLine(g.stderr) || `exit ${g.rc}`}` };
    try {
      // Not deduped: a list holds many targets' packages, and one CVE in two
      // versions of a package (openssl 3.6.4 and 4.0.2) is a finding for each —
      // deduping by CVE + package kept one and lost the other target's (#788).
      // The scan counts from raw findings too; dedupe is for its ACT display.
      return { ...splitVex(grypeFindings(g.stdout), vex), error: "" };
    } catch {
      return { findings: [], suppressed: [], error: "grype output not parseable" };
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── images by reference, matched without running them (#788) ─────────
// The release preview compares the images a past release shipped with the ones
// the next would: neither has to run here. trivy fetches each by its registry
// reference (layers cached between runs); same parser as a running container.
export function scanImageRefs(refs: string[], io: SecurityIO, vex: VexStatement[] = []): Record<string, ListScan> {
  const out: Record<string, ListScan> = {};
  for (const ref of [...new Set(refs.filter((r) => !!r))]) {
    const r = io.trivyImage(ref);
    if (!r.ran || r.rc !== 0) {
      out[ref] = { findings: [], suppressed: [], error: `trivy failed: ${lastLine(r.stderr) || `exit ${r.rc}`}` };
      continue;
    }
    try {
      // As the scan counts an image (trivyTarget): build-only packages apart.
      out[ref] = { ...splitVex(trivyParse(r.stdout).findings.filter((f) => !isBuildOnly(f.pkg)), vex), error: "" };
    } catch {
      out[ref] = { findings: [], suppressed: [], error: "trivy output not parseable" };
    }
  }
  return out;
}

export function groupByImage(cs: Container[]): Container[][] {
  const m = new Map<string, Container[]>();
  for (const c of cs) {
    const key = c.digests[0] ?? `local:${c.image}`;
    m.set(key, [...(m.get(key) ?? []), c]);
  }
  const byName = (a: Container, b: Container): number => a.name.localeCompare(b.name);
  return [...m.values()].map((g) => [...g].sort(byName)).sort((a, b) => byName(a[0], b[0]));
}

// What an image's bundled libraries added (#811): matched separately (grype, by
// CPE) and merged into the image's own result.
export interface BundledMatch { components: Component[]; findings: Finding[]; note: string }

function trivyTarget(base: Pick<TargetStatus, "id" | "name" | "layer" | "host" | "runsOn" | "ref">, r: RemoteResult, vex: VexStatement[], bundled: BundledMatch | null = null): CdxTarget {
  if (!r.ran || r.rc !== 0) {
    return { status: summarize(base, 0, `trivy failed: ${lastLine(r.stderr) || `exit ${r.rc}`}`, [], vex, true), version: "", components: [] };
  }
  try {
    const t = trivyParse(r.stdout);
    if (bundled) {
      t.components.push(...bundled.components);
      t.findings.push(...bundled.findings);
    }
    const running = t.findings.filter((f) => !isBuildOnly(f.pkg));
    const runIds = new Set(running.map((f) => f.id));
    const buildOnly = new Set(t.findings.filter((f) => isBuildOnly(f.pkg) && !runIds.has(f.id)).map((f) => f.id)).size;
    const notes = [t.osName ? `${t.family} ${t.osName}` : "", buildOnly > 0 ? `${buildOnly} CVE(s) only in build-only packages (headers, compilers), not counted` : "", bundled?.note ?? ""];
    const status = summarize(base, t.components.length, osCoverage(t.family, t.components.length), running, vex, true, notes.filter(Boolean).join("; "));
    if (buildOnly > 0) status.buildOnly = buildOnly;
    return {
      status,
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

// A column of width n: long names are cut with an ellipsis and always leave a
// space, so "authentik-server, authentik-worker (identity)" never runs into
// the verdict beside it.
export function fit(text: string, n: number): string {
  return (text.length > n - 1 ? `${text.slice(0, n - 2)}…` : text).padEnd(n);
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
      `${fit(t.name, 30)}${pad(t.layer, 9)}${pad(t.seen, 6)}${pad(t.findings, 6)}${pad(t.critical, 5)}${pad(t.high, 5)}` +
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
  const built = rows.filter((t) => (t.buildOnly ?? 0) > 0);
  if (built.length > 0) {
    out.push(`Not counted, only in build-only packages (kernel headers, compilers): ${built.map((t) => `${t.name} ${t.buildOnly}`).join(", ")}.`);
  }
  return out;
}

// ── the validate gate: WARN, never FAIL (ADR-011 §9) ───────────────────
// A CVE published upstream must not be able to fail a sweep or a test run;
// the gate makes the scan visible, the mail and the report make it actionable.
export const STALE_DAYS = 8;

// The node or deployed module a scan target belongs to, from its id: "node:<n>",
// "image:<module>/<image>", or the module's own name.
export function targetSubject(t: TargetStatus): CheckSubject {
  if (t.id.startsWith("node:")) return { kind: "node", name: t.id.slice(5) };
  const img = /^image:([^/]+)\//.exec(t.id);
  return { kind: "module", name: img ? img[1] : t.id };
}

export function checkCveStatus(configDir: string, now: number): CheckResult {
  const s = readStatus(join(sbomDir(configDir), STATUS_FILE));
  if (!s) return { name: "cve-status", status: "skip", detail: "no security scan yet — health-manager scan security" };
  const rows: CheckRow[] = [];
  for (const t of s.targets) {
    if (t.verdict === "failed" || t.verdict === "act") {
      rows.push({ status: "warn", text: `${fit(t.name, 30)}${verdictLine(t)}`, subject: targetSubject(t) });
    }
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
