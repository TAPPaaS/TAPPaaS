# ADR-011 — SBOM Governance

| | |
|---|---|
| **Status** | Draft |
| **Version** | 0.2 |
| **Date** | 2026-06-17 |
| **Author** | Erik Daniel |
| **Related** | **#143** (CVE tracking / SBOM — origin); **#363** (module lifecycle blueprint ADR — artifact naming); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Module = atomic deployable unit); [ADR-017](<ADR-017 - Update scheduling and mothership self-update.md>) (nixpkgs pinning — same flake-metadata gap this ADR's tooling hits) |
| **Changelog** | v0.1 — skeleton (Erik⟷Lars design direction agreed 2026-06-16). v0.2 — tooling decision (§4): `sbomnix` for NixOS-templated modules, `syft` for the Debian/Ubuntu minority; CycloneDX floor corrected to 1.4+ (was 1.5+) to match the chosen tool's native output; both tools tested live, head-to-head, against the same real module derivation (`module-manager`) — `sbomnix` correctly found its dependencies, `syft`'s `nix-cataloger` found zero. |

Per-module Software Bill of Materials: what, where, when, and how TAPPaaS modules declare their component inventory.

## Context

TAPPaaS modules ship as VMs with bundled packages, services, and dependencies. Without a machine-readable component inventory, CVE tracking (#143) requires manual effort and is incomplete. The industry standard for this is a Software Bill of Materials (SBOM).

Two open questions the meeting (2026-06-16) resolved at the design level:

1. **Where does the SBOM live?** Per-module directory (co-located), not a single aggregated file.
2. **What format?** CycloneDX JSON.

Two questions deferred to this ADR:

3. **What tooling generates/validates the SBOM?**
4. **How does CVE merge/compile work?** (Second phase — out of scope for v1.)

## Decision

### 1. Artifact location and naming

Each module directory carries `{module-name}-sbom.json` alongside the other blueprint artifacts (README.md, install.sh, test.sh, update.sh). Co-location rule — same as the module lifecycle blueprint (ADR to be accepted, #363).

### 2. Format

[CycloneDX](https://cyclonedx.org/) 1.4+ (JSON) — corrected from the original 1.5+ floor (§4):
1.4 is what the chosen primary tool (`sbomnix`) emits natively, and 1.4 already
satisfies the actual rationale below; requiring 1.5+ would need an added
conversion step for no real gain. Rationale: JSON-native (consistent with
`module-fields.json`); broad tooling support (`syft`, `cdxgen`, vendor SBOMs);
[NTIA-minimum-elements](https://www.ntia.gov/report/2021/minimum-elements-software-bill-materials-sbom) compliant.

### 3. Obligation level

**SHOULD** (not MUST) in v1 — enforced by linting, not install-time blocking. Same obligation level as INSTALL.md. First iteration scope: top-level component list only (direct dependencies). Transitive tree is a v2 concern.

### 4. Tooling — decided, tested against a real module

TAPPaaS modules are not uniformly one OS: the default template is NixOS
(`dependsOn: templates:nixos`, 22+ modules), but real Debian/Ubuntu images are
also in use (`debian-13-generic`, `ubuntu-24.04-server-cloudimg`, per
[`DEVELOP.md`](<../../src/apps/00-Template/DEVELOP.md>)'s own "ships as
NixOS/Debian/ISO/Windows" statement). One tool does not fit both — the decision
is per module-OS-type, not a single universal choice:

| Module type | Tool | Why |
|---|---|---|
| NixOS-templated (default) | [`sbomnix`](https://github.com/tiiuae/sbomnix) | Reads the Nix derivation's *actual* build closure directly — structurally more precise than a filesystem scanner, since Nix already knows the exact dependency graph from the build itself. Native CycloneDX output. |
| Debian/Ubuntu image-based | [`syft`](https://github.com/anchore/syft) (Anchore) | Does have a `nix-cataloger`, so it's not a Nix-blind tool — but tested it against the same `module-manager` derivation `sbomnix` was tested against (§4 below) and it returned **zero components**; its cataloger appears to need a populated Nix DB/full store context, not a bare built derivation, so it doesn't fit TAPPaaS's actual per-module SBOM model. Still the right fit for the non-Nix minority, where this limitation doesn't apply. |
| Modules with an upstream-published SBOM | Vendor SBOM (e.g. PostgreSQL, Nextcloud) | Reference rather than regenerate — unchanged from the original options list. |

`nix2sbom` and [`bombon`](https://github.com/nikstur/bombon) were also
considered as Nix-native alternatives to `sbomnix`; not chosen because `sbomnix`
is already packaged in `nixpkgs` (`nix shell nixpkgs#sbomnix`, no extra build
step) and its output already carries the richest provenance metadata
(`nixpkgs:flakeref`, `rev`, `metadata_source_method`) of the three.

**Tested live, not assumed** — ran `sbomnix` against `module-manager`'s real
built derivation:

```
sbomnix /nix/store/fpy9a8iqjmdq5gm70h473xrpm602s0fy-module-manager-0.1.0 \
  --depth=1 --cdx module-manager-sbom.cdx.json
```

`--depth=1` matches §3's own v1 scope ("top-level component list only") exactly
— output correctly contained just `module-manager`'s two true direct runtime
deps (`bash@5.3p3`, `nodejs@22.22.2`), matching its actual wrapper script
(`exec node ... main.js`). Real CycloneDX 1.4 JSON, correct `purl` scheme
(`pkg:nix/module-manager@0.1.0`), CPE auto-generated (useful groundwork for
§5's CVE integration). Confirmed the v2 "transitive tree" scope (§3) needs no
new tooling later — the same command without `--depth` returned the full
19-component closure today.

Ran `syft` (`nix-cataloger`) against the identical store path as a direct
comparison: `syft /nix/store/.../module-manager-0.1.0 -o cyclonedx-json=...`
returned CycloneDX 1.6 JSON with **zero components** — its `nix-cataloger`
warned about deriving an artifact ID from a bare directory path, "which is
not ideal." `sbomnix` correctly found the real dependencies on the same
input `syft` found none for.

**One dependency on [ADR-017](<ADR-017 - Update scheduling and mothership self-update.md>) D3:**
`sbomnix` warned it could not read flake metadata for `module-manager`
specifically, because that module's `default.nix` still resolves `pkgs` from
the ambient `<nixpkgs>` (`import <nixpkgs> { }`) rather than a flake
reference — the exact gap ADR-017 D3 proposes closing
(`lib/nix/pinned-pkgs.nix`, reading `tappaas-cicd`'s own `flake.lock`). Once
that lands, `sbomnix` output for every TS manager should gain richer
provenance (`nixpkgs:flakeref`/`rev`) for free — no extra SBOM-side work.

Decision: `sbomnix` (NixOS modules) + `syft` (Debian/Ubuntu modules), both
producing CycloneDX 1.4+ JSON per §2.

### 5. CVE integration (phase 2 — out of scope for v1)

A separate function merges per-module SBOMs against a CVE database (e.g. OSV, NVD) and surfaces risk. Design deferred until per-module SBOMs exist. Tracked in #143.

## Acceptance

- [ ] `{module-name}-sbom.json` naming and co-location rule adopted in module lifecycle blueprint (ADR, #363).
- [ ] CycloneDX JSON format specified in module 00-Template.
- [x] Tooling decision made and documented (update this ADR to v0.2) — `sbomnix` +
      `syft`, tested live against `module-manager` (§4).
- [ ] At least one foundation module carries a CycloneDX SBOM (proof-of-concept).
- [ ] Linting rule added to validate SBOM presence (SHOULD-level warning, not error).
