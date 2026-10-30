# ADR-041 live test plan (hrossen)

First run of branch `adr-041` (ADR-040 with its live-test fixes, plus health in
the CMDB) on real hardware. Method and safety as in
[adr-040-live-test-plan.md](adr-040-live-test-plan.md): a git clone of the branch
bind-mounted over `/home/tappaas/TAPPaaS`, `tappaas-rebuild@tappaas-cicd` for the OS,
`TAPPAAS_NO_GIT_PULL=1 refresh-control-plane.sh` for `~/bin`.

## Decisions

- **Migration 0027 on the real config, restored at teardown**, as before.
- **Rollback at teardown**: the operator is away. Generation 114, `~/bin`, `positions.json`.
- **The ADR-040 run's store is kept** for phase 3: its old `health` rows must not break
  `assess`, `show` or the console now that the metamodel no longer declares `health`.
- **Root-cause case: `tappaas4`.** `config/tappaas4.json` has no node behind it, already
  critical. No guest is stopped. Nothing touches `deconz-test` or any household service.
- **The ADR-039 rule file is validated and dry-run only.** `HealthRootCause` would mail
  the operator about `tappaas4` on apply. Applying it is his call.
- **The receiver hook** is tested only if a synthetic ALERT can avoid a mail.
- **Loki** is read on the logging VM with `logcli` and the VM's own admin credential
  (logging README), read-only. The credential is not copied off the VM or printed.

## Teardown (written first, runs last)

`~/dev/adr041-teardown.sh`, idempotent, as ADR-040's plus the health state:

1. Remove the rendered `cmdb-sweep.timer` and `health-assess.timer`.
2. `umount`; the checkout must be at the site's own HEAD.
3. Roll back to generation 114, delete the branch's generation.
4. Refresh `~/bin` and the console from the site's checkout.
5. Remove links and gcroots `main` does not know.
6. Restore `positions.json` and `.migrations/` from the baseline; remove
   `config/.health-emit-cursor` and its lock.
7. Leftovers: `~/bin` link for link against the baseline, no mount, checkout clean, current
   system equal to the baseline, console 200, no listener on 9098/5432/9197/9198, no cmdb or
   health timer, `config/` differing only in timestamps.
8. Delete baseline, clone, logs, scripts.

**May stay:** `/var/lib/postgresql`, `/var/lib/cmdb/dump`, `/etc/secrets/cmdb-token`,
empty `config/.cmdb-spool/`.

## Phases

| # | Phase | Check | Result |
|---|---|---|---|
| 0 | Baseline, clone, teardown script | present | |
| 1a | Build | every flake package | |
| 1b | health-manager fast tests | on the site | |
| 1c | ui fast tests | on the site | |
| 1d | cmdb-controller, alert-rules tests | pass | |
| 1e | x86 evaluation | toplevel drvPath | |
| 2a | OS rebuild from the branch | unit exits 0 | |
| 2b | `health-assess.timer` | rendered from `site.json`, default 5 | |
| 2c | `health-assess.service` | assess && emit as `tappaas`, in its sandbox | |
| 3a | `assess` on the real site | each gate's condition on its object | |
| 3b | Objects | a vm, a machine, a pool, the cluster, the backup-peer | |
| 3c | `validate` as a read | same verdict as `--live`, and as before | |
| 3d | Second assess | changes only `lastChecked` | |
| 3e | Old `health` rows | reads survive them; dropped or dead | |
| 4a | `rootCauses[]` on the site | names tappaas4 | |
| 4b | `impact` on dependants; `roots` | as derived | |
| 4c | `ack` the root | symptoms silenced | |
| 4d | `unack` | restored | |
| 5a | `emit` lines | kinds causal, symptom, recovery | |
| 5b | Cursor and flapping | cursor moves; no flapping on a steady site | |
| 5c | Receiver hook | synthetic ALERT, no mail | |
| 5d | ADR-039 rule file | validate, apply --dry-run | |
| 6a | `/health` as installer | graph on the roots | |
| 6b | Sub-flows, CI panel | open and read | |
| 6c | Ack as a job | change row with job and actor | |
| 6d | SSE through Caddy | `health/stream` on the real route | |
| 6e | `health/graph?at=` | real history | |
| 6f | Overview, Backup, Modules | read conditions, agree with the graph | |
| 7a | `cmdb-sweep` in Loki | read on the logging VM | |
| 7b | `tappaas-health` in Loki | same | |
| 8a | Teardown | script exit 0 | |
| 8b | Leftover check | every item above | |

## Fixes made during the run

| Commit | What |
|---|---|

## Still broken or unverified

## For the operator to decide
