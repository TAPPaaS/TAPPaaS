# cluster/assets

Vendored binary artifacts used during Proxmox node provisioning.

## r8127-dkms_11.015.00-1_all.deb

Realtek **RTL8127** 10GbE DKMS driver, vendored so a node can be fixed/bootstrapped
offline (the RTL8127 is the only wired NIC on the Minisforum MS-S1 MAX, and the
in-tree `r8169` driver drops it on warm reboot — see `setup-realtek-nic.sh` and
issue #308 / the node hardware-quirk section in `../README.md`).

| | |
|---|---|
| Version (tag) | `11.015.00-1` |
| File | `r8127-dkms_11.015.00-1_all.deb` |
| SHA256 | `b946bf2f72fd82f95640ed82397b17475be008ec145def3565e4a1996777ccff` |
| Source | https://github.com/minisforum-repo/r8127-dkms/releases/tag/11.015.00-1 |
| Arch | `all` (DKMS source package — builds against the running kernel's headers) |

`setup-realtek-nic.sh` prefers this vendored copy and verifies the SHA256 before
installing; if absent it falls back to downloading the same asset from the URL above.

### Updating the driver

```bash
ver=<new-tag>            # e.g. 11.016.00-1
cd src/foundation/cluster/assets
curl -fSLO "https://github.com/minisforum-repo/r8127-dkms/releases/download/${ver}/r8127-dkms_${ver}_all.deb"
sha256sum "r8127-dkms_${ver}_all.deb"     # record below + in setup-realtek-nic.sh
```
Then update `R8127_DEB` / `R8127_SHA256` in `../setup-realtek-nic.sh` and this file,
and remove the old `.deb`.
