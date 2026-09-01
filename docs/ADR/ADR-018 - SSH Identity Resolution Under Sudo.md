# ADR-018 — SSH identity resolution under `sudo -n`

| | |
|---|---|
| **Status** | **Superseded in part** — the acute root-cause analysis below stands (this is why it is preserved on `main`), but the per-call-site explicit-`-i` sweep is **not** the chosen fix. PR #523 (the bash-side/full-estate sweep) will **not** be merged. The decided direction is the ownership/identity **guard** in **#533**: managers run as `tappaas` over `tappaas`-owned config + repos, so the manager estate never runs under `sudo -n` and SSH identity resolves via the `tappaas` UID with no per-site flags. The explicit-`-i` helper is retained **only** for the genuinely-root paths that cannot run as `tappaas` — `install-platform.sh` (bootstrap, `EUID==0`), `node-provisioner` (netboot/TTL), and `opnsense-controller`'s root firewall path (dedicated `tappaas-fw` key). See #533, #535, #536. |
| **Version** | 0.5 |
| **Date** | 2026-08-30 |
| **Author** | Erik Daniel |
| **Related** | **#518** (root cause, originally surfaced), **#519** (first attempted fix — `$HOME` override — closed but did not actually resolve #518), **#520** (confirms #519 didn't work; the real fix, merged), **PR #521** (the fix, TypeScript side, `lib/ts/src/cluster.ts`); **#226** (2026-05-25, `grant_cicd_firewall_access()` — the firewall's own dedicated-key mechanism, load-bearing context for the firewall-domain closure below); **#142** (open, 2026-04-15 — the same pattern at the architecture level: whether SSH+sudo should remain the AI-agent/automation access model at all); **owner:** `lib/common-install-routines.sh` (bash side, this ADR), `lib/ts/src/cluster.ts` (TypeScript side, already merged) |
| **Changelog** | v0.1 — initial draft, Phase 1 only. v0.2 — Phase 2 (weak host-key checking). v0.3 — Phase 3 (`havm_exec()`; `_tunnel_ssh()` investigated and excluded, see Consequences), Phase 4 (remaining node-domain files). v0.4 — firewall domain closed (`tappaas_fw_ssh()`), tree re-swept twice; mutation-tested all three identity guarantees (test-quality audit, see Consequences); independently ratified by a fresh chief-architect + cybersecurity-specialist review (architect: REFINE, 4 items, all addressed; security: APPROVE). v0.5 — Phase 5 closed (guest-VM domain, confirmed via the actual cloud-init provisioning path, no new resolver needed). All five phases plus the firewall domain now closed; scope is the full estate, not a subset. |

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
  `tappaas_ssh_identity()`, `tappaas_ssh()`): this ADR. Phase 1 of what became
  a full-estate closure across five phases plus a distinct firewall domain
  (see Consequences) — the 5-phase estimate at Phase 1's own start turned out
  to undercount the actual scope once the tree was swept twice.

## Scope

Confirmed to cover three identity domains: `root@<proxmox-node>.mgmt.internal`,
`root@firewall` (OPNsense, via `tappaas_fw_ssh()`), and `tappaas@`/`debian@<guest-VM>`
(Phase 5, closed 2026-08-30 — see Consequences). The guest-VM domain was
investigated, not assumed: traced to `foundation/cluster/Create-TAPPaaS-VM.sh`,
which seeds every application-module VM's cloud-init with `~/tappaas/tappaas-cicd.pub`
— confirmed (via `install.sh`) to be a copy of the same `id_ed25519.pub`
`tappaas_ssh_identity()` already resolves. Live-falsified against two real,
independently-provisioned VMs (`ebh-mcp`, `deconz`) under the actual `sudo -n`
bug context before generalizing — a first test target (`backup`) initially looked
like a refutation until its config was checked and found to be `vmid: null`, a
stub with no real VM, not a counter-example. `tappaas-cicd`'s own VM is the one
confirmed exception — it uses the Proxmox node's own key for its own
chicken-and-egg bootstrap (`install-platform.sh` Phase B), not this pattern.

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
3. **Phase 3** (partial, by design): two pre-existing wrapper functions found as
   a bonus during the sweep, investigated as *two different identity domains*,
   not one — `lib/ha-vm-lib.sh`'s `havm_exec()` (confirmed same
   `root@<proxmox-node>` domain — **fixed**) and
   `manager/satellite-manager/lib/tunnel.sh`'s `_tunnel_ssh()` (confirmed a
   *different* domain — the satellite's dedicated, out-of-band operator key,
   documented by `satellite-manager install --sshkey`'s own help text as
   explicitly "NOT a tappaas-cicd key" — **excluded**, deliberately, not
   deferred: applying this ADR's default there would have been wrong, not
   just unverified).
4. **Phase 4**: the remaining node-domain files (11, not the originally
   estimated ~17 — some of the original sweep's 19 files turned out to already
   be covered by Phases 1–3, or to belong to the firewall domain below), same
   pattern, file-by-file (real variance in existing flags across them — no
   single mechanical find/replace). A second sweep after this phase found four
   more files the first sweep had missed (`test-variants/`,
   `test-vm-creation/test-vm.sh`/`test-reinstall.sh`, `prepare-netboot.sh`) —
   fixed alongside the firewall domain below.
5. **Firewall domain** (a third identity domain, found mid-initiative, not
   originally in the 5-phase estimate): `root@firewall` (OPNsense). Closed via
   a new `tappaas_fw_ssh()`/`tappaas_fw_ssh_identity()` pair — prefer the
   dedicated `~/.ssh/tappaas-fw` key `#226` provisions when present, fall back
   to the operator key otherwise (falsified against this site's actual
   provisioning dates before deciding: both predate `#226` by weeks, and its
   provisioning step is run-once, non-retroactive — this site's operator-key
   fallback is expected, not drift). ~26 call sites across 11 files.
6. **Test-quality audit**: none of the above had been mutation-tested until
   audited and closed — green alone proves a guarantee holds, not that the
   test fails for the right reason. Closed by actually stripping `-i`/
   `IdentitiesOnly=yes` from all three identity guarantees (`tappaas_ssh()`,
   `tappaas_fw_ssh()`, `havm_exec()`) in turn, confirming the right test (and
   only that test) went red, restoring, and confirming green and
   byte-identical again.
7. **Independent ratification**: a fresh chief-architect + cybersecurity-
   specialist review (each inspecting the diffs directly, re-running every
   test suite and the mutation test themselves, rather than trusting a prior
   summary) — security: **APPROVE**; architect: **REFINE**, four small,
   concrete items (a stale cross-reference, an undocumented exclusion, a
   comment-only sourcing-order contract, a tracked follow-up for the
   duplicated identity-resolution logic) — all four addressed and re-verified.
8. **Phase 5** (closed 2026-08-30): the `tappaas@`/`debian@<guest>` identity
   domain — confirmed to use the same operator key (see Scope), no new resolver
   needed. Reused `tappaas_ssh()`/`tappaas_ssh_identity()` directly — that
   function takes the full `user@host` target, so nothing guest-VM-specific
   was required. Closed the two remaining `-o StrictHostKeyChecking=no` sites
   on this domain alongside it (`resize-disk.sh`, `check-disk-threshold.sh`),
   matching Phase 2's reasoning. ~34 call sites across `resize-disk.sh`,
   `check-disk-threshold.sh`, `update-os.sh`, `test-vm.sh`. Live-verified: the
   actual patched `check-disk-threshold.sh` run end-to-end against a real VM
   (`deconz`) under `sudo -n`, real disk-usage reading returned.

**Satellite domain**: deliberately excluded throughout (see Phase 3) — a
genuinely separate identity model, not part of this closure. **Full-tree
re-sweep after Phase 5** (every domain: node, HA, firewall, guest-VM) found
zero remaining unmigrated `ssh`/`scp` call sites — every residual hit is a
comment, a `warn`/`die` string, a test string-literal, or already fixed via a
variable that bakes the identity flags in.

Does **not** give `root` a standing SSH identity of its own — that remains a
deliberate, separate, not-yet-made site-level decision (raised, and explicitly
deferred, in the original #518 root-cause analysis). Does not pre-empt #142's
open architectural question (SSH+sudo vs. a scoped REST API / direct Proxmox API
for automation access) — this ADR closes the acute bug class within the current
model; #142 is Lars's/the community's call on whether that model should persist at
all. Findings from this sweep are intended to be fed to #142 as evidence once this
initiative is far enough along to be worth surfacing.

**Open follow-up, not blocking this ADR**: the identity-resolution precedence
(`TAPPAAS_SSH_IDENTITY`/`TAPPAAS_OPERATOR_HOME` → `$SUDO_USER` → fallback) now
exists in four places kept in sync by commit-message discipline alone —
`lib/ts/src/cluster.ts` (canonical TypeScript), `lib/common-install-routines.sh`
(canonical bash), and two deliberate bash duplicates
(`manager/health-manager/check-disk-threshold.sh`,
`scripts/prepare-netboot.sh` — each self-contained by design, avoiding a new
shared-lib dependency). Nothing currently detects the four drifting apart.
Independent chief-architect ratification review (2026-08-30) flagged this as
the most legitimate structural risk in the whole initiative — not urgent
enough to block, but worth a tracked follow-up (a parity-check test, or at
minimum a checklist item) before it's forgotten.
