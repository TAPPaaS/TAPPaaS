# #889 — an SSID is site-wide, owned by ap-manager, bound to a zone

Working survey and checklist for #889. Today a WiFi network is three half-records:

1. the zone's `SSID` in `zones.json` — written only by the interactive
   `setup-wlan-secrets.sh`; not in `zones-fields.json`, so `network-manager modify`
   and the console cannot write it, and `ap-manager delta` keeps warning about the
   template placeholder;
2. the passphrase in `~/.wlan-secrets.txt` (0600, `<SSID>=<passphrase>`);
3. one `accessPoints{<ap>}.ssids{<ssid>}` entry per access point in
   `switch-configuration-desired.json` (`ap-manager ssid <ap> add …`), so the same
   network is declared once per AP.

A changed passphrase for an SSID an AP already broadcasts is never pushed: `apply`
only calls the vendor controller for an AP whose delta has a change, and a
passphrase is not part of the delta.

Decision (operator, 2026-10-26): an SSID is one site-wide object, owned by
ap-manager, broadcast by every access point; it belongs to exactly one zone (the
VLAN it bridges to), and the zone shows which SSID it carries.

## Survey: every reader and writer, and what each becomes

### The zone's `SSID` field (`zones.json`)

| Who | Reads / writes | Becomes |
|---|---|---|
| `setup-wlan-secrets.sh` (`set_zone_ssid`) | writes `.[$zone].SSID` with jq | no longer writes zones.json: a placeholder zone's name is chosen with `ap-manager ssid add`, which the script runs for it |
| `ap-manager validate()` via `wlan-lib.sh wlan_zones` | reads (active zones with an SSID; placeholder warning; "no AP broadcasts it") | reads it against the site-wide list: a zone naming an SSID the list does not hold, or held for another zone, is a warning; the placeholder warning stays only while no site-wide SSID is recorded for the zone |
| `ap-manager _ssid_add` | — (takes `--zone`, writes nothing to the zone) | `ssid add/modify/remove` write it through network-manager (below) |
| network-manager `types.ts` `SSID?: string` | type only | unchanged |
| network-manager `modify --set SSID=…` | refused today as "not a field zones-fields.json declares" | refused as `manual`, with a note naming the ap-manager verbs |
| network-manager `show` / `list --json` | prints the zone as stored | unchanged — shows `SSID` |
| opnsense-controller `zone_manager.py` (`ssid=data.get("SSID")`) | parsed, unused for rules | unchanged |
| `network/test.sh` Deep B | writes `.swdeepA.SSID` with jq, then `ssid testap add` | uses the site-wide `ssid add`, which writes the field |
| ui `setup.ts` (`wifi` step input `zones[].ssid`) | reads | unchanged; the step's "served" test reads the site-wide SSIDs |
| ui `wizards.ts` `wifiZones().declared` | reads | unchanged (shown when no site-wide SSID is on the zone) |
| ui `Zones.tsx` zone card | does not show it | an `SSID` row, read-only, linking to the WiFi step |
| template `network-manager/zones.json` | `<HOME_SSID>` … placeholders | unchanged (a placeholder is "not chosen yet") |

### The per-AP `accessPoints{}.ssids{}`

| Who | Reads / writes | Becomes |
|---|---|---|
| `ap-manager ssid <ap> add/remove/list` | writes / reads | aliases of the site-wide verbs for one release (below) |
| `ap-manager update-desired` | re-tracks `.vlan` from the zone | **derives** every AP's `ssids{}` from the site-wide list (see "derived view") |
| `ap-manager compute_delta`, `validate`, `cmd_list`, `cmd_show` | read | read the derived view; `delta` adds passphrase and settings changes |
| `ap-manager confirm` | copies desired `accessPoints` into actual | also clears the `passphraseChanged` markers |
| `wlan-lib.sh wlan_ssid_count` (the ceiling) | reads | unchanged — counts the derived view |
| UniFi plugin `plugin_ap_apply` (Community `unifi-os`) | reads `.accessPoints[$ap].ssids` from desired | unchanged for now: it reads the derived view (see "UniFi plugin") |
| UniFi plugin `plugin_ap_interrogate` | writes actual's per-AP `ssids` | unchanged — actual stays per AP |
| switch-manager (line ~950), switch-controller `main.ts` (auto-register APs) | preserve `.ssids` (or `{}` for a new AP) | unchanged; a new AP gets its derived SSIDs at the next `update-desired` |
| network-manager `topology.ts` (`accessPoints[].ssids`) | reads | unchanged — the AP panel lists what the AP broadcasts |
| ui `reads.ts` (`ap-manager list --json`), `setup.ts`, `wizards.ts`, `Wifi.tsx`, `Setup.tsx`, `Day2.tsx`, `SidePanel.tsx` | read per AP | read `ap-manager ssid list --json` (site-wide) where they mean "the networks"; the AP panel keeps the per-AP view |
| `switch-configuration-schema.json` | `accessPoint.ssids` required | `ssids` at the top level (the site-wide list); `accessPoint.ssids` documented as derived, no longer required |
| migration 0021 fixtures | carry `ssids` | unchanged |

### The secrets file (`~/.wlan-secrets.txt`)

| Who | Reads / writes | Becomes |
|---|---|---|
| `setup-wlan-secrets.sh` (`get/set/del/has_secret`) | reads, writes | the helpers move to `wlan-lib.sh` (one set of rules: split on the first `=`, 0600, temp file then rename); the script sets a passphrase with `ap-manager ssid set-passphrase` |
| `ap-manager ssid set-passphrase` | — | new writer: stdin or `--file`, never an argument; 8–63 characters, no newline; marks the SSID `passphraseChanged` |
| `ap-manager ssid list` | — | reads which SSIDs have one (never the value) |
| `ap-manager ssid remove` | — | drops the SSID's line |
| UniFi plugin `_unifi_wlan_passphrase` | reads | unchanged |
| ui `secrets.ts` `wlan` spec (`writeSecret`) | writes the file directly | the route runs `ap-manager ssid set-passphrase <ssid>` with the passphrase on stdin (so the SSID is marked); GET keeps reading key names |
| ui `secrets.ts` `secretStatus` | reads key names | unchanged |
| `tappaas-cicd.nix` (comment) | — | unchanged |

### The wizard's secrets route (`POST /api/v1/secrets/wlan`)

| Who | Becomes |
|---|---|
| `server.ts secretsApi` | for `wlan`: validate `{ssid, passphrase}` as today, then run `ap-manager ssid set-passphrase <ssid>` with the passphrase on stdin; the SSID must be declared site-wide (400 with ap-manager's reason otherwise). Logged and recorded in Activity by SSID only. `acme-dns` and `unifi` unchanged. |
| `run.ts` | a stdin-taking runner beside `runAsync` (argv array, no shell, stdin written then closed) |
| `Wifi.tsx` | the form posts after `ssid add` (the SSID must exist to be marked) |

## The site-wide data shape

`switch-configuration-desired.json` gets one top-level `ssids{}`:

```json
"ssids": {
  "rossen-home": {
    "zone": "home",
    "security": "wpa2-personal",
    "radius": "corp-radius",          // enterprise only
    "captive": true,                  // absent = false
    "disabled": true,                 // absent = broadcast
    "broadcastOn": "all",             // or ["Nano HD", "ap-loft"]; absent = "all"
    "passphraseChanged": true         // set by set-passphrase, cleared by confirm
  }
}
```

- The VLAN is not stored: it is the zone's `vlantag`, read when the view is derived.
- `broadcastOn` absent or `"all"` means every AP in the inventory, including one
  added later. A list names the APs that broadcast it (the per-AP opt-out).
- `passphraseChanged` is a marker, not a secret. `delta` turns it into a
  `ssid-passphrase` change on every AP that broadcasts the SSID; `confirm` clears it.

### The derived per-AP view

`accessPoints{<ap>}.ssids{}` stays, **written only by ap-manager** from the site-wide
list (each SSID whose `broadcastOn` includes the AP), in the shape it had:
`{vlan, zone, security, enabled, radiusServer?, captivePortal?}`. Every ap-manager
command that changes the list or the inventory re-derives it, and so does
`update-desired`. Why keep it: the vendor controllers (the UniFi plugin in the
Community repository), the topology, the console's AP panel and the ceiling all
read an AP's SSIDs there, and `delta` compares it with the interrogated per-AP
`actual`. Hand edits there are overwritten at the next derive.

## Ownership of the zone's `SSID`

`zones-fields.json` declares `SSID` (string, `changeClass: manual`, the note naming
`ap-manager ssid add|modify|remove`). `network-manager modify --set SSID=…` is
refused like `state` and `environment`, naming the verbs.

network-manager is the only writer of `zones.json`; ap-manager writes the field
through a network-manager verb made for it, `network-manager set-ssid <zone>
<ssid> | --unset`, as environment-manager writes `environment` through `bind`. Its
help says it is ap-manager's writer. ap-manager:

- `ssid add <s> --zone z`: refuses when z carries another site-wide SSID (one SSID
  per zone, since the field is one name); a placeholder or a name the list does
  not hold is replaced;
- `ssid modify <s> --zone z2`: unsets the old zone's field, sets z2's;
- `ssid remove <s>`: unsets the zone's field.

## ap-manager verbs

```
ssid add <ssid> --zone <z> --security <sec> [--radius <r>] [--captive] [--disabled]
                [--broadcast-on all|<ap>,<ap>…]
ssid modify <ssid> [--zone <z>] [--security <sec>] [--radius <r>|--unset radius]
                [--captive|--no-captive] [--disabled|--enabled] [--broadcast-on …]
ssid remove <ssid>
ssid list [--json]                  zone, VLAN, security, broadcast, passphrase set/changed
ssid set-passphrase <ssid> [--file <path>]   stdin when no --file; never an argument
```

Old forms, kept for one release and saying so on stderr:

| Old | Now |
|---|---|
| `ssid <ap> add <s> --zone … [--vlan n]` | `ssid add` (or `modify` when it exists); `--vlan` other than the zone's is refused — the VLAN is the zone's. Broadcasts on every AP. |
| `ssid <ap> remove <s>` | stop broadcasting on `<ap>`: drops it from `broadcastOn`; when no AP is left (or `<ap>` is the only AP) the SSID is removed |
| `ssid <ap> list` | the SSIDs `<ap>` broadcasts, the same object shape as before |

An AP whose name is one of `add modify remove list set-passphrase` cannot use the
old form (it is read as the new verb). The console manifest (`ui/manifest/bash-verbs.json`,
ap-manager's `--help --json` answer) gets the new verbs; the old entries stay,
marked as aliases.

## Reconcile and the UniFi plugin

- `update-desired` derives the per-AP view (VLAN from the zone).
- `delta` per AP: `create-ssid`, `ssid-vlan` (as today), `ssid-settings` (security
  or enabled differ from actual), `ssid-passphrase` (marker set), and removals.
- `apply` calls the controller for each AP with a change — so a passphrase change
  reaches the plugin, which already PUTs `x_passphrase` on an existing WLAN.
- `confirm` (run when every AP applied, or by the operator after manual steps)
  copies the state and clears every `passphraseChanged`.
- Validations: an enabled SSID no AP broadcasts; a site-wide SSID whose zone does
  not exist or is not Active; a zone whose `SSID` the list does not hold (with the
  `ssid add` to run); the placeholder warning only for a zone with no site-wide
  SSID; the ceiling and uplink checks over the derived view, as today.

### What the UniFi plugin must change (Community `unifi-os`, not edited here)

1. **Read the site-wide list.** `plugin_ap_apply` reads
   `.accessPoints[$ap].ssids`; that keeps working (the derived view), but the plugin
   should read `.ssids{}` and `.zone`→VLAN when it converges the controller, since
   UniFi WLANs are controller-wide — one PUT per SSID instead of one per AP.
2. **Honour `broadcastOn`.** It creates every WLAN with `ap_group_mode: "all"` on
   the default AP group, so an AP opted out still broadcasts it, and `interrogate`
   reports it on every AP (a removal `delta` keeps showing). For a list it should
   use (or create) an AP group of those devices and set `ap_group_ids` to it.
   Until then ap-manager warns when an opt-out names a UniFi AP.
3. **Field names.** Site-wide uses `radius`, `captive`, `disabled`; the derived view
   keeps `radiusServer`, `captivePortal`, `enabled` for the plugin.
4. **Passphrase.** No change needed: it already sends `x_passphrase` when the
   secrets file has one; ap-manager now calls it when the marker is set.
5. Its warning text names `setup-wlan-secrets.sh`; it should name
   `ap-manager ssid set-passphrase <ssid>`.

## Migration 0025 — per-AP entries become the site-wide list

`0025-ssids-become-site-wide.sh`, touches `switch-configuration-desired.json` only.

- For every `accessPoints{ap}.ssids{s}`: group by SSID name. The settings compared
  are `zone`, `security`, `radiusServer`, `captivePortal`, `enabled`; `vlan` is
  dropped when it is the zone's `vlantag` (and refused when it is not — the VLAN is
  the zone's now).
- One entry per SSID in `.ssids{}`: `zone`, `security`, `radius`, `captive`,
  `disabled`; `broadcastOn` `"all"` when every AP declared it, else the list of the
  APs that did.
- Refuses, changing nothing, two APs declaring the same SSID with different
  settings (naming the SSID, the APs and the differing fields), an SSID with no
  zone, a VLAN other than its zone's, and a `.ssids` already present that disagrees.
- The per-AP `ssids` stay (they are the derived view); ap-manager's next derive
  writes the same content.
- Does not touch `zones.json` (a migration writes no manager-owned field through a
  manager; the validation names the zone whose `SSID` differs, with the command).
- Idempotent, `--check`, backup in `.migrations/backup/0025/`. Fixture test with two
  APs declaring the same SSIDs with the same settings, one AP-only SSID, and a
  conflicting case.

## Console

- Zone card: an `SSID` row, read-only, "set from the WiFi step" linking to
  `/setup/day2#wifi-<zone>`.
- Day 2 WiFi form: 1 the network (SSID name, how clients join), 2 `ap-manager
  ssid add` (or `ssid modify` for the same name, or `ssid remove` + `add` for a new
  name), 3 the passphrase through the secrets route (`set-passphrase`), 4 the
  reconcile, 5 the result. No AP choice: every AP broadcasts it.
- Setup's WiFi step and its table: the site-wide SSIDs with zone, security and
  passphrase state (set / changed, not pushed yet / not set).
- AP panel: the SSIDs that AP broadcasts (the derived view), with the link to the
  WiFi step.

## Steps (one commit each)

1. this survey;
2. schema `SSID` + `network-manager set-ssid` + the refusal;
3. ap-manager site-wide verbs, aliases, manifest, README;
4. reconcile (derive, delta, confirm) and the plugin note;
5. migration 0025 + fixture test;
6. console;
7. docs (ZONES.md, ap-manager README, ADR-008 note, DATAMODEL, migrations README) — `close #889`.
