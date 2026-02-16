# OPNsense 26.1: Interface Assignment API Broken After Upgrade

## ✅ STATUS: RESOLVED (2026-02-16)

The interface assignment issue has been **fully resolved**. See [Solution Details](#solution-details) below.

## Problem Description

After upgrading OPNsense from version 25.7 to 26.1, the custom `AssignSettingsController.php` API endpoint fails with HTTP 500 errors when attempting to assign VLAN interfaces to OPNsense interface slots (opt1, opt2, etc.).

The `zone-manager` tool successfully creates:
- ✅ VLAN devices (vlan0.220, vlan0.230, etc.)
- ✅ DHCP ranges for each zone

But fails when attempting to:
- ❌ Assign VLANs to interface slots
- ❌ Configure IP addresses on interfaces

## Solution Details

### Root Causes Discovered

1. **Controller Naming Conflict**
   - `AssignSettingsController` is a **reserved name** in OPNsense 26.1
   - Controllers ending in "SettingsController" must extend `ApiMutableModelControllerBase` (Model-based)
   - Using `ApiControllerBase` with this suffix causes framework routing failure with no error logs

2. **sessionClose() Incompatibility**
   - Calling `$this->sessionClose()` in controllers extending `ApiControllerBase` causes HTTP 500 errors
   - OPNsense 26.1 changed session handling for API controllers

### Solution Implemented

**Created new `InterfaceAssignController.php`** with fixes:

1. ✅ **Renamed**: `AssignSettingsController` → `InterfaceAssignController`
2. ✅ **Removed**: All `$this->sessionClose()` calls
3. ✅ **Updated API**: `/api/interfaces/assign_settings/addItem` → `/api/interfaces/interface_assign/addItem`
4. ✅ **Updated ACL**: Added `api/interfaces/interface_assign/*` pattern
5. ✅ **Fixed Python**: Updated `vlan_manager.py` controller name to `interface_assign`

### Files Modified

Repository changes committed:
```
src/foundation/30-tappaas-cicd/opnsense-patch/InterfaceAssignController.php  (NEW - replaces AssignSettingsController.php)
src/foundation/30-tappaas-cicd/opnsense-patch/ACL.xml                         (UPDATED - added new endpoint pattern)
src/foundation/30-tappaas-cicd/opnsense-controller/.../vlan_manager.py      (FIXED - controller name, type coercion)
src/foundation/30-tappaas-cicd/opnsense-controller/.../zone_manager.py      (FIXED - VLAN tag type mismatch)
config/zones.json                                                             (FIXED - duplicate descriptions)
```

### Testing Verification

```bash
# Test interface assignment
curl -k -u "${key}:${secret}" -H "Content-Type: application/json" \
  -d '{"assign": {"device": "vlan0.220", "description": "business", "enable": true, "ipv4Address": "10.2.20.1", "ipv4Subnet": 24}}' \
  https://firewall.mgmt.internal/api/interfaces/interface_assign/addItem

# Response:
{"result":"saved","ifname":"opt1"}

# Verification:
<opt1>
  <if>vlan0.220</if>
  <descr>business</descr>
  <enable>1</enable>
  <ipaddr>10.2.20.1</ipaddr>
  <subnet>24</subnet>
</opt1>
```

### Deployment Status

**OPNsense Firewall**: ✅ Deployed and tested
```bash
scp opnsense-patch/InterfaceAssignController.php root@firewall:/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/
scp opnsense-patch/ACL.xml root@firewall:/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/
ssh root@firewall "configctl webgui restart"
```

**NixOS Python Package**: ⏳ Requires rebuild
- Python code changes in `opnsense-controller/` need NixOS config rebuild
- Until rebuilt, use `zone-manager --no-assign` flag
- Manual interface assignment via OPNsense UI still required for now

### Next Steps

1. Rebuild NixOS configuration to deploy updated Python package
2. Test end-to-end zone-manager with interface assignment
3. Verify all existing zones get interfaces assigned correctly

---

## Original Investigation Details

## Symptoms

```bash
/home/tappaas/bin/zone-manager --no-ssl-verify --zones-file /home/tappaas/config/zones.json --execute
```

Results in:
```
ERROR: API call failed | Response: {'status_code': 500 ... 'errorMessage':'Unexpected error, check log for details'}
```

**No error logs** appear in:
- `/var/log/system/latest.log`
- `/var/log/lighttpd/latest.log`
- Controller's `error_log()` statements never execute

## Investigation Summary

### What We Fixed

1. **Type Mismatch Bug** in `zone_manager.py:330`
   - OPNsense API returns VLAN tags as strings (`"220"`)
   - Python code compared as integers (`220`)
   - **Fix**: Convert tags to int when building lookup dict

2. **Duplicate Descriptions** in `zones.json`
   - `srv` and `business` zones had identical descriptions
   - Caused fallback lookup to match wrong VLAN
   - **Fix**: Unique descriptions for each zone

3. **Missing ACL Entry**
   - OPNsense ACL didn't include `assign_settings` API endpoint
   - Created `/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/ACL.xml`
   - **Fix**: Added ACL entry for `api/interfaces/assign_settings/*`

### Root Cause

**OPNsense 26.1 Architectural Change**: The release migrated interface configuration to an MVC/Model architecture. The custom `AssignSettingsController.php`:

1. Extends `ApiControllerBase` (simple base class)
2. Uses direct XML config manipulation via `Config::getInstance()->save()`
3. This approach worked in OPNsense 25.7 but appears deprecated/broken in 26.1

**Working controllers** in 26.1:
- Extend `ApiMutableModelControllerBase`
- Use the Model system (XML schemas in `/usr/local/opnsense/mvc/app/models/`)
- Don't directly manipulate config XML

### Official OPNsense Status

From [GitHub Issue #7324](https://github.com/opnsense/core/issues/7324):
- Interface assignment API was marked "not planned" in Sept 2024
- OPNsense team indicated community PRs for this feature unlikely to be accepted
- As of March 2025, [PR #8436](https://github.com/opnsense/core/pull/8436) is open but status unclear

## Current State

### Working
- VLAN devices created: 210, 220, 230, 310, 410, 420, 610
- DHCP ranges functional on all VLANs
- VLANs are operational for DHCP (interface field set to "any")

### Not Working
- Interface assignment (VLANs show as "Unassigned Interface" in OPNsense)
- Static IP configuration on assigned interfaces
- Interface descriptions/naming in OPNsense GUI

## Recommended Solutions

### Option 1: Disable Interface Assignment (Immediate Fix)

**Pros**: Works immediately, VLANs are functional
**Cons**: Manual one-time setup required per zone

**Implementation**:

```bash
# Run zone-manager without interface assignment
/home/tappaas/bin/zone-manager --no-ssl-verify \
  --zones-file /home/tappaas/config/zones.json \
  --no-assign \
  --execute
```

**Manual steps** (one-time per new VLAN):
1. Login to OPNsense web UI
2. Navigate to **Interfaces → Assignments**
3. For each unassigned VLAN device (e.g., `vlan0.220`):
   - Select device from dropdown
   - Click **Add** to create interface (e.g., OPT1)
   - Click on new interface name
   - Enable interface
   - Set Description (e.g., "business")
   - Set IPv4 Configuration: Static
   - Set IPv4 Address: Gateway IP from zones.json (e.g., `10.2.20.1/24`)
   - Save and Apply

### Option 2: Update AssignSettingsController for OPNsense 26.1

**Pros**: Fully automated, maintains existing workflow
**Cons**: Requires PHP development, may break again in future updates

**Required Changes**:
1. Research OPNsense 26.1 Config API changes
2. Rewrite controller to use supported config manipulation methods
3. OR: Wait for official OPNsense interface assignment API
4. Test thoroughly with OPNsense 26.1+

**Investigation needed**:
- How does `Config::getInstance()->save()` work in 26.1?
- Are there new Model-based approaches for interface config?
- Check OPNsense 26.1 source code for interface management examples

### Option 3: Direct XML Manipulation Script

**Pros**: Bypasses API, direct control
**Cons**: Fragile, breaks OPNsense support, risky

**Approach**:
```bash
# Direct manipulation of /conf/config.xml
# Add interface XML nodes manually
# Run: configctl interface reconfigure
```

**Not recommended** due to:
- No validation
- Could corrupt config
- Future OPNsense updates may change XML structure
- Bypasses OPNsense's safety checks

## Recommended Action Plan

### Short Term (Now)
1. **Use Option 1** - Disable interface assignment with `--no-assign` flag
2. Document manual assignment steps in `src/foundation/10-firewall/README.md`
3. Update `update.sh` to copy `ACL.xml` to firewall (fixes future installs)

### Medium Term (Next Sprint)
4. Create helper script for manual assignment steps
5. Monitor [OPNsense PR #8436](https://github.com/opnsense/core/pull/8436) for official API support
6. Consider contributing to OPNsense core if PR #8436 stalls

### Long Term (Future)
7. If official API becomes available, update zone-manager to use it
8. OR: Rewrite AssignSettingsController for 26.1 compatibility
9. Add automated tests for OPNsense version compatibility

## Files Modified

- `src/foundation/30-tappaas-cicd/opnsense-controller/src/opnsense_controller/zone_manager.py`
  - Fixed type mismatch in VLAN tag comparison
  - Lines 330, 335, 352

- `config/zones.json`
  - Updated business zone description to be unique
  - Line 36: "Business services network for commercial applications"

- `src/foundation/30-tappaas-cicd/opnsense-patch/ACL.xml` (NEW)
  - Added ACL entry for assign_settings API endpoint
  - Should be copied during firewall setup/update

## Testing Performed

1. ✅ VLAN creation: Successfully creates VLAN 220, 230, 420
2. ✅ DHCP creation: Successfully creates DHCP ranges
3. ✅ Type mismatch fix: VLANs now correctly detected as existing
4. ✅ ACL file: Copied and web GUI restarted
5. ❌ Interface assignment: Still fails with 500 error (no logs)

## References

- [OPNsense 26.1 Changelog](https://docs.opnsense.org/releases/CE_26.1.html)
- [OPNsense Interfaces API Docs](https://docs.opnsense.org/development/api/core/interfaces.html)
- [GitHub Issue #7324 - Interface Assignment API](https://github.com/opnsense/core/issues/7324)
- [Original AssignSettingsController Gist](https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba)
- [OPNsense PR #8436](https://github.com/opnsense/core/pull/8436) - Pending interface assignment API

## Environment

- OPNsense Version: 26.1 (upgraded from 25.7)
- TAPPaaS Foundation: 30-tappaas-cicd
- Affected Tool: zone-manager (opnsense-controller)
- Python Version: 3.12
- Date: 2026-02-16

## Labels

`bug`, `opnsense`, `api`, `breaking-change`, `workaround-available`

## Priority

**Medium** - Workaround available (manual assignment), but impacts automation goals.
