# debianhost — design

Primary audience: module developers.

## One module, many instances (ADR-026 D6)

Every machine is an instance of this one module: `config/<hostname>.json`, with `.moduleSource`
pointing here, so `module_of <instance>` answers `debianhost` whatever the machine is called.
Nothing parses the instance name. The machine is reached by its **`address`** field — never by a
name derived from the instance, and never through Proxmox: every script talks to the machine
over SSH only (`lib/debianhost-lib.sh`, `dh_ssh`).

`tier: foundation` gives what a machine needs — installed in `mgmt`, from an official source.
Its value text still says *single-instance*; that does not hold here and is not enforced for
instances named with `--instance` (the guard looks for `config/debianhost.json`). ADR-022e's
`scope: site` replaces `tier` and says it honestly.

## Root, by key, never a password (ADR-026 D8.1)

`dh_ssh` logs in as `root` with the mothership's key: `BatchMode`, `PasswordAuthentication=no`,
`KbdInteractiveAuthentication=no`. A machine that does not accept the key is unreachable to this
module, and every script says so rather than prompting.

## Registering changes nothing

`install.sh` only proves reachability and the OS. Key-only SSH, firewalling or any other
hardening is a separate, explicit step (operator decision, 2026-09-18).

## The reboot rule (ADR-020 D8)

`update.sh` runs `apt-get full-upgrade` with `--force-confdef --force-confold`, so local
configuration files are kept. A pending reboot (`/var/run/reboot-required`) is taken only when
authorized:

- `TAPPAAS_ALLOW_DISRUPTION=1` — the module-manager sets it for the module's own `update.sh`
  when the run has `--allow-disruption` (`reconcile.ts`); or
- `rebootOk: true` during the scheduled pass (`TAPPAAS_SCHEDULED_PASS=1`) — the rule the
  `cluster:vm` service applies.

Otherwise it prints `DEFERRED: <instance> reboot …` and exits 0; update-tappaas collects those
lines into the run's `deferred_changes`. A reboot is verified by the **boot id** changing, read
before and after — so "it came back" is never confused with "it never went"; without a boot id
beforehand it does not reboot at all.

## Deleting unregisters (ADR-026)

`delete-module.sh` treats `kind: machine` as config-only: no VM lookup, and `--vmid` is refused —
naming one could only destroy something the machine is not (a stand-in VM sharing its name).
