# ADR-016 — Source NAT for subnet-filtering IoT devices

| | |
|---|---|
| **Status** | **Proposed** — draft (not yet implemented) |
| **Version** | 0.2 |
| **Date** | 2026-08-16 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-009 Composition Meta-Model](<ADR-009 - Composition Meta-Model.md>) (`<module>:<service>` coordinates) |
| **Refines** | [ADR-014 Zone ↔ Environment Lifecycle](<ADR-014 - Zone and Environment Lifecycle.md>) (zone-owned policy gates), ADR-002 (dynamic VLAN), [ADR-003 Dependency management](<ADR-003 - Dependency management in TAPPaaS.md>) (`dependsOn`-driven service hooks) |
| **Related** | **#239** (origin: Alfen Eve Pro rejects cross-subnet sessions), **TAPPaaS/Community#3** (module NAT install-service does not verify its apply), **#285** (`network:nat` destination-NAT service — the precedent this mirrors); **owner:** `network-manager` (policy + command surface), `opnsense-controller` (push) |
| **Changelog** | v0.2 — mode enum corrected to the API's spelling (`advanced`, not `manual`); the `snat_mode` read verified against a live OPNsense and its option-dict shape recorded (refutes the "not exposed" report in #583). v0.1 — initial draft: zone-owned `snat-allowed-from` gate, module-local `snat.json`, `network-manager snat` verbs, `opnsense-controller` source-NAT push incl. the `snat_mode` prerequisite, module lifecycle hooks. |

## Context

Some IoT appliances apply application-level source-IP filtering: they accept TCP sessions
only from their own `/24`. The Alfen Eve Pro (`iotCloud`, 10.4.20.0/24) is the live case —
it accepts an iPhone on IoT WiFi and ignores the same app from `home` (10.3.10.0/24), while
the OPNsense log confirms the packets were **passed**. Firewall policy is not the problem;
the device is.

TAPPaaS has no way to express "rewrite the source address of traffic entering this zone".
Three gaps make this more than a missing feature:

1. **No declarative home.** A working fix exists only as hand-made OPNsense rules, or (in
   the Community `alfen` module) as a module-private `services/nat/` that reaches the
   OPNsense API directly. Neither survives a firewall rebuild driven from config.
2. **Module-declared, zone-wide effect.** The `alfen` implementation writes
   `destination_net = <zone0 subnet>`, so a rule declared by one module masquerades **all**
   traffic from the listed zones to **every** device in `iotCloud`. The declaration is
   module-scoped; the blast radius is the zone. The module has no device address to narrow
   it with — `alfen.json` carries no `ip` (it is a physical appliance, not a guest).
3. **A firewall-global prerequisite nobody owns.** Source-NAT rules are only enforced when
   OPNsense's outbound NAT mode is `hybrid` or `advanced` (the API's spelling of the mode
   the GUI labels "Manual"). On `automatic` — the default, and
   the live setting on the reference cluster — custom rules are accepted into config and
   silently excluded from the generated ruleset. No TAPPaaS tool can read or set this.

The result is a failure that reports success at three levels: the API returns `saved`, the
module's `install-service.sh` reports ✓, and its `test-service.sh` confirms the rule is
*present* — while no translation occurs. Three green checks and no working path.

### Why source NAT, and not something else

The discriminator is **transparency**. The Alfen app discovers the charger by proprietary
UDP broadcast (port 36549, relayed cross-VLAN by `network:discovery` via
`os-udpbroadcastrelay`) and then connects **directly to the address it learned**. A client
that cannot be told to connect somewhere else can only be served by an in-path fix.

## Decision

Source NAT becomes a **foundation capability**: policy owned by the zone, intent declared
by the module, mechanism owned by `network-manager` + `opnsense-controller`. Modules never
call the OPNsense API directly.

### D1 — `zones.json` gains `snat-allowed-from` (zone owns the policy)

The target zone declares which source zones **may** be masqueraded into it. This mirrors the
existing `pinhole-allowed-from` gate exactly: the zone grants, the module requests, and a
module can never widen its own permission.

```jsonc
"iotCloud": {
  "type": "IoT",
  "ip": "10.4.20.0/24",
  "access-to": ["internet"],
  "pinhole-allowed-from": ["srvHome", "home"],
  "snat-allowed-from":    ["srvHome", "home"],   // NEW — subset of pinhole-allowed-from
  ...
}
```

Rules:

- **R1** — a zone in `snat-allowed-from` MUST also be in `pinhole-allowed-from`. Masquerade
  without reachability is meaningless, and this keeps SNAT from becoming a second, weaker
  path into a zone. Enforced by `network-manager validate`.
- **R2** — absent `snat-allowed-from` = today's behaviour (no masquerade possible). Opt-in.
- **R3** — a module request naming a zone outside the gate is **refused**, not trimmed.

This resolves gap 2 at the level where the trade-off actually lives: masquerading into a
zone affects every device in it, so the zone — not a module — must consent.

### D2 — module-local `snat.json` declares intent

A module that needs masquerade ships `snat.json` beside its module JSON:

```jsonc
// src/.../alfen/snat.json
{
  "_comment": "Alfen NG5 firmware accepts TCP only from its own /24. Masquerade traffic from these zones to zone0 so the charger sees the zone0 gateway address.",
  "masqueradeFrom": ["home", "srvHome"],
  "reason": "Alfen NG5 firmware rejects sessions sourced outside iotCloud (#239)"
}
```

- `masqueradeFrom` — source zone names. Destination is always the module's `zone0`; a module
  cannot masquerade into a zone it does not live in.
- `reason` — required free text. It lands in the OPNsense rule description context and in
  `snat list`, so the next operator learns *why* a zone lost client attribution.
- The module adds `network:snat` to `dependsOn`. Absent `snat.json`, the hook is a no-op.

`snat.json` is a **request**. The effective set is `masqueradeFrom ∩ zone.snat-allowed-from`,
and a non-empty difference is a hard error (R3).

### D3 — `network-manager snat` command surface

`network-manager` already owns `zones.json` and the reconcile loop; source NAT is zone
policy, so it belongs there rather than in `rules-manager` (which compiles per-module filter
rules) or `nat-manager` (destination NAT, #285).

```
network-manager snat add <module> [--check]      # apply snat.json ∩ zone gate
network-manager snat delete <module> [--check]   # remove this module's rules
network-manager snat list [--json]               # live rules + owning module + reason
network-manager snat verify <module>             # declared == live AND enforced
network-manager snat mode [--set automatic|hybrid|advanced]  # read/set the OPNsense prerequisite
```

- `add` is idempotent — rules are keyed by description (D4) and matched before insert.
- `verify` checks **enforcement, not presence**: it fails when `snat_mode` is `automatic`
  even though the rule exists. This is the specific hole that made #239 fail silently.
- `--check` is dry-run everywhere, consistent with `network-manager add|delete`.
- `snat` participates in `network-manager reconcile --only snat`, so drift is pruned like
  every other plane — including, per D4, `snat_mode` itself in the safe direction.
- `mode --set automatic` first calls `list` and **refuses if any live rule exists at all**
  — owned or unowned. A still-declared, TAPPaaS-owned rule would silently stop being
  enforced under `automatic` while looking present in config; that is the exact failure
  class this ADR exists to close, so `automatic` is only safe to set when the rule set is
  genuinely empty, not merely unowned-rule-free.

### D4 — Pushing to OPNsense via `opnsense-controller`

`opnsense-controller` gains a `snat_manager.py` + `snat_cli.py` pair, mirroring the existing
`nat_manager.py` (which wraps `firewall/d_nat` for #285 via the oxl `raw` module). Same
shape, different controller: `firewall/source_nat`.

| Operation | API call |
|---|---|
| list | `POST firewall/source_nat/searchRule` |
| add | `POST firewall/source_nat/addRule` |
| delete | `POST firewall/source_nat/delRule/<uuid>` |
| apply | `POST firewall/source_nat/apply` |
| mode read | `GET firewall/source_nat/get` → `.filter.general.snat_mode` |

**The mode read is verified against a live OPNsense (2026-09-05), not assumed.** It was
reported in #583 as unreadable — "not exposed by `firewall/source_nat/get` (returns
`{filter}` only)" — which is a stop one level too early: `filter` holds
`general, rules, snatrules, npt, onetoone`, and the mode is `general.snat_mode`. It comes
back as an OPNsense **option dict**, not a scalar:

```json
{"snat_mode": {"automatic": {"value": "Automatic Source NAT rule generation", "selected": 1},
               "hybrid":    {"value": "Hybrid Source NAT rule generation",    "selected": 0},
               "advanced":  {"value": "Manual Source NAT rule generation",    "selected": 0},
               "disabled":  {"value": "Disable Source NAT rule generation",   "selected": 0}}}
```

Three consequences for the implementation:

- **The current value is the key whose `selected` is `1`** — here `automatic`, which is the
  live setting on the reference cluster and therefore the state in which every source-NAT
  rule is accepted into `config.xml` and silently excluded from the generated ruleset. The
  precondition check in D4 is implementable today; it needs no new endpoint.
- **The API spells the "Manual" mode `advanced`.** The GUI label and the API key differ, and
  a `--set manual` would fail. This document said `manual` throughout until this revision.
- `opnsense-controller` already unwraps this exact shape — `_option_str()` in
  `caddy_manager.py`, added for #580, where `HttpVersion` and `accesslist` arrive the same
  way. Reuse it rather than writing a second unwrapper.
| mode set | `POST firewall/source_nat/set` |

Rule payload:

```jsonc
{"rule": {
  "enabled":         "1",
  "interface":       "<zone0 OPNsense iface>",   // resolved from zones.json, not hardcoded
  "source_net":      "<source zone CIDR>",
  "destination_net": "<zone0 CIDR>",
  "target":          "<zone0 iface>ip",
  "description":     "tappaas-snat:<module>:<from>-><zone0>"
}}
```

The description is the idempotency key and the ownership marker — `snat delete <module>`
removes by the `tappaas-snat:<module>:` prefix, matching how `rules-manager` and
`nat_manager` already scope their rules.

**The `snat_mode` prerequisite is part of this decision, not a footnote.** `add` MUST:

1. read `.filter.general.snat_mode`;
2. if `automatic`, **auto-flip to `hybrid`** before proceeding — this transition is
   additive (OPNsense keeps generating its automatic per-interface rules unchanged; it
   only starts also evaluating custom ones alongside them), so nothing existing is at
   risk. Report the flip in output; do not do it silently;
3. **refuse** with a named error if it is `disabled` — an unusual, deliberate state,
   never touched automatically;
4. proceed on `hybrid` or `advanced`;
5. verify the rule is present *after* `apply`, and fail if it is not (the defect behind
   Community#3).

Only the `automatic → hybrid` transition is safe to automate — it never removes existing
rule generation. `advanced` transitions stay **explicit, human-only** operator actions via
`network-manager snat mode --set`, because `advanced` *replaces* automatic generation
entirely; moving into or out of it without accounting for every existing rule can break
outbound connectivity site-wide. `hybrid` remains the recommended target: it keeps
OPNsense's automatic per-interface rules and lets custom rules coexist.

**The reverse direction is also automatable, guarded by the same ownership check `mode
--set automatic` uses.** `network-manager reconcile --only snat`, after pruning any
TAPPaaS-owned rule whose module or zone no longer declares it, auto-reverts `hybrid` →
`automatic` when zero TAPPaaS-owned rules remain **and** `snat list` shows no unowned
rule present. An unowned rule found at that point blocks the revert and surfaces a
warning instead of silently discarding something TAPPaaS never declared — the same
`tappaas-nat:*`-unowned case §Consequences already names for the Community migration,
reused here as the safety gate rather than a one-off note.

**This follows the same inspect-vs-apply convention every manager already uses**
(`module-manager list --diff`, `<manager> reconcile [--apply]`): `network-manager
reconcile --only snat` **without** `--apply` is read-only — it reports the same
rogue/unowned-rule finding and the would-be revert decision without changing anything,
so an operator can inspect drift before ever risking a mutation. `--apply` is what
actually prunes and reverts. Rogue detection is therefore not only an internal safety
gate inside `mode --set automatic` — it is directly inspectable on demand, the same way
every other plane's drift already is.

### D5 — Module lifecycle hooks

The charger module calls `network-manager`; it never touches the OPNsense API. All three
hooks are idempotent and safe to re-run.

**`install.sh`** — after the VM/device config exists, before post-install tests:

```bash
if [[ -f "${MODULE_DIR}/snat.json" ]]; then
    info "  Requesting source NAT for ${MODULE}..."
    network-manager snat add "${MODULE}" \
        || die "source NAT request failed — see 'network-manager snat mode'"
fi
```

A failure here is **fatal**. Installing a module whose only working path depends on
masquerade, and continuing when the masquerade was refused, is what produced #239's silent
success.

**`update.sh`** — re-assert, picking up edits to `snat.json` or the zone gate:

```bash
[[ -f "${MODULE_DIR}/snat.json" ]] && network-manager snat add "${MODULE}"
```

**`delete.sh`** — unconditional, so a module removed after its `snat.json` was deleted still
cleans up:

```bash
network-manager snat delete "${MODULE}" || warn "  Could not remove source NAT rules for ${MODULE}"
```

**`test.sh`** — `network-manager snat verify "${MODULE}"`, which asserts enforcement rather
than presence.

## Alternatives considered

| Alternative | Why not |
|---|---|
| **L4/L7 gateway in `iotCloud`** — proxy HA's traffic from an in-subnet address | Clean, scoped, preserves attribution — but **not transparent**. The phone app connects to the address it discovered over UDP/36549; it has no proxy setting. Would work for HA only, or require spoofing a proprietary discovery protocol. |
| **`zone1` multi-homing** — give Home Assistant a second NIC in `iotCloud` | Already supported (`bridge1` + `zone1`), zero new code — but same transparency limit (HA only, not the phone), and it dual-homes HA across two trust tiers, defeating the segmentation ADR-014 establishes. |
| **Move the device into `home`** | Fixes both clients, no new mechanism — but puts a cloud-connected IoT appliance in a trusted client zone, the inverse security trade. |
| **Zone-level blanket masquerade** (original #239 option 2) | Simpler, but masquerades every source→`iotCloud` flow with no module opt-in and no record of why. D1+D2 keep the zone consent while retaining per-module intent and a `reason`. |
| **Keep it module-private** (status quo: `alfen/services/nat/`) | Rejected: reaches the OPNsense API directly, cannot be reconciled, silently zone-wide, and cannot see the `snat_mode` prerequisite. This ADR supersedes that implementation. |

## Schema changes

- **`zones.json` — new optional `snat-allowed-from`** (array of zone names). Absent = SNAT
  refused for that zone. Must be a subset of `pinhole-allowed-from` (R1).
- **`schemas/zones-fields.json`** — add `snat-allowed-from` to `fields`; document alongside
  `pinhole-allowed-from` in `network-manager/ZONES.md` with the attribution-loss warning.
- **`schemas/module-fields.json`** — no change. Intent lives in the module-local `snat.json`,
  not in the module JSON, mirroring how `pinhole.json` sits beside a service.
- **New file `<module>/snat.json`** — `masqueradeFrom` (array, required), `reason` (string,
  required), `_comment` (optional). Validated by `network-manager snat add`.
- **No `module-catalog` change.**

## Consequences

- **Client attribution is lost inside the target zone.** The device sees the zone gateway
  address for every masqueraded client and logs it that way. This is irreversible downstream
  — no logging layer can recover the original client. The mandatory `reason` field and the
  zone-level gate make it a deliberate, recorded choice rather than a side effect.
  Traffic *out* of the zone is unaffected: a device shipping syslog to `mgmt` still carries
  its real source address.
- **`snat_mode` moves to `hybrid` automatically** the first time a module's request is
  applied, and **reverts to `automatic` automatically** once no TAPPaaS-owned request
  remains and no unowned rule blocks it — no explicit operator action needed for this
  transition, only visibility (`snat mode`, `snat list`). `advanced` stays a deliberate,
  human-only choice, since it replaces automatic generation entirely rather than adding
  to it.
- **Existing hand-made rules** (`tappaas-nat:alfen:*` on sites that ran the Community
  implementation) are not adopted. `snat list` reports them as unowned; the migration is to
  delete them and re-run `install.sh` with this ADR's hook.
- **Community `alfen/services/nat/` is retired** in favour of `snat.json` + `dependsOn:
  network:snat`. Community#3 is resolved by D4's post-apply verification rather than by
  patching the module.
- **`network:nat` (destination NAT, #285) is untouched** and remains the answer for exposing
  ports outward. The names are close; the ADR fixes the vocabulary as **destination NAT =
  `network:nat`**, **source NAT = `network:snat`**.

## Open (deferred to implementation)

- **Host-scoped rules.** `destination_net` is the zone CIDR because `alfen.json` has no
  device address. If physical appliances gain a recorded `ip` (DHCP reservation), the rule
  should narrow to `<device>/32` and the zone-wide consequence largely disappears. Worth
  revisiting with the IoT device-registration work.
- **Whether `snat verify` should test the path, not just the config.** A synthetic
  connection from a source zone would prove enforcement end-to-end; it needs a probe host in
  each source zone.
- **OPNsense firewall-log attribution** under SNAT (pre- vs post-translation addresses in
  the filter log shipped to `logging`) is unverified.
- ~~Whether the mode is readable at all~~ — **closed**: verified live, see D4. The open
  part is only the *write* path (`POST firewall/source_nat/set`), which is untested here.
- **Whether `firewall/source_nat/searchRule` cleanly separates automatically-generated
  per-interface rules from manually/API-added custom ones** is assumed from OPNsense's
  documented Hybrid-mode semantics, not confirmed live against this instance — the rogue-
  detection gate (`mode --set automatic`, `reconcile --only snat`'s auto-revert) depends on
  this distinction being reliable. Verify empirically in a test/staging window before
  relying on it in production.

## Acceptance (draft — becomes a checklist on Accepted)

- [ ] `snat-allowed-from` in `zones-fields.json`; R1 enforced by `network-manager validate`.
- [ ] `network-manager snat add|delete|list|verify|mode` implemented, `--check` on mutators.
- [ ] `snat add` auto-flips `automatic` → `hybrid` (reported, not silent) and refuses only
      on `disabled`, with a named error.
- [ ] `snat add` verifies rule presence after `apply` and fails when absent.
- [ ] `snat verify` fails on a present-but-unenforced rule.
- [ ] `reconcile --only snat` prunes rules whose module or zone gate no longer declares them.
- [ ] `snat mode --set automatic` refuses if any live rule exists at all, owned or
      unowned — not only on an unowned one.
- [ ] `reconcile --only snat` auto-reverts `hybrid` → `automatic` when no TAPPaaS-owned
      rule remains and no unowned rule is present; otherwise warns and leaves the mode
      unchanged.
- [ ] `reconcile --only snat` **without** `--apply` reports the rogue-rule finding and the
      would-be revert decision read-only, matching every other manager's inspect-vs-apply
      convention.
- [ ] A request naming a zone outside `snat-allowed-from` is refused, not trimmed.
- [ ] `alfen` migrated to `snat.json`; `services/nat/` removed; #239 and Community#3 closed.
- [ ] Alfen reachable from `home` (phone app) and `srvHome` (HA) with no hand-made rules.
