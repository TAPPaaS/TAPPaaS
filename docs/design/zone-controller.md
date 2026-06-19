# zone-controller — single primitive for zone create/delete

Status: accepted (2026-06-18) · Owner: foundation/firewall · Related: #372, #373, #335, ADR-007f

## Problem

Creating a network zone is a multi-step, multi-plane operation:

1. **Author** the entry in `zones.json` (allocate a VLAN tag, derive the subnet,
   inherit ACLs).
2. **Reconcile OPNsense** so the L3 side exists (VLAN interface, DHCP, dnsmasq,
   firewall rules).
3. **Update the hypervisors** so the L2 path exists: the firewall VM's per-VM
   trunk **and every node's `lan` bridge VLAN list (`bridge-vids`)**.
4. **Distribute** `zones.json` to the nodes so node-side VM creation can resolve
   the new VLAN.
5. Maintain the **`mgmt` reachability invariant** (`zones.json._README`).

Today there is **no single owner** of this sequence. `zone-manager` is a pure
*declarative reconciler* of `zones.json` into OPNsense — it has **no `add`/`delete`
command** and never touches Proxmox. So `variant-manager` authors the zone entry
**inline** (`create_variant_zone`) and then calls a *subset* of the downstream
steps; an operator adding a zone by hand calls a *different* subset. Steps get
silently dropped. Two confirmed consequences:

- **bridge-vids gap (#335 family).** Neither path runs `proxmox-manager
  bridge-vids --apply`, so a newly-added tagged VLAN is **not** added to the node
  `lan` bridges. A module VM placed on a node *other than the firewall's node*
  then boots with **no DHCP IP** → unreachable → `cicd → VM` SSH (e.g. identity
  step 5a) **times out**. Reproduced 2026-06-18 (VM on `tappaas1`, co-located with
  the firewall VM, worked; the same VM migrated to `tappaas2`, which lacked the
  VID, got no IP and 100% packet loss). `mgmt.access-to` is **not** the cause
  (mgmt is the untagged native LAN with the stock "allow LAN to any").
- **mgmt invariant drift (#372, #373).** Nothing keeps `mgmt.access-to` in step
  with the zone set.

## Decision

Introduce a **standalone bash orchestrator `zone-controller`** that is the single
entry point for the zone lifecycle. It does **not** reimplement OPNsense or
Proxmox logic — it owns zone **authoring** and **orchestrates** the existing
reconcilers. Both `variant-manager` (and any future environment-manager) and a
hands-on operator call it.

```
variant-manager (environment-manager)              "manager" — variant/domain/cert/role-group
        │  zone-controller add <name> --from-zone <src> --variant <name>
        ▼
zone-controller  add | delete                      "controller" — owns zone lifecycle + invariants
        ├─ author zones.json            (jq temp→validate→mv)
        ├─ maintain mgmt.access-to      (explicit append/remove — see "mgmt" below)
        ├─ zone-manager --zones-file --execute      → OPNsense reconcile (VLAN/DHCP/rules)
        ├─ distribute zones.json → all nodes
        ├─ proxmox-manager reconcile --apply        → per-VM trunks (firewall VM gets the tag)
        └─ proxmox-manager bridge-vids --apply      → node lan bridges   ← closes the gap
```

`zone-manager` stays the OPNsense reconciler; `proxmox-manager` stays the
hypervisor reconciler. `zone-controller` sits above both (ADR-007f
Manager→Controller boundary).

## CLI contract

```
zone-controller add <name> [--from-zone <src>] [--type <T> --typeId <N>] [--vlan <tag>]
                           [--variant <name>] [--state Active] [--no-bridge-apply]
                           [--no-activate] [--check]
zone-controller delete <name> [--force] [--keep-bridge-vid] [--check]

common: --zones-file <f> (default $CONFIG_DIR/zones.json), --no-ssl-verify, --check (dry-run)
add echoes the created zone name (drop-in for create_variant_zone's stdout contract).
```

## `add` — orchestration

```
preflight
  - zones.json exists & valid; name matches ^[a-z][a-zA-Z0-9]*$; name absent
  - --from-zone exists (if given); reject creating a zone that violates the
    isolation_invariant (no Tier-4 zone in a non-mgmt access-to)

1. AUTHOR  (extracted from variant-manager:create_variant_zone)
     - allocate a free VLAN in the typeId band (scan 99..60), or honor --vlan
     - ip = 10.<typeId>.<sub>.0/24
     - inherit type/typeId/bridge/access-to/pinhole-allowed-from from --from-zone,
       else a Service template (typeId 2, access-to ["internet","dmz"])
     - optional metadata: variant, parent(=from-zone), description
     - write via jq temp → jq empty validate → mv     (atomic; never partial)

2. mgmt INVARIANT
     - append <name> to mgmt.access-to if absent (jq temp-validate-mv)
       (explicit-list form — see "mgmt" and "Deferred enhancement")

3. RECONCILE OPNsense        (skipped under --no-activate)
     - zone-manager --no-ssl-verify --zones-file <f> --execute

4. DISTRIBUTE
     - distribute_zones_to_nodes   (scp zones.json → each node:/root/tappaas/)

5. PROXMOX LAN PORTS
     - proxmox-manager reconcile --apply       → per-VM trunks: firewall (+trunk-ALL) VMs get <tag>
     - proxmox-manager bridge-vids --apply       → add <tag> to every node lan bridge   [unless --no-bridge-apply]

6. VERIFY
     - proxmox-manager bridge-vids (dry-run) reports in-sync
     - echo <name>

On failure after step 1: stop, report the failed step + remediation. Every step
is idempotent, so re-running `add` converges (no rollback of zones.json needed).
```

## `delete` — orchestration (mirror of the verified manual teardown)

```
preflight
  - zone exists; refuse if any VM is still on this VLAN (pvesh) unless --force

1. mgmt INVARIANT:  remove <name> from mgmt.access-to
2. DISABLE:         set .<name>.state = "Disabled"   (jq temp-validate-mv)
3. RECONCILE:       zone-manager --execute
                      → unassign interface + delete OPNsense VLAN/DHCP/rules for the disabled zone
4. PROXMOX:         proxmox-manager reconcile --apply        → drop <tag> from firewall trunk
                    proxmox-manager bridge-vids --apply        → remove <tag> from node bridges  [guarded]
5. REMOVE:          del(.<name>) from zones.json; distribute to nodes
6. VERIFY:          bridge-vids in sync (tag gone); no OPNsense iface; zone absent
```

## bridge-vids safety model (why `add` auto-applies, `delete` is guarded)

`proxmox-manager bridge-vids --apply` is operator-gated in general because
rewriting a live node bridge can disrupt traffic. The risk is **asymmetric**:

- **`add` = adding a VID is non-disruptive.** It only *widens* the allow-list;
  no existing VLAN's traffic is affected. `zone-controller add` therefore applies
  it automatically (the gap-closer). `--no-bridge-apply` is the escape hatch.
- **`delete` = removing a VID is the sensitive direction.** Before removal,
  verify across all nodes that **no running VM is tagged with that VID**; only
  then remove. `--keep-bridge-vid` leaves it in place (an unused VID in the
  allow-list is harmless) when zero bridge churn is wanted.

Per-node application loops node-by-node, verifies each, and **continues on
partial failure while reporting which nodes converged** — never a silent
half-apply.

## mgmt reachability

`mgmt` is the untagged native LAN (`vlantag: 0`, the bridge's PVID) with the
stock "Default allow LAN to any" rule, so it already reaches every zone — it is
**not** subject to the tagged-VLAN bridge-vids gap, and `mgmt.access-to`
currently drives **no** generated firewall rule (`zone-manager` skips Manual
zones). `zone-controller` still maintains the explicit `mgmt.access-to` list on
add/delete to satisfy the documented `isolation_invariant.mgmt_exception` and to
keep `zones.json` auditable / future-proof (for if/when mgmt rules become
generated). This is the **explicit-list** form and does **not** change today's
behaviour.

## Idempotency / atomicity
- All `zones.json` edits use `jq → jq empty (validate) → mv` (no partial writes).
- Every downstream tool is declarative/idempotent (`zone-manager` matches
  `zones.json`; `proxmox-manager reconcile`/`bridge-vids` compare desired-vs-
  actual). A partially-failed `add` is fixed by re-running it.

## `variant-manager` integration
- `create_variant_zone` + the inline `zone-manager --execute` /
  `proxmox-manager trunks --apply` / `distribute_zones_to_nodes` block are
  replaced by one call:
  `zone_name="$(zone-controller add "$name" --from-zone "$from" ${vlan:+--vlan "$vlan"} --variant "$name")"`.
- `cmd_remove` calls `zone-controller delete "$zone_name"` before deleting the
  variant config entry.
- The VLAN-allocation algorithm and the `10.<typeId>.<sub>.0/24` convention move
  **into** `zone-controller` (single source of truth).

## Deferred enhancement — `mgmt.access-to: ["internet","all"]` sentinel
Replacing the explicit mgmt list with an `"all"` sentinel expanded at apply time
would make the mgmt invariant **self-maintaining** (no per-zone append/remove)
and is the cleaner long-term form. It is intentionally **out of scope** here and
tracked as a separate enhancement issue (see `issue-mgmt-all-sentinel.md`).
`zone-controller`'s explicit append/remove is forward-compatible: if the sentinel
is adopted later, steps `add:2` / `delete:1` simply become no-ops.
