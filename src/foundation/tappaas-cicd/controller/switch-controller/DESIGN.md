# switch-controller — design notes

## Language & build

**Bash.** No compile step. `install.sh` symlinks every executable regular file
in this directory (except the verb scripts, `README.md`, and `test-*.sh`) into
`/home/tappaas/bin/`, idempotently via `ln -sfn`. `update.sh` `exec`s
`install.sh`.

Linked entry points:

- `switch-controller` — the main `switch-manager` reconciler (the file is named
  `switch-manager` on disk; the `switch-controller` name is its primary CLI).
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

### Five-verb reconcile

`reconcile` runs `interrogate → update-desired → delta → apply → confirm`. With
`--apply` it auto-confirms after a plugin push; for manual switches it records
the *intended* config in `actual.json` and tells the operator which VLANs to tag
by hand. The exit code reflects whether changes/warnings remain pending so CI
can gate on convergence.

## How a manager calls it

The network manager (owner of `zones.json`) calls `switch-controller reconcile
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
