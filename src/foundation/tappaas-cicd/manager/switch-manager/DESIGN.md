# switch-manager — design notes

## Language & build

**Bash.** No compile step. `install.sh` symlinks every executable regular file
in this directory (except the verb scripts, `README.md`, and `test-*.sh`) into
`/home/tappaas/bin/`, idempotently via `ln -sfn`. `update.sh` `exec`s
`install.sh`.

Linked entry points:

- `switch-manager` — the main `switch-manager` reconciler (the file is named
  `switch-manager` on disk; the `switch-manager` name is its primary CLI).
- `setup-switches.sh` — interactive registration helper.

> Note: the binary's internal name and usage text still say `switch-manager`;
> it is in the controller layer and behaves as a controller (it drives real
> switch hardware).

## Internal structure

State lives in two JSON files in the config directory:

- `switch-configuration-actual.json` — inventory + the live/applied VLAN config.
- `switch-configuration-desired.json` — regenerated each run from `actual`'s
  topology and the active VLAN set; never hand-edited.

Inventory mutations are atomic `jq` rewrites of `actual.json`. The active VLAN
set (the trunk set for node uplinks) is read from `zones.json`.

### Vendor-plugin model

Vendor automation lives in `network/scripts/plugins/<vendor>.sh`, with
`manual.sh` as the fallback. The plugin directory is overridable via the
`PLUGIN_DIR` env var (used by tests to supply stub plugins). For each switch the
controller selects a plugin by sourcing each plugin and asking
`plugin_supports <vendor>`; a switch marked `managed:manual` always uses
`manual.sh` even if its brand has a real plugin. The plugin exposes
`plugin_interrogate` (read live config) and `plugin_apply` (push VLAN changes);
`manual.sh` instead prints the steps for the operator.

### Parking (#853)

A parked port is a record `{parked: true, zone}` with no `type`: desired makes
it an access port on the zone's VLAN, so delta, apply and confirm treat it as
any access port (delta also counts a trunk that should be an access port as a
change). `interrogate` parks (`park_unrecorded`) only ports with no record, a
reported link of `down`, not disabled and outside any aggregate — a port with
a link may be a node uplink not yet registered. `update-port --park` and
`remove-port` go through `park_port`: the plugin's `plugin_apply` is handed a
desired holding only that port (`SWITCH_DESIRED`, which the UniFi plugin reads
instead of the site's desired; ports it does not name keep their override), and
the record changes after the switch has it. The default profile is never
restored (README, *Parked ports*).

### LAG members follow their lead (#854)

`LAG_LEADS_JQ` (`lag_leads`) is the one rule for which port leads an
aggregate: a port declared in a LAG follows the lowest-numbered port of that
LAG; an unrecorded port the switch reports inside an aggregate follows the port
that lists it in its live members; a recorded port outside any declared LAG
follows nothing (an aggregate the switch still has there is taken apart by the
next apply). `interrogate`, `lag set`/`remove` write it to `actual` as
`lagLead`; `update-desired` and `list-ports` re-derive it, so a stale record
cannot mislead them. A follower's desired record has no mode or VLANs,
`delta` skips it, `confirm` leaves its live VLANs as read, and the UniFi plugin
never gives it an override.

### Five-verb reconcile

`reconcile` runs `interrogate → update-desired → delta → apply → confirm`. With
`--apply` it auto-confirms after a plugin push; for manual switches it records
the *intended* config in `actual.json` and tells the operator which VLANs to tag
by hand. The exit code reflects whether changes/warnings remain pending so CI
can gate on convergence.

## How a manager calls it

The network manager (owner of `zones.json`) calls `switch-manager reconcile
[--apply]` so the physical switch VLANs track the declared zones. The manager
provides no per-device logic — the controller and its plugins own that.

## Tests

`test.sh` runs the co-located `test-switch-manager.sh` and
`test-setup-switches.sh` (offline; plugins stubbed via `PLUGIN_DIR`), exiting
non-zero on failure.

## Pending / not yet implemented

- **Vendor plugins are limited.** Only `unifi.sh` (full automation) and
  `manual.sh` (operator-applied fallback) exist in
  `network/scripts/plugins/`. Any other brand falls through to `manual.sh`, so
  `apply` prints instructions rather than programming the switch.
- **Device-arch brands** (e.g. MikroTik) are referenced in `setup-switches.sh`
  as a management mode but have no plugin yet — they are effectively manual
  until a plugin lands.
