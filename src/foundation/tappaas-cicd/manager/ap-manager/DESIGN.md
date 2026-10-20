# ap-manager — design notes

## Language & build

**Bash.** No compile step. `install.sh` symlinks every executable regular file
in this directory (except the verb scripts, `README.md`, and `test-*.sh`) into
`/home/tappaas/bin/`, idempotently via `ln -sfn`. `update.sh` `exec`s
`install.sh`.

Linked entry points:

- `ap-manager` — the main reconciler (named `ap-manager` internally; its
  usage text and messages still use the `ap-manager` name).
- `ap-manager` — compatibility alias symlink to `ap-manager` (to be dropped
  at a later cutover).
- `setup-wlan-secrets.sh` — interactive SSID-name + passphrase helper.

## Internal structure

AP inventory and SSIDs live under the `accessPoints` key of the **same**
desired/actual state files the switch controller uses
(`switch-configuration-desired.json` / `switch-configuration-actual.json`), so
the switch and AP planes share one topology view. Mutations are atomic `jq`
rewrites. The active VLAN set and per-zone SSID/VLAN come from `zones.json`.

### Vendor controllers (ADR-035 D4)

Vendor automation is a controller answering the `ap/1` verbs, listed in
`config/control-plane.json` with `ap-manager` in its `plugsInto` and found
through `lib/controller-lib.sh`. Per AP the manager picks the controller that
drives its vendor: `ap-interrogate --ap` reads live AP state, `ap-apply --ap`
pushes SSID/VLAN changes. A brand no controller drives gets the built-in
manual controller, which prints the steps for the operator.

### Five-verb reconcile + validations

`reconcile` runs `update-desired → interrogate → delta → apply → confirm`. The
`delta` step also validates the wiring: every zone that declares an `SSID` must
be broadcast by some AP, and each AP's uplink switch port must carry every one
of that AP's SSID VLANs (cross-checked against the switch config). Failures are
emitted as warnings and reflected in the exit code so a manager/CI can gate on
them.

## How a manager calls it

The network manager (owner of `zones.json`) calls `ap-manager reconcile
[--apply]` so the wireless SSID→VLAN mapping tracks the declared zones. The
controller and its plugins own all per-device logic.

## Tests

`test.sh` runs the co-located `test-ap-manager.sh` and
`test-setup-wlan-secrets.sh` (offline; plugins/fixtures injected via env), and
exits non-zero on failure.

## Pending / not yet implemented

- **Vendor controllers are limited.** Only `unifi-controller` (the Community `unifi-os`
  module) and the manual
  fallback exist. Any other AP brand falls through to manual, so `apply` prints instructions rather than programming the AP.
- The validations in `delta` rely on the AP's `link` (uplink switch/port) being
  recorded; an AP without a linked uplink cannot have its uplink-VLAN coverage
  cross-checked.
