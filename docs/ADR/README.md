# Architecture Decision Records

Significant decisions in TAPPaaS are made in writing, **before the code**: each one is an
Architecture Decision Record (ADR) in this directory, and it stays here forever — superseded ADRs
are marked, never deleted. If you want to know *why* the platform is the way it is, this is the trail.

## The 2.0 spine — the taxonomy family

| ADR | Decides |
|-----|---------|
| [ADR-007 — TAPPaaS Taxonomy](<ADR-007 - TAPPaaS Taxonomy.md>) | The model everything hangs on: one **Site**, three classification domains (**People · Apps · Environments**), **Health** as a cross-cutting lens. Detailed per domain in sub-ADRs 007a–007e, realization (managers/controllers) in 007f. |
| [ADR-009 — Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) | How a deployable unit is *built* (module = atomic deployable unit; `<module>:<service>` coordinates) — composition, as distinct from ADR-007's classification. |

## Platform decisions

| ADR | Decides |
|-----|---------|
| [ADR-001 — Trunk-mode VLAN connectivity](<ADR-001 - Use Trunk Mode for TAPPaaS VM VLAN Connectivity.md>) | VMs attach on trunk ports; zones are VLANs. |
| [ADR-002 — Dynamic VLAN configuration](<ADR-002-Dynamic VLAN Configuration for TAPPaaS VM Deployment.md>) | Zone/VLAN wiring happens at deploy time, driven by module config. |
| [ADR-003 — Dependency management](<ADR-003 - Dependency management in TAPPaaS.md>) | Modules declare `dependsOn`; install order is derived, never hardcoded. |
| [ADR-004 — Module catalog & config cascade](<ADR-004-module-catalog-config-cascade.md>) | Where module configuration comes from and how overrides cascade. |
| [ADR-005 — Variant domain architecture](<ADR-005-variant-domain-architecture.md>) | *Superseded in practice by the ADR-007 Environments model (variants → environments).* |
| [ADR-006 — Identity: users and roles](<ADR-006-identity-users-and-roles.md>) | The identity model behind SSO (Authentik) — users, groups, roles. |
| [ADR-008 — Switch module / network infrastructure](<ADR-008-switch-module-network-infrastructure.md>) | Physical switches and APs become managed parts of the platform. |
| [ADR-010 — VPS satellite](<ADR-010-vps-satellite-reverse-proxy-backup.md>) | The optional off-premises satellite: public ingress, off-site backup, admin VPN. |
| [ADR-012 — Backup enhancement](<ADR-012-backup-enhancement.md>) | The managed backup-policy model (site → environment → module cascade). |
| [ADR-016 — Source NAT for subnet-filtering devices](<ADR-016 - Source NAT for subnet-filtering devices.md>) | Masquerade into a zone for IoT appliances that only accept sessions from their own subnet: zone-owned `snat-allowed-from` gate, module-local `snat.json`, `network-manager snat` verbs. |
| [ADR-017 — Update scheduling and mothership self-update](<ADR-017 - Update scheduling and mothership self-update.md>) | When the sweep runs and how the mothership updates itself (systemd `ExecStartPre=+`, schedule from `site.json`). |
| [ADR-019 — HA and Cross-Node VM Migration Policy](<ADR-019 - HA and Cross-Node VM Migration Policy.md>) | *Proposed.* The full `migrate-vm.sh` matrix — HA/non-HA, live-vs-offline by CPU compatibility (`--force` for downtime), `strict`/`comment` round-trip, when `module.json.node` is rewritten. |

## Governance

| ADR | Decides |
|-----|---------|
| [ADR-011 — SBOM Governance](<ADR-011 - SBOM Governance.md>) | Per-module software bill of materials (CycloneDX) for CVE tracking. |
| [ADR-013 — Documentation Structure and Standards](<ADR-013 - Documentation Structure and Standards.md>) | Where documentation lives, which artifact serves which audience, and how the site syncs from source. |
| [ADR-015 — Community Governance and Contribution Files](<ADR-015 - Community Governance and Contribution Files.md>) | The community-health file set (CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, GOVERNANCE, CODEOWNERS, templates) — names, per-repo placement, and contents. |

---

Writing a new ADR? Decide in writing first, before the code; the process and standards are in
[ADR-013 — Documentation Structure and Standards](<ADR-013 - Documentation Structure and Standards.md>).
