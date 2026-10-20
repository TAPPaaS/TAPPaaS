# unifi-controller — design

- **Contracts:** `switch/1` and `ap/1` (ADR-035 D4), declared in `contract.json`.
- **Layout:** `unifi-controller` is the entry point; `unifi.sh` holds the vendor logic as
  `plugin_*` functions; `lib/controller-shim.sh` maps the contract's verbs onto them
  (`interrogate --controller` → `plugin_controller_interrogate`, `apply` →
  `plugin_apply` with `SWITCH_DESIRED`, `ap-interrogate` → `plugin_ap_interrogate`,
  `ap-apply` → `plugin_ap_apply`, `check-access` → `plugin_check_access`).
- **One login per run:** the manager passes `--session DIR`; the cookie jar and the CSRF
  token are kept there for the rest of its run.
- **API notes** (UniFi OS / Network 10.x): port overrides on the device
  (`port_overrides`): access → `forward: native`; trunk → `forward: customize` with
  `tagged_vlan_mgmt: custom` and the excluded networks (without `tagged_vlan_mgmt` the
  controller silently keeps `forward: all`); a LAG is `op_mode: aggregate` on the lead
  port, and the apply waits until the device reports it settled. API payloads reach `jq`
  through files, never arguments (a site's device list passed Linux's 128 KiB limit).
- **Tests:** `test-unifi-controller.sh` (the vendor logic over fixtures) and `test.sh`
  (the contract verbs); neither calls a controller.
