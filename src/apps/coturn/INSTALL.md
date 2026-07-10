# coturn — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. `nextcloud` is installed (`nextcloud:fileservice` dependency) — coturn serves Nextcloud
   Talk and the installer fails without it.
2. The `dmz` zone has internet egress — the installer detects the public (post-NAT) IP from
   the coturn VM via external echo services.

> To deviate from the defaults in `./coturn.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh coturn

## Post-install

1. Configure OPNsense manually (the installer prints a reminder; not automated):
   - NAT rule: WAN:3478 (UDP+TCP) -> coturn DMZ IP:3478
   - NAT rule: WAN:49152-65535 (UDP) -> coturn DMZ IP:49152-65535 (relay ports)
   - DNS A record: the module's public domain -> public WAN IP
2. Only if the installer warned that it could not detect the public IP (DMZ egress blocked):
   set it manually on the coturn VM, then restart the service:

       ssh tappaas@coturn.dmz.internal
       sudo sed -i 's/^COTURN_EXTERNAL_IP=.*/COTURN_EXTERNAL_IP=<YOUR-WAN-IP>/' \
         /etc/secrets/coturn.env
       sudo systemctl restart coturn.service

## Verification

    test-module.sh coturn

| Check | Expected |
|-------|----------|
| SSH to `coturn.dmz.internal` | Connection succeeds |
| `systemctl is-active coturn` | `active`; `turnserver` process running |
| TCP port 3478 | Open from tappaas-cicd |
| UDP port 3478 | Answers a STUN binding request |
| `/etc/secrets/coturn.env` | Exists, mode 0600, `COTURN_SECRET` is 64 hex chars |
| `/run/coturn/turnserver.conf` | Generated at service start, contains `denied-peer-ip` entries |
| `coturn-backup-secrets.timer` | Active (skip if not yet started) |
| `COTURN_EXTERNAL_IP` | Set in `/etc/secrets/coturn.env` (else external calls fail) |

## Troubleshooting

**`install-module.sh` exits with a dependency error**
`nextcloud` is not installed. Install it first.

**Talk calls fail to connect across NATs**
Clients cannot reach UDP 3478, or the shared secret is out of sync.

    ssh tappaas@coturn.dmz.internal "sudo systemctl status coturn; sudo ss -lunp | grep 3478"
    # confirm the secret on the VM matches the management plane copy:
    ssh tappaas@coturn.dmz.internal "sudo cat /etc/secrets/coturn.env"
    cat /home/tappaas/secrets/coturn.env   # on tappaas-cicd

`COTURN_SECRET` on the coturn VM must match the management-plane copy that Nextcloud
Talk and `nextcloud-hpb` consume.

**Calls from external networks fail while internal calls work**
`COTURN_EXTERNAL_IP` is unset/wrong, or the WAN NAT rules (3478 and the 49152-65535
relay range) are missing on OPNsense. See Post-install.
