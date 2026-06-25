# TAPPaaS-CICD Scripts

Utility scripts for TAPPaaS-CICD operations. These scripts are installed to `/home/tappaas/bin/` during setup.

## Module-config storage model (#207)

A TAPPaaS module's JSON has two equivalent shapes:

- **Flat** — every field at the top level: `{ "vmname": "x", "cores": 2, ... }`. Older sources used this; deprecated for new modules but still accepted everywhere.
- **Pattern A (canonical)** — module identity / general fields stay at the top; service-owned fields move under `config["<module>:<service>"]` per the field's `usedBy` metadata in [`../../schemas/module-fields.json`](../../schemas/module-fields.json):
  ```json
  {
    "vmname": "x", "dependsOn": ["cluster:vm","network:proxy"],
    "config": {
      "cluster:vm":    { "cores": 2, "memory": "4096" },
      "network:proxy": { "proxyDomain": "x.test", "proxyPort": 80 }
    }
  }
  ```

**On disk**, installed configs in `${CONFIG_DIR}` are written in canonical Pattern A by `copy-update-json.sh` (install) and `apply-json-merge.sh` (update). The repo's source JSONs in `src/foundation/*/*.json` and `src/apps/*/*.json` are also Pattern A; the [`convert-json-to-config.sh`](#convert-json-to-configsh) tool can migrate any straggling flat module.

**In scripts**, all reads go through `read_module_config <m>` (or `get_config_value <field>` when `$JSON` is auto-loaded). Both helpers normalize Pattern A → flat on the fly, so script code keeps reading top-level fields like `.cores` regardless of how the file is stored. Writes go through `jq_module_write <m> <jq-filter>` which re-renders canonical Pattern A on the way out. The [`audit-jq-readers.sh`](#audit-jq-readerssh) tool greps for any direct `jq … "${MODULE_JSON}"` reads that bypass this funnel — it must report **0** on the foundation tree.

The merge-on-update flow (3-way merge of `current`, `.orig`, and the new release `source`) is described under [`apply-json-merge.sh`](#apply-json-mergesh).

## Zone configuration (#209)

The global `${CONFIG_DIR}/zones.json` follows the same drift-detection / merge model. The upstream template at [`../../firewall/zones.json`](../../firewall/zones.json) is seeded once on first install by [`install.sh`](../install.sh); thereafter [`apply-zones-merge.sh`](#apply-zones-mergesh) — invoked from [`pre-update.sh`](../pre-update.sh) on every `update-tappaas` cycle — does the 3-way reconciliation against `zones.json.orig`. Only `state` is operator-pinned (operators flip it via [`zone-state.sh`](#zone-statesh)); everything else follows the standard pin-vs-adopt rule.

## Scripts

### common-install-routines.sh

Shared library of functions and utilities for module installation scripts.

**Usage:** Source this file in install scripts:
```bash
. /home/tappaas/bin/common-install-routines.sh <vmname>
```

**Features:**
- Color definitions for terminal output (YW, BL, RD, GN, etc.)
- `info()` / `warn()` / `error()` / `debug()` / `die()` — Logging functions
- `get_config_value()` — Extract values from module JSON configuration (reads `$JSON`, which is auto-loaded in normalized flat form regardless of the on-disk shape — see #207)
- `normalize_module_config()` — Flatten a Pattern A `config` block to top-level fields. Stdin → stdout. Used internally by the readers.
- `read_module_config <module>` — Read a module's installed config and emit it in normalized flat form on stdout. Use this in place of `jq … "${CONFIG_DIR}/<m>.json"` so the on-disk shape can evolve without breaking readers (#207).
- `jq_module_write <module> <jq-filter> [jq-args…]` — Apply a jq filter to a module's installed config and write the result back atomically in canonical Pattern A form. Use in place of `jq … > tmp; mv tmp ${MODULE_JSON}` (#207).
- `check_json()` — Validate a module JSON file against module-fields.json schema
- Node lookup helpers (read from `configuration.json`):
  - `get_primary_node_fqdn()` — FQDN of the first node (e.g., `tappaas1.mgmt.internal`)
  - `get_node_hostname [index]` — Actual system hostname of the Nth node
  - `get_node_dns_hostname [index]` — DNS hostname (falls back to system hostname)
  - `get_all_node_hostnames` — All node hostnames, one per line
  - `get_node_fqdn [index]` — Full FQDN of the Nth node
- Loads JSON configuration from `/home/tappaas/config/<vmname>.json`

**Example:**
```bash
. common-install-routines.sh mymodule
vmid=$(get_config_value "vmid")
cores=$(get_config_value "cores" "2")  # with default value
check_json /home/tappaas/config/mymodule.json || exit 1

# Node lookup (no module JSON needed)
primary=$(get_primary_node_fqdn)       # tappaas1.mgmt.internal
first_host=$(get_node_hostname 0)      # tappaas1
all_nodes=$(get_all_node_hostnames)    # tappaas1\ntappaas2\ntappaas3
```

---

### copy-update-json.sh

Copies a module JSON file to the config directory and optionally updates fields. Supports creating module variants with `--variant`.

**Usage:**
```bash
copy-update-json.sh <module-name> [--variant <name>] [--<field> <value>]...
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module | `identity` |
| `--variant <name>` | Create a variant (output: `<module>-<name>.json`) | `--variant staging` |
| `--<field> <value>` | Set JSON field to value (repeatable) | `--node "tappaas2"` |

**Example:**
```bash
# Copy identity.json with default values
copy-update-json.sh identity

# Copy and modify fields
copy-update-json.sh identity --node "tappaas2" --cores 4
copy-update-json.sh nextcloud --memory 4096 --zone0 "trusted"

# Create a variant of openwebui (auto-derives vmname, vmid, zone0, proxyDomain)
copy-update-json.sh openwebui --variant staging

# Create a variant with explicit overrides
copy-update-json.sh openwebui --variant dev --zone0 srv-dev --vmid 315
```

**What it does:**
1. Copies `./<module>.json` from current directory to `/home/tappaas/config/` (or `<module>-<variant>.json` in variant mode)
2. Automatically sets the `location` field to the module directory
3. Validates field names against `module-fields.json` schema
4. In variant mode, applies automatic field derivation (see below)
5. Applies `--<field> <value>` modifications to the copied JSON
6. Creates a `.orig` backup if modifications are made
7. Validates the resulting JSON is valid

**Variant mode (`--variant <name>`):**

When `--variant` is used, the following fields are derived automatically unless explicitly overridden with `--<field>`:

| Field | Derivation | Example (variant=staging) |
|-------|-----------|--------------------------|
| `vmname` | `<source vmname>-<variant>` | `openwebui-staging` |
| `vmid` | Next available VMID after source | `312` (if 311 is source) |
| `zone0` | `<variant>` if it matches a zone in `zones.json`, else unchanged | `srv` (unchanged) |
| `proxyDomain` | Insert `<variant>` after first segment | `openwebui.staging.test.tapaas.org` |

**Notes:**
- Integer fields (per schema) are stored as JSON numbers
- String fields are stored as JSON strings
- Unknown field names will cause an error
- In variant mode, `EFFECTIVE_MODULE` is exported for scripts that source this file
- The installed `.json` is written in canonical Pattern A form on disk (#207): module identity / general header fields stay at the top, service-owned fields move under `config["<module>:<service>"]`. Downstream tooling reads through `read_module_config` / `get_config_value` which normalize to flat on the fly, so callers see a flat view regardless of on-disk shape.
- The `--<field>` CLI overrides are applied to the flat internal form and then re-rendered in canonical Pattern A as the very last step, so an override like `--cores 16` lands under `config["cluster:vm"].cores`, not at the top. The override log line tells you exactly where each field will land in the canonical shape (#264):
  ```
    Set cores = 16 → config["cluster:vm"].cores
    Set proxyDomain = test.example.com → config["network:proxy"].proxyDomain
    Set vmid = 12345 → top-level
    Set HANode = tappaas2 → top-level (orphan)
  ```
  `top-level (orphan)` means the field's `usedBy` lists a dep the module hasn't declared, so it stays at top until the operator either adds the dep or removes the field.
- Override behavior is covered end-to-end by [`scripts/test/test-install-overrides.sh`](test/test-install-overrides.sh) (43 cases — flat + Pattern A + variant + multi-dep tiebreak; #264). Run it alongside the other tabletop suites.

---

### convert-json-to-config.sh

Converts a flat module JSON into the canonical Pattern A form (config block grouping per `dependsOn` coordinate). Used both as a one-shot migration tool for source files in the repo and as a sourceable library called by `apply-json-merge.sh` and `copy-update-json.sh` to render the canonical on-disk shape (#207).

**Usage (CLI):**
```bash
convert-json-to-config.sh <module-json>            # to stdout
convert-json-to-config.sh --in-place <module-json> # overwrite
convert-json-to-config.sh --dry-run <module-json>  # show diff
```

**Usage (sourceable):**
```bash
. /home/tappaas/bin/convert-json-to-config.sh
regroup_to_pattern_a < flat.json > patternA.json
```

**Grouping rules** (per `usedBy` metadata in `module-fields.json`):
1. Header-pinned fields (`vmname`, `vmid`, `vmtag`, `node`, `zone*`, `mac*`, `dependsOn`, `provides`, `config`, `variant`) — stay at top.
2. `usedBy == ["general"]` (e.g. `description`, `version`, `releaseDate`, `installTime`, …) — stay at top.
3. Field not present in the schema — stay at top, warning emitted.
4. `usedBy ∩ dependsOn == ∅` (orphan — module has a field for a dep it doesn't declare) — stay at top, warning emitted.
5. `usedBy ∩ dependsOn` has ≥1 match — move under `config["<first-match-in-dependsOn-order>"]`. Documented multi-match tiebreak: **first dep in `dependsOn` order wins**.

Output is reordered per `.fieldOrder` in `module-fields.json`, both at the top level and within each `config["<coord>"]` block. The conversion is idempotent (re-running on Pattern A input is a no-op) and lossless (`normalize_module_config(regroup_to_pattern_a(X)) == normalize_module_config(X)`).

---

### apply-json-merge.sh

3-way reconciliation of a module's installed config against a new release source (#207). Called automatically as **Step 0** of `update-module.sh`, before the snapshot and any hooks, so the snapshot and all subsequent steps see the merged config.

**Usage:**
```bash
apply-json-merge.sh <effective-module>
```

**Sourceable:**
```bash
. /home/tappaas/bin/apply-json-merge.sh
apply_three_way_merge <effective-module> <module-dir>
```

**Inputs:**
- `current = ${CONFIG_DIR}/<eff>.json` — live config; may have operator edits.
- `orig = ${CONFIG_DIR}/<eff>.json.orig` — snapshot of the source at last install / upgrade.
- `source = <module_dir>/<base>.json` — new release source.

**Per-leaf rule:**
1. If the path's top-level key is in **AUTO_FIELDS** (`location`, `installTime`, `updateTime`, `releaseDate`, `variant`) → keep `current`.
2. Else if path absent in `source`, present in `current` → keep `current` (operator-added).
3. Else if path absent in `current` → adopt `source` (new release field).
4. Else if `current == orig` → adopt `source` (operator untouched → follow release).
5. Else → keep `current` (operator-pinned).

**Notes:**
- All three inputs are normalized to flat form before per-leaf comparison, so the merge is invariant under refactors that move fields between the top level and the `config` block. Output is rendered in canonical Pattern A via `regroup_to_pattern_a`.
- Arrays are compared whole — if the operator touched the array at all, the whole array is pinned. (Documented limitation; revisit when a real module needs path-level array merge.)
- The `variant` field (persisted by `copy-update-json.sh` when `--variant` is used) tells the merge which source file to read; falls back to a filename heuristic for pre-#207 installs.
- If `.orig` does not exist (pre-#207 install), it is backfilled as `cp source → orig` so existing operator customizations remain pinned. The alternative (`cp current → orig`) would silently drop all customizations on the first update post-#207.
- After a successful merge, `.orig` is advanced to the new `source`.

---

### audit-jq-readers.sh

Greps the foundation + apps tree for direct `jq … "${CONFIG_DIR}/<m>.json"` (or `${MODULE_JSON}` etc.) reads on installed module configs (#207). Such reads bypass normalization and return `null` for any field that has moved under a `config` block, so they are a regression hazard.

**Usage:**
```bash
audit-jq-readers.sh             # report all direct readers
audit-jq-readers.sh --quiet     # print count only
audit-jq-readers.sh --strict    # exit non-zero if any are found (for CI)
```

A clean audit (count = 0) means every reader goes through `read_module_config` / `get_config_value` and is therefore agnostic to the on-disk shape.

---

### zone-state.sh

Atomic state-change helper for [`zones.json`](../../firewall/zones.json) (#209). Replaces the manual `jq '.<zone>.state = "…"' zones.json > tmp && mv …` ritual with one command that validates the zone exists, refuses bogus transitions, and prints the next-step `zone-manager --execute` command. Does **not** push to OPNsense itself — the operator runs zone-manager when ready.

**Usage:**
```bash
zone-state.sh enable  <zone-name>
zone-state.sh disable <zone-name>
zone-state.sh manual  <zone-name>
zone-state.sh enable dmz --force    # Mandatory zones refused otherwise
```

**Verb → state mapping:**

| Verb | `state` written | zone-manager behavior |
|------|-----------------|------------------------|
| `enable` | `Active` | creates VLAN + DHCP + rules |
| `disable` | `Inactive` | defined but not deployed |
| `manual` | `Manual` | operator-managed, zone-manager leaves alone |

**Behavior:**

- Refuses an unknown zone name (lists known zones for convenience).
- No-op (exit 0) when the zone is already in the requested state.
- Refuses to leave `Mandatory` (e.g., `dmz`) without `--force`.
- Writes atomically via `jq` + `mv`; the file is left unchanged if the new JSON would be invalid.
- The `Mandatory` and `Disabled` states are intentionally not exposed as verbs — `Mandatory` is for platform-required zones (security model), `Disabled` is reserved for the zone-manager removal flow. Use `--force` if you really need to leave Mandatory.

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | state changed (or already in target state) |
| `1` | zone not found / file IO failure / Mandatory without `--force` |
| `2` | bad arguments / unknown verb |

---

### apply-zones-merge.sh

3-way merge for `${CONFIG_DIR}/zones.json` against the upstream source at `src/foundation/firewall/zones.json` (#209). The same machinery as [`apply-json-merge.sh`](#apply-json-mergesh), tailored to the single global zones file:

- Per-leaf merge within each shared zone:
  - **AUTO_FIELDS** (`["state"]`) — operator-pinned, never adopted from source. `zone-state.sh` is the only path that should change `state`.
  - Otherwise: `current == orig` → adopt source; else → pin current.
- Zone-level rules:
  - Zone in source, absent in current → **add** with release defaults.
  - Zone in current, absent in source → **keep** + warning (operator-added, or release-removed but operator still wants it).
  - Same `vlantag` in both but different zone names → **flag as possible rename**; do not auto-rename.
- If `zones.json.orig` is missing on first run, `cp source → orig` (same backfill decision as #207 — preserves operator customizations on the first post-#209 cycle).

The merge runs **automatically as part of every `update-tappaas` cycle**, wired into [`pre-update.sh`](../pre-update.sh). The standalone CLI is for ad-hoc preview / drift checks.

**Usage:**
```bash
apply-zones-merge.sh           # run merge; write current + advance .orig
apply-zones-merge.sh --diff    # show what would change; do not write
```

**Report (sample):**
```
Merge: 7 adopted, 30 pinned, 1 added, 0 kept (orphan), 0 possible rename(s)
  added (new in release): srv-cust
  pinned (operator customizations preserved):
    home: access-to, description
    mgmt: access-to
  adopted (release changes applied):
    home: _comment
  possible rename(s) — same vlantag, different zone name:
    vlantag=830: source=lab vs current=test3
```

**Override the source location** for testing via `TAPPAAS_ZONES_SOURCE=/path/to/zones.json`. By default it reads the upstream `firewall/zones.json` from the TAPPaaS repo path declared in `configuration.json` (or `/home/tappaas/TAPPaaS` as fallback).

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | success (zero or more changes applied) |
| `1` | source missing / IO failure |
| `2` | bad arguments |

After a merge that actually changed anything, push to OPNsense:
```bash
zone-manager --no-ssl-verify --zones-file /home/tappaas/config/zones.json --execute
```

---

### zone-controller.sh

The single **zone lifecycle primitive** — one command that creates or deletes a network zone end to end, across all three planes. Where [`zone-state.sh`](#zone-statesh) only flips a zone's `state` and [`zone-manager`](../opnsense-controller/README.md) only reconciles `zones.json` into OPNsense, **`zone-controller` owns the whole sequence** so no caller can forget a step (the root cause of the `#335`-family bridge-vids gap and the `#372`/`#373` mgmt-invariant drift). Operators and test harnesses call it directly to create/delete an environment's dedicated zone. Full design: [`docs/design/zone-controller.md`](../../../../docs/design/zone-controller.md).

It does **not** reimplement OPNsense/Proxmox logic — it authors `zones.json` and orchestrates the existing reconcilers:

```
add    : author zones.json (VLAN alloc + inheritance) → append zone to mgmt.access-to
         → zone-manager --execute (OPNsense VLAN/DHCP/rules) → distribute zones.json
         → proxmox-manager reconcile --apply (firewall-VM trunk)
         → proxmox-manager bridge-vids --apply (every node's lan bridge)   ← closes the gap
delete : remove from mgmt.access-to → set Disabled → zone-manager --execute (drops the iface)
         → proxmox-manager reconcile/bridge-vids --apply (drop trunk + VID, guarded)
         → delete the key → distribute
```

**Usage:**
```bash
zone-controller add <name> [--from-zone <src>] [--vlan <tag>] [--variant <name>] \
                           [--no-bridge-apply] [--no-activate] [--check]
zone-controller delete <name> [--force] [--keep-bridge-vid] [--check]
# examples
zone-controller add tenant1 --from-zone srvCust --variant tenant1
zone-controller delete tenant1
```

`add` allocates a free VLAN (sub-id 60–99 in the type band, or `--vlan`), derives `10.<typeId>.<sub>.0/24`, and inherits `type`/`bridge`/`access-to`/`pinhole-allowed-from` from `--from-zone` (else a Service template). It echoes the created zone name. `--check` is a dry-run; `--no-activate` authors `zones.json` (+ mgmt) only.

**bridge-vids safety:** adding a VID only *widens* a node bridge's allow-list (non-disruptive), so `add` applies it automatically — this is what lets a module VM on a node **other than the firewall's** get a DHCP IP. Removing a VID is the sensitive direction, so `delete` guards it: if any VM still runs on that VLAN, the VID is kept (`--keep-bridge-vid` forces this; `--force` proceeds past the VM-present check). All `zones.json` edits are atomic (`jq` → validate → `mv`), and every downstream tool is idempotent, so a partially-failed `add` is fixed by re-running it.

> **Note — mgmt invariant:** `zone-controller` maintains the explicit `mgmt.access-to` list (append on add, remove on delete) per `zones.json._README.isolation_invariant`. A self-maintaining `"all"` sentinel is a deferred enhancement — see [`docs/design/issue-mgmt-all-sentinel.md`](../../../../docs/design/issue-mgmt-all-sentinel.md).

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | zone created / deleted (downstream reconcile warnings are non-fatal) |
| `1` | bad zone name, zone exists (add) / not found (delete), or VMs still present without `--force` |

**Deep test:** [`../test-variants/test-variant-zone-node.sh --deep`](../test-variants/test-variant-zone-node.sh) creates a variant zone, asserts the new VLAN reaches **every** node's bridge, places a `tvbase` VM on a non-firewall node (default `tappaas3`), and verifies it gets an IP and is reachable — the end-to-end regression for the bridge-vids gap.

---

### test/ — tabletop tests for the storage-model tooling

Runnable test scripts under [`test/`](test/) exercise the #207 + #209 + #237 + #264 plumbing without touching any VM or live config. Each writes its fixtures into a temp dir and tears down on exit. Run them individually or in sequence:

```bash
scripts/test/test-convert-to-config.sh      #  9 cases — converter rules + idempotency + round-trip
scripts/test/test-json-merge.sh             # 11 cases — module 3-way merge: pin/adopt/orphan/auto + Pattern A inputs
scripts/test/test-read-module-config.sh     #  4 cases — read funnel + jq_module_write Pattern A render
scripts/test/test-zones-merge.sh            # 11 cases — zones 3-way merge: pin state, adopt vlantag, rename detection, backfill
scripts/test/test-zone-state.sh             #  9 cases — verbs, no-op, Mandatory refusal, --force, missing zone, invalid verb
scripts/test/test-zone-name-validation.sh   #  6 cases — module-fields regex rejects hyphens in zone names (#237)
scripts/test/test-migrate-zone-keys.sh      # 11 cases — zone-key migration: zones+modules rewrite, marker, backup, idempotency
scripts/test/test-install-overrides.sh      # 43 cases — install-time --<field> overrides (flat + Pattern A + variant + multi-dep; #264)
```

Each script exits with the failure count (0 on success). They have no network or filesystem dependencies beyond `jq` and the schema file (`module-fields.json`), so they're suitable for CI.

---

### create-configuration.sh

Creates or updates the `configuration.json` file for the TAPPaaS system by querying the running cluster. Supports two argument styles: positional (backwards compatible) and named arguments with defaults.

**Usage:**
```bash
# Named arguments (all optional — defaults are discovered from the Proxmox node)
create-configuration.sh [--upstream-git URL] [--branch NAME] [--domain DOMAIN]
                        [--email EMAIL] [--schedule FREQ] [--weekday DAY] [--hour H]
                        [--primary-node FQDN] [--update]

# Positional arguments (backwards compatible)
create-configuration.sh <upstreamGit> <branch> <domain> <email> <schedule> [weekday] [hour]
```

**Named Arguments:**

| Argument | Description | Default |
|----------|-------------|---------|
| `--upstream-git` | Git repository URL | `github.com/TAPPaaS/TAPPaaS` |
| `--branch` | Git branch to track | `stable` |
| `--domain` | Primary domain for TAPPaaS | From Proxmox node FQDN, or existing config |
| `--email` | Admin email for SSL and notifications | From Proxmox `root@pam` user, or existing config |
| `--schedule` | Update frequency: `monthly`, `weekly`, `daily`, `none` | `weekly` |
| `--weekday` | Day of week for updates | `Tuesday` |
| `--hour` | Hour of day 0-23 | `2` |
| `--primary-node` | Primary node FQDN for cluster discovery | Auto-detect from config or `tappaas1.mgmt.internal` |
| `--update` | Update mode: preserve existing config, overlay provided args | *(flag)* |

**Default Discovery:**

When `--domain` or `--email` are not explicitly provided, the script SSHs to the primary Proxmox node and discovers:
- **Domain**: from the node's FQDN (`hostname --fqdn`), extracting the domain part (e.g., `node1.mydomain.com` → `mydomain.com`)
- **Email**: from `/etc/pve/user.cfg`, reading the `root@pam` user's email address

If the node is unreachable, falls back to `CHANGE-mytappaas.dev` / `CHANGE-tappaas@mytappaas.dev` (which must be updated before deployment).

**Examples:**
```bash
# Create with all defaults (discovers domain/email from Proxmox node)
create-configuration.sh

# Create with specific domain and email
create-configuration.sh --domain mytappaas.dev --email admin@mytappaas.dev

# Update existing config — only change the domain
create-configuration.sh --update --domain newdomain.com

# Update mode — re-discover nodes and validate
create-configuration.sh --update

# Legacy positional syntax
create-configuration.sh github.com/TAPPaaS/TAPPaaS main my.dev admin@my.dev weekly
```

**What it does:**
1. Discovers domain and email from the primary Proxmox node's installer settings
2. Queries Proxmox cluster for all nodes via `pvecm` or `pvesh`
3. Gets IP addresses for each node via DNS or SSH
4. Creates or updates `/home/tappaas/config/configuration.json`
5. In update mode: preserves existing values, repositories, and `dns-hostname` mappings
6. Runs `validate-configuration.sh` on the result

**Generated configuration includes:**
- `tappaas` section: `version`, `domain`, `email`, `nodeCount`, `repositories[]`, `updateSchedule`
- `tappaas-nodes` array: `hostname`, `dns-hostname` (optional), and `ip` for each node

---

### validate-configuration.sh

Validates `/home/tappaas/config/configuration.json` for correctness and consistency.

**Usage:**
```bash
validate-configuration.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--config <path>` | Path to configuration.json (default: `/home/tappaas/config/configuration.json`) |
| `--check-connectivity` | Ping each node IP to verify reachability |
| `--check-cluster` | SSH to first node, verify cluster nodes match configuration |
| `--check-repos` | Verify repository URLs are accessible via `git ls-remote` |
| `--quiet` | Only output errors, suppress info messages |

**Checks performed (always):**
- File exists and is valid JSON
- `domain` and `email` not starting with `CHANGE` (placeholder values)
- Email format validation
- `nodeCount` matches length of `tappaas-nodes` array
- No duplicate IPs or hostnames in `tappaas-nodes`
- Valid `updateSchedule` values (frequency, weekday, hour)
- All required fields present (`version`, `domain`, `email`, `nodeCount`, `repositories`, `tappaas-nodes`)
- `dns-hostname` fields are non-empty if set
- IP addresses are valid IPv4 format

**Examples:**
```bash
# Basic validation
validate-configuration.sh

# Full validation with connectivity and cluster checks
validate-configuration.sh --check-connectivity --check-cluster --check-repos

# Validate a specific file quietly
validate-configuration.sh --config /tmp/test-config.json --quiet
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | All checks passed (may have warnings) |
| `1` | One or more validation errors found |

**Integration:** This script is called automatically by:
- `create-configuration.sh` (after generating config)
- `cluster/update.sh` (Step 0, warn-only)
- `tappaas-cicd/test.sh` (Test 3: Configuration files)

---

### update-os.sh

Updates a VM's operating system based on its type (NixOS or Debian/Ubuntu).

**Usage:**
```bash
update-os.sh <vmname> <vmid> <node>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM | `nextcloud` |
| `vmid` | Proxmox VM ID | `610` |
| `node` | Proxmox node name | `tappaas1` |

**Example:**
```bash
update-os.sh myvm 610 tappaas1
```

**What it does:**
1. Waits for VM to get an IP address (via guest agent or DHCP leases)
2. Updates SSH known_hosts
3. Detects OS type (NixOS or Debian/Ubuntu)
4. For **NixOS**:
   - Runs `nixos-rebuild` using `./<vmname>.nix` in current directory
   - Reboots VM to apply configuration
   - Waits for VM to come back up
5. For **Debian/Ubuntu**:
   - Waits for cloud-init to complete
   - Runs `apt-get update && apt-get upgrade`
   - Installs QEMU guest agent
6. Fixes DHCP hostname registration via NetworkManager

**Requirements:**
- For NixOS VMs: `./<vmname>.nix` must exist in current directory
- SSH access to VM as tappaas user
- QEMU guest agent installed on VM

---

### update-tappaas scheduling (no script — systemd timer)

cron was retired in issue #150. The update scheduler is now driven by a
**systemd timer** declared in `tappaas-cicd.nix`
(`systemd.timers.update-tappaas`, `OnCalendar=hourly`, `Persistent=true`).
There is no `update-cron.sh` anymore.

**Inspect:**
```bash
systemctl status update-tappaas.timer
systemctl list-timers update-tappaas.timer
journalctl -u update-tappaas.service
```

**Why hourly?** The timer fires every hour; `update-tappaas` only performs
updates when the current hour matches the global `updateSchedule`, so an
hourly tick guarantees the scheduled hour is hit. Output → journald →
Promtail → Loki.

---

### check-disk-threshold.sh

Checks if a VM's disk usage exceeds a threshold and automatically expands the disk by 50% if needed.

**Usage:**
```bash
check-disk-threshold.sh <vmname> <threshold>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM (must have a JSON config) | `nextcloud` |
| `threshold` | Disk usage percentage threshold (1-99) | `80` |

**Example:**
```bash
# Check if nextcloud disk usage exceeds 80%
check-disk-threshold.sh nextcloud 80
```

**What it does:**

1. Connects to the VM via SSH and checks current disk usage with `df`
2. If usage is below threshold, exits with no action
3. If usage exceeds threshold:
   - Retrieves current disk size from Proxmox
   - Calculates new size (50% increase, minimum 5GB)
   - Calls `resize-disk.sh` to perform the resize
   - Logs the resize event to `/home/tappaas/logs/disk-resize.log`

**Cron usage:**
```bash
# Check disk usage every hour
0 * * * * /home/tappaas/bin/check-disk-threshold.sh nextcloud 80
```

**Requirements:**

- SSH access to the VM as tappaas user
- SSH access to the Proxmox node as root
- VM must be running and reachable

---

### resize-disk.sh

Resizes the disk of a VM both in Proxmox and inside the VM filesystem.

**Usage:**
```bash
resize-disk.sh <vmname> <new-size>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `vmname` | Name of the VM (must have a JSON config) | `nextcloud` |
| `new-size` | New disk size (G, M, T, K suffix) | `50G` |

**Example:**
```bash
# Resize nextcloud disk to 50GB
resize-disk.sh nextcloud 50G
```

**What it does:**

1. Validates that the new size is larger than the current size (shrinking not supported)
2. Resizes the disk in Proxmox using `qm resize`
3. Connects to the VM via SSH and resizes the partition and filesystem:
   - **NixOS**: Uses `sfdisk` to grow the partition, then `resize2fs` for ext4
   - **Debian/Ubuntu**: Uses `growpart` to grow the partition, then `resize2fs` for ext4
4. Verifies the new filesystem size
5. Updates the `diskSize` field in the VM's JSON configuration (via `jq_module_write`, so the canonical Pattern A on-disk shape is preserved; `diskSize` lands under `config["cluster:vm"]`)

**Supported configurations:**

| OS | Filesystem | Status |
|----|------------|--------|
| NixOS | ext4 | Fully supported |
| Debian/Ubuntu | ext4 | Fully supported |
| Other | Any | Proxmox disk resized, manual filesystem resize required |

**Requirements:**

- SSH access to the VM as tappaas user with sudo
- SSH access to the Proxmox node as root
- VM must be running and reachable

---

### setup-caddy.sh

Installs and configures the Caddy reverse proxy stack on the OPNsense firewall.
Called automatically by `install.sh` during initial cicd install; safe to
re-run (every step is idempotent).

**Usage:**
```bash
setup-caddy.sh
```

**What it does:**
1. Installs the **os-caddy** package on the firewall
2. Installs **os-acme-client** and **os-ddclient** (issue #254) — needed for
   wildcard TLS via any of acme.sh's 120 DNS providers (os-caddy ≥ 2.0.0 only
   ships the Cloudflare provider, so this is how non-Cloudflare operators —
   and anyone who wants a single wildcard for internal services — actually get
   a public cert) and for dynamic-WAN DNS updates
3. Moves the OPNsense web GUI from port 443 to **8443** (frees 443 for Caddy)
4. Creates firewall rules for HTTP (port 80) and HTTPS (port 443) on the WAN
5. Enables Caddy and sets the global ACME email from `configuration.json`

**What it does NOT do:** issue a TLS certificate. After `setup-caddy.sh`
completes, the operator runs `acme-setup.sh` (next section) to obtain the
wildcard certificate — that step needs a DNS-API token which can't be
provisioned automatically. Until then, services are reachable on the LAN but
their public HTTPS endpoint has no certificate.

---

### acme-setup.sh

Operator-driven, idempotent setup of the TAPPaaS wildcard TLS certificate via
**os-acme-client** (issue #254). Run once at INSTALL.md §2.3, after the
install chain has finished but before `rest-of-foundation.sh`.

**Usage:**
```bash
acme-setup.sh                       # interactive; uses Let's Encrypt PROD
acme-setup.sh --staging             # use Let's Encrypt staging CA (no rate limits, untrusted certs)
acme-setup.sh --provider hetzner    # pick a different DNS provider
acme-setup.sh --no-save-creds       # don't offer to save creds to ~/.acme-dns-credentials.txt
```

**What it does (idempotent — re-run any time):**
1. Reads `tappaas.domain` and `tappaas.email` from `configuration.json`
2. Sources DNS-API credentials from `~/.acme-dns-credentials.txt` (mode 600) if
   present, otherwise prompts interactively (Cloudflare token by default; for
   other providers it asks you to seed the file with the right
   `dns_<provider>_<field>=<value>` keys — see the os-acme-client GUI for the
   field names)
3. Calls `acme-manager setup` to provision, on the firewall:
   - ACME account (Let's Encrypt — prod by default, staging with `--staging`)
   - DNS-01 validation with the chosen provider
   - `caddy-reload` automation (type `configd_reload_caddy`) that fires on
     every renewal so Caddy serves the new cert without manual intervention
   - Wildcard certificate `*.<domain>` (+ bare apex)
   - Triggers issuance and waits (~10–30 s)
4. Writes the issued certificate's OPNsense Trust **refid** back into
   `configuration.json` as `tappaas.tlsCertRefid`. Every subsequent
   `proxyTls: dns01` module install reads this refid and binds the wildcard
   via Caddy's per-domain `CustomCertificate` — no per-module ACME, no
   DNS-API call at module install time, one cert serves every dns01 module.

**DNS provider support:** any of the **120** providers os-acme-client ships
(Cloudflare, deSEC, Hetzner, OVH, Route 53, Namecheap, GoDaddy, PowerDNS,
Njalla, INWX, Gandi, HE, AWS, …). The script knows 14 friendly aliases; for
anything else, pass the raw `dns_<provider>` key as `--provider` and use the
matching field names from the os-acme-client GUI.

**Cloudflare credentials file template** (chmod 600):
```ini
provider=cloudflare
dns_cf_token=YOUR-CLOUDFLARE-API-TOKEN
# dns_cf_account_id=...     # optional
```

Token scope: create a custom token at
<https://dash.cloudflare.com/profile/api-tokens> with permissions
`Zone → Zone → Read` and `Zone → DNS → Edit` for your domain.

**Switching staging → prod:** run with `--staging` first to validate the
plumbing without burning the prod LE rate limit, then re-run without
`--staging`. The script swaps the cert in place; the `caddy-reload`
automation makes Caddy pick up the new cert within ~10 s, no operator action.

**Renewal:** acme.sh handles it. The `caddy-reload` automation registered by
this script ensures Caddy starts serving the renewed cert automatically — no
manual reload needed.

---

### roles-ensure.sh

Reconciles the Authentik **role groups** for the current environment set (ADR-006, #56).
Idempotent — safe to re-run. Called automatically by `identity/update.sh`; run by
hand to repair drift.

**Usage:**
```bash
roles-ensure.sh                 # installers + default scope + every registered variant
roles-ensure.sh --variant acme  # just the acme scope
```

**Guarantees these groups exist:**
- `tappaas-installers` — global superuser (platform root); never per-variant
- default scope: parent group `tappaas` → `tappaas-admins`, `tappaas-users`
- per registered variant `<v>`: parent `<v>` → `<v>-admins`, `<v>-users`

Each group carries `attributes.tappaas = {variant, role}`. Per-module admin groups
(`<scope>-<module>-admins`) are opt-in and created at module install / by `user.sh`,
not here. Talks to Authentik via `authentik-manager` (override with
`AUTHENTIK_MANAGER=` for testing).

---

### user.sh

Manage a person's **single Authentik login** and their **roles** (ADR-006, #56).
One person = one user; roles are group memberships, scoped to a variant (except
`installer`, which is global). See also `src/foundation/identity/USERS.md`.

**Usage:**
```bash
user.sh add    <username> --email <addr> [--name N] [--variant v] [--role R ...] [--no-credential]
user.sh modify <username> [--variant v] [--add-role R ...] [--remove-role R ...] [--email E] [--name N] [--credential]
user.sh delete <username> [--yes]
user.sh show   <username>
user.sh list   [--variant v]
```

**Roles** (`--role` / `--add-role` / `--remove-role`): `installer`, `admin`, `user`,
`module-admin:<module>`. They resolve to scope groups (`installer`→`tappaas-installers`;
`admin`/`user`→`<scope>-admins`/`-users`; `module-admin:nextcloud`→`<scope>-nextcloud-admins`,
created on demand). `<scope>` is `tappaas` by default or the `--variant` name.

**Examples:**
```bash
user.sh add lars --email lars@example.org --role admin
user.sh add jane --email jane@acme.org --variant acme --role module-admin:nextcloud
user.sh modify jane --variant acme --remove-role user --add-role admin
user.sh show lars
user.sh delete lars
```

**Idempotent + additive:** `add` re-runs add roles, never remove. **Credential**
(`add`, or `modify --credential`): a one-time enrollment link when the brand has a
recovery flow (emailed once SMTP is configured — deferred to the SMTP issue), else a
generated password is set and printed.

---

### install-module.sh

Installs a TAPPaaS module with dependency validation and service wiring. Supports installing module variants with `--variant`.

**Usage:**
```bash
install-module.sh <module-name> [--variant <name>] [--force | --reinstall] [--<field> <value>]...
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to install | `openwebui` |
| `--variant <name>` | Install a variant of the module | `--variant staging` |
| `--force` | Install even if the module already exists — re-runs the installer against the **existing** deployment (idempotent service installers reconcile drift). Removes nothing. | |
| `--reinstall` | Delete the existing deployment first (`delete-module.sh --force`), then install fresh. Use to recover from a partial/broken install (issue #301). | |
| `--<field> <value>` | Override a JSON field (passed to `copy-update-json.sh`) | `--node tappaas2` |

> `--force` and `--reinstall` differ deliberately: `--force` keeps the current VM and just re-runs the installers over it (skip the already-installed check); `--reinstall` tears the deployment down and rebuilds it from scratch.

**What it does:**
1. Checks the module is not already installed — aborts early otherwise (unless `--force`, or `--reinstall` which first deletes the existing deployment). Detects an existing install by its config in `~/config`; for VM-backed modules (those that `dependsOn cluster:vm`) it also confirms the VM exists on the cluster, so a leftover config whose VM is gone is treated as not-installed.
2. Copies and validates the module JSON config (variant-aware via `copy-update-json.sh`)
3. Checks that every `dependsOn` service is provided by an installed module
4. Validates that the module has service scripts for each service it provides
5. Iterates `dependsOn` and calls each provider's `install-service.sh`
6. Calls the module's own `install.sh` (if present)

**Example:**
```bash
install-module.sh vaultwarden
install-module.sh litellm --node tappaas2

# Install a staging variant of openwebui (auto-derives vmname, vmid, proxyDomain)
install-module.sh openwebui --variant staging

# Install a dev variant with explicit zone and vmid overrides
install-module.sh openwebui --variant dev --zone0 srv-dev --vmid 315

# Re-run the installer against an already-installed module (keeps the VM)
install-module.sh identity --force

# Recover from a partial/broken install: delete, then install fresh (issue #301)
install-module.sh homeassistant --reinstall
```

**Variant mode:**

When `--variant <name>` is used, the source module's JSON is used as a base, but the output config is named `<module>-<variant>.json`. Fields like `vmname`, `vmid`, `zone0`, and `proxyDomain` are automatically derived unless explicitly overridden. See `copy-update-json.sh` for full variant field derivation rules.

---

### update-module.sh

Updates a TAPPaaS module safely with snapshot, testing, and automatic rollback.

**Usage:**
```bash
update-module.sh [options] <module-name>
```

**Options:**
| Option | Description |
|--------|-------------|
| `--force` | Proceed even if pre-update test fails |
| `--no-snapshot` | Skip pre-update test, snapshot, and rollback on failure |
| `--debug` | Show Debug-level messages |
| `--silent` | Suppress Info-level messages |

**What it does:**
0. Runs `apply-json-merge.sh` to reconcile the installed config against the new release source (#207). Adopts release changes for fields the operator hasn't touched; preserves operator customizations for fields where `current != .orig`. Advances `.orig` to the new release. Runs before the snapshot so the snapshot reflects the merged config.
1. Creates a pre-update VM snapshot (rollback safety net) — skipped with `--no-snapshot`
2. Runs `test-module.sh` pre-update — aborts if tests fail (unless `--force`) — skipped with `--no-snapshot`
3. Runs the module's `pre-update.sh` hook (if present)
4. Iterates `dependsOn` and calls each provider's `update-service.sh`
5. Calls the module's own `update.sh`
6. Runs `test-module.sh` post-update — rolls back on fatal failure (warns only with `--no-snapshot`)
7. On success, prunes old pre-update snapshots to `tappaas.snapshotRetention` (default `5`) via `snapshot-vm.sh --cleanup`, so per-VM snapshot chains stay bounded (#353). Best-effort — a cleanup failure warns but does not fail the update. Skipped after a rollback and with `--no-snapshot`.

**Exit codes:**
| Code | Meaning |
|------|---------|
| `0` | Update succeeded, all tests passed |
| `1` | Update completed but post-update test failed (non-fatal) |
| `2` | Fatal error (rollback attempted if snapshot exists) |

**Example:**
```bash
update-module.sh vaultwarden
update-module.sh --force litellm
update-module.sh --no-snapshot nextcloud
update-module.sh --debug openwebui
```

---

### repository.sh

Manages module repositories for the TAPPaaS platform. Supports adding, removing, modifying, and listing external module repositories alongside the main TAPPaaS repository.

**Usage:**
```bash
repository.sh <command> [options]
```

**Commands:**

| Command | Description |
|---------|-------------|
| `add <url> [--branch <branch>]` | Add a new module repository |
| `remove <name> [--force]` | Remove a module repository |
| `modify <name> [--url <url>] [--branch <branch>]` | Modify a repository |
| `list` | List all tracked repositories |

**Examples:**
```bash
# Add a community module repository
repository.sh add github.com/someone/tappaas-community

# Add with a specific branch
repository.sh add github.com/someone/tappaas-community --branch develop

# List all repositories
repository.sh list

# Switch a repository to a different branch
repository.sh modify tappaas-community --branch stable

# Change a repository's URL
repository.sh modify tappaas-community --url github.com/other/repo --branch main

# Remove a repository
repository.sh remove tappaas-community

# Force remove even if modules are installed from it
repository.sh remove tappaas-community --force
```

**What `add` does:**
1. Validates the repository URL is reachable via `git ls-remote`
2. Clones the repository to `/home/tappaas/<name>/`
3. Checks out the specified branch (default: `stable`)
4. Verifies the repo contains `src/module-catalog.json` (legacy `src/modules.json` also accepted)
5. Warns on VMID or module name conflicts with existing repos
6. Updates `configuration.json` with the new repository entry

**What `remove` does:**
1. Checks that no installed modules have their `location` pointing into the repository
2. Removes the repository directory
3. Updates `configuration.json` to remove the repository entry

**What `modify` does:**
- **Branch-only change**: Fetches and checks out the new branch in place
- **URL change**: Validates new repo has all currently-installed modules, re-clones, and updates module `location` fields

**Notes:**
- Repository URLs use the same format as `upstreamGit` (without `https://` prefix)
- The main TAPPaaS repository is the first entry in the `repositories` array
- All repositories are treated equally — no special handling for the main repo
- VMID and module name conflicts are warnings, not errors

---

### snapshot-vm.sh

Manages VM snapshots on the Proxmox cluster for an installed module.

**Usage:**
```bash
snapshot-vm.sh <module-name> [--list | --cleanup <N> | --restore <N>]
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module (must have config in ~/config) | `vaultwarden` |
| `--list` | List all snapshots on the VM | |
| `--cleanup <N>` | Delete all snapshots except the last N | `--cleanup 3` |
| `--restore <N>` | Restore snapshot N steps back (1 = most recent) | `--restore 1` |

**Example:**
```bash
# Create a new snapshot
snapshot-vm.sh vaultwarden

# List all snapshots
snapshot-vm.sh vaultwarden --list

# Keep only the last 3 snapshots
snapshot-vm.sh vaultwarden --cleanup 3

# Restore to the most recent snapshot
snapshot-vm.sh vaultwarden --restore 1
```

**What it does:**
1. Validates the module has a config in `~/config` with a `vmid`
2. Verifies the VM exists on the configured Proxmox node
3. Performs the requested snapshot operation via `qm snapshot`/`qm rollback`/`qm delsnapshot`

**Notes:**
- Snapshot names follow the format `tappaas-YYYYMMDD-HHMMSS`
- Restore stops the VM, rolls back, then starts it again
- Cleanup deletes oldest snapshots first
- `--cleanup` is invoked automatically by `update-module.sh` after a successful
  update, keeping `tappaas.snapshotRetention` snapshots (default `5`), so chains
  stay bounded without manual pruning (#353)

---

### inspect-cluster.sh

Compares actual running VMs across the Proxmox cluster against module configurations.

**Usage:**
```bash
inspect-cluster.sh
```

**What it does:**
1. Discovers reachable Proxmox nodes from `configuration.json` (falls back to scanning tappaas1–9)
2. Queries cluster-wide VM list via `pvesh get /cluster/resources`
3. Reads all `~/config/*.json` files that define a `vmid`
4. Displays a table of all running VMs with their config status
5. Lists configured modules whose VMs are not running

**Output:**
- VMs with a matching config show green "yes"
- VMs not in any config show yellow "NOT IN CONFIG"
- Configured modules with no running VM show red "NOT RUNNING"

---

### inspect-vm.sh

Generates a 3-column comparison table for a module's VM showing config, git, and actual values.

**Usage:**
```bash
inspect-vm.sh <module-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to inspect | `openwebui` |

**Example:**
```bash
inspect-vm.sh openwebui
inspect-vm.sh vaultwarden
```

**What it does:**
1. Reads deployed config from `~/config/<module>.json` (normalized to flat regardless of Pattern A / flat on-disk shape; #207)
2. Reads git source JSON from the module's `location` directory (also normalized)
3. Queries actual VM config from Proxmox via `qm config`
4. Displays a comparison table with color-coded differences

**Color coding:**
- **Yellow** — config value differs from git value (config drift from source)
- **Red** — actual VM value differs from config value (VM out of sync)

**Fields compared:** vmname, vmid, node, cores, memory, diskSize, storage, bios, cputype, bridge0, zone0 (with VLAN resolution), mac0, HANode, description, vmtag

---

### migrate-vm.sh

Migrates VMs between Proxmox cluster nodes. Attempts live migration first; if it fails, automatically falls back to offline migration (shutdown → migrate → start).

**Usage:**
```bash
migrate-vm.sh <module-name>
migrate-vm.sh --node <node-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to migrate | `identity` |
| `--node <name>` | Target node — migrate all its VMs back | `--node tappaas1` |
| `--offline` | Skip live migration attempt | |

**Modes:**

1. **Single module** (`migrate-vm.sh identity`):
   - If the VM is on its primary node (`node`), migrates to the HA node (`HANode`)
   - If the VM is on its HA node, migrates back to the primary node
   - If the VM is on any other node, migrates to the primary node

2. **Node mode** (`migrate-vm.sh --node tappaas1`):
   - Finds all modules whose configured `node` is `tappaas1`
   - For each VM not currently on that node, migrates it there
   - Useful for returning VMs after maintenance or failover

**Example:**
```bash
# Migrate identity to its HA node
migrate-vm.sh identity

# Force offline migration (no live attempt)
migrate-vm.sh --offline identity

# Return all VMs to tappaas1 after maintenance
migrate-vm.sh --node tappaas1
```

**What it does:**
1. Reads module config to determine VMID, primary node, and HA node
2. Queries the cluster to find where the VM is currently running
3. Saves HA state (resource + affinity rule) before migration
4. Attempts live migration (unless `--offline`)
5. Falls back to offline migration if live fails
6. Restores HA resource and affinity rule after migration
7. Replication direction is automatically updated by Proxmox

**Notes:**
- Live migration may fail on clusters with different CPU architectures (e.g., Intel + AMD). The script handles this gracefully by falling back to offline migration
- HA affinity rules are saved and restored automatically
- The `--node` mode shows a summary of migrated/skipped/failed VMs

---

### migrate-node.sh

Evacuates all VMs from a Proxmox node (for maintenance) or returns them afterwards. Uses `migrate-vm.sh` for each individual migration.

**Usage:**
```bash
migrate-node.sh <node-name>
migrate-node.sh --return <node-name>
migrate-node.sh --list <node-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `node-name` | Proxmox node to evacuate | `tappaas1` |
| `--return <name>` | Return VMs that belong on this node | `--return tappaas1` |
| `--list <name>` | Dry run — show what would happen | `--list tappaas1` |
| `--offline` | Skip live migration attempts | |

**Modes:**

1. **Evacuate** (`migrate-node.sh tappaas1`):
   - Finds all VMs currently running on the node
   - Migrates each to its configured HANode
   - VMs without an HANode are skipped with a warning

2. **Return** (`migrate-node.sh --return tappaas1`):
   - Finds all modules whose configured `node` is `tappaas1`
   - For each VM currently running elsewhere, migrates it back
   - VMs already on the correct node are skipped

3. **List** (`migrate-node.sh --list tappaas1`):
   - Shows both evacuate and return views without migrating
   - Color-coded: green = would migrate, yellow = no target/skipped

**Example workflow — planned maintenance:**
```bash
# 1. Check what would happen
migrate-node.sh --list tappaas1

# 2. Evacuate the node
migrate-node.sh --offline tappaas1

# 3. Perform maintenance on tappaas1
# ...

# 4. Return all VMs
migrate-node.sh --return --offline tappaas1
```

**Notes:**
- Each VM migration is delegated to `migrate-vm.sh`, which handles HA save/restore
- VMs without an HANode cannot be evacuated (requires manual migration)
- The summary shows migrated/skipped/failed counts

---

### test-module.sh

Tests a TAPPaaS module with dependency-recursive service testing.

**Usage:**
```bash
test-module.sh [options] <module-name>
```

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to test | `openwebui` |
| `--deep` | Run extended/heavy tests | |
| `--debug` | Show Debug-level messages | |
| `--silent` | Suppress Info-level messages | |

**What it does:**
1. Validates the module JSON config exists and is valid
2. Checks that dependency services have `test-service.sh` scripts
3. Iterates `dependsOn` and calls each provider's `test-service.sh`
4. Calls the module's own `test.sh` (if present)
5. Reports structured results with pass/fail/skip counts

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | All tests passed |
| `1` | One or more tests failed |
| `2` | Fatal error (requires rollback/reinstall) |

**Service tests included:**

| Service | Tests (standard) | Tests (--deep) |
|---------|-----------------|----------------|
| `cluster:vm` | VM running, ping, SSH | Disk usage, memory |
| `cluster:ha` | HA resource status, affinity rule | Replication job, replication health |
| `network:proxy` | Caddy domain, handler, HTTPS | TLS certificate, upstream reachability |

**Structured output:** Each message is prepended with `[Info]`, `[Debug]`, `[Warning]`, `[Error]`, or `[Fatal]`.

**Environment variables:**
- `TAPPAAS_TEST_DEEP=1` — same as `--deep`
- `TAPPAAS_DEBUG=1` — same as `--debug`

**Example:**
```bash
# Quick sanity check
test-module.sh openwebui

# Full regression test
test-module.sh --deep openwebui

# Silent mode for CI
test-module.sh --silent openwebui
```

---

### delete-module.sh

Deletes a TAPPaaS module with dependency-aware service teardown. Before any VM
is destroyed it resolves and **confirms the exact target VM**, refusing to guess
when multiple instances share a name (issue #195). Two lifecycle modes control
what happens to the config and backups (issue #215).

**Usage:**
```bash
delete-module.sh <module-name> [--archive|--remove] [--vmid <id>] [--yes] [--force]
```

**Lifecycle modes (issue #215):**

| Mode | VM | Config | PBS backup | inspect-cluster |
|------|----|--------|-----------|-----------------|
| `--archive` *(default, safe)* | removed | kept, `status: "archived"` | **kept** (restorable) | shows `[archived]` |
| `--remove` *(destructive)* | removed | **deleted** | **dropped** | no longer listed |

The default is `--archive` so an accidental delete never loses the config or
backups. `--remove` requires confirmation (unless `--yes`/`--force`), and
**`--force` implies `--remove`** (preserving its historical full-teardown
behaviour for scripted/CI cleanup).

**Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| `module-name` | Name of the module to delete | `vaultwarden` |
| `--archive` | Keep config (marked `archived`) and PBS backup; just remove the VM (default) | |
| `--remove` | Remove VM **and** delete config **and** drop PBS backup entry (destructive) | |
| `--vmid <id>` | Target a specific VM instance by VMID. **Required** when more than one cluster VM shares the module's name. If it differs from the config VMID, only that VM is destroyed and the module config is left intact (see notes). | `--vmid 313` |
| `--yes`, `-y` | Skip the destroy confirmation prompt (for automation) | |
| `--force` | Delete even if other modules depend on this module's services; **also implies `--yes` and `--remove`** | |

**What it does:**
1. Validates the module JSON config exists in `/home/tappaas/config/`
2. **Resolves and confirms the target VM**: lists every cluster VM sharing the module's name; if more than one exists it aborts and requires `--vmid`; otherwise prompts `Confirm destroy of VM <id>? [y/N]` before proceeding (skipped by `--yes`/`--force`; refuses in a non-interactive shell without them). The prompt states whether the config/backups will be kept (`--archive`) or deleted (`--remove`).
3. Checks reverse dependencies — blocks if other modules depend on this module's services (unless `--force`)
4. Calls the module's own `delete.sh` (if present) while the VM still exists
5. Iterates `dependsOn` in **reverse** order and calls each provider's `delete-service.sh` (skips if not found). Under `--archive`, the `backup:vm` deregistration is **skipped** so the PBS entry is retained.
6. **Archive:** marks the config `"status": "archived"` (config + `.orig` kept; written via `jq_module_write` so the canonical Pattern A on-disk shape is preserved). **Remove:** deletes the config files (`.json` and `.json.orig`).

**Example:**
```bash
# Archive a module — removes its VM but keeps config + backups (default, prompts)
delete-module.sh vaultwarden

# Full removal (prompts for confirmation)
delete-module.sh litellm --remove

# Non-interactive full removal (CI / test cleanup) — --force implies --remove
delete-module.sh test-vmdrift --force

# Two VMs named "openwebui" exist — destroy only the stray test instance,
# leaving the configured (prod) VM and its config untouched
delete-module.sh openwebui --vmid 313
```

**Notes:**
- **An archived module is re-installable:** `install-module.sh` treats it as not-installed (VM gone) and re-deploys it, overwriting `status=archived` with the module's real status.
- **Confirmation is mandatory by default.** In a non-interactive shell (no TTY) the script refuses unless `--yes` or `--force` is passed, so a buggy script can never silently destroy a VM. The resolved name, VMID and node are shown before the prompt.
- **Multiple instances:** if the cluster has more than one VM with the module's name (e.g. prod + a stray test VM), deletion aborts with the list and requires `--vmid <id>` to pick the instance — preventing the "destroyed the wrong VM" class of incident.
- **VM-only mode:** when `--vmid` names a VM other than the module config's own VMID, *only* that VM is destroyed; the module's `delete.sh`, reverse-dependency check, service teardown and config removal are all skipped (the config still describes a different, live VM).
- The resolved VMID **and node** are handed to `cluster:vm delete-service.sh` (via `TAPPAAS_VMID_OVERRIDE`/`TAPPAAS_NODE_OVERRIDE`), which also corrects a stale `.node` after an HA migration.
- The deletion order is reversed compared to installation: the module's own `delete.sh` runs first (while the VM still exists), then services are torn down in reverse dependency order.
- HA/replication is removed before the VM is destroyed to prevent conflicts.
- Missing `delete-service.sh` scripts are skipped (not an error), allowing incremental rollout.
- Service teardown failures produce warnings but do not abort the overall deletion.

---

## Installation

These scripts are automatically installed by `install.sh`:
```bash
cp scripts/*.sh /home/tappaas/bin/
chmod +x /home/tappaas/bin/*.sh
```

Or symlinked via NixOS configuration.

## Directory Structure

```
scripts/
├── README.md                    # This file
├── check-disk-threshold.sh      # Auto-expand disks when usage exceeds threshold
├── common-install-routines.sh   # Shared library for install scripts
├── copy-update-json.sh          # Copy and modify module JSON configs
├── create-configuration.sh      # Create or update system configuration.json
├── delete-module.sh             # Delete a module with dependency-aware teardown
├── inspect-cluster.sh           # Compare running VMs against module configs
├── inspect-vm.sh                # 3-column config/git/actual VM comparison
├── install-module.sh            # Install a module with dependency validation
├── migrate-node.sh              # Evacuate or return all VMs on a node
├── migrate-vm.sh                # Migrate VMs between nodes (live or offline)
├── repository.sh                # Manage module repositories (add/remove/modify/list)
├── resize-disk.sh               # Resize VM disk in Proxmox and filesystem
├── setup-caddy.sh               # Install Caddy reverse proxy + os-acme-client + os-ddclient
├── acme-setup.sh                # Issue the TAPPaaS wildcard TLS cert via os-acme-client (#254)
├── roles-ensure.sh             # Reconcile Authentik role groups for the variant set (ADR-006)
├── user.sh                     # Manage Authentik logins + roles: add/modify/delete/show/list (ADR-006)
├── snapshot-vm.sh               # VM snapshot management (create/list/cleanup/restore)
├── test-module.sh               # Test a module with dependency-recursive service testing
├── update-module.sh             # Update a module with snapshot, testing, and rollback
├── update-os.sh                 # OS-specific update (NixOS/Debian)
└── validate-configuration.sh    # Validate configuration.json for correctness
```
