# ADR-007 — Manager & Controller verb alignment (design for Remaining-outstanding #3)

Design input for the all-managers-to-TypeScript migration (#3) and the verb /
CRUD conventions (#4, #5). Goal: every manager presents the **same verbs for the
same concepts**, every network-plane controller the same provider contract.

## Principle — admins drive verbs, not JSON

An admin manages everything through manager **verbs**; they never need to hand-edit
a JSON config. Hand-editing remains *allowed* but is only valid when followed by a
`reconcile`. So `add`/`modify`/`delete` **write the (validated) config**, and
`reconcile` pushes config → live. The two paths converge on the same files.

## Canonical verb vocabulary (standardized names)

| Verb | Meaning | Notes |
|------|---------|-------|
| `install` / `update` / `test` | component contract | stay `.sh` (build/link the bin); 🟢 for all, omitted from the table |
| `validate` | config is well-formed + internally consistent | health is special — see §Health |
| `list` | enumerate managed entities | |
| `show` | one entity in detail | (was get) |
| `add` | create an entity (writes validated config) | (was create) |
| `modify` | change an entity (writes validated config) | (was set/update-entity) — distinct from component `update` |
| `delete` | remove an entity (writes validated config) | (was remove) |
| `reconcile` | converge config → live | (was sync) |

`diff` / `dry-run` are **NOT verbs** — they are options (see Table 2). Default of
`reconcile` is preview; `--apply` commits.

---

## Table 1 — Managers × verbs (target = full CRUD for all)

Legend: 🟢 exists as verb · ✎`name` exists, wrong name · 📜`file` script exists (port target) · ✗ missing · N/A.
TS today: **people, network**. Script (port targets): **site, environment, module, backup, health**.

| Verb | people | network | site | environment | module | backup | health |
|---|---|---|---|---|---|---|---|
| **validate** | 📜`validate.sh` | 📜`validate.sh` (`zones-check`) | 📜`validate-site.sh` | 📜`validate-environment.sh` | 📜`validate-module.sh` | 📜`validate-backup.sh` | ✗ → **define** (§Health) |
| **list** | 🟢 | 🟢`zone list` | ✗ | ✗ | ✗ | ✎`backup-status.sh` | ✎`inspect-cluster.sh` → `list vm` |
| **show** | ✎`get` | ✗ | ✗ | ✗ | ✗ | ✎`backup-status.sh` | ✎`inspect-vm.sh` → `show vm` |
| **add** | ✗ | 🟢`zone add` | ✎`create-site.sh` | ✎`create-minimal-environments.sh` | ✎`install-module.sh` | ✗ | N/A |
| **modify** | ✗ | ✗ | ✗ | ✗ | ✎`update-module.sh` | ✗ | N/A |
| **delete** | ✗ | 🟢`zone delete` | N/A (singleton) | ✗ | ✎`delete-module.sh` | ✗ | N/A |
| **reconcile** | ✎`sync` | 🟢`reconcile` | ✎`repository.sh` (repos only) | ✗ (→ re-apply dependent modules) | ✗ (per-module today) | ✎`backup-manager.sh` | N/A |

**Entity model per manager** (what the CRUD operates on — the entity is the first arg):

| Manager | CRUD entities (`<manager> <entity> <verb>`) |
|---|---|
| people | `org`, `group`, `role`, `user` |
| network | `zone` (reconcile spans the 4 planes) |
| site | `site` (singleton → show/modify only), `node`, `repository` |
| environment | `environment` |
| module | `module` (the deployed module + its config) |
| backup | `job` / `policy` (the cascade entries) |
| health | **read-only** — `vm`, `cluster`; no add/modify/delete/reconcile |

### Health manager — specifics

- **`list vm`** (was `inspect-cluster.sh`): with no option, lists the basics for
  each running VM; with **`--diff`** it lists drift between **orig / config /
  running** (exactly what `inspect-cluster.sh` does today).
- **`show vm <name>`** (was `inspect-vm.sh`): one VM in detail.
- **`validate` (special meaning):** unlike the config managers (validate = config
  well-formed), **health `validate` asserts the *live* system is healthy** — it
  runs the health gates (`check-disk-threshold`, `check-backup-status`, service
  liveness, …) against the running cluster and exits non-zero if any fail. It is
  the health *assertion*, not a config check. The current `check-*.sh` scripts
  become the checks aggregated under `validate`.
- `update-os` stays a distinct action verb (it patches the OS; not CRUD).

### Findings — managers

1. **Real gaps to build:** `list`/`show` for site/environment/module; `add/modify/
   delete` verbs for people, environment, backup (today: edit-config + reconcile).
2. **Renames (✎):** people `get`→`show`, `sync`→`reconcile`; module `install/
   update/delete-module`→`module add/modify/delete`; backup `backup-status`→
   `list`/`show`, `backup-manager`→`reconcile`; health `inspect-*`→`list/show vm`.
3. **`validate` is a script everywhere, a verb nowhere** — fold into each port (#5).
4. **Two reconcile questions to decide:** does `environment reconcile` mean
   *re-apply modules that consume the env*? does `module reconcile` mean *re-apply
   all deployed modules*? (Both are ✗ today; both are reasonable, both optional.)

---

## Table 2 — Common & special options per manager

Legend: 🟢 supported · ✗ not yet · N/A.

| Option | people | network | site | environment | module | backup | health |
|---|---|---|---|---|---|---|---|
| `--config-dir <dir>` (config root) | 🟢 | 🟢 | 🟢 | 🟢 | 🟢 | 🟢 | 🟢 |
| `--json` (machine output, list/show) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| `--apply` (reconcile: commit; default=preview) | ✗ | 🟢 | N/A | N/A | N/A | ✗ | N/A |
| `--diff` (show drift detail) | ✗ | 🟢`zones-merge --diff` | ✗ | ✗ | ✗ | ✗ | ✎ (the `list vm --diff` above) |
| `--dry-run` (preview a write/reconcile) | ✗ | 🟢 (default) | ✗ | ✗ | ✗ | ✗ | N/A |

**Special options (per manager):**

| Manager | Special options |
|---|---|
| people | — (only the commons) |
| network | `reconcile --only opnsense\|proxmox\|switch\|ap`; `zone add --vlan/--type`; `zones-init --name <N>`; `--strict`, `--no-activate`, `zones-merge --template <tpl>` |
| site | `add --name <N> --domain <d>`; `node add --hostname/--ip`; `repository add --url/--branch` |
| environment | `add --name <env> --domain <d>` |
| module | `add --proxyDomain --proxyTls --environment <env>` + tier flags; `--force` (delete) |
| backup | `--scope module\|env\|site` (cascade); `restore --snapshot <id>`; `--namespace <ns>` |
| health | `list vm --diff` (orig/config/running); `--threshold <pct>`; `update-os --reboot` |

> **Note — `--config-dir` is the one true common option today** (every component
> reads `CONFIG_DIR`). `--json` is proposed (none emit machine output yet) and is
> worth standardizing during #3 so the verbs are scriptable.

---

## Table 3 — Controllers × the ADR-008 provider contract (unchanged from review)

Provider contract (network planes): `interrogate → update-desired → delta → apply
→ confirm`, wrapped by `reconcile`; plus inventory CRUD + `list/show`.

| Verb | opnsense | proxmox | switch | ap | backup | identity |
|---|---|---|---|---|---|---|
| interrogate | N/A (stateless) | ✎ folded in `reconcile` | 🟢 | 🟢 | ✗ | N/A |
| update-desired | N/A | ✎ folded | 🟢 | 🟢 | ✗ | N/A |
| delta | ✎`--summary` | ✎ folded | 🟢 | 🟢 | ✗ | N/A |
| apply | ✎`--execute` | 🟢`reconcile --apply` | 🟢 | 🟢 | 📜 (manager) | N/A |
| confirm | N/A | N/A | 🟢 | 🟢 | ✗ | N/A |
| reconcile | ✎`zone-manager --execute` | 🟢 | 🟢 | 🟢 | ✗ (manager-driven) | ✗ |
| list / show | 🟢 | 🟢 | 🟢 | 🟢 | 🟢 | 🟢 |
| add / remove | 🟢 | N/A (discovers) | 🟢 | 🟢 | N/A | 🟢 |

Only **switch + ap** implement the full 5-verb contract (the reference). proxmox
folds it into `reconcile`; opnsense is legitimately different (stateless REST —
align only the `delta`(`--summary`)/`apply`(`--execute`) naming). backup + identity
are manager-driven query/ensure controllers — `reconcile`/5-verb is N/A.

---

## Domain-specific verbs — reconsidered (most collapse into the standard verbs)

| Manager | Was "special" | Verdict |
|---|---|---|
| people | `sync` | → **`reconcile`** (standard) |
| people | `user-setup.sh` | **stays** — a thin bash wrapper that drives `people-manager user/org add` (operator onboarding convenience), not a manager verb |
| network | `zone add/delete/list` | → standard **CRUD** |
| network | `zones-check` | → **`validate`** |
| network | `zones-distribute` | → part of **`reconcile`** (push zones.json to nodes) |
| network | `zones-init` | **stays special** — install-time template stamp (`--name`); a one-shot bootstrap, not steady-state CRUD |
| network | `zones-merge` | **stays special** — update-time 3-way rebase of the repo template into the live zones.json |
| site | `create-site` | → **`add`** (create the site singleton) |
| site | `repository` | → `repository` **CRUD** + **`reconcile`** |
| site | `convert-json-to-config`, `migrate-configuration-to-site` | **transitional** — retire post-conversion |
| environment | `create-minimal-environments` | → **`add`** with defaults (bootstrap = add the standard envs) |
| module | `install/update/delete-module` | → **`add`/`modify`/`delete`** |
| module | `test-module`, `validate-module` | → **`test`** / **`validate`** |
| module | `snapshot-vm` | **stays special** — a VM operation (pre-update safety), not module CRUD |
| module | `copy-update-json`, `module-format`, `validate-module-tier-source` | internal helpers — fold under `modify`/`validate` or keep private |
| backup | `backup-status` | → **`list`** / **`show`** |
| backup | `backup-manager` | → **`reconcile`** (apply jobs to PBS) |
| backup | `validate-backup` | → **`validate`** |
| backup | `backup-restore` | **stays special** — a recovery action, not CRUD |
| backup | `lib-cascade` | internal lib |
| health | `inspect-cluster` / `inspect-vm` | → **`list vm`** / **`show vm`** |
| health | `check-disk-threshold`, `check-backup-status` | → aggregated under **`validate`** |
| health | `update-os` | **stays special** — an OS-patch action |

**Residual genuinely-special verbs** (everything else collapses to standard CRUD/
reconcile/validate): `network zones-init`, `network zones-merge`, `module
snapshot-vm`, `backup restore`, `health update-os`, and the transitional site
migration tools. Small, well-justified set.

---

## Recommended sequencing for #3

1. **Lock this vocabulary** (verbs standardized above; `--config-dir`/`--json`/
   `--apply`/`--diff` as the common options).
2. **Port in value order**, reference = people/network (already TS): **module**
   (rename install/update/delete → add/modify/delete; add `list`/`show`) →
   **site** → **environment** → **backup** → **health last** (read-only: `list/
   show vm`, `validate`=health gate).
3. **Fold `validate` into each port** (closes #5).
4. **Controllers:** align proxmox/opnsense dry-run/apply naming to `delta`/`apply`;
   leave backup/identity as manager-driven.
