# ADR-011 — SBOM Governance

| | |
|---|---|
| **Status** | Draft |
| **Version** | 0.3 |
| **Date** | 2026-09-27 |
| **Author** | Erik Daniel (v0.1–v0.2); Lars Rossen (v0.3 revision, for Erik's review) |
| **Related** | **#143** (CVE tracking / SBOM — origin); **#750** (container image pinning and cadence — the image layer this ADR scans); [ADR-028](<ADR-028 - Release Cadence and Patching.md>) (D1 one estate pin — the source of every Nix identity here; D12 emergency patching — what a finding here can trigger); [ADR-027](<ADR-027 - Module Blueprint.md>) D7 (the blueprint's `<module>-sbom.json` MAY, pending this ADR); [ADR-017](<ADR-017 - Update scheduling and mothership self-update.md>) (the `pinned-pkgs.nix` provenance question — answered here, §4); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Module = atomic deployable unit) |
| **Changelog** | **v0.3 (2026-09-27)** — rewritten on measurement: a dry run of the candidate tools against the test site (hrossen) — mothership, a guest, a container image, a Proxmox node and the firewall. Inventory is **generated per installation from what is deployed**, not committed per module (§1); the **full runtime closure**, not `--depth=1` (§3); **one tool per layer** — Nix closures, container images, Debian hosts, OPNsense (§4); CVE matching is **no longer deferred** (§5); new §6 coverage (a scan that saw nothing is a failure), §7 actionability (the metric is *fix available and not applied*), §8 triage decisions committed as VEX. v0.2's CycloneDX 1.4+ floor and its preference for Nix-native inventory over filesystem scanning stand. · v0.2 — tooling decision (§4): `sbomnix` for NixOS-templated modules, `syft` for the Debian/Ubuntu minority; CycloneDX floor corrected to 1.4+ (was 1.5+) to match the chosen tool's native output; both tools tested live, head-to-head, against the same real module derivation (`module-manager`) — `sbomnix` correctly found its dependencies, `syft`'s `nix-cataloger` found zero. · v0.1 — skeleton (Erik⟷Lars design direction agreed 2026-06-16). |

What software is actually running on a TAPPaaS installation, and which of it has a known
vulnerability that someone should act on.

## Context

TAPPaaS modules ship as VMs with bundled packages, services, and dependencies. Without a
machine-readable component inventory, CVE tracking (#143) requires manual effort and is
incomplete. The industry standard for this is a Software Bill of Materials (SBOM).

v0.1–v0.2 settled the format (CycloneDX JSON), put the SBOM next to each module as a
committed file, scoped v1 to direct dependencies, chose `sbomnix` for NixOS modules and
`syft` for Debian ones, and deferred CVE matching. v0.2 tested that on one derivation
(`module-manager`).

v0.3 tested it on a whole installation. On 2026-09-27 every candidate tool in the
estate's pinned nixpkgs (26.05: `sbomnix` 1.7.6 with `vulnxscan`, `vulnix` 1.12.4,
`grype` 0.112.0, `syft` 1.44.0, `trivy` 0.72.0, `osv-scanner` 2.3.3) was run, read-only,
against hrossen. What the estate is made of decides most of this ADR, so it comes first:

| Layer | Examples on hrossen | Where its versions come from |
|---|---|---|
| NixOS closures | the mothership (`tappaas-cicd`), every NixOS guest | the estate's one nixpkgs pin (ADR-028 D1) |
| Container images | authentik, and every `virtualisation.oci-containers` app | the image tag in the module — **not** the pin (#750) |
| Debian hosts | Proxmox nodes (Debian 13), PBS, unifi-os, the vLLM LXC | Debian's archive, via `apt` |
| OPNsense | the firewall (FreeBSD) | the OPNsense firmware channel |

A NixOS guest that runs an app in a container has **two** inventories: its own closure
(Nix) and the image (usually Debian-based). Neither covers the other.

### What was measured

| Target | Tool | Result |
|---|---|---|
| mothership closure | `sbomnix`, full closure | 728 components, 40 s |
| same | `sbomnix --depth=1` (v0.2's v1 scope) | **27 components** — no openssl, openssh, systemd, zlib, sqlite, libxml2 |
| same | `grype` on the `sbomnix` SBOM | 86 CVEs in 21 packages (Critical 7, High 44), 61 s; every match by CPE, **no fix-state** |
| same | `vulnix --system` | 323 CVEs in 94 packages; **8 % overlap** with `grype` (29 in both). `vulnix` extras include name collisions: `tar@0.4.45` (a Rust crate), `vault` and `safe` (Haskell libraries) |
| same | `vulnxscan` (grype + vulnix + OSV) | 121 findings; 28 seen by two scanners; **0 by all three — OSV contributes nothing** |
| same | `osv-scanner` on the `sbomnix` SBOM | "Filtered 716 local/unscannable packages", **0 vulnerabilities** — it does not understand `pkg:nix` |
| same | path list + nixpkgs CPE (§4) | 427 components, 115 CVEs (Critical 8, High 53) in 3 s; 80 of `sbomnix`'s 86, plus **27 in glibc that `sbomnix` misses entirely** |
| identity guest | `sbomnix` run **on the guest** | crashed after 184 s having added **1.6 GiB** to the guest's store (`nix-env -qa --meta` cannot evaluate a guest built from a nixpkgs tarball) |
| same | `nix copy` of the closure to the mothership | refused: guest-built paths are unsigned |
| same | path list + nixpkgs CPE (§4), guest runs only `nix-store -q` | 368 components, 110 CVEs (Critical 10, High 50) in 3 s; guest-only findings in redis and postgresql |
| authentik image, by running digest | `trivy image` | 546 CVEs (Critical 14, High 175), **394 with a fix published** — 154 of them Critical/High. Debian 12.9 base layer is most of it |
| Proxmox node tappaas1 | `trivy rootfs` on a copy of its dpkg status | 2675 CVEs (Critical 10, High 211), **0 fixable** — patched that morning |
| same, `/etc/debian_version` not copied | `trivy rootfs` | **0 packages, 0 vulnerabilities — reported as a clean scan** |
| firewall | `pkg audit` | 55 CVEs in 6 packages (unbound 33, strongswan 11, openssl 8); firmware channel "up to date" |

Six things follow, and each overturns or extends part of v0.2:

1. **The SBOM has to describe what is deployed, which differs per installation.** Two
   sites on different channels (ADR-028) run different closures; a site's image tag drifts
   from the repo (#750); a Proxmox node's packages are whatever `apt` last installed. A
   file committed in the module tree describes none of these.
2. **Direct dependencies miss the vulnerable part.** The CVEs live in openssl, glibc,
   libxml2, gnutls — transitive by definition. `--depth=1` kept 3.7 % of the mothership's
   components.
3. **Container images are opaque to every Nix tool.** Authentik's 546 CVEs are invisible
   from the guest's closure, and it is the single largest source of *fixable* findings on
   the site.
4. **A raw CVE count is not a signal.** tappaas1 carries 2675 CVEs and nothing to do about
   any of them today; authentik carries fewer and 154 Critical/High ones with a fix
   published. The count ranks them the wrong way round.
5. **A scanner that saw nothing says "0 vulnerabilities".** `trivy` without
   `/etc/debian_version` and `osv-scanner` on `pkg:nix` both did, confidently.
6. **For Nix, the weak link is identity, not inventory.** Matching is by CPE, and the CPE
   *vendor* decides whether NVD matches at all. `sbomnix` guesses `glibc:glibc` (NVD says
   `gnu:glibc`) and finds nothing in glibc; a naive vendor = product guess lost 20 recent
   Critical/High CVEs (gnutls, libxml2, libxslt, p11-kit). nixpkgs itself declares the
   right vendor for the packages that matter (`meta.identifiers.cpe`), and it is the
   estate's own pin, so the identity is exact. Nix also carries no distro fix-state: a
   CPE match says "this version is in NVD's range", not "nixpkgs has not patched it"
   (glibc `2.42-84` is 84 backport commits past 2.42, and NVD ranges do not know that).

## Decision

### 1. Inventory is generated per installation; decisions are committed

The mothership generates the inventory of every target on its installation, from what is
running, on each scan (§9). Output lives on the mothership under
`~/config/sbom/<timestamp>/` — one CycloneDX file per target, the scanner results next to
them, and a `summary.json` — and is **not committed**. It is installation state, like
`last-update-result.json`.

What **is** committed is what a human decided about a finding: the VEX statements of §8,
co-located per module as `<module>-vex.json`. That keeps v0.1's co-location rule for the
thing that is actually authored, and it resolves ADR-027 D7: the blueprint's
`<module>-sbom.json` becomes `<module>-vex.json`, still a MAY.

### 2. Format

[CycloneDX](https://cyclonedx.org/) 1.4+ (JSON), as v0.2 — `sbomnix`, the path-list
generator (§4) and `trivy` all emit it, and grype and trivy both consume it. VEX in
CycloneDX VEX (the same schema, `vulnerabilities[].analysis`). Rationale unchanged:
JSON-native, broad tooling, NTIA minimum elements.

### 3. Scope: the full runtime closure

Every runtime dependency, not direct ones only. For Nix that is
`nix-store -q --requisites` of the deployed system — runtime, not build-time: a compiler
in the build closure is not running on the site. For images and Debian hosts it is every
installed package, which is what the tools do by default.

### 4. Tooling — one per layer, each matched against the database that knows that layer

| Layer | Inventory | Matching | Fix-state |
|---|---|---|---|
| NixOS closure (mothership **and** guests) | the target's runtime path list → `paths2cdx` → CPE vendor from the estate's nixpkgs (`meta.identifiers.cpeParts`) | `grype` (NVD by CPE) | **none** — triage (§8) |
| Container image | the image **as running**, by digest — never by tag | `trivy image` | yes (distro + language ecosystems) |
| Debian host | a copy of `/etc/os-release`, `/etc/debian_version`, `/var/lib/dpkg/status` | `trivy rootfs` | yes (Debian security tracker) |
| OPNsense | on the firewall | `pkg audit` (VuXML) + firmware channel status | via the channel |

**Nix closures — one method for mothership and guests.** The guest runs one read-only
command it already has (`nix-store -q --requisites /run/current-system`); the list comes
back over the existing ssh trust; everything else happens on the mothership. Nothing is
installed on the guest, nothing is copied into the mothership's store, and no store
signing is needed. Measured: 3 s per target. The store-path name gives package and version
(`<hash>-<pname>-<version>[-<output>]`); the CPE vendor comes from the mothership's
nixpkgs, which is the same pin the guest was built from (ADR-028 D1) — so the identity
holds for every guest without asking the guest anything. Where nixpkgs declares no vendor
(of the mothership's 427 components, 54 have one — which covers the libraries CVEs
concentrate in), the generator falls back to vendor = product and says so in the
component's `tappaas:cpe-source` property. The fix for a missing vendor is upstream, in
nixpkgs `meta.identifiers` (`libmicrohttpd` is one: 2 CVEs missed for want of `gnu`) —
not a local mapping table.

This replaces `sbomnix` as the generator. `sbomnix` on the mothership is a reasonable
cross-check but not a baseline: it misses glibc, it cannot run on a tarball-built guest,
and its `--depth=1` mode is what v0.2 chose. It also answers ADR-017's open question:
provenance comes from the estate pin, so `sbomnix`'s flake metadata and
`lib/nix/pinned-pkgs.nix` are not needed for it.

**Not chosen, on measurement:** `vulnix` (8 % agreement with grype, name collisions with
non-Nix ecosystems, no severity model); `osv-scanner` (ignores `pkg:nix`); three-scanner
consensus (`vulnxscan` — never agreed on a single finding, because OSV contributes
nothing); `syft`'s nix cataloger (v0.2: zero components). `syft` stays a candidate for
images if trivy is ever dropped.

**Images are scanned as running.** The digest comes from Podman on the guest
(`podman inspect`), not from the tag in the module — the tag is what #750 is about.

### 5. CVE matching is part of v1

v0.2 deferred it until per-module SBOMs existed. The dry run shows the inventory alone
answers nothing an operator asks, and the matching is where every failure mode above
lives (vendor identity, empty scans, fix-state). Inventory and matching ship together.

The scanners' vulnerability databases are fetched by the mothership (grype and trivy each
keep one; OPNsense fetches its own). That is the only outbound traffic this adds: a DB
update per scan, from the scanner's publisher. It is not small: after the dry run the
mothership held **4.4 GB** of scanner cache (grype 3.0 GB, trivy 1.4 GB), which the
scan has to budget for: hrossen's mothership has a 32 GB root with 8.8 GB free, so the
caches would take half of it.

### 6. Coverage — a scan that saw nothing is a failure

Every target has a coverage assertion, checked before its findings are reported, and a
target that fails it is reported **SCAN FAILED — not clean**, never as zero findings:

| Layer | Coverage holds when |
|---|---|
| Nix closure | ≥ 50 components, and `glibc` is among them |
| Image / Debian host | the scanner detected an OS family, and saw > 0 packages |
| OPNsense | `pkg info` lists > 0 packages |

An unreachable target produces an empty inventory and therefore fails coverage by the
same rule — there is no separate "could not connect" path to forget.

### 7. Actionability — the metric is "fix available and not applied"

The summary per target is not a CVE count. It is, in order:

1. coverage failed → **SCAN FAILED**;
2. a Critical/High CVE with a fix published → **ACT** (with the count);
3. only Low/Medium fixable → **act, low priority**;
4. nothing fixable → **watch** — waiting on upstream;
5. Nix → **triage**, until nixpkgs fix-state exists (§8).

An **ACT** on a Critical/High finding is the "high-severity security CVE" of ADR-028 D12:
it is what qualifies a fix to reach a channel before its boundary, when there is no
workaround.

### 8. Triage is committed as VEX

A finding a person has looked at gets a VEX statement — `not_affected` (with the
justification: the vulnerable code is not in the build, not reachable, patched by a
nixpkgs backport), `affected` (with the plan), or `fixed` — in the `<module>-vex.json` of
the module that owns the component (the estate-wide base — glibc, openssl, systemd —
belongs to `templates`). The next scan applies it, so a decided finding stops being
reported until its version changes. This is where Nix's missing fix-state is made up for,
once per finding, by someone who checked.

### 9. When it runs

Not decided in this revision. The dry run took 15 s for seven targets with warm scanner
databases, so running with the daily sweep costs nothing measurable; the open question is
where the result is surfaced (the sweep's result file, the health report, a notification).
See Open questions.

## Consequences

- **The inventory stops being a document and becomes a scan.** Nothing to keep in sync
  with the code, and nothing that can drift from what is running.
- **Authentik (and every image-based app) becomes the loudest finding** until #750 gives
  images a cadence. That is correct: it is where the published fixes are.
- **Nix findings need a person, once.** The first scan will produce ~100 findings per
  closure to triage; VEX makes that a one-off per finding, not per scan.
- **nixpkgs metadata becomes something TAPPaaS depends on** — and improves upstream
  (`meta.identifiers`), which benefits everyone else scanning Nix.

## Alternatives considered

- **Committed per-module SBOM (v0.1–v0.2).** Describes the repository, not a site; stale
  the moment an image tag or apt package moves. Kept for what is authored — VEX.
- **`sbomnix` run on each guest.** Measured: 1.6 GiB per guest and a crash on
  tarball-built guests.
- **Copying guest closures into the mothership's store.** Needs every guest to sign its
  store paths or the mothership to trust `tappaas` as a Nix trusted user — a security
  decision this ADR has no reason to force when a path list suffices.
- **Consensus of several Nix scanners.** Measured: no finding reached consensus.

## Open questions for review

1. **Where the result is surfaced** (§9): the sweep's `last-update-result.json`, the
   health report (ADR-007e), a notification on ACT only — or all three.
2. **Nix fix-state.** NixOS has no security tracker comparable to Debian's. Options:
   triage by VEX only (this revision); read nixpkgs' applied patch list for CVE ids
   (backports often name the CVE); or contribute to an upstream effort. Worth a
   conversation before we build more than VEX.
3. **Debian hosts beyond the Proxmox nodes** — PBS, unifi-os, the vLLM LXC — need their
   own copy method (the nodes' is `scp` from the mothership, which already has root there).
4. **Whether VEX lives per module or in one estate file** — per module keeps ownership
   clear; one file is easier to review.
5. **Scanner database freshness** as its own coverage condition: a database older than N
   days reports stale, not clean.

## Acceptance

- [ ] A scan command on the mothership produces the §4 inventory and matching for every
      target on its installation, with the §6 coverage check and the §7 summary.
- [ ] Guest closures are listed read-only; nothing is installed on guests.
- [ ] Images are scanned by running digest.
- [ ] A target that cannot be reached or yields no packages reports SCAN FAILED (tested
      by removing `/etc/debian_version` from a node copy, as the dry run did).
- [ ] VEX statements are applied, and a decided finding is no longer reported.
- [ ] ADR-027 D7 updated: `<module>-vex.json` MAY, replacing `<module>-sbom.json`.
- [ ] The result is surfaced where §9 decides.
