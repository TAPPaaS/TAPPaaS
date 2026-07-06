# lib/

Shared libraries for tappaas-cicd managers/controllers (ADR-007 P4). **Never
copied per component** — shared logic lives here once and is sourced /
imported / built in.

| Entry | What it is |
|---|---|
| `common-install-routines.sh` | The big module-context bash library (config readers, logging, service checks). Sourcing it initialises module context. |
| `component-install-lib.sh` | Tiny, side-effect-free helpers for component verb scripts: `build_and_link_nix_component`, `link_component_executables`, `run_component_test_scripts` (Phase 3.8 of the post-ADR-007 refactor). |
| `apply-json-merge.sh`, `audit-jq-readers.sh`, `test-config-readers.sh` | Module-config merge + reader-audit tools. |
| `ts/` | The shared TypeScript library the TS managers compile in (see [`ts/README.md`](ts/README.md)). |
| `nix/ts-manager.nix` | The one nix derivation builder every TS manager's `default.nix` imports. |
