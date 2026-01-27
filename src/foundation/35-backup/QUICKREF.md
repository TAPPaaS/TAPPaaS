# TAPPaaS Backup Quick Reference

Run all commands from `tappaas-cicd` as the `tappaas` user.

## Initial Setup

```bash
cd ~/TAPPaaS/src/foundation/35-backup

# 1. Install PBS on designated node
./install.sh

# 2. Configure PBS automatically (includes DNS setup)
./configure.sh
# (You'll be prompted for the tappaas password)
```

## Daily Operations

### Check Backup Status
```bash
./backup-manage.sh status          # Overview of PBS system
./backup-manage.sh list-jobs       # Show scheduled backup jobs
```

### Manual Backups
```bash
./backup-manage.sh run-now 101     # Backup single VM
./backup-manage.sh run-now-all     # Backup all VMs
```

### Restore Operations
```bash
# List available backups
./restore.sh --list-all            # All backups
./restore.sh --vmid 101 --list     # Backups for VM 101

# Restore VM
./restore.sh --vmid 101            # Restore latest backup
./restore.sh --vmid 101 --node tappaas2   # Restore to different node
```

### Maintenance
```bash
./backup-manage.sh prune           # Remove old backups per retention policy
./backup-manage.sh gc              # Free up disk space
./backup-manage.sh retention       # Show retention settings
```

## Common Scenarios

### Disaster Recovery - Full VM Restore
```bash
# 1. List available backups
./restore.sh --vmid <vmid> --list

# 2. Restore the VM
./restore.sh --vmid <vmid>

# 3. Start VM when prompted (or manually later)
```

### Test Restore to Different Node
```bash
# Restore to secondary node for testing without affecting production
./restore.sh --vmid 101 --node tappaas2 --storage tanka2
```

### Before Major Changes
```bash
# Backup specific VMs before risky operations
./backup-manage.sh run-now 101
./backup-manage.sh run-now 102
```

### Weekly Maintenance
```bash
# Check status and clean up
./backup-manage.sh status
./backup-manage.sh prune
./backup-manage.sh gc
```

## Troubleshooting

### Backup Failing
```bash
# Check PBS status
ssh root@backup.mgmt.internal "systemctl status proxmox-backup"

# Check disk space on PBS node
ssh root@backup.mgmt.internal "df -h"

# Check PBS logs
ssh root@backup.mgmt.internal "journalctl -u proxmox-backup -f"
```

### Restore Issues
```bash
# Verify backup integrity
./restore.sh --vmid 101 --list     # Check if backups exist

# Check storage availability on target node
ssh root@tappaas1.mgmt.internal "pvesm status"
```

### Full Disk
```bash
# Run garbage collection to free space
./backup-manage.sh gc

# Check if old backups should be pruned
./backup-manage.sh retention
./backup-manage.sh prune
```

## PBS GUI Access

URL: `https://<pbs-node-ip>:8007`

Login options:
- **root@pam** - Full administrative access
- **tappaas@pbs** - Backup operations only

## Important Files

- `backup.json` - PBS installation configuration
- `configure.sh` - Automated PBS setup
- `restore.sh` - VM restoration utility
- `backup-manage.sh` - Backup management operations

## Default Retention Policy

- Last 4 backups
- 14 daily backups (2 weeks)
- 8 weekly backups (2 months)
- 12 monthly backups (1 year)
- 6 yearly backups

## Emergency Contacts

For critical backup failures:
1. Check PBS GUI dashboard
2. Review system logs on PBS node
3. Verify network connectivity between nodes
4. Ensure adequate disk space on backup storage

## Best Practices

- Monitor backup job completion daily
- Test restore procedures monthly
- Keep PBS node updated
- Maintain off-site backup copy
- Document any configuration changes
