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

The tappaas-cicd update (its `pre-update.sh`) automatically deploys these files to the
firewall:

```bash
update-module.sh tappaas-cicd
```

Manual deployment (from tappaas-cicd):
```bash
cd /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/controller/opnsense-controller/patches

scp InterfaceAssignController.php \
    root@firewall.mgmt.internal:/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/

scp ACL.xml \
    root@firewall.mgmt.internal:/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/

ssh root@firewall.mgmt.internal "configctl webgui restart"
```

Then re-run `update-module.sh network`.

## Fresh installs: expected 404 until the patch is deployed

OPNsense ships **no** API for programmatic interface assignment — the
`/api/interfaces/interface_assign/*` endpoints exist only once this controller is
deployed. On a fresh OPNsense install from the prebuilt image the controller is absent,
so `zone-manager --execute` fails interface assignment with:

```
ERROR: API call failed | Response: {'status_code': 404, ...
'_content': b'{"errorMessage":"Endpoint not found"}'}
```

The standard bootstrap (`install.sh`) handles the ordering automatically:

1. `config-firewall.sh` — creates the OPNsense VM from the prebuilt image
2. `install-platform.sh` — creates the tappaas-cicd VM, runs `update-module.sh tappaas-cicd`
3. tappaas-cicd's `pre-update.sh` deploys this controller patch to the firewall
4. `update-module.sh network` — zone-manager now works

The 404s therefore only occur when running `update-module.sh network` **before**
`update-module.sh tappaas-cicd`, when deleting/reinstalling the firewall VM without
re-running the tappaas-cicd update, or when manually testing against a fresh firewall
that bypassed the standard install. They do not affect DNS or basic firewall operation —
zones show "enabled" but get no firewall interfaces until the controller is deployed.
Recover with the manual deployment above (or `update-module.sh tappaas-cicd`).

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
- Full investigation log preserved in git history (`ISSUES/opnsense-26.1-interface-assignment.md`, ISSUES/ cleanup #317)

## Credits

Original concept by [szymczag](https://github.com/szymczag), adapted and fixed for OPNsense 26.1 by TAPPaaS Team.
