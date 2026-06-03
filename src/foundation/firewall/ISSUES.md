# OPNsense Firewall Known Issues

## Unbound DNS Failure During Zone Configuration

**Issue ID:** UNBOUND-DNSBL-PYTHON
**Status:** Mitigated (update.sh reorders operations)
**Date Identified:** 2026-06-02
**Date Updated:** 2026-06-03

### Symptoms

- DNS resolution fails on the 10.0.0.0/24 management network
- Clients cannot resolve hostnames via the firewall at 10.0.0.1
- Issue surfaces during `zone-manager --execute` when creating new VLAN zones
- Error in Unbound logs: `ModuleNotFoundError: No module named 'dns'`

### Root Cause

OPNsense 25.x has a **Python version mismatch** between Unbound and dnspython:

- **Unbound** is compiled against **Python 3.11** (`libpython3.11.so.1.0`)
- **dnspython** is installed for **Python 3.13** (`py313-dnspython`)
- **py311-dnspython does not exist** in OPNsense package repositories

The `unbound.inc` PHP plugin **unconditionally** adds `python iterator` to the module-config (line 207) and includes the DNSBL python script (lines 388-389). When Unbound config is regenerated (via zone-manager API calls or OPNsense update), it fails to load the Python module:

```
Traceback (most recent call last):
  File "unbound-dnsbl/dnsbl_module.py", line 37, in <module>
    import dns
ModuleNotFoundError: No module named 'dns'
```

### Why the Prebuilt Image Works

The prebuilt OPNsense image includes a pre-generated `/var/unbound/unbound.conf` that works. Unbound starts successfully from this config. The problem occurs when **any operation regenerates the config**, because OPNsense always includes the Python module.

### Mitigation in update.sh

The `update.sh` script has been reordered to run OPNsense update and reboot **before** zone-manager:

1. `opnsense-update -bkp` - Update OPNsense packages
2. **Unconditional reboot** - Apply updates and regenerate configs
3. **Wait for firewall** - Ensure SSH is accessible
4. **DNS health check** - Verify Unbound is responding on 10.0.0.1
5. `zone-manager --execute` - Now runs after reboot

This ensures:

- OPNsense updates (which might fix the Python mismatch) are applied first
- Config regeneration happens during update/reboot, not during zone creation
- DNS failures are detected early, before zones are configured

### Additional Root Cause (Path Issue)

There's also a **relative path issue** with the DNSBL module. Two different code paths exist for starting Unbound:

| Method | Script | Has `cd /var/unbound/` | Result |
|--------|--------|------------------------|--------|
| `pluginctl -c unbound_start` | `/usr/local/opnsense/scripts/unbound/start.sh` | Yes (line 37) | **Works** |
| `service unbound restart` | `/usr/local/etc/rc.d/unbound` | No | **Fails** |

When Unbound is restarted via the `rc.d` script (e.g., `service unbound restart`), `unbound-checkconf` runs from the wrong directory and fails to find the DNSBL Python module:

```
pythonmod: can't open file unbound-dnsbl/dnsbl_module.py for reading
```

The OPNsense API and configd use `pluginctl`, which calls `start.sh` - this script correctly changes to `/var/unbound/` before running checkconf, so API-driven restarts work.

### When This Occurs

1. **Zone-manager creating new zones** - May trigger Unbound restart via a code path that uses `service unbound restart` instead of `pluginctl`
2. **Manual service restart** - Running `service unbound restart` directly on the firewall
3. **System boot edge cases** - If rc.d script runs before pluginctl takes over

### Diagnosis

On the firewall, check if Unbound is running and if checkconf passes:

```csh
service unbound status
unbound-checkconf /var/unbound/unbound.conf
```

If status shows running but checkconf fails with the `dnsbl_module.py` error, the current process is using an old (working) config but any restart will fail.

### Recovery Commands

When Unbound DNS fails, run this on the firewall to restore service:

```csh
pluginctl -c unbound_start
```

This uses the correct `start.sh` script which handles the working directory properly.

**Alternative** (more verbose, same effect):

```csh
cd /var/unbound && /usr/local/sbin/unbound-checkconf /var/unbound/unbound.conf && service unbound restart
```

### Permanent Fix Options

1. **Patch `unbound.inc` to remove Python module** - Change line 207 from `$module_config = 'python ';` to `$module_config = '';` and remove lines 388-389 (python: section). This disables the DNSBL Python integration. Note: This will be overwritten by OPNsense updates.

2. **Wait for OPNsense to fix the version mismatch** - Future OPNsense updates may ship py311-dnspython or recompile Unbound against Python 3.13.

3. **Patch `/usr/local/etc/rc.d/unbound`** - Add `cd /var/unbound` before the checkconf calls (lines 68 and 86). This fixes the path issue but not the Python version mismatch.

4. **Disable DNSBL entirely** - Remove the blocklist from OPNsense configuration so the Python module isn't needed. This removes DNS-level ad/malware blocking.

### Debug Instrumentation

The `zone_manager.py` includes debug instrumentation that checks Unbound DNS status (10.0.0.1:53) before and after key operations:

- `create_vlan()` - VLAN creation
- `apply_vlan_settings()` - Interface reconfiguration
- `set_dnsmasq_interfaces()` - Dnsmasq interface binding
- `dnsmasq reconfigure()` - DHCP service restart

Look for `[UNBOUND-CHECK]` messages in zone-manager output to identify exactly which operation triggers a failure.

### Related Files

- `/var/unbound/unbound.conf` - Unbound configuration (regenerated by OPNsense)
- `/var/unbound/unbound-dnsbl/dnsbl_module.py` - DNSBL Python module
- `/usr/local/opnsense/scripts/unbound/start.sh` - Working startup script (has `cd /var/unbound`)
- `/usr/local/etc/rc.d/unbound` - RC script (missing `cd /var/unbound`)
- `/usr/local/etc/inc/plugins.inc.d/unbound.inc` - PHP plugin that generates config
