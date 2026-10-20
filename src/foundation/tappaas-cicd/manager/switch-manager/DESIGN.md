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

### Vendor controllers (ADR-035 D4)

Vendor automation is a controller: an executable answering the `switch/1`
verbs, listed in `config/control-plane.json` with `switch-manager` in its
`plugsInto`. `lib/controller-lib.sh` finds them and runs them; the manager
never sources vendor code. For each switch the manager picks the controller
whose `describe` names the switch's vendor (or that answers `supports
<vendor>`); a switch marked `managed:manual`, or a brand no controller drives,
gets the built-in manual controller, which prints the steps for the operator.
`interrogate --controller` reads every device a controller adopts,
`interrogate --switch` one standalone switch, `apply --switch` pushes its
changes. `PLUGIN_DIR` (tests) adds every `*.sh` there as a controller run
through `lib/controller-shim.sh`.

### Parking (#853)

A parked port is a record `{parked: true, zone}` with no `type`: desired makes
it an access port on the zone's VLAN, so delta, apply and confirm treat it as
any access port (delta also counts a trunk that should be an access port as a
change). `interrogate` parks (`park_unrecorded`) only ports with no record, a
reported link of `down`, not disabled and outside any aggregate — a port with
a link may be a node uplink not yet registered. `update-port --park` and
`remove-port` go through `park_port`: the controller's `apply` is handed a
desired holding only that port (`--desired`, which unifi-controller reads
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
`test-setup-switches.sh` (offline; controllers stubbed via `PLUGIN_DIR`), exiting
non-zero on failure.

## Pending / not yet implemented

- **Vendor controllers are limited.** Only `unifi-controller` (full
  automation) and the manual fallback exist. Any other brand falls through to
  manual, so
  `apply` prints instructions rather than programming the switch.
- **Device-arch brands** (e.g. MikroTik) are referenced in `setup-switches.sh`
  as a management mode but have no controller yet — they are effectively manual
  until a plugin lands.
