# debianhost — design

Primary audience: module developers.

## One module, many instances (ADR-026 D6)

Every machine is an instance of this one module: `config/<hostname>.json`, with `.moduleSource`
pointing here, so `module_of <instance>` answers `debianhost` whatever the machine is called.
Nothing parses the instance name. The machine is reached by its **`address`** field — never by a
name derived from the instance, and never through Proxmox: every script talks to the machine
over SSH only (`lib/debianhost-lib.sh`, `dh_ssh`).

`stack: foundation` gives what a machine needs: it makes the module site-scoped (ADR-022e) —
installed in `mgmt`, from an official source, `--force` to delete. Site scope is not
single-instance (D4), which is what lets one module have several named machines.

## Root, by key, never a password (ADR-026 D8.1)

`dh_ssh` logs in as `root` with the mothership's key: `BatchMode`, `PasswordAuthentication=no`,
`KbdInteractiveAuthentication=no`. A machine that does not accept the key is unreachable to this
module, and every script says so rather than prompting.

## Registering changes one thing: SSH

`install.sh` proves reachability and the OS, then makes SSH key-only unless the config says
`sshKeyOnly: false` (operator decision 2026-10-02, #756, reversing 2026-09-18's "registering
changes nothing"). Firewalling or any other hardening is not done.

The work is `tappaas-cicd/scripts/ssh-key-only.sh`, the script the cluster nodes use (#19),
fed over the key login (`dh_key_only`) so nothing is copied to the machine. One sshd drop-in,
`/etc/ssh/sshd_config.d/10-tappaas-hardening.conf`: `PermitRootLogin prohibit-password`,
`PasswordAuthentication no`, `KbdInteractiveAuthentication no`. `sshd -t` before the reload,
with the previous state restored on rejection; the effective values read back with `sshd -T`,
so an earlier line in `sshd_config` that wins over the drop-in is a failure, not a pass.

- `update.sh` converges it first, before `apt`: applied when wanted, the TAPPaaS drop-in
  removed when `false` (a drop-in it did not write is left alone). A state it cannot reach
  fails the update.
- `test.sh` asserts it when wanted; in the pre-update gate it is reported, not failed, because
  the update is what applies it.
- The satellite runs these same scripts for its machine, so it gets the same behaviour.
- A field that is absent means `true`. Machines adopted before #756 were promised the opposite,
  so migration 0013 wrote `false` into their configs; `adopt` writes the value it chose into
  every new config, so the config always says.

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
