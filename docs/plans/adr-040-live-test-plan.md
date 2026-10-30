# ADR-040 live test plan (hrossen)

First run of branch `adr-040` on real hardware. hrossen runs `main` and the
operator's home production, so the test is built to be undone.

## How the branch gets onto the site

The code cannot run from a scratch directory alone: managers, `lib/cmdb.sh`,
`components.json`, the rebuild unit's `WorkingDirectory` and the sweep's sources
all name `/home/tappaas/TAPPaaS` literally.

**Decision: a bind mount.** `~/dev/adr040-live` is a git clone of the branch
(made from a bundle; nothing is pushed). `mount --bind` puts it over
`/home/tappaas/TAPPaaS`. The site's checkout stays byte for byte as it was
underneath; every hard-coded path, unit and git flake then sees the branch. A
reboot or `umount` ends it. `~/dev/adr040-live` is a real clone because the flake
needs git's root (`../` paths); harness scratch copies have no `.git` and are
removed on each sync.

- Refresh of `~/bin` (compiled managers, console, cmdb): `TAPPAAS_NO_GIT_PULL=1
  refresh-control-plane.sh` from the clone. Without that flag the pull would
  point the clone at `main`.
- OS rebuild: `sudo systemctl start --wait tappaas-rebuild@tappaas-cicd` with the
  mount in place. Not `module-manager update`: its pre-update pulls.
- A fix: commit on the Mac, send a bundle, fast-forward the clone, refresh.

## Migration 0027: on the real config, with restore

**Decision: run on the real `config/positions.json`, restore at teardown.** A copy
would prove little: the console, the sweep and asset-manager in units all read
`config/`. Baseline tarball first; teardown restores `positions.json` and
`.migrations/` from it (the 0027 ledger line goes with it, and the run-snapshot
pruning that the runner does is undone too).

## Baseline (taken before anything changes)

`~/dev/adr040-baseline/`, mode 0700: `config.tgz`, `bin.txt` (`ls -l ~/bin`),
`gcroots.txt`, `units.txt` (`systemctl list-units/timers`), system generation
(114, `7l847fcp…-nixos-system-tappaas-cicd-26.05.20261025.1f607aa`).

## Teardown (written first, runs last)

`~/dev/adr040-teardown.sh`, idempotent, in this order:

1. Remove the rendered `/run/systemd/system/cmdb-sweep.timer`; stop the timer.
2. `umount /home/tappaas/TAPPaaS`; check HEAD is `f092c05f` or the site's later tip.
3. Roll back the OS: `nix-env -p /nix/var/nix/profiles/system --switch-generation
   114`, then that generation's `switch-to-configuration switch`; delete the
   branch's generation link. Unless the operator says keep.
4. `TAPPAAS_NO_GIT_PULL=1 ~/TAPPaaS/.../refresh-control-plane.sh`: `~/bin`,
   console, `control-plane.json`, `module-fields.json` back to `main`.
5. Remove links `main` does not know (`asset-manager`, `cmdb`, `cmdb-controller`, …).
6. Restore `config/positions.json` and `config/.migrations/` from the baseline.
7. Leftover check: `ls -l ~/bin` names equal baseline, `git status` clean,
   `findmnt` shows no mount, `readlink /run/current-system` equals baseline,
   `systemctl --failed` no worse than baseline, console active, `~/config` diff
   against the baseline holds only the site's own changes, `tests clones gone`.
8. Delete the baseline tarball (it holds config) and the clone.

**May stay:** `/var/lib/postgresql` (the database `cmdb`), `/var/lib/cmdb/dump`,
`/etc/secrets/cmdb-token`, `config/.cmdb-spool/` (empty). With the rollback nothing
reads them and a later install takes them up. Listed in the final report.

## Safety rules for this run

- `pgrep` on the test processes as a call of its own before each phase.
- Long runs in the background with a 10-minute log-growth watcher.
- No reboots, nothing destructive on tappaas3, no update sweep. Must finish before
  the 02:00 `update-tappaas.timer`, or the teardown runs first.
- Reports are read-only for the planes. Writes to a plane are only the ones in
  phase 5, each chosen by what it costs if it goes wrong.

## Phases

| # | Phase | Check | Result |
|---|---|---|---|
| 0 | Baseline, clone, teardown script | files present, clone at branch tip | |
| 1a | TypeScript build | `tsc` of all components / `nix build` | |
| 1b | cmdb-controller `test.sh` | throwaway PostgreSQL | |
| 1c | switch-manager, ap-manager CLI halves | `test-cmdb-report.sh` | |
| 1d | `test-migrate-vm.sh` | passes | |
| 1e | opnsense-controller, pbs-controller tests | passes | |
| 1f | registry test | `test-control-plane-registry.sh` | |
| 1g | x86 system evaluates | `nix eval … toplevel.drvPath` | |
| 2a | OS rebuild from the branch | unit exits 0; which services restarted | |
| 2b | Services up | postgresql, cmdb-db, cmdb-paths, cmdb as `tappaas` | |
| 2c | Socket and listener | socket 0660 in a 0750 dir; 9098 loopback with token, 401 without | |
| 2d | Metamodel | `cmdb class list` | |
| 2e | Dump and backup path | `cmdb-dump`; `backup:filesystem` would capture it | |
| 3a | 0027 `--check`, apply | exit 0, ledger line | |
| 3b | `asset-manager validate`, aliases | answers as all three names | |
| 3c | Console Physical view | Record, Change, Remove the record | |
| 4a | site-manager | report, discover, second run no-op | |
| 4b | identity-manager | same | |
| 4c | module-manager | same | |
| 4d | environment-manager | same | |
| 4e | network-manager | same; rule `position` is evaluation order? | |
| 4f | switch-manager, ap-manager | same | |
| 4g | backup-manager | same | |
| 4h | storage-manager | same | |
| 4i | health-manager | `validate` writes health | |
| 4j | asset-manager | not refused; second run writes nothing, no drift; allocations resolve | |
| 5a | Console job: module-manager modify | job id + actor in `cmdb history` | |
| 5b | wlan passphrase from Setup | only if safe | |
| 5c | `migrate-vm` from a job | only if a cheap guest can move | |
| 5d | `control-plane.json` shows `cmdbSource` | after refresh | |
| 6a | `cmdb rescan` in the unit context | sandbox: spool, known_hosts | |
| 6b | `cmdb sweep` in the unit context | record, exit code | |
| 6c | Journal reaches Loki | `cmdb-sweep` lines | |
| 6d | health-manager gate `cmdb` | reads the last sweep | |
| 6e | Timer placement | before the update window | |
| 6f | Second sweep | only expected changes | |
| 7a | Teardown | script exit 0 | |
| 7b | Leftover check | every item above | |

## Fixes made during the run

| Commit | What |
|---|---|

## Still broken or unverified

## For the operator to decide
