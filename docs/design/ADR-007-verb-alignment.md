# ADR-007 — Manager & Controller verb alignment (design for Remaining-outstanding #3)

Design input for the all-managers-to-TypeScript migration (#3) and the verb /
CRUD conventions (#4, #5). The goal: a single, aligned command surface so every
manager presents the same verbs for the same concepts, and every network-plane
controller presents the same provider contract.

**Legend**

| Mark | Meaning |
|------|---------|
| 🟢 | exists as a proper verb (TS subcommand), correct name |
| ✎ `name` | exists but **wrong/legacy name** (current name shown) |
| 📜 `file` | **a script exists** for the function (manager not yet TS) — port target |
| ✗ | **missing** — should exist, does not |
| N/A | not applicable to this manager/controller |

`install` / `update` / `test` stay `.sh` **by design** (the component contract —
`install.sh` builds/links the bin; not meant to be TS verbs), so they are 🟢
(contract met) for everyone and omitted from the alignment rows below.

---

## Table 1 — Managers × verbs

TS today: **people**, **network**. Script today (port targets): **site,
environment, module, backup, health**.

| Verb (concept) | people · TS | network · TS | site | environment | module | backup | health |
|---|---|---|---|---|---|---|---|
| **validate** (check config) | 📜 `validate.sh` | 📜 `validate.sh` | 📜 `validate-site.sh` | 📜 `validate-environment.sh` | 📜 `validate-module.sh` | 📜 `validate-backup.sh` | ✗ |
| **list** (enumerate entities) | 🟢 `org/group/role/user list` | 🟢 `zone list` | ✗ | ✗ | ✗ | 📜 `backup-status.sh` | 📜 `inspect-cluster.sh` |
| **show / get** (one entity) | 🟢 `… get` | ✗ | ✗ | ✗ | ✗ | 📜 `backup-status.sh` | 📜 `inspect-vm.sh` |
| **add / create** | ✗ (edit config + `sync`) | 🟢 `zone add` | 📜 `create-site.sh` | 📜 `create-minimal-environments.sh` | 📜 `install-module.sh` | ✗ (edit config) | N/A |
| **modify / set** | ✗ (edit config + `sync`) | ✗ (edit zones.json + reconcile) | ✗ | ✗ | ✎ `update-module.sh` (=redeploy) | ✗ | N/A |
| **delete / remove** | ✗ (edit config + `sync`) | 🟢 `zone delete` | N/A (singleton) | ✗ | 📜 `delete-module.sh` | ✗ | N/A |
| **reconcile / sync** (config→live) | 🟢 `sync` | 🟢 `reconcile` | ✎ `repository.sh` (repos only) | N/A | 📜 `backup-manager.sh` (jobs→PBS) | N/A | N/A |
| **diff / dry-run** | ✗ | 🟢 `reconcile` (no `--apply`); `zones-merge --diff` | ✗ | ✗ | ✗ | ✗ | N/A |

**Per-manager domain-specific verbs (keep; not part of the aligned core):**

| Manager | Domain verbs |
|---|---|
| people | `sync`, `user-setup.sh` |
| network | `reconcile [--only opnsense\|proxmox\|switch\|ap]`, `zones-init`, `zones-merge`, `zones-check`, `zones-distribute`, `zone add/delete/list` |
| site | `create-site`, `repository`, `convert-json-to-config`, `migrate-configuration-to-site` (+ legacy `create-configuration`, `validate-configuration`) |
| environment | `create-minimal-environments` |
| module | `install-module`, `update-module`, `delete-module`, `test-module`, `validate-module`, `snapshot-vm`, `copy-update-json`, `module-format`, `validate-module-tier-source` |
| backup | `backup-restore`, `backup-status`, `validate-backup`, `lib-cascade` |
| health | `inspect-cluster`, `inspect-vm`, `check-backup-status`, `check-disk-threshold`, `update-os` |

### Findings — managers

1. **The `update` overload.** Component `update.sh` (self-patch) vs a domain
   *modify-an-entity* verb are different things. `module-manager update-module`
   is really **modify/redeploy** — pick one canonical domain verb (`set` or
   `modify`) distinct from component `update`.
2. **CRUD is only real on network (zones).** people does **read** (`list/get`)
   but **create/modify/delete go through config files + `sync`** — a deliberate
   reconcile-from-config model, not a gap to "fix" blindly. Decide per manager:
   *direct CRUD verbs* (network/zones) vs *edit-config-then-sync* (people). This
   is the #6 decision, and it should be made **before** #3 ports them.
3. **`validate` exists everywhere as a script** but is a verb nowhere — the #5
   work. Port it as a TS `validate` subcommand during #3 for free.
4. **`list`/`show` are the biggest real gaps** (site, environment, module): an
   operator cannot enumerate environments or deployed modules from the CLI.
5. **health is read-only** — `add/modify/delete/reconcile` are genuinely N/A;
   align it on `list`(=inspect) + `show`(=inspect one) + a `check`/`status` verb,
   not the write CRUD.

---

## Table 2 — Controllers × the ADR-008 provider contract

The provider contract (network planes): `interrogate → update-desired → delta →
apply → confirm`, wrapped by `reconcile`. Plus inventory CRUD + `list/show`.

| Verb | opnsense | proxmox | switch | ap | backup | identity |
|---|---|---|---|---|---|---|
| **interrogate** (live→actual) | N/A (stateless API) | ✎ folded into `reconcile` | 🟢 | 🟢 | ✗ | N/A |
| **update-desired** | N/A | ✎ folded | 🟢 | 🟢 | ✗ | N/A |
| **delta** (desired−actual) | ✎ `--summary` (dry-run) | ✎ folded | 🟢 | 🟢 | ✗ | N/A |
| **apply** (push) | ✎ `--execute` | 🟢 `reconcile --apply` | 🟢 | 🟢 | 📜 (via backup-manager) | N/A |
| **confirm** (record applied) | N/A | N/A | 🟢 | 🟢 | ✗ | N/A |
| **reconcile** (the cycle) | ✎ `zone-manager --execute` | 🟢 | 🟢 | 🟢 | ✗ (driven by manager) | ✗ |
| **list** | 🟢 (per-CLI) | 🟢 | 🟢 | 🟢 | 🟢 | 🟢 |
| **show / cat** | 🟢 | 🟢 `show`/`cat` | 🟢 | 🟢 | 🟢 `job-status` | 🟢 |
| **add / remove** (inventory) | 🟢 (dns/caddy add-*) | N/A (discovers VMs) | 🟢 `add/remove-controller/switch/port` | 🟢 `add/remove`/`link` | N/A | 🟢 (group/user/app) |

**Controller domain-specific operations:**

| Controller | bin(s) | Operations |
|---|---|---|
| opnsense | `zone-manager`, `caddy-manager`, `dns-manager`, `rules-manager`, `nat`, `acme`, `syslog`, `unbound`, `test-network` | per-CLI add/list/delete + `--summary`/`--execute` |
| proxmox | `proxmox-controller` | `reconcile`, `bridge-vids`, `trunks`, `show`, `node evacuate/return`, `migrate-node`, `migrate-vm`, `resize-disk`, `module`, `nixos` |
| switch | `switch-controller` | full 5-verb + inventory CRUD (`add/remove/update-port`, `list-ports`) |
| ap | `ap-controller` | full 5-verb + inventory CRUD + `link`, `ssid` |
| backup | `backup-controller` | `job-status`, `list`, `namespaces`, `verify` |
| identity | `authentik-manager` | group/user/role/app/provider ensure/set (argparse) |

### Findings — controllers

1. **Only switch + ap implement the full 5-verb provider contract.** They are
   the reference. proxmox **folds** interrogate/delta/apply into a single
   `reconcile` (works, but not introspectable — you cannot `delta` it standalone).
   opnsense uses an older `--summary`/`--execute` style.
2. **opnsense is genuinely different** (stateless REST per resource, no
   actual/desired files) — N/A on interrogate/confirm is correct; align only on
   `apply`(=`--execute`) / `delta`(=`--summary`) **naming**, not structure.
3. **backup + identity controllers are manager-driven**, not standalone
   reconcilers — `reconcile`/5-verb is N/A; they expose query + ensure ops. Keep.
4. **Naming alignment, cheap win:** rename proxmox/opnsense dry-run + apply to the
   `delta`/`apply` vocabulary the planes share, so `network-manager` can talk to
   all four planes in one verb language (it already calls `reconcile [--apply]`
   uniformly via `PlaneClient` — the controllers just spell it differently).

---

## Recommended sequencing for #3 (do NOT port blindly)

1. **Decide the CRUD model per manager first (#6 before #3):** direct verbs vs
   edit-config+sync. Don't port a missing `add` onto people if the model is
   sync-from-config.
2. **Lock the canonical verb vocabulary** (this doc) — esp. resolve the `update`
   overload (`update`=self-patch; `set`/`modify`=entity).
3. **Port in dependency order**, reference = people/network (already TS): start
   with **module-manager** (highest-value `list`/`show` gaps + the `update-module`
   rename) then site → environment → backup; **health last** (read-only, smallest
   surface).
4. **Fold `validate` into each port** as the TS `validate` verb (closes #5 as you go).
5. **Controllers:** align proxmox/opnsense dry-run/apply naming to `delta`/`apply`;
   leave backup/identity as manager-driven query/ensure controllers.
