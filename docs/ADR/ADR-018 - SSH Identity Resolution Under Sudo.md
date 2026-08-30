# ADR-018 — SSH identity resolution under `sudo -n`

| | |
|---|---|
| **Status** | **Draft** — Phase 1 implemented and locally verified; not yet published/reviewed; held per Lars's own request for a deep code review, not yet available until Monday evening. Not on `main`. |
| **Version** | 0.1 |
| **Date** | 2026-08-30 |
| **Author** | Erik Daniel |
| **Related** | **#518** (root cause, originally surfaced), **#519** (first attempted fix — `$HOME` override — closed but did not actually resolve #518), **#520** (confirms #519 didn't work; the real fix, merged), **PR #521** (the fix, TypeScript side, `lib/ts/src/cluster.ts`); **#142** (open, 2026-04-15 — the same pattern at the architecture level: whether SSH+sudo should remain the AI-agent/automation access model at all); **owner:** `lib/common-install-routines.sh` (bash side, this ADR), `lib/ts/src/cluster.ts` (TypeScript side, already merged) |
| **Changelog** | v0.1 — initial draft, written alongside Phase 1's implementation (`tappaas_operator_home`/`tappaas_ssh_identity`/`tappaas_ssh` in `common-install-routines.sh`, mirroring the already-merged TypeScript fix). |

## Context

Every `sudo -n <manager-cmd>` invocation on `tappaas-cicd` — the only way to read the
managers' own root-owned config files — failed fleet-wide with `Failed to get VM
config from Proxmox (...via qm)` / `cluster unreachable`, on every module, on both
cluster nodes, production modules included (#518).

### Root cause

OpenSSH's default identity-file resolution does not consult the `$HOME` environment
variable. It resolves the home directory from the *running process's real UID* via
`getpwuid()` — this is documented OpenSSH client behavior (tilde-expansion for the
default config/identity search path uses `pw->pw_dir` from a passwd-database lookup,
not `getenv("HOME")`), not a bug or a version-specific quirk.

`sudo -n` sets the process's effective UID to `root`. `/root/.ssh/` holds only
`authorized_keys` + `known_hosts` — no private identity of its own. The key that
actually authorizes `root@<node>` login belongs to the operator who invoked sudo
(`tappaas`), not to root — the same key `check-ha-health.service` already
authenticates with, running unprivileged, with no SSH agent, using its own static
key. So every `ssh root@<node>` call made under `sudo -n` searches the wrong
location for an identity, no matter what `$HOME` is set to.

### First attempted fix, and why it didn't work

#519 (closed via `660fb8d5`) introduced `operatorHome()`/`sshEnv()`: resolve the
invoking operator via `$SUDO_USER`, then override the spawned `ssh` process's `$HOME`
environment variable to point at that operator's home directory, hoping SSH's
default identity search would then find the right key.

It didn't. `operatorHome()`'s resolution was (and remains) correct —
`$SUDO_USER=tappaas` genuinely resolves to `/home/tappaas`. But per the root cause
above, `$HOME` was never the input SSH's identity search actually reads. Confirmed
live: `sudo -n env HOME=/home/tappaas ssh -vvv ... root@<node> whoami` still searched
only `/root/.ssh/id_rsa`, `/root/.ssh/id_ecdsa`, `/root/.ssh/id_ed25519`, etc. — the
override had no effect — and failed with `Permission denied (publickey,password)`,
even though `/home/tappaas/.ssh/id_ed25519` genuinely exists and is genuinely
trusted as root on every node (#520).

## Decision

Pass an **explicit** `-i <identity>` on every outbound `ssh root@<node>` call,
plus `-o IdentitiesOnly=yes` (stops ssh from also racing a forwarded agent key
first — under `sudo -n` an operator's own forwarded key gets offered, correctly
rejected by the node since it was never authorized there, and only then does the
client fall back to its (broken) default search; `IdentitiesOnly=yes` skips that
detour entirely). Never rely on SSH's own default identity-file resolution, and
never attempt to redirect it via `$HOME` — it is UID-based, not `$HOME`-based, and
overriding `$HOME` cannot change that.

The identity value itself is resolved **dynamically**, not hardcoded to one site's
operator username: `$SUDO_USER` (skip if `root`) → that operator's
`~/.ssh/id_ed25519`, falling back to `/home/tappaas/.ssh/id_ed25519` only when not
running under sudo at all. Overridable via `TAPPAAS_SSH_IDENTITY` /
`TAPPAAS_OPERATOR_HOME` for sites whose operator account isn't named `tappaas`, or
whose key isn't `ed25519`/at the default path.

Two independent implementations of the same fix, kept in lockstep on purpose:

- **TypeScript** (`lib/ts/src/cluster.ts` — `operatorHome()`, `sshIdentity()`,
  `ssh()`): merged on `main`, PR #521, live-verified against real production
  modules on both cluster nodes.
- **Bash** (`lib/common-install-routines.sh` — `tappaas_operator_home()`,
  `tappaas_ssh_identity()`, `tappaas_ssh()`): this ADR, Phase 1 of a 5-phase
  closure (see Consequences).

## Scope

`root@<proxmox-node>.mgmt.internal` calls only — the domain both the original bug
and this fix are confirmed against. Calls targeting `tappaas@`/`debian@<guest-VM-ip>`
may authenticate via a different key entirely (the module's own generated/cloud-init
key, not the operator's) and are **explicitly not covered** by this decision —
applying the same default there without first verifying that assumption would be
exactly the kind of unfalsified claim this initiative exists to avoid. Investigated,
not assumed, as its own phase (see Consequences, Phase 5).

## Consequences

A repo-wide sweep (2026-08-30) found **19 bash files, ~70+ individual call sites**,
doing raw `ssh root@<node>` with no explicit identity — the identical latent bug,
unpatched, because each lives outside the one helper this ADR fixes. This is not
hypothetical: `common-install-routines.sh`'s own `vm_exists_on_cluster()` was one of
them, and is almost certainly the cause of a real failure hit the same night this fix
was written (`module-manager modify tappaas-cicd` reporting "VM 130 (tappaas-cicd)
not found on the cluster" against a host confirmed healthy throughout).

Closure is phased, same branch, each phase independently verified before the next:

1. **Phase 1** (this ADR): the shared helper (`tappaas_operator_home`/
   `tappaas_ssh_identity`/`tappaas_ssh`) in `common-install-routines.sh`, plus the
   two call sites already confirmed to have caused real failures —
   `vm_exists_on_cluster()` and `test.sh`'s "Test 5: SSH connectivity to Proxmox
   nodes". Hermetic unit test: `lib/test-common-install-routines.sh`.
2. **Phase 2**: `controller/proxmox-controller/resize-disk.sh` and
   `manager/health-manager/check-disk-threshold.sh` — these additionally use the
   weaker `-o StrictHostKeyChecking=no` (silently *updates* a changed host key
   instead of rejecting it, unlike `accept-new` used everywhere else) — a real,
   separate, currently-live security weakness, prioritized to keep the exposure
   window short.
3. **Phase 3**: two pre-existing wrapper functions with the same bug, found as a
   bonus during the sweep — `manager/satellite-manager/lib/tunnel.sh`'s
   `_tunnel_ssh()` and `lib/ha-vm-lib.sh`'s `havm_exec()`.
4. **Phase 4**: the remaining ~17 files, same pattern, file-by-file (real variance
   in existing flags across them — no single mechanical find/replace).
5. **Phase 5**: the `tappaas@`/`debian@<guest>` identity-domain question —
   investigation first, fix only once the actual authenticating key is confirmed,
   which may turn out to need no change at all.

Does **not** give `root` a standing SSH identity of its own — that remains a
deliberate, separate, not-yet-made site-level decision (raised, and explicitly
deferred, in the original #518 root-cause analysis). Does not pre-empt #142's
open architectural question (SSH+sudo vs. a scoped REST API / direct Proxmox API
for automation access) — this ADR closes the acute bug class within the current
model; #142 is Lars's/the community's call on whether that model should persist at
all. Findings from this sweep are intended to be fed to #142 as evidence once this
initiative is far enough along to be worth surfacing.
