# Proxmox PVE Host Management Report Template

## Purpose

This template guides you (or an AI assistant) to assess a Proxmox PVE host for **compliance**, **cyber security**, **resilience**, and **performance**.  
It provides a command-line checklist and a reporting structure with actionable recommendations and urgency ratings.

---

## AI Prompt

> You are a senior Linux system administrator. You are given access to a Proxmox PVE host. Your task is to generate a management report that rates the system in four areas:  
> - **Compliance** (with Proxmox and Linux best practices)  
> - **Cyber Security**  
> - **Resilience** (fault tolerance, backup, recovery)  
> - **Performance**  
>
> For each area, use the command-line checklist below to gather evidence.  
> - Summarize findings in clear, simple language.  
> - For each issue, provide a recommended action and classify its urgency as:  
>   - **Critical** (fix now)  
>   - **High** (fix soon)  
>   - **Medium** (plan to fix)  
>   - **Low** (optional improvement)  
> - End with a summary table of ratings (1–5 stars per area) and a prioritized action list.

---

## Command-Line Checklist

### 1. Compliance

```sh
# Proxmox version and updates
pveversion
apt update && apt list --upgradable

# ZFS pool health and status
zpool status
zpool list

# ZFS dataset mountpoints
zfs list -o name,mountpoint,canmount,mounted

# /boot/efi mount and ESPs
lsblk -f | grep EFI
cat /etc/fstab | grep efi
mount | grep efi

# Storage configuration
cat /etc/pve/storage.cfg

# LXC and VM storage paths
pct list
qm list
```

### 2. Cyber Security

```sh
# Open ports and services
ss -tulpen
systemctl list-units --type=service --state=running

# User accounts and sudo/root access
getent passwd | grep -E '/bin/bash|/bin/sh'
getent group sudo

# Recent security updates
apt list --upgradable | grep security

# Firewall status
pve-firewall status
ufw status
```

### 3. Resilience

```sh
# ZFS redundancy and scrubs
zpool status
zpool history | grep scrub

# Backup schedules and status
cat /etc/pve/vzdump.cron
ls -lh /var/lib/vz/dump/

# UPS/Power protection (if applicable)
systemctl status nut-monitor
```

### 4. Performance

```sh
# CPU, memory, and disk usage
top -b -n1 | head -20
free -h
zpool iostat -v 2 5

# Hardware errors
dmesg | grep -i error
journalctl -p 3 -xb

# Disk health (repeat for all disks)
smartctl -a /dev/sda
smartctl -a /dev/sdb
```

---

## Example Report Structure

### Management Report for PVE Host: `hostname`

#### Compliance
- **Findings:** All ZFS pools healthy. /boot/efi correctly mounted. Proxmox version up to date.
- **Issues:** None.
- **Rating:** ★★★★★

#### Cyber Security
- **Findings:** Firewall enabled. All users accounted for. No pending security updates.
- **Issues:** SSH open to WAN (recommend restrict).
- **Rating:** ★★★★☆

#### Resilience
- **Findings:** ZFS mirror in place. Backups scheduled daily.
- **Issues:** Last ZFS scrub >30 days ago (recommend run now).
- **Rating:** ★★★★☆

#### Performance
- **Findings:** CPU and memory usage normal. No hardware errors.
- **Issues:** One disk with high reallocated sectors (monitor).
- **Rating:** ★★★★☆

---

### Prioritized Action List

| Action                                      | Urgency   |
|----------------------------------------------|-----------|
| Restrict SSH to LAN or use VPN               | High      |
| Run ZFS scrub on all pools                   | High      |
| Monitor disk sdb for further errors          | Medium    |

---

## Instructions

- Run the commands above on the target PVE host.
- Paste the outputs into the AI with the prompt above.
- The AI will generate a management report, ratings, and prioritized actions.

---

*Template version: 2024-07-15*