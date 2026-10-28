# ap-manager

The **wireless access-point network controller** for TAPPaaS. It owns the site's
WiFi networks (SSIDs) and keeps every access point broadcasting them on the right
VLAN, without manual AP configuration.

An **SSID is site-wide**: declared once, broadcast by every access point (unless
it names the ones that should), and bridged to exactly **one zone** — devices
that join it land on that zone's VLAN, with its rules. The zone shows which SSID
it carries in its `SSID` field in `zones.json`; ap-manager sets that field, so
the SSID, its zone and the access points stay in step. A zone carries one SSID.

The SSIDs live in `ssids` in `switch-configuration-desired.json`, beside the AP
inventory under `accessPoints` — the same desired/actual files the
[`switch-manager`](../switch-manager/) uses. Each AP's own `ssids` there is
written by ap-manager from the site-wide list (the vendor plugins read it); do
not edit it by hand.

`managed:auto` APs are programmed through a **vendor plugin**; otherwise the
manual plugin prints the steps and you apply them by hand, then `confirm`.

## CLI: `ap-manager`

A compatibility alias `ap-manager` points at the same binary.

```
ap-manager <command> [args]
```

### Inventory commands

| Command | Purpose |
|---------|---------|
| `add <name> --vendor <v> [--ip <ip>] [--model <m>] [--location <name>] [--description <d>]` | Register an AP. `--location` is one of the site's locations (`site-manager location list`); unset, the primary one. Free text goes in `--description`. |
| `modify <name> [--location <name>] [--description <d>] [--model <m>] [--ip <ip>] [--unset location,description]` | Change the AP's own record in `desired.json`; nothing on the AP changes. |
| `validate` | Every AP's `location` is one of the site's locations. |
| `remove <name>` | Remove an AP. |
| `list [--json]` | List access points, with their uplink port and SSIDs. |
| `show <name>` | Show one AP. |
| `link <ap> --switch <switch> --port <port>` | Associate an AP's uplink with a switch port. |

### SSID commands

| Command | Purpose |
|---------|---------|
| `ssid add <ssid> --zone <zone> --security <sec> [--radius <srv>] [--captive] [--disabled] [--broadcast-on all\|<ap>,…]` | Declare a WiFi network. It bridges to the zone's VLAN and sets the zone's `SSID` (replacing a template placeholder such as `<HOME_SSID>`). Refused when the zone already carries another SSID. Broadcast by every access point unless `--broadcast-on` names some. |
| `ssid modify <ssid> [--zone <zone>] [--security <sec>] [--radius <srv>] [--unset radius] [--captive\|--no-captive] [--disabled\|--enabled] [--broadcast-on all\|<ap>,…]` | Change it. `--zone` moves it: the old zone's `SSID` is cleared and the new one's set. |
| `ssid remove <ssid>` | Remove it, with the zone's `SSID` and its passphrase. The next `reconcile` lists it for removal on each access point. |
| `ssid list [--json]` | Every SSID: its zone and VLAN, security, the access points that broadcast it, and its passphrase — `set`, `changed` (not pushed yet), `not set`, or `not needed` (open, enterprise). Never the passphrase itself. |
| `ssid set-passphrase <ssid> [--file <path>]` | Store the WPA passphrase (8–63 characters) for a `wpa2-personal` or `wpa3-personal` SSID. It is read from **stdin** (asked twice, hidden, at a terminal) or the first line of `--file` — **never an argument**, which would land in the shell history and the process list. The SSID is marked changed, so the next `reconcile --apply` pushes the new passphrase to every access point that broadcasts it. |

`--security` is one of: `open`, `wpa2-personal`, `wpa3-personal`,
`wpa2-enterprise`, `wpa3-enterprise`. `--radius` goes with the enterprise ones.

The passphrase lives only in a `0600` secrets file (`~/.wlan-secrets.txt`, one
`<SSID>=<passphrase>` line each, `WLAN_SECRETS` moves it), which the vendor
plugins read at apply time; never in a config.

```bash
echo 'correct horse battery' | ap-manager ssid set-passphrase rossen-home
ap-manager ssid set-passphrase rossen-home --file /run/user/1000/psk
```

**The per-AP forms, for this release.** `ssid <ap> add …` declares the SSID
site-wide (or updates it when it exists; a `--vlan` other than the zone's is
refused), `ssid <ap> remove <ssid>` stops `<ap>` broadcasting it (and removes it
when no access point would), `ssid <ap> list` shows what `<ap>` broadcasts. Each
says on stderr which site-wide verb replaces it. An access point named like a
verb (`add`, `list`, …) cannot use them.

### Reconciliation commands (five-verb provider flow)

| Command | Purpose |
|---------|---------|
| `update-desired` | Track each SSID's VLAN from its zone (`zones.json` → desired). |
| `interrogate` | Pull live AP state into `actual.json` (via the vendor plugin). An AP that cannot be read is left unchanged, the plugin's reason is shown (e.g. `UniFi login failed: HTTP 401 — …`), and the command exits 1. |
| `delta` | Show desired-vs-actual differences plus zone/SSID/uplink validations: an Active zone's SSID that no AP broadcasts (a template placeholder such as `<HOME_SSID>` is no SSID and is not mentioned), an AP over its SSID ceiling, an uplink port missing an SSID's VLAN. |
| `apply` | Push the delta via the vendor plugin; the manual plugin prints the steps. |
| `confirm` | Record the applied state into `actual.json`. |
| `reconcile [--apply]` | Run all five in order; `--apply` pushes and confirms, otherwise it is a dry-run. If any AP could not be read, the delta is shown but **nothing is applied** (exit 1) — it would be computed from stale state. |

### Examples

```bash
# Register an AP, link its uplink, and a guest WiFi on the guest zone's VLAN:
ap-manager add ap-living --vendor unifi --ip 10.0.10.21
ap-manager link ap-living --switch core --port 5
ap-manager ssid add rossen-guest --zone guest --security wpa2-personal
echo 'a passphrase for guests' | ap-manager ssid set-passphrase rossen-guest

# Dry-run, then apply:
ap-manager reconcile
ap-manager reconcile --apply
```

### SSID ceiling per AP

Every SSID beacons separately on every radio, so each one takes airtime from the
rest; vendor guidance (Ubiquiti) puts the practical limit at about **4 per
radio**. `ssid add` and `ssid modify` warn when an AP goes over its ceiling, and `delta`
counts it as a validation warning — before `reconcile --apply` creates the SSIDs.
Only enabled SSIDs count. The ceiling is 4 (`TAPPAAS_AP_MAX_SSIDS` changes the
default); an AP that should carry more sets `maxSsids` on its entry in
`switch-configuration-desired.json`. The rules shared with `setup-wlan-secrets.sh`
(placeholders, active zones, the ceiling) live in `tappaas-cicd/lib/wlan-lib.sh`.

## Setup helper: `setup-wlan-secrets.sh`

Walks the active zones whose `SSID` is still a template placeholder (or names an
SSID ap-manager does not hold), asks for the real name and how clients join, and
declares it with `ap-manager ssid add`; for a WPA-personal SSID it then asks for
the passphrase (hidden, twice) and hands it to `ap-manager ssid set-passphrase`
on stdin. It writes no file itself. A blank answer skips.

```
setup-wlan-secrets.sh          # interactively name SSIDs + set passphrases
setup-wlan-secrets.sh --list   # each WiFi zone, its SSID and whether a passphrase is set
setup-wlan-secrets.sh --help
```
