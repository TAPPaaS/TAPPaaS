# coturn — Installation

Only manual steps are listed here. Scripts handle everything else automatically (VM creation, NixOS rebuild, secret generation).

## Prerequisites

- `nextcloud` is installed (`nextcloud:vm` dependency) — coturn serves Nextcloud Talk.
- Verify `coturn.json` matches your environment (node, storage, zone `dmz`). Override with flags below.

## Install

```bash
install-module.sh coturn
```

## Customisation (optional)

```bash
install-module.sh coturn --node tappaas2 --vmid 399
```

| Flag | Default | Controls |
|---|---|---|
| `--node` | `tappaas1` | Proxmox node |
| `--zone0` | `dmz` | Network zone (VLAN) |
| `--vmid` | `341` | Proxmox VM ID |

## Post-install

On first boot the VM auto-generates the shared TURN secret (`COTURN_SECRET`) and external IP into `/etc/secrets/coturn.env`. Copy that file to the Nextcloud VM at the same path so Talk can issue matching credentials:

```bash
scp tappaas@coturn.dmz.internal:/etc/secrets/coturn.env /tmp/ \
  && scp /tmp/coturn.env tappaas@nextcloud.<zone>.internal:/etc/secrets/coturn.env
```

The `nextcloud-configure-talk` service picks it up on the next boot. (`nextcloud-hpb` consumes `coturn:turn` automatically.)

## Verification

```bash
./test.sh coturn
```

Confirms the VM is up and the TURN/STUN daemon answers on UDP/TCP 3478.

## Backup and restore

The VM is registered with Proxmox Backup Server (`backup:vm`); coturn is stateless beyond `/etc/secrets/coturn.env` — re-generated on reinstall if absent. No application data to restore.

## Upgrading

```bash
update-module.sh coturn
```

NixOS rebuild only; the TURN daemon has no container image to pin.

## Troubleshooting

**`install-module.sh` exits with a dependency error** — `nextcloud` is not installed. Install it first.

**Talk calls fail to connect across NATs** — clients cannot reach UDP 3478, or the secret is out of sync.
```bash
ssh tappaas@coturn.dmz.internal "sudo systemctl status coturn; sudo ss -lunp | grep 3478"
# confirm COTURN_SECRET matches on both VMs:
ssh tappaas@coturn.dmz.internal "sudo cat /etc/secrets/coturn.env"
```
The secret in `/etc/secrets/coturn.env` must be identical on the coturn and Nextcloud VMs.
