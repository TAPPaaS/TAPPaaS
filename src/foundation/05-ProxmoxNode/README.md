
# Proxmox node setup

## Overview


Bootstrapping TAPPaaS foundation has not been fully automated. However some steps are scripted.

you need to do the following activities (next sections give exact instructions)

1) Install proxmox on the first TAPPaaS node
2) TAPaaSPostPVEInstall.sh: Do basic household activities on Proxmox after initial install

continue with [OPNSense](../10-OPNsense/README.md) and [TAPaaS CICD](../15-TAPPaaS-CICD/README.md) setup in


## Proxmox install:

- prepare physical hardware. see [Examples](../../Documentation/Examples/README.md) or [Hardware](../../Documentation/Architecture/Hardware.md)
- ensure you designed your basic setup [Design](../../Documentation/Installation/README.md)
- download a Proxmox VE iso installer image from: [Official Proxmox Download site](https://www.proxmox.com/en/downloads)
- create a boot USB (on windows we recommend to use [Rufus](https://rufus.ie/en/), on Linux Mint right click on .iso and select make bootable usb stick)
- boot the machine from the USB and do an install: use ZFS for the boot disk if you are having boot disk mirror.
- once it is rebooted go to management console and create the "tanks" as zfs pools (minimum is to have a tanka1). further info in [pools](./Proxmox-VE-Installer.md)
(if sufficient hw resources are available then use mirror on boot and tanka1)
- run post install script
```
curl -fsSL https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/main/src/foundation/00-ProxmoxNode/install.sh | bash
```

- You can now run the run the Proxmox helper post PVE install script (to be replaced with a dedicated script) to disable subscription nagging and updating debian and proxmox apt repositories (via the proxmox management console): 
    - Answer Yes to all questions:
    - disable enterprise and cept repositories
    - enable HA
    - Do reboot
```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
```

Now after reboot:
- check that it all looks fine!! (TODO automate check setup)
- Edit the /root/tappaas/configuration.json to reflect choices in this install


