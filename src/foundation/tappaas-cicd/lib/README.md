# lib/

Shared libraries for tappaas-cicd managers/controllers (ADR-007 P4). **Never
copied per component** — shared logic lives here once and is sourced /
imported / built in.

| Entry | What it is |
|---|---|
| `common-install-routines.sh` | The big module-context bash library (config readers, logging, service checks). Sourcing it initialises module context. |
| `component-install-lib.sh` | Tiny, side-effect-free helpers for component verb scripts: `build_and_link_nix_component`, `link_component_executables`, `run_component_test_scripts` (Phase 3.8 of the post-ADR-007 refactor). |
| `cmdb.sh` | The bash layer's client of the CMDB (ADR-040): `cmdb_report` (a report from stdin or a file; never fails the caller, a refusal is a warning), `cmdb_query`, `cmdb_show`, `cmdb_available` — thin wrappers over the `cmdb` CLI, which spools what the service cannot take. |
| `cmdb-report.sh` | On top of `cmdb.sh`, for the bash managers that report (ADR-040 D4): `cmdb_current_job` (the console job and actor as `{job, actor}`: `TAPPAAS_JOB_ID`, `TAPPAAS_ACTOR` else the OS user, as lib/ts `job.ts`), `cmdb_change_head <verb>` (a change's verb, job and actor), `cmdb_send_reports` (a JSON array of reports, each sent on its own so a refused one takes nothing else with it; `TAPPAAS_CMDB=off` sends nothing). |
| `cli-gate.sh` | `cli_gate` — the argument gate the bash controllers call before dispatch: `-h`/`--help` in any position prints that verb's usage and runs nothing; an option the verb does not declare in the CLI's `CLI_SPEC` is refused (#644). |
| `apply-json-merge.sh`, `audit-jq-readers.sh`, `test-config-readers.sh` | Module-config merge + reader-audit tools. |
| `verify-repo.sh`, `test-verify-repo.sh` | Signed releases (ADR-033): the tree's SHA-256, a release tag's signature checked against the `.tappaas/allowed_signers` of the last verified release, rollback refusal, a key's validity read against today when moving (the tag's date can be back-dated), the revocation list `.tappaas/revoked_signers`, the chain through the releases in between, a fresh clone's current release checked against its owners' fingerprints (`verify_introduction`, D5), and the trust record in `config/.trust/`. `repo-sync.sh` gates every staging/production checkout move through it; `tappaas-train.sh` uses it to cut signed tags. |
| `nix-site-key.sh` | The mothership's Nix signing key (ADR-033 D8) in `/etc/nix/tappaas-site-signing.{sec,pub}`: created once by `tappaas-render-fragments.sh` (or `update-os.sh`), its public half rendered into every guest's `tappaas-site.nix`; `update-os.sh` signs each guest closure with it before a signature-checked `nix copy`. |
| `ts/` | The shared TypeScript library the TS managers compile in (see [`ts/README.md`](ts/README.md)). |
| `nix/ts-manager.nix` | The one nix derivation builder every TS manager's `default.nix` imports. |
