# TAPPaaS Proxmox Backup Server (PBS) 

This module install PBS from official apt repository onto an existing TAPPaaS node.
the pbs.json define which node, and define the actual apt package to install

Consider editing the json before installing

## Install

### Step 1: Install PBS
Run the install script from the tappaas-cicd vm as the tappaas user:

```bash
cd ~/TAPPaaS/src/foundation/35-backup
chmod +x install.sh
./install.sh
```

### Step 2: Automated Configuration
After installation completes, run the automated configuration script:

```bash
chmod +x configure.sh
./configure.sh
```

This script will automatically:
1. Create the PBS datastore (tappaas_backup)
2. Create the tappaas@pbs user
3. Set permissions for the user on the datastore
4. Configure retention policy (4 last, 14 daily, 8 weekly, 12 monthly, 6 yearly)
5. Get the PBS fingerprint
6. Add PBS storage to Proxmox datacenter
7. Create a daily backup job at 21:00 for all VMs
8. Register DNS entry in OPNsense (backup.mgmt.internal)

**All configuration is now automated!** No manual steps required.

### Step 3 (Optional): Backup of Backup
Configure a remote PBS system to pull backups from your TAPPaaS PBS for off-site redundancy.

## Restore VMs from Backup

### List Available Backups
```bash
# List all backups
./restore.sh --list-all

# List backups for specific VM
./restore.sh --vmid 101 --list
```

### Restore a VM
```bash
# Restore latest backup of VMID 101
chmod +x restore.sh
./restore.sh --vmid 101

# Restore to specific node
./restore.sh --vmid 101 --node tappaas2

# Restore to different storage
./restore.sh --vmid 101 --storage tanka2

# Restore specific backup version
./restore.sh --vmid 101 --backup-id "tappaas_backup:backup/vm/101/2025-01-26T21:00:00Z"
```

The restore script will:
- Find the latest backup (or use specified backup)
- Check if VM exists and confirm overwrite if needed
- Restore the VM to the target node
- Optionally start the VM after restore

## Backup Management

Use the backup management script for common operations:

```bash
chmod +x backup-manage.sh

# Show backup status
./backup-manage.sh status

# List configured backup jobs
./backup-manage.sh list-jobs

# Run immediate backup for a specific VM
./backup-manage.sh run-now 101

# Backup all VMs immediately
./backup-manage.sh run-now-all

# Run prune operation (remove old backups per retention policy)
./backup-manage.sh prune

# Run garbage collection (free up disk space)
./backup-manage.sh gc

# Show retention policy
./backup-manage.sh retention
```

## Scripts Overview

All scripts should be run from tappaas-cicd as the tappaas user:

- [install.sh](install.sh) - Installs PBS on the designated node
- [configure.sh](configure.sh) - Automates PBS configuration (datastore, user, permissions, backup jobs, DNS)
- [restore.sh](restore.sh) - Automates VM restoration from backups with various options
- [backup-manage.sh](backup-manage.sh) - Common backup management operations

The DNS management is handled by the `dns-manager` command from the [OPNsense controller](../30-tappaas-cicd/opnsense-controller/).

## Accessing PBS GUI

Access the PBS web interface at: `https://<pbs-node-ip>:8007` or `https://backup.mgmt.internal:8007`
- Username: root@pam (for full admin) or tappaas@pbs (for backup operations)
- Password: Your tappaas node password
- Select "Linux PAM standard authentication" for root@pam

## Retention Policy

The default retention policy configured by [configure.sh](configure.sh):
- Keep Last: 4 (last 4 backups regardless of age)
- Keep Daily: 14 (one backup per day for 14 days)
- Keep Weekly: 8 (one backup per week for 8 weeks)
- Keep Monthly: 12 (one backup per month for 12 months)
- Keep Yearly: 6 (one backup per year for 6 years)

This provides approximately:
- Short-term: 2 weeks of daily backups
- Medium-term: 2 months of weekly backups
- Long-term: 1 year of monthly backups + 6 years of yearly backups

Adjust these values in [configure.sh](configure.sh) if needed before running.

# TODO
- Add encryption to backups
- Restrict backup user tappaas to only push and pull backups (currently has Admin role)
- Use API keys instead of passwords for authentication
- Add detailed documentation for backup-of-backup configuration
