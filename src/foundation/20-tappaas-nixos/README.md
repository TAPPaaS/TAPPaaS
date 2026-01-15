# TAPPaaS NixOS setup

## Introduction

Setup runs in these macro steps:

- set up a minimal NixOS with cloud-init support 
- convert/create a NixOS template from this

## Create a minimum NixOS

run the following script as root from the proxmox console

```bash
BRANCH="main"
curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/20-tappaas-nixos/tappaas-nixos.json >~/tappaas/tappaas-nixos.json
~/tappaas/Create-TAPPaaS-VM.sh tappaas-nixos
```

in the console of VM 8080 install nixos

- use the username "tappaas", give it a strong password, preferably same pwd as root on the tappaas node.
- for graphical desktop select: no desktop
- allow use of unfree software
- select erase disk and no swap in disk partition menu
- keep 'encrypt disk' unselected
- review summary and select install on lower right bottom (maximize window)
- start the install it will take some time
  - it may appear to be stalled at 46% for minutes - be patient!
  - toggle log to see detailed progress
- wait for the message: "all done"
- keep 'Restart now' UNchecked
- select Done at lower right bottom to finish installation without reboot
- Shutdown the VM8080 by selecting and confirm 'VM8080 (tappaas-nixos) - Shutdown' in PVE GUI
- in PVE console, select Hardware -> CD/DVD Drive (IDE3)
  - Edit --> select 'Do not use any media' to detach the iso
- select >_ Console, start the VM
- when the VM is booted:
  - nixos login: tappaas
  - Password: the password you created in step 1 (tappaas node root pwd?!] 

In the console of the VM do the following (and sorry, nixos do not support cut and paste and ssh ot of the box, so some typing is required)

```bash
BRANCH="main"
sudo curl -fsSL  https://raw.githubusercontent.com/TAPPaaS/TAPPaaS/$BRANCH/src/foundation/20-tappaas-nixos/tappaas-nixos.nix  >tappaas-nixos.nix
sudo cp tappaas-nixos.nix /etc/nixos/configuration.nix
sudo nixos-rebuild switch

sudo reboot

```

Clean the newly created NIXOS VM before turning it into a template

After reboot, access the VM via the PVE console and login:
UID = root (note, tappaas user is disables after rebuild!) 
PWD = the password you created in step 1 (same as tappaas node root pwd?!] 

you should see: [root@tappaas-nixos:~] 

```bash
sudo sh -eux <<'CLEAN'
# Repeat safe cleanup (ensure minimal store size)
for u in $(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd); do
  sudo -u "$u" nix profile wipe-history --older-than 30d || true
done
nix store gc
nix store optimise

# Vacuum systemd journal (remove old logs)
journalctl --vacuum-time=1s || true

# Remove all log files (reduce image size)
rm -rf /var/log/* || true

# Reset machine-id (new clones get unique ID)
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true

# Remove SSH host keys (regenerated on first boot)
rm -f /etc/ssh/ssh_host_* || true

# Reset random seed (fresh entropy for clones)
rm -f /var/lib/systemd/random-seed || true

# Clear user and root caches (avoid leftover data)
rm -rf /root/.cache/* 2>/dev/null || true
find /home -maxdepth 2 -type d -name ".cache" -exec rm -rf {} + 2>/dev/null || true

shutdown -h now
CLEAN
```

## Convert to template

[optional] reboot the VM and test it still work

then from the Proxmox tappaas console do a template generation from the VM. 

```bash
qm stop 8080
qm template 8080
```

or do it from the proxmox gui
