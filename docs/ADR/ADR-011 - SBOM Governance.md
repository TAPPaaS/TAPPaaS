# ADR-011 — SBOM Governance

| | |
|---|---|
| **Status** | Draft |
| **Version** | 0.1 |
| **Date** | 2026-06-17 |
| **Author** | Erik Daniel |
| **Related** | **#143** (CVE tracking / SBOM — origin); **#363** (module lifecycle blueprint ADR — artifact naming); [ADR-009](<ADR-009 - Composition Meta-Model.md>) (Module = atomic deployable unit) |
| **Changelog** | v0.1 — skeleton (Erik⟷Lars design direction agreed 2026-06-16) |

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

CycloneDX 1.5+ (JSON). Rationale: JSON-native (consistent with `module-fields.json`); broad tooling support (`syft`, `cdxgen`, vendor SBOMs); NTIA-minimum-elements compliant.

### 3. Obligation level

**SHOULD** (not MUST) in v1 — enforced by linting, not install-time blocking. Same obligation level as INSTALL.md. First iteration scope: top-level component list only (direct dependencies). Transitive tree is a v2 concern.

### 4. Tooling (TBD)

_Options to evaluate:_

- `syft` (Anchore) — scans installed packages inside a VM/container; generates CycloneDX JSON.
- Vendor-published SBOMs — e.g. PostgreSQL, Nextcloud publish their own; reference rather than regenerate.
- Manual stub — acceptable for MVP when automated scanning is not yet wired.

Decision: _to be made after tooling evaluation. Assign: @ErikDaniel007._

### 5. CVE integration (phase 2 — out of scope for v1)

A separate function merges per-module SBOMs against a CVE database (e.g. OSV, NVD) and surfaces risk. Design deferred until per-module SBOMs exist. Tracked in #143.

## Acceptance

- [ ] `{module-name}-sbom.json` naming and co-location rule adopted in module lifecycle blueprint (ADR, #363).
- [ ] CycloneDX JSON format specified in module 00-Template.
- [ ] Tooling decision made and documented (update this ADR to v0.2).
- [ ] At least one foundation module carries a CycloneDX SBOM (proof-of-concept).
- [ ] Linting rule added to validate SBOM presence (SHOULD-level warning, not error).
