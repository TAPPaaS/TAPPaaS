# debianhost

Primary audience: TAPPaaS admin.

A **Debian machine TAPPaaS manages** — a physical server, a mini-PC, anything with its own
Debian install that is not a Proxmox guest (ADR-026). TAPPaaS keeps its operating system
patched on the same schedule, and under the same reboot rules, as a cluster node. It is the
first `kind: machine` module: one module, as many instances as you have machines, each named
after its machine.

## What you get

| Capability | How |
|---|---|
| The machine in TAPPaaS's inventory | one instance per machine, `config/<hostname>.json`, `kind: machine`, `os: debian` |
| OS patching | `apt` full-upgrade on every update — nightly with the sweep, or `module-manager module update <instance>` |
| Reboots only when authorized | a reboot the upgrade needs waits for `--allow-disruption`, or for `rebootOk: true` in the scheduled pass; until then it is reported as deferred |
| Health checks | reachable, Debian, no reboot pending, disk below 90%, clock synchronised, SSH key-only (when `sshKeyOnly`) |
| Key-only SSH | password and keyboard-interactive logins over SSH refused for every user, root by key only — as on the cluster nodes (#19, #756). On by default; the console keeps the root password |

## What is not included

- **Nothing else on the machine changes when it is registered.** Key-only SSH is the one change,
  and you can decline it when you adopt: `module adopt <address> --set sshKeyOnly=false` — for
  a machine someone reaches by password. Firewalling and other hardening are not done.
- **Removing it never harms it.** `module delete <instance>` unregisters the machine; it keeps
  running, untouched.
- **Its network cabling is recorded, not enforced.** `zone0` says which network its NIC is on;
  nothing sets the switch port (#668).
- Other operating systems: one module per OS (ADR-026 D7). An Ubuntu or NixOS machine is not a
  `debianhost`.
- Installing the OS. For now the machine is installed by hand; PXE installation is ADR-026 D8a.

## Requirements

- Debian, reachable from the mothership over SSH.
- The mothership's public key authorised for `root` on the machine
  ([INSTALL.md](INSTALL.md) shows how).
