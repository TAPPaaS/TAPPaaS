# unifi-controller

Drives UniFi switches and WiFi access points through a UniFi OS controller, for
`switch-manager` (contract `switch/1`) and `ap-manager` (`ap/1`). It reads and writes
devices only: which ports TAPPaaS manages, the desired VLANs and the inventory are the
managers'.

- **Controller architecture:** one UniFi OS controller adopts every switch and AP, so
  `interrogate --controller <name> --ip <controller>` returns all of them.
- **Credentials:** a local admin of the controller in `~/.unifi-os-credentials.txt`
  (`username=`, `password=`; no SSO or MFA), or `--credentials FILE`.
- **What it sets:** VLANs on the ports TAPPaaS annotated or parked, aggregates (the lead
  port's override), and SSIDs with their VLAN networks. It never deletes an SSID and
  leaves every other port as the switch has it.

```bash
unifi-controller describe
unifi-controller check-access --ip <controller>
unifi-controller interrogate --controller <name> --ip <controller>
unifi-controller apply --switch <name> [--desired FILE] [--changes-json JSON]
unifi-controller ap-interrogate --ap <name> --ip <controller>
```

The managers call it; an operator uses `switch-manager` and `ap-manager`. The UniFi OS
controller itself is installed by the `unifi-os` module.
