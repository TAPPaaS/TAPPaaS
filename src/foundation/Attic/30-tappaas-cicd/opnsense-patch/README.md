# OPNsense Custom Controllers

This directory contains custom OPNsense API controllers and ACL configurations required for TAPPaaS automated network management.

## Files

### InterfaceAssignController.php

Custom API controller for programmatic interface assignment in OPNsense 26.1+.

**Installation Path:**
```
/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/InterfaceAssignController.php
```

**API Endpoint:**
```
/api/interfaces/interface_assign/addItem
/api/interfaces/interface_assign/delItem/{interface}
```

**Features:**
- Assign VLAN devices to OPNsense interface slots (OPT1, OPT2, etc.)
- Configure static IPv4 addresses on interfaces
- Enable/disable interfaces
- Delete interface assignments
- Compatible with OPNsense 26.1+

**OPNsense 26.1 Compatibility:**

This controller was specifically designed for OPNsense 26.1+ after the original `AssignSettingsController` broke during the upgrade from 25.7. Key differences:

1. **Controller naming**: Uses `InterfaceAssignController` instead of `AssignSettingsController`
   - OPNsense 26.1 reserves the "SettingsController" suffix for Model-based controllers

2. **No sessionClose()**: Removed `$this->sessionClose()` calls
   - OPNsense 26.1 changed session handling, causing HTTP 500 errors with `sessionClose()`

3. **Direct Config API**: Uses `Config::getInstance()` and direct XML manipulation
   - Still extends `ApiControllerBase` (not `ApiMutableModelControllerBase`)

### ACL.xml

Access Control List configuration that grants API access to the interface assignment endpoints.

**Installation Path:**
```
/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/ACL.xml
```

**Patterns Included:**
```xml
<pattern>api/interfaces/assign_settings/*</pattern>  <!-- Legacy endpoint -->
<pattern>api/interfaces/interface_assign/*</pattern> <!-- Current endpoint -->
```

Both patterns are included for backward compatibility.

## Usage

### Assign Interface

```bash
curl -k -X POST -u "API_KEY:API_SECRET" \
     -H "Content-Type: application/json" \
     -d '{
           "assign": {
             "device": "vlan0.210",
             "description": "srv",
             "enable": true,
             "ipv4Address": "10.2.10.1",
             "ipv4Subnet": 24
           }
         }' \
     https://firewall.mgmt.internal/api/interfaces/interface_assign/addItem
```

**Response:**
```json
{"result":"saved","ifname":"opt1"}
```

### Delete Interface

```bash
curl -k -X POST -u "API_KEY:API_SECRET" \
     https://firewall.mgmt.internal/api/interfaces/interface_assign/delItem/opt1
```

**Response:**
```json
{"result":"deleted"}
```

## Deployment

The `update.sh` script automatically copies these files to the firewall:

```bash
cd /home/tappaas/TAPPaaS/src/foundation/30-tappaas-cicd
./update.sh tappaas-cicd
```

Manual deployment:
```bash
scp InterfaceAssignController.php root@firewall:/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/
scp ACL.xml root@firewall:/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/
ssh root@firewall "configctl webgui restart"
```

## History

### Original Implementation (OPNsense 25.7)
- Based on [GitHub Gist by szymczag](https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba)
- Controller: `AssignSettingsController.php`
- Endpoint: `/api/interfaces/assign_settings/addItem`
- Status: ❌ Broken in OPNsense 26.1

### Current Implementation (OPNsense 26.1+)
- Controller: `InterfaceAssignController.php` (this file)
- Endpoint: `/api/interfaces/interface_assign/addItem`
- Status: ✅ Working in OPNsense 26.1
- Fixed: February 2026
- See: `ISSUES/opnsense-26.1-interface-assignment.md` for full investigation details

## Credits

Original concept by [szymczag](https://github.com/szymczag), adapted and fixed for OPNsense 26.1 by TAPPaaS Team.
