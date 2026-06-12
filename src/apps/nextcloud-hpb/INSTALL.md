# nextcloud-hpb — Installation

Only manual steps are listed here. Scripts handle everything else automatically (VM creation, NixOS rebuild, secret generation).

> **Status: Development** — the VM provisions, but the NixOS signaling config is still being finalised. Treat a successful install as "VM ready", not "signaling live".

## Prerequisites

- `nextcloud` is installed (`nextcloud:vm` dependency) and `coturn` is installed (`coturn:vm`) — HPB distributes TURN credentials from coturn.
- Verify `nextcloud-hpb.json` matches your environment (node `tappaas2`, zone `srv`).

## Install

```bash
install-module.sh nextcloud-hpb
```

## Customisation (optional)

```bash
install-module.sh nextcloud-hpb --node tappaas1 --vmid 399
```

| Flag | Default | Controls |
|---|---|---|
| `--node` | `tappaas2` | Proxmox node |
| `--zone0` | `srv` | Network zone (VLAN) |
| `--vmid` | `342` | Proxmox VM ID |

## Post-install

On first boot the VM auto-generates the signaling secret (`HPB_SECRET`) into `/etc/secrets/hpb.env`. Copy it to the Nextcloud VM at the same path so Talk registers the HPB backend:

```bash
scp tappaas@nextcloud-hpb.srv.internal:/etc/secrets/hpb.env /tmp/ \
  && scp /tmp/hpb.env tappaas@nextcloud.<zone>.internal:/etc/secrets/hpb.env
```

The `nextcloud-configure-hpb` service registers `wss://<proxyDomain>/spreed` as the Talk signaling server on the next boot.

## Verification

```bash
./test.sh nextcloud-hpb
```

Confirms the VM is up and the signaling server answers on port 8080.

## Backup and restore

Registered with Proxmox Backup Server (`backup:vm`). HPB is stateless beyond `/etc/secrets/hpb.env` — re-generated on reinstall if absent. No application data to restore.

## Upgrading

```bash
update-module.sh nextcloud-hpb
```

NixOS rebuild only; no container image to pin.

## Troubleshooting

**`install-module.sh` exits with a dependency error** — `nextcloud` or `coturn` is not installed. Install both first.

**Talk does not use the HPB (still PHP signaling)** — the secret is not on the Nextcloud VM, or the backend is not registered.
```bash
ssh tappaas@nextcloud-hpb.srv.internal "sudo systemctl status nextcloud-spreed-signaling; sudo journalctl -u nextcloud-spreed-signaling -n 30"
```
Confirm `HPB_SECRET` in `/etc/secrets/hpb.env` is identical on the HPB and Nextcloud VMs, then restart the container/service.
