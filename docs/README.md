# Documentation for TAPPaaS

This directory holds the contributor-facing documentation of the TAPPaaS source repo.
Per [ADR-013 - Documentation Structure and Standards](<ADR/ADR-013 - Documentation Structure and Standards.md>), every document has exactly one home:

- [`ADR/`](ADR/) — Architecture Decision Records: durable decision records (Draft → Accepted → Superseded, never deleted).
- [`design/`](design/) — implementation design docs for accepted ADRs/features; kept while the implementation is current.
- [`Architecture/`](Architecture/) — continuously maintained architecture SSOT: glossary, ontology/taxonomy, and concept docs.
- [`Examples/`](Examples/) — example TAPPaaS deployments and hardware sizing.

Module documentation (README/INSTALL/DESIGN) lives with the module under `src/`, and reference docs live next to the code they describe.

The public documentation site is [tappaas.org](https://tappaas.org), maintained separately in the [Documentation repo](https://codeberg.org/TAPPaaS/Documentation), which syncs selected docs from this repo at build time.
