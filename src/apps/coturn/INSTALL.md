# coturn — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. `nextcloud` is installed (`nextcloud:fileservice` dependency) — coturn serves Nextcloud
   Talk and the installer fails without it.
2. The `dmz` zone has internet egress — the installer detects the public (post-NAT) IP from
   the coturn VM via external echo services.
3. `zones.json`: `dmz.pinhole-allowed-from` lists `home` (the shipped template does) so the
   client-zone pinhole declared in `coturn.json` compiles. A site with further client zones
   adds them there and to coturn's `ingress`.

> To deviate from the defaults in `./coturn.json` (target node, storage, sizing, or the
> public name `publicDomain`), copy the json to `/home/tappaas/config` and edit it before
> installing. `publicDomain` defaults to `turn.<site domain>`.

## Install

    install-module.sh coturn

The installer: detects the WAN IP and sets `COTURN_EXTERNAL_IP`; publishes `COTURN_SECRET`
to the management plane; defaults and persists `publicDomain`; registers the split-horizon
record `publicDomain → coturn VM` in the site resolver. The dependency services create the
WAN port-forwards (`network:nat`), the firewall rules (`network:rules`) and — through the
`talk` connector — register the relay in Nextcloud Talk (`nextcloud:fileservice`).

## Post-install

1. **Public DNS record** (the only manual step): `publicDomain` (default `turn.<domain>`) →
   the public WAN IP the installer printed.
2. Only if the installer warned that it could not detect the public IP (DMZ egress blocked):
   set it manually on the coturn VM, then restart the service:

       ssh tappaas@coturn.dmz.internal
       sudo sed -i 's/^COTURN_EXTERNAL_IP=.*/COTURN_EXTERNAL_IP=<YOUR-WAN-IP>/' \
         /etc/secrets/coturn.env
       sudo systemctl restart coturn.service

3. **Test a real call from off-network.** Talk's admin page "green checkmark" only probes
   port 3478; media needs the relay range too. A call from a phone on mobile data to a
   participant inside the site is the check that counts.

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
| `nat-manager list-rules` | Two `TAPPaaS: coturn` port-forwards (3478 TCP/UDP, 49152-50151 UDP) |
| Nextcloud `occ talk:turn:list` | Lists `publicDomain:3478` (the `talk` connector) |

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
`COTURN_EXTERNAL_IP` is unset/wrong, the public A record for `publicDomain` is missing, or
the port-forwards did not apply — `nat-manager --no-ssl-verify list-rules` must show both.

**Internal calls between two zones fail while calls with an external party work**
The split-horizon record is missing (`publicDomain` resolves to the WAN IP inside the site
and the NAT does not reflect). `update-module.sh coturn` re-registers it; or check
`dmz.pinhole-allowed-from` includes the caller's zone so the `ingress` rules compiled.

**Talk has no TURN server after installing coturn alone**
The `talk` connector runs in Nextcloud's fileservice converge: `update-module.sh nextcloud`
(or `update-module.sh coturn`) re-applies it; it needs `COTURN_SECRET` in
`/home/tappaas/secrets/coturn.env`.
