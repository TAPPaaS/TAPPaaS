# NetBird DNS Management Fix

## Problem

The code in `install.sh` lines 275-278 was executing but failing to preserve the original DNS configuration:

```bash
if [ -f /etc/resolv.conf.original.netbird ]; then
  cp /etc/resolv.conf.original.netbird /etc/resolv.conf
  chattr +i /etc/resolv.conf
fi
```

**Root Cause**: NetBird daemon continuously manages `/etc/resolv.conf` and immediately overwrites any changes. Even setting the immutable flag wasn't effective because NetBird had already modified the file or held it open.

## Solution Implemented

Updated the code to:
1. Stop NetBird service before modifying the file
2. Remove any existing immutable flag
3. Restore the original DNS configuration
4. Set the immutable flag
5. Restart NetBird service

**New Code**:
```bash
msg_info "Install netbird client:"
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Wait for NetBird to finish initial setup and create backup
sleep 2

if [ -f /etc/resolv.conf.original.netbird ]; then
  msg_info "Restoring original resolv.conf and preventing NetBird DNS management"

  # Stop NetBird service to prevent it from modifying resolv.conf
  systemctl stop netbird 2>/dev/null || true

  # Remove immutable flag if it was set by previous runs
  chattr -i /etc/resolv.conf 2>/dev/null || true

  # Restore original resolv.conf
  cp /etc/resolv.conf.original.netbird /etc/resolv.conf

  # Set immutable flag to prevent any modifications
  chattr +i /etc/resolv.conf

  # Restart NetBird - it will work but won't be able to modify DNS
  systemctl start netbird 2>/dev/null || true

  msg_ok "Restored original DNS configuration and protected resolv.conf"
else
  msg_info "NetBird backup file not found, keeping NetBird DNS settings"
fi

msg_ok "Installed netbird client"
```

## Test Results

Tested on `tappaas1.mgmt.internal`:

**Before Fix**:
```
search netbird.cloud mgmt.internal
nameserver 100.100.182.137  # NetBird's DNS
```

**After Fix**:
```
search mgmt.internal
nameserver 10.0.0.1  # Original DNS
```

**NetBird Status**: ✅ Still fully functional
```
Management: Connected
Signal: Connected
Relays: 4/4 Available
NetBird IP: 100.100.182.137/16
```

**File Protection**: ✅ Immutable flag active
```
----i---------e------- /etc/resolv.conf
```

## Key Improvements

1. **Added sleep 2**: Gives NetBird time to create the backup file
2. **Stop before modify**: Prevents race conditions with NetBird daemon
3. **Remove existing flag**: Handles re-runs and previous installations
4. **Error suppression**: `2>/dev/null || true` prevents script failures
5. **Better messaging**: User sees what's happening with DNS configuration

## Files Modified

- `/home/tappaas/TAPPaaS/src/foundation/05-ProxmoxNode/install.sh` (lines 273-279)

## Why This Matters

NetBird's DNS management can interfere with local network resolution, especially for:
- `.mgmt.internal` domain resolution
- Local service discovery
- Proxmox cluster communication
- TAPPaaS internal services

By preserving the original DNS configuration while keeping NetBird functional, we ensure both VPN connectivity and local network services work correctly.

---

**Status**: ✅ Fixed and tested
**Date**: 2026-02-16
