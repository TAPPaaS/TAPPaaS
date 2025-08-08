# Proxmox PVE Host Management Report Template

## Purpose

This template guides you (or an AI assistant) to assess a Proxmox PVE host for **compliance**, **cyber security**, **resilience**, and **performance**.  
It provides a command-line checklist and a reporting structure with actionable recommendations and urgency ratings.

---

# Proxmox PVE Host Management Report – AI Prompt

> You are a senior Linux system administrator. You are given access to a Proxmox PVE host.  
> Your task is to generate a management report that rates the system in four areas:  
> - **Compliance** (with Proxmox and Linux best practices)  
> - **Cyber Security**  
> - **Resilience** (fault tolerance, backup, recovery)  
> - **Performance**  
>
> For each area:
> - Summarize findings in clear, simple language.
> - Highlight unique strengths and enterprise-grade features (e.g., dual ESP, ZFS mirrors, NVMe tier).
> - List any issues or deviations, with a recommended action and urgency:  
>   - **Critical** (fix now)  
>   - **High** (fix soon)  
>   - **Medium** (plan to fix)  
>   - **Low** (optional improvement)  
> - Provide a “Minor Improvements” section for cosmetic or low-urgency suggestions.
> - End with a summary table of ratings (1–5 stars per area), a prioritized action list, and “next steps” (e.g., “Would you like help with kernel cleanup or ZFS tuning?”).
>
> **Example Output:**  
> - “Your configuration is EXCELLENT – 98% Perfect! You have enterprise-grade boot and storage redundancy. Minor improvements: kernel cleanup, optional ZFS tuning.”

---

## 4. Improved Command-Line Checklist

```sh
# === Physical Disk Layout ===
lsblk -f

# === ESP Partition Details ===
blkid | grep -E "(C60D-29EE|C60D-B264)"   # Replace with your ESP UUIDs

# === EFI Boot Manager ===
efibootmgr -v

# === ZFS Pool Layout and Health ===
zpool list -v
zpool status
zpool events -v

# === ZFS Dataset Mountpoints and Tuning ===
zfs list -o name,mountpoint,canmount,mounted
zfs get all rpool | grep -E 'compression|atime|primarycache'
zfs get all tanka1 | grep -E 'compression|atime|primarycache'
zfs get all zfs-nvme-970PRO | grep -E 'compression|atime|primarycache'

# === Kernel Information and Cleanup ===
uname -r
dpkg -l | grep -E "(pve-kernel|proxmox-kernel)" | grep -v "^rc"
# To remove old kernels (after checking current kernel):
# apt remove <old-kernel-package>
# apt autoremove

# === VM/Container Disk Mapping ===
lsblk -f
zfs list -t volume

# === Proxmox Version and Updates ===
pveversion
apt update && apt list --upgradable

# === Storage Configuration ===
cat /etc/pve/storage.cfg

# === LXC and VM List ===
pct list
qm list

# === Security: Open Ports, Services, Users, Firewall ===
ss -tulpen
systemctl list-units --type=service --state=running
getent passwd | grep -E '/bin/bash|/bin/sh'
getent group sudo
apt list --upgradable | grep security
pve-firewall status
ufw status

# === Resilience: ZFS Scrubs, Backups, UPS ===
zpool history | grep scrub
cat /etc/pve/vzdump.cron
ls -lh /var/lib/vz/dump/
systemctl status nut-monitor

# === Performance: CPU, Memory, Disk, Errors ===
top -b -n1 | head -20
free -h
zpool iostat -v 2 5
dmesg | grep -i error
journalctl -p 3 -xb
smartctl -a /dev/sda
smartctl -a /dev/sdb
# (repeat for all disks)
```

## Action for administrators:

- Run the commands above on the target PVE host.
- Paste the outputs into the AI with the prompt above.
- The AI will generate a management report, ratings, and prioritized actions.

---

*Template version: 2024-07-15*