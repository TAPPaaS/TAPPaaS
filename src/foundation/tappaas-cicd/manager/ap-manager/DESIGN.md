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
- `setup-wlan-secrets.sh` — interactive SSID-name + passphrase helper over
  `ap-manager ssid add` and `ssid set-passphrase`.

## Internal structure

AP inventory (`accessPoints`) and the site-wide SSIDs (`ssids`) live in the
**same** desired/actual state files the switch controller uses
(`switch-configuration-desired.json` / `switch-configuration-actual.json`), so
the switch and AP planes share one topology view. Mutations are atomic `jq`
rewrites.

An SSID is one site-wide entry — `{zone, security, radius?, captive?,
disabled?, broadcastOn: "all" | [ap…], passphraseChanged?}` — with no VLAN of its
own: the VLAN is its zone's `vlantag`. Each AP's `ssids{}` in desired is derived
from that list (`derive_ap_ssids`, after every change and in `update-desired`) in
the per-AP shape the vendor controllers read, `{vlan, zone, security, enabled,
radiusServer?, captivePortal?}`; `actual` keeps what each AP really broadcasts,
so `delta` stays a per-AP comparison.

The zone's `SSID` field names the SSID that bridges to it. ap-manager owns it
and writes it through `network-manager set-ssid` (zones.json has one writer); a
generic `network-manager modify --set SSID` is refused. The passphrase lives
only in the secrets file (`lib/wlan-lib.sh` holds its rules, shared with
`setup-wlan-secrets.sh`); `ssid set-passphrase` marks the SSID
`passphraseChanged`, `delta` turns the mark into an `ssid-passphrase` change on
each AP that broadcasts it, and `confirm` clears it.

### Vendor controllers (ADR-035 D4)

Vendor automation is a controller answering the `ap/1` verbs, listed in
`config/control-plane.json` with `ap-manager` in its `plugsInto` and found
through `lib/controller-lib.sh`. Per AP the manager picks the controller that
drives its vendor: `ap-interrogate --ap` reads live AP state, `ap-apply --ap`
pushes SSID/VLAN changes. A brand no controller drives gets the built-in
manual controller, which prints the steps for the operator.

### Five-verb reconcile + validations

`reconcile` runs `update-desired → interrogate → delta → apply → confirm`. The
`delta` step also validates the wiring: each active zone's `SSID` is a
site-wide SSID bridged to that zone (a template placeholder counts as no SSID
and is not mentioned), each site-wide SSID bridges to a zone
that exists, is on and names it, and is broadcast by some AP, no AP is over its
SSID ceiling, and each AP's uplink switch port carries every one of that AP's
SSID VLANs (cross-checked against the switch config). Failures are
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

- **The UniFi plugin reads the derived per-AP view** and creates every WLAN on
  the controller's "All APs" group, so an SSID's `broadcastOn` list is not
  honoured on UniFi (ap-manager warns when a list leaves a UniFi AP out). What
  the plugin must change is written down in `docs/design/889-site-wide-ssid.md`
  ("What the UniFi plugin must change").
- **Vendor controllers are limited.** Only `unifi-controller` (the Community `unifi-os`
  module) and the manual
  fallback exist. Any other AP brand falls through to manual, so `apply` prints instructions rather than programming the AP.
- The validations in `delta` rely on the AP's `link` (uplink switch/port) being
  recorded; an AP without a linked uplink cannot have its uplink-VLAN coverage
  cross-checked.
